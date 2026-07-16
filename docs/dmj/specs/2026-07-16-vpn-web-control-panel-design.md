# VPN web control panel (serverless, WireGuard-only) — Design v2

- Date: 2026-07-16
- Status: PROPOSED — awaiting user approval (revised after security + pre-mortem review)
- Tier: Heavy (public web endpoint, auth, secrets, money, deletion)

## Problem

Replace `connect.bat`/`destroy.bat` for casual use with a **web page**: Start / Stop
buttons, live status, a password gate so others can't abuse it, and from the page a QR
(phone) / `.conf` + one-click installer (laptop) to connect. 5h auto-delete still applies.
Auto-deploy from GitHub on push.

## Key decisions (user-approved)

WireGuard-only; abuse posture = password + rate-limit + budget (no WAF v1); password hashed
in Lambda env. **Design change from review: WireGuard keys are generated ON THE BOX**, not
in the Lambda (no custom crypto, and readiness = key-availability).

## Architecture

- **One control Lambda** (`uk-vpn-control`, Python 3.12) behind an **API Gateway HTTP API**
  (public HTTPS, proxy → Lambda). Serves UI + `/api/*`.
  - Designed as a Function URL (`AuthType=NONE`), but that is **refused on this account**:
    403 at the URL auth layer despite a correct public resource policy, while an IAM-signed
    request to the same URL returns 200 — the *public* path is blocked, not the function.
    CloudFront+OAC in front of it was also refused. **API Gateway works** (invokes via
    `lambda:InvokeFunction`, same payload-format-2.0 event ⇒ handler unchanged). Proven live.
  - **Reserved concurrency** is skipped when the account Lambda limit is <15 (this account:
    10, a new-account default); that account-wide cap is itself the flood bound.
  - IAM, learned live: `lightsail:TagResource` is **required** (we tag on create), and an
    `aws:RequestedRegion` condition on the Lightsail statement **denies** CreateInstances
    (Lightsail doesn't populate that key) — the app validates the region instead.
- **Box**: Lightsail `nano_3_0`, name `uk-vpn-web`, created in the **user-selected region**
  (AZ `<region>a`) from a fixed **allow-list** (default London). Exit country = selected
  region. WireGuard-only, self-installs via cloud-init `user-data`. Tags
  `created-by=uk-vpn-oneclick` + `expires-at=now+5h` ⇒ janitor reaps it. Firewall set to
  **only UDP 51820** (PutInstancePublicPorts replaces the whole set, dropping default SSH 22).
- **Exactly one box, ever** (any region): enforced by the DynamoDB mutex below. `Start`
  while one runs returns the existing box (+ its region); to **change region**, `Stop` then
  `Start` elsewhere. The `config` item records the box's region so status/config/stop query
  the right one.

### Region allow-list (selectable exit)

A fixed server-side list (rejects anything else). Starter set — each is a Lightsail region
with `nano_3_0`, one AZ used (`<region>a`):

| UI label | region |
|---|---|
| London, UK (default) | eu-west-2 |
| Frankfurt, Germany | eu-central-1 |
| Dublin, Ireland | eu-west-1 |
| Stockholm, Sweden | eu-north-1 |
| Virginia, US-East | us-east-1 |
| Oregon, US-West | us-west-2 |
| Montreal, Canada | ca-central-1 |
| Mumbai, India | ap-south-1 |
| Singapore | ap-southeast-1 |
| Tokyo, Japan | ap-northeast-1 |
| Sydney, Australia | ap-southeast-2 |

The list lives in ONE place (Lambda + janitor share it via an env var) so they never drift.
- **Box generates its own keys** (`wg genkey`/`pubkey`/`genpsk`) on boot, brings up
  `wg-quick@wg0`, then **POSTs `{client_privkey, server_pubkey, psk, ready}` + a per-launch
  register token to `/api/ready`**. The Lambda stores the client material. The **server
  privkey never leaves the box** (not in user-data/CloudTrail/SSM).
- **State: one DynamoDB table** `uk-vpn-control` (on-demand, encrypted at rest w/ the
  AWS-managed key, **TTL enabled**). Items: `lock` (single-box mutex), `rate#<ip>` (per-IP
  attempts), `config` (current box's client material + register-token hash). Atomic
  conditional writes give the mutex + lockout the atomicity SSM lacks.
- **Janitor**: must now scan **every allow-list region** (a box can be anywhere), not just
  eu-west-2. This is a CHANGE to the already-deployed janitor: `janitor.py` loops the region
  list (from a shared env var), and its `DeleteInstance` IAM widens to those regions. Its
  tag logic (created-by + expires-at / 24h cap) is unchanged. Redeploy it as part of this
  work (then CI/CD keeps both Lambdas current).

## Endpoints (Function URL, path-routed)

| Route | Method | Auth | Action |
|---|---|---|---|
| `/` | GET | none | HTML UI (Start/Stop, status poll, password field). Sets security headers. |
| `/api/start` | POST | password + `X-CSRF` | body `{region}` (validated vs allow-list) → lock (atomic) → create box in that region → `starting` |
| `/api/ready` | POST | register token | box calls back with its keys → store `config`, mark ready |
| `/api/status` | GET | session | `stopped`/`starting`(box up, no beacon yet)/`running`(beacon in)+IP |
| `/api/config` | GET | session | ready → client `.conf` (+ `DNS=1.1.1.1`) + QR + static installer |
| `/api/stop` | POST | session + `X-CSRF` | delete box (tag-gated) → then clear `config`/`lock` → `stopped` |

## Auth & abuse control

- Password = **PBKDF2-HMAC-SHA256, 600k iters, hex salt+hash in the Lambda env** (never
  plaintext; strong password enforced at deploy). Verify with `hmac.compare_digest`.
  (Deviation from CLAUDE.md Argon2id is deliberate: keeps the Lambda a pure-stdlib zip; on
  record.)
- **Lockout, per-IP (`requestContext.http.sourceIp`), password-checked such that a correct
  password always succeeds** (lockout only delays wrong-guessers — never a self-DoS of the
  owner). Read `locked_until` from DynamoDB and reject **before** running PBKDF2 (no CPU
  amplification). Counter via DynamoDB atomic `UpdateItem ADD` + conditional write + TTL;
  **fail CLOSED** if DynamoDB errors.
- **Reserved concurrency = 5** on the Lambda: the ONLY real-time spend cap (budget alerts
  lag hours). Caps a flood's Lambda cost and blast radius.
- **CSRF**: state-changing routes require a custom header `X-CSRF: 1` (browsers can't send
  it cross-site without a preflight the server never grants). `/api/start` also needs the
  password in-body. Fail closed on missing/invalid session.
- **Session**: HMAC-signed bearer token (`expiry|nonce`, secret in env), ~2h, returned in
  the body and sent back as `Authorization: Bearer` (no cookie ⇒ no CSRF/SameSite surface).
  Constant-time verify; server-side expiry. Revocation = rotate the env secret (documented).
- **CORS OFF** (UI + API same-origin). Never reflect `Origin` with credentials.
- **Security headers** on every response: `Content-Security-Policy` (self + inline nonce),
  `HSTS`, `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`,
  `Cache-Control: no-store` on `/api/config`.
- **No secrets in logs**: log only `sourceIp + route + outcome`; never bodies/keys.

## Box `user-data` (WireGuard-only, self-registering)

Quoted heredoc (`<<'EOF'`, no shell expansion of anything request-derived — nothing
request-derived is injected). Steps: wait for the apt/dpkg lock
(`apt-get -o DPkg::Lock::Timeout=180`) → install wireguard qrencode → `wg genkey|pubkey`
for server+client + `wg genpsk` → write `wg0.conf` (server priv, client-pub peer, PSK,
`PostUp` NAT+forward on detected WAN) → `ip_forward=1` → `systemctl enable --now
wg-quick@wg0` → **only after wg is up**, `curl -fsS -X POST <FUNCURL>/api/ready` with the
register token + client material + this box's public IP. Install/҃bring-up failure ⇒ beacon
never fires ⇒ `/status` stays `starting` (never false-ready). IMDSv2 + hop-limit 1.

## IAM (control Lambda role, least privilege)

- `lightsail`: `GetInstances`, `GetInstance`, `CreateInstances`, `DeleteInstance`,
  `PutInstancePublicPorts` — with `aws:RequestedRegion` restricted to the **region
  allow-list** (not a single region). Widens blast radius to those regions only; reserved
  concurrency + the one-box mutex still bound cost.
- `dynamodb`: `GetItem/PutItem/UpdateItem/DeleteItem` on the one table ARN.
- `logs`: write. Nothing else. Compromise ⇒ churn eu-west-2 Lightsail + the one table only.
- Residual: `CreateInstances` can't be resource-scoped; reserved concurrency bounds the
  rate; the janitor only reaps **tagged** boxes, so the deploy also adds a **cheap periodic
  check that flags ANY eu-west-2 Lightsail instance the tool didn't create** (untagged-box
  cost guard). Documented residual.

## CI/CD — auto-deploy from GitHub on push

- `.github/workflows/deploy.yml`: on push to `main` touching `deploy/**`, **GitHub OIDC**
  → assume a scoped AWS role `uk-vpn-gha-deploy` (trust locked to
  `repo:divyamohan1993/uk-vpn-oneclick:ref:refs/heads/main`) → `aws lambda
  update-function-code` for `uk-vpn-control` (+ `uk-vpn-janitor`). **No AWS keys stored in
  GitHub** (OIDC issues short-lived creds). Role limited to `lambda:UpdateFunctionCode`
  (+`UpdateFunctionConfiguration`) on the two function ARNs, region-conditioned.
- One-time setup (in `setup-control`): create the GitHub OIDC identity provider (if absent)
  + the `uk-vpn-gha-deploy` role with that tight trust. Idempotent.

## Cost — ₹0 standing (guarded)

Free at this usage: Lambda (idle-free, reserved-conc has no charge), Function URL, DynamoDB
on-demand (25 GB free) w/ the **AWS-managed** encryption key, CloudWatch Logs (1-day
retention), SSM not used. Only the `nano_3_0` box bills while up (~₹0.58/h), reaped ≤5h.
**Keep OFF (would bill):** customer-managed KMS key, SSM Advanced params, Lightsail static
IP (detached) or snapshots. One metered edge: VPN traffic counts against the bundle's
transfer quota (low risk personal). `$0.01` budget alert already guards surprises.

## Acceptance criteria

API-checkable:
1. `GET /` → 200 HTML with Start/Stop/Status.
2. `/api/start` without/wrong password or missing `X-CSRF` → 401/403; **no box created**.
3. Right password + a valid region → exactly ONE `uk-vpn-web` box in `<region>a`, tags
   `created-by` + `expires-at≈now+18000`; a 2nd concurrent start (any region) creates **no**
   second box (mutex). An off-allow-list region → 400, no box.
4. Before the beacon, `/api/status` = `starting`; after `/api/ready`, `running`+IP.
5. `/api/stop` → box deleted, then `config`/`lock` cleared, status `stopped`.
6. `git grep` shows no plaintext password/keys; env holds only the PBKDF2 hash + session
   secret; DynamoDB items encrypted at rest.
7. N wrong passwords from an IP → that IP locked; correct password still succeeds.
8. `setup-control` re-run = idempotent (no dup Function URL/role/table).
9. Push to `main` triggers the workflow → `uk-vpn-control` code updated via OIDC (no keys).

E2E (needs a real wg client + geo check, run manually):
10. Scan QR / import `.conf` → connected, **exit IP matches the selected region's country**,
    DNS resolves (no blackhole). Switching region (Stop → Start elsewhere) moves the exit.

## Assumption ledger

- A1-A2 CONFIRMED (WireGuard-only; password+rate-limit+budget; hash in env).
- A3 (revised): **keys generated on the box** (`wg` tools) — removes the pure-Python X25519
  need. `segno` (pure-Python) still used for the QR. Lambda stays a self-contained zip.
- A4: `nano_3_0` fine for WireGuard-only (no compile).
- A5: single box enforced by the **atomic DynamoDB mutex** (with a TTL'd stale-lock
  release), not a check-then-act.
- A6: deploy needs admin creds (have `claude-admin`); CI/CD thereafter via OIDC.
- A7 (residual, on record): a leaked Function-URL + leaked password = attacker gets a VPN
  on the owner's AWS account (abuse/attribution risk). Mitigations: strong password, per-IP
  lockout, reserved concurrency, source-IP logging, budget alert. Treat the URL as a secret.

## Rollout

1. **Spike** (disposable worktree): prove the box user-data self-install + `/api/ready`
   beacon end-to-end (install under apt-lock, wg up, callback received). Cross-check a box
   `wg pubkey` + a live handshake. Discard code; keep evidence.
2. Build: Lambda (`deploy/control/`), UI (inline HTML), `setup-control.ps1`/`.sh`,
   `teardown-control`, `.github/workflows/deploy.yml`.
3. Deploy (admin profile) → API smoke tests → live e2e (start → QR → GB → stop).
4. Defer candidate if timeline slips: the cross-platform one-click installer — ship QR +
   `.conf` first, installer as fast-follow (QR/.conf cover phone + laptop already).
