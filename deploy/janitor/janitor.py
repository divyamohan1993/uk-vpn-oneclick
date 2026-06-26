"""
uk-vpn-oneclick janitor - deletes EXPIRED ephemeral VPN instances.

Runs as an AWS Lambda on a 15-minute EventBridge schedule. It only ever touches
Lightsail instances tagged created-by=uk-vpn-oneclick, and only deletes one when:
  * its `expires-at` tag (epoch seconds) is in the past, OR
  * it is older than the 24h hard cap (covers a missing/tampered expires-at tag).

Anything not carrying our tag is never read past the tag check and never deleted.
The decision logic (`instances_to_delete`) is a pure function so it unit-tests with
no AWS calls. See test_janitor.py.
"""
import os
import time
from datetime import datetime

TAG_KEY = "created-by"
TAG_VALUE = "uk-vpn-oneclick"
EXPIRES_TAG = "expires-at"
HARD_CAP_SECONDS = 24 * 3600
REGION = os.environ.get("TARGET_REGION", "eu-west-2")


def _tag(instance, key):
    for t in instance.get("tags") or []:
        if t.get("key") == key:
            return t.get("value")
    return None


def _to_epoch(value):
    """Accept a datetime, an int/float epoch, or an ISO-8601 string; else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if hasattr(value, "timestamp"):
        try:
            return value.timestamp()
        except Exception:
            return None
    if isinstance(value, str):
        s = value.strip()
        try:
            return float(s)            # epoch-seconds string, e.g. our expires-at tag
        except ValueError:
            pass
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()  # ISO-8601
        except ValueError:
            return None
    return None


def instances_to_delete(instances, now_epoch):
    """Pure decision: names+reasons of OUR instances that are expired or past 24h.

    Fail-safe rules:
      - not tagged created-by=uk-vpn-oneclick -> NEVER deleted.
      - expires-at in the past -> delete ("expired").
      - expires-at unparseable -> delete ("bad-expires-tag") (don't let a garbage
        tag keep a box alive forever).
      - age > 24h -> delete ("hard-cap-24h") even if expires-at is missing or set to
        the future (anti-tamper). Hard cap wins over a future expiry.
      - ours, no/var expires-at, age <= 24h, age unknown -> LEFT ALONE (destroy.bat
        is the backstop; we never nuke a young box we can't reason about).
    """
    doomed = []
    for inst in instances:
        if _tag(inst, TAG_KEY) != TAG_VALUE:
            continue
        name = inst.get("name")
        if not name:
            continue
        reason = None

        exp = _tag(inst, EXPIRES_TAG)
        if exp is not None:
            exp_epoch = _to_epoch(exp)
            if exp_epoch is None:
                reason = "bad-expires-tag"
            elif now_epoch >= exp_epoch:
                reason = "expired"

        created_epoch = _to_epoch(inst.get("createdAt"))
        if created_epoch is not None and (now_epoch - created_epoch) > HARD_CAP_SECONDS:
            reason = reason or "hard-cap-24h"

        if reason:
            doomed.append((name, reason))
    return doomed


def _get_all_instances(client):
    instances, token = [], None
    while True:
        resp = client.get_instances(pageToken=token) if token else client.get_instances()
        instances.extend(resp.get("instances", []))
        token = resp.get("nextPageToken")
        if not token:
            break
    return instances


def handler(event, context):
    import boto3  # imported here so the pure logic above tests without boto3 installed
    client = boto3.client("lightsail", region_name=REGION)
    now_epoch = time.time()
    instances = _get_all_instances(client)
    doomed = instances_to_delete(instances, now_epoch)

    deleted = []
    for name, reason in doomed:
        try:
            client.delete_instance(instanceName=name)
            deleted.append({"name": name, "reason": reason})
            print(f"deleted {name} ({reason})")
        except Exception as e:  # noqa: BLE001 - log and continue; next run retries
            print(f"ERROR deleting {name}: {type(e).__name__}: {e}")

    print(f"janitor: scanned {len(instances)} instance(s) in {REGION}, deleted {len(deleted)}")
    return {"scanned": len(instances), "deleted": deleted}
