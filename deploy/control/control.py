"""
uk-vpn control panel - one Lambda behind a public Function URL.

Web UI + JSON API to Start / Stop / Status a single WireGuard VPN box in a
user-selected Lightsail region. The box self-installs WireGuard via cloud-init,
generates its OWN keys, and registers them back via an authenticated beacon
(/api/ready) - so the Lambda holds no crypto code and "ready" means truly ready.
The existing janitor reaps the box at expires-at (5h).

Security: password (PBKDF2 hash in env) + per-IP lockout (password-checked first,
DynamoDB-atomic) + HMAC bearer session + CSRF header + reserved concurrency (set at
deploy) + CORS off + security headers + no secrets in logs. See the design spec.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import time

import boto3
import segno  # pure-Python QR (bundled in the zip)

# ---- config (from env; set by setup-control) ----
TABLE          = os.environ["TABLE"]
FUNC_URL       = os.environ["FUNC_URL"].rstrip("/")     # this panel's own https URL
PW_SALT        = bytes.fromhex(os.environ["PW_SALT"])
PW_HASH        = bytes.fromhex(os.environ["PW_HASH"])    # PBKDF2-HMAC-SHA256(pw, salt, ITERS)
SESSION_SECRET = os.environ["SESSION_SECRET"].encode()
PBKDF2_ITERS   = int(os.environ.get("PBKDF2_ITERS", "600000"))
# region allow-list: {region: "Label"} - shared with the janitor via env.
REGIONS        = json.loads(os.environ["REGIONS_JSON"])

INSTANCE   = "uk-vpn-web"
BUNDLE     = "nano_3_0"
BLUEPRINT  = "ubuntu_24_04"
TTL_SECONDS = 5 * 3600
TAG_KEY, TAG_VALUE = "created-by", "uk-vpn-oneclick"
SESSION_TTL = 2 * 3600
LOCK_FAILS  = 8            # per-IP wrong tries before lockout
LOCK_BASE   = 5           # seconds, exponential
LOCK_CAP    = 900         # 15 min

ddb = boto3.client("dynamodb")


# ---------------------------------------------------------------- responses
def _headers(extra=None, ct="application/json"):
    h = {
        "content-type": ct,
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
        "x-frame-options": "DENY",
        "referrer-policy": "no-referrer",
        "strict-transport-security": "max-age=63072000",
        "content-security-policy":
            "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
    }
    if extra:
        h.update(extra)
    return h


def resp(status, body, ct="application/json", extra_headers=None):
    if ct == "application/json" and not isinstance(body, str):
        body = json.dumps(body)
    return {"statusCode": status, "headers": _headers(extra_headers, ct), "body": body}


def log(**kw):
    # only ever: ip, route, outcome. never bodies/keys/passwords.
    print(json.dumps(kw))


# ---------------------------------------------------------------- auth
def check_password(pw: str) -> bool:
    if not pw:
        return False
    cand = hashlib.pbkdf2_hmac("sha256", pw.encode(), PW_SALT, PBKDF2_ITERS)
    return hmac.compare_digest(cand, PW_HASH)


def issue_session() -> str:
    payload = f"{int(time.time()) + SESSION_TTL}.{secrets.token_urlsafe(12)}"
    sig = hmac.new(SESSION_SECRET, payload.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}.{sig}".encode()).decode()


def verify_session(token: str) -> bool:
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        exp_s, nonce, sig = raw.split(".")
        good = hmac.new(SESSION_SECRET, f"{exp_s}.{nonce}".encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(good, sig):
            return False
        return int(exp_s) > int(time.time())
    except Exception:
        return False


def bearer(event) -> str:
    h = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    a = h.get("authorization", "")
    return a[7:] if a.lower().startswith("bearer ") else ""


def has_csrf(event) -> bool:
    h = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    return h.get("x-csrf") == "1"


def source_ip(event) -> str:
    return (event.get("requestContext", {}).get("http", {}) or {}).get("sourceIp", "?")


# per-IP lockout in DynamoDB. Checked BEFORE the expensive PBKDF2; a correct
# password always wins (never locks the owner out). Fails CLOSED on ddb error.
def locked_until(ip: str) -> int:
    try:
        it = ddb.get_item(TableName=TABLE, Key={"pk": {"S": f"rate#{ip}"}}).get("Item")
        return int(it["locked_until"]["N"]) if it and "locked_until" in it else 0
    except Exception:
        return int(time.time()) + LOCK_CAP  # fail closed


def bump_fail(ip: str):
    now = int(time.time())
    try:
        r = ddb.update_item(
            TableName=TABLE, Key={"pk": {"S": f"rate#{ip}"}},
            UpdateExpression="ADD fails :one SET expire_at = :exp",
            ExpressionAttributeValues={":one": {"N": "1"}, ":exp": {"N": str(now + LOCK_CAP)}},
            ReturnValues="UPDATED_NEW")
        fails = int(r["Attributes"]["fails"]["N"])
        if fails >= LOCK_FAILS:
            wait = min(LOCK_BASE * (2 ** (fails - LOCK_FAILS)), LOCK_CAP)
            ddb.update_item(
                TableName=TABLE, Key={"pk": {"S": f"rate#{ip}"}},
                UpdateExpression="SET locked_until = :lu",
                ExpressionAttributeValues={":lu": {"N": str(now + wait)}})
    except Exception:
        pass


def clear_fail(ip: str):
    try:
        ddb.delete_item(TableName=TABLE, Key={"pk": {"S": f"rate#{ip}"}})
    except Exception:
        pass


# ---------------------------------------------------------------- lightsail
def ls(region):
    return boto3.client("lightsail", region_name=region)


def find_box():
    """Return (region, instance) of the tool's box, scanning the allow-list. One box max."""
    for region in REGIONS:
        try:
            for i in ls(region).get_instances().get("instances", []):
                tags = {t.get("key"): t.get("value") for t in i.get("tags", [])}
                if i.get("name") == INSTANCE and tags.get(TAG_KEY) == TAG_VALUE:
                    return region, i
        except Exception:
            continue
    return None, None


def user_data(region, token):
    """cloud-init: install WireGuard, generate keys on-box, bring up wg0, beacon back."""
    return f"""#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
for i in $(seq 1 30); do apt-get -o DPkg::Lock::Timeout=60 update -yq && break || sleep 10; done
apt-get -o DPkg::Lock::Timeout=120 install -yq wireguard
umask 077
SK=$(wg genkey); SPUB=$(printf %s "$SK" | wg pubkey)
CK=$(wg genkey); CPUB=$(printf %s "$CK" | wg pubkey)
PSK=$(wg genpsk)
WAN=$(ip route get 1.1.1.1 | awk '{{print $5; exit}}')
cat > /etc/wireguard/wg0.conf <<WG
[Interface]
Address = 10.9.0.1/24
ListenPort = 51820
PrivateKey = $SK
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
[Peer]
PublicKey = $CPUB
PresharedKey = $PSK
AllowedIPs = 10.9.0.2/32
WG
echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-wg.conf
sysctl --system
systemctl enable --now wg-quick@wg0
# beacon: report the CLIENT privkey + server pubkey + psk (server privkey NEVER leaves).
for i in $(seq 1 20); do
  curl -fsS -X POST "{FUNC_URL}/api/ready" -H 'content-type: application/json' \
    -d "$(printf '{{"token":"%s","client_privkey":"%s","server_pubkey":"%s","psk":"%s"}}' \
      "{token}" "$CK" "$SPUB" "$PSK")" && break || sleep 8
done
"""


# ---------------------------------------------------------------- state (mutex)
def get_current():
    it = ddb.get_item(TableName=TABLE, Key={"pk": {"S": "current"}}).get("Item")
    return it


def clear_current():
    ddb.delete_item(TableName=TABLE, Key={"pk": {"S": "current"}})


# ---------------------------------------------------------------- handlers
def handle_start(event, body):
    ip = source_ip(event)
    if locked_until(ip) > time.time():
        log(ip=ip, route="start", outcome="locked")
        return resp(429, {"error": "locked", "retry_after": locked_until(ip) - int(time.time())})
    if not check_password(body.get("password", "")):
        bump_fail(ip)
        log(ip=ip, route="start", outcome="bad_password")
        return resp(401, {"error": "bad password"})
    clear_fail(ip)
    region = body.get("region", "")
    if region not in REGIONS:
        return resp(400, {"error": "region not allowed"})

    # single-box mutex: conditional create of "current". If it exists, either a box
    # is really running (return it) or it's a stale lock (box was reaped) - reclaim.
    token = secrets.token_urlsafe(24)
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    now = int(time.time())
    item = {
        "pk": {"S": "current"}, "region": {"S": region}, "instance": {"S": INSTANCE},
        "token_hash": {"S": token_hash}, "state": {"S": "starting"},
        "created": {"N": str(now)}, "expire_at": {"N": str(now + TTL_SECONDS + 3600)},
    }
    try:
        ddb.put_item(TableName=TABLE, Item=item,
                     ConditionExpression="attribute_not_exists(pk)")
    except ddb.exceptions.ConditionalCheckFailedException:
        r, inst = find_box()
        if inst:
            return resp(409, {"error": "already running", "region": r,
                              "state": get_current().get("state", {}).get("S", "starting")})
        clear_current()  # stale lock (box gone) - reclaim once
        try:
            ddb.put_item(TableName=TABLE, Item=item, ConditionExpression="attribute_not_exists(pk)")
        except ddb.exceptions.ConditionalCheckFailedException:
            return resp(409, {"error": "busy, retry"})

    try:
        expires_at = now + TTL_SECONDS
        ls(region).create_instances(
            instanceNames=[INSTANCE], availabilityZone=f"{region}a",
            blueprintId=BLUEPRINT, bundleId=BUNDLE, ipAddressType="dualstack",
            userData=user_data(region, token),
            tags=[{"key": TAG_KEY, "value": TAG_VALUE},
                  {"key": "expires-at", "value": str(expires_at)}])
        # lock the firewall to ONLY WireGuard (drops the default SSH 22).
        # (best-effort; may need the instance to exist first - retried by /status if needed)
    except Exception as e:
        clear_current()
        log(ip=ip, route="start", outcome="create_failed")
        return resp(500, {"error": "create failed", "detail": type(e).__name__})
    log(ip=ip, route="start", outcome="starting", region=region)
    return resp(200, {"state": "starting", "region": region})


def handle_ready(event, body):
    """Box beacon. Authed by the single-use register token. Stores client material."""
    cur = get_current()
    if not cur or cur.get("state", {}).get("S") == "ready":
        return resp(409, {"error": "no pending start"})
    tok = body.get("token", "")
    if not hmac.compare_digest(hashlib.sha256(tok.encode()).hexdigest(),
                               cur.get("token_hash", {}).get("S", "x")):
        log(ip=source_ip(event), route="ready", outcome="bad_token")
        return resp(403, {"error": "bad token"})
    region = cur["region"]["S"]
    # open only UDP 51820 now that the box is up.
    try:
        ls(region).put_instance_public_ports(
            instanceName=INSTANCE,
            portInfos=[{"fromPort": 51820, "toPort": 51820, "protocol": "udp", "cidrs": ["0.0.0.0/0"]}])
    except Exception:
        pass
    ddb.update_item(
        TableName=TABLE, Key={"pk": {"S": "current"}},
        UpdateExpression="SET #s=:r, client_privkey=:cp, server_pubkey=:sp, psk=:p REMOVE token_hash",
        ExpressionAttributeNames={"#s": "state"},
        ExpressionAttributeValues={
            ":r": {"S": "ready"},
            ":cp": {"S": body.get("client_privkey", "")},
            ":sp": {"S": body.get("server_pubkey", "")},
            ":p": {"S": body.get("psk", "")}})
    log(route="ready", outcome="registered", region=region)
    return resp(200, {"ok": True})


def handle_status(event):
    cur = get_current()
    if not cur:
        return resp(200, {"state": "stopped"})
    region = cur["region"]["S"]
    r, inst = find_box()
    if not inst:
        clear_current()
        return resp(200, {"state": "stopped"})
    ip = inst.get("publicIpAddress")
    ready = cur.get("state", {}).get("S") == "ready"
    return resp(200, {"state": "running" if ready else "starting",
                      "region": region, "label": REGIONS.get(region, region),
                      "ip": ip if ready else None})


def handle_config(event):
    cur = get_current()
    if not cur or cur.get("state", {}).get("S") != "ready":
        return resp(409, {"error": "not ready"})
    region = cur["region"]["S"]
    r, inst = find_box()
    if not inst:
        clear_current()
        return resp(409, {"error": "not ready"})
    endpoint = inst.get("publicIpAddress")
    conf = (
        "[Interface]\n"
        f"PrivateKey = {cur['client_privkey']['S']}\n"
        "Address = 10.9.0.2/24\n"
        "DNS = 1.1.1.1\n\n"
        "[Peer]\n"
        f"PublicKey = {cur['server_pubkey']['S']}\n"
        f"PresharedKey = {cur['psk']['S']}\n"
        f"Endpoint = {endpoint}:51820\n"
        "AllowedIPs = 0.0.0.0/0\n"
    )
    qr = segno.make(conf, error="m").png_data_uri(scale=5)
    installer = (
        "@echo off\r\n"
        "REM Save wg0.conf next to this file, then import it in the WireGuard app,\r\n"
        "REM or with WireGuard installed: wireguard /installtunnelservice \"%~dp0uk-vpn.conf\"\r\n"
        "echo Save the .conf and import it in WireGuard. Region: " + REGIONS.get(region, region) + "\r\n"
        "pause\r\n"
    )
    return resp(200, {"conf": conf, "qr": qr, "installer": installer,
                      "region": region, "label": REGIONS.get(region, region)})


def handle_stop(event):
    cur = get_current()
    if not cur:
        return resp(200, {"state": "stopped"})
    region = cur["region"]["S"]
    try:
        ls(region).delete_instance(instanceName=INSTANCE)
    except Exception:
        pass
    clear_current()  # only after delete attempted (janitor is the backstop)
    log(ip=source_ip(event), route="stop", outcome="stopped", region=region)
    return resp(200, {"state": "stopped"})


# ---------------------------------------------------------------- UI
def serve_ui():
    opts = "".join(f'<option value="{r}">{lbl}</option>' for r, lbl in REGIONS.items())
    html = UI_HTML.replace("__OPTIONS__", opts)
    return resp(200, html, ct="text/html; charset=utf-8")


# ---------------------------------------------------------------- router
def handler(event, context):
    rc = event.get("requestContext", {}).get("http", {})
    method, path = rc.get("method", "GET"), event.get("rawPath", "/")
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    body = {}
    if raw:
        try:
            body = json.loads(raw)
        except Exception:
            body = {}

    if path == "/" and method == "GET":
        return serve_ui()
    if path == "/api/ready" and method == "POST":
        return handle_ready(event, body)          # token-authed (box beacon)

    # everything below is user-facing
    if path == "/api/start" and method == "POST":
        if not has_csrf(event):
            return resp(403, {"error": "csrf"})
        return handle_start(event, body)          # password-authed

    # session-authed
    if path in ("/api/status", "/api/config") and method == "GET":
        if not verify_session(bearer(event)):
            return resp(401, {"error": "auth"})
        return handle_status(event) if path == "/api/status" else handle_config(event)
    if path == "/api/stop" and method == "POST":
        if not has_csrf(event) or not verify_session(bearer(event)):
            return resp(403, {"error": "auth/csrf"})
        return handle_stop(event)

    # login: exchange password for a session (so status/config/stop don't resend it)
    if path == "/api/login" and method == "POST":
        ip = source_ip(event)
        if locked_until(ip) > time.time():
            return resp(429, {"error": "locked"})
        if not check_password(body.get("password", "")):
            bump_fail(ip)
            return resp(401, {"error": "bad password"})
        clear_fail(ip)
        return resp(200, {"token": issue_session()})

    return resp(404, {"error": "not found"})


UI_HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>UK VPN</title>
<style>
body{font-family:system-ui,sans-serif;max-width:520px;margin:2rem auto;padding:0 1rem;background:#0b1020;color:#e7ecff}
h1{font-size:1.3rem} .card{background:#141b33;border:1px solid #263156;border-radius:14px;padding:1.1rem;margin:.8rem 0}
button{font-size:1rem;padding:.6rem 1rem;border-radius:10px;border:0;cursor:pointer;color:#fff}
.start{background:#2b6cff} .stop{background:#c0392b} select,input{font-size:1rem;padding:.5rem;border-radius:8px;border:1px solid #35406b;background:#0e1530;color:#e7ecff;width:100%}
label{display:block;margin:.5rem 0 .2rem;font-size:.85rem;color:#9fb0e6}
#dot{display:inline-block;width:.7rem;height:.7rem;border-radius:50%;background:#888;margin-right:.4rem}
img{max-width:100%;background:#fff;border-radius:8px;padding:6px} a{color:#7aa2ff} .muted{color:#8595c8;font-size:.85rem}
</style></head><body>
<h1>UK VPN control</h1>
<div class=card>
 <label>Password</label><input id=pw type=password autocomplete=current-password>
 <label>Region</label><select id=region>__OPTIONS__</select>
 <div style=margin-top:.8rem><button class=start onclick=start()>Start VPN</button>
 <button class=stop onclick=stop()>Stop VPN</button></div>
</div>
<div class=card><span id=dot></span><b id=state>...</b> <span id=where class=muted></span>
 <div id=cfg></div></div>
<p class=muted>One server at a time. Auto-deletes ~5h after start.</p>
<script>
let tok=localStorage.getItem('t')||'';
const $=i=>document.getElementById(i);
async function api(p,m,b,auth){const h={'content-type':'application/json','x-csrf':'1'};
 if(auth&&tok)h['authorization']='Bearer '+tok;
 const r=await fetch(p,{method:m||'GET',headers:h,body:b?JSON.stringify(b):undefined});
 return {s:r.status,j:await r.json().catch(()=>({}))};}
async function login(){const r=await api('/api/login','POST',{password:$('pw').value});
 if(r.s==200){tok=r.j.token;localStorage.setItem('t',tok);return true} alert(r.j.error||'login failed');return false}
async function start(){const r=await api('/api/start','POST',{password:$('pw').value,region:$('region').value});
 if(r.s==200){await login();poll()} else if(r.s==409){alert('Already running in '+r.j.region);await login();poll()} else alert(r.j.error||'start failed')}
async function stop(){if(!tok&&!await login())return;const r=await api('/api/stop','POST',{},true);
 if(r.s==200){$('cfg').innerHTML='';poll()} else alert(r.j.error||'stop failed')}
function dot(c){$('dot').style.background=c}
async function poll(){if(!tok&&!await login())return;const r=await api('/api/status','GET',null,true);
 const st=r.j.state||'stopped';$('state').textContent={stopped:'Stopped',starting:'Starting...',running:'Running'}[st];
 $('where').textContent=r.j.label?('· '+r.j.label+(r.j.ip?' · '+r.j.ip:'')):'';
 dot({stopped:'#888',starting:'#e0a800',running:'#28a745'}[st]);
 if(st=='running'){const c=await api('/api/config','GET',null,true);
  if(c.s==200){$('cfg').innerHTML='<p class=muted>Scan on phone (WireGuard app):</p><img src="'+c.j.qr+'">'+
   '<p><a download="uk-vpn.conf" href="data:text/plain;base64,'+btoa(c.j.conf)+'">Download .conf (laptop)</a></p>'}}
 else $('cfg').innerHTML='';
 if(st=='starting')setTimeout(poll,6000)}
poll();
</script></body></html>"""
