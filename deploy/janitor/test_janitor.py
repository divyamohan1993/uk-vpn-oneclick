"""Unit tests for the janitor's pure decision logic. Run: python test_janitor.py
No AWS, no boto3, no network. Exits non-zero on any failure."""
from datetime import datetime, timezone, timedelta

from janitor import instances_to_delete, TAG_KEY, TAG_VALUE, EXPIRES_TAG

NOW = 1_800_000_000  # fixed "now" epoch for deterministic tests


def inst(name, *, tag=True, expires=None, created=None, extra_tags=None):
    tags = []
    if tag:
        tags.append({"key": TAG_KEY, "value": TAG_VALUE})
    if expires is not None:
        tags.append({"key": EXPIRES_TAG, "value": str(expires)})
    for k, v in (extra_tags or {}):
        tags.append({"key": k, "value": v})
    d = {"name": name, "tags": tags}
    if created is not None:
        d["createdAt"] = created
    return d


def names(result):
    return sorted(n for n, _ in result)


def reason_of(result, name):
    return dict(result).get(name)


def run():
    iso_now = datetime.fromtimestamp(NOW, tz=timezone.utc)
    young = iso_now - timedelta(hours=2)        # 2h old
    old = iso_now - timedelta(hours=30)         # 30h old (> 24h hard cap)

    cases = []

    # 1. Not ours -> never deleted, regardless of expiry/age.
    foreign = inst("not-ours", tag=False, expires=NOW - 9999, created=old)
    # 2. Ours, expired -> deleted.
    expired = inst("expired", expires=NOW - 60, created=young)
    # 3. Ours, future expiry, young -> kept.
    future = inst("future", expires=NOW + 18000, created=young)
    # 4. Ours, no expires tag, old (>24h) -> deleted by hard cap.
    capped = inst("capped", expires=None, created=old)
    # 5. Ours, no expires tag, young -> kept (can't reason, leave it).
    young_untagged = inst("young-untagged", expires=None, created=young)
    # 6. Ours, garbage expires tag -> deleted (fail safe).
    garbage = inst("garbage", expires="not-a-number", created=young)
    # 7. Ours, FUTURE expiry but OLD box -> hard cap wins (anti-tamper).
    tampered = inst("tampered", expires=NOW + 10_000_000, created=old)
    # 8. Ours, expired, createdAt as ISO string -> still deleted (parser handles ISO).
    expired_iso = inst("expired-iso", expires=NOW - 1, created=young.isoformat())

    pool = [foreign, expired, future, capped, young_untagged, garbage, tampered, expired_iso]
    result = instances_to_delete(pool, NOW)
    got = names(result)
    want = sorted(["expired", "capped", "garbage", "tampered", "expired-iso"])
    assert got == want, f"FAIL set: got {got}, want {want}"

    assert reason_of(result, "expired") == "expired"
    assert reason_of(result, "capped") == "hard-cap-24h"
    assert reason_of(result, "garbage") == "bad-expires-tag"
    assert reason_of(result, "tampered") == "hard-cap-24h"
    assert "not-ours" not in got
    assert "future" not in got
    assert "young-untagged" not in got

    # 9. createdAt as real datetime (what boto3 returns) works for the hard cap.
    dt_old = inst("dt-old", expires=None, created=old)  # already datetime
    assert names(instances_to_delete([dt_old], NOW)) == ["dt-old"]

    # 10. Empty + no-tags-at-all are safe no-ops.
    assert instances_to_delete([], NOW) == []
    assert instances_to_delete([{"name": "bare"}], NOW) == []

    print("all janitor unit tests passed")


if __name__ == "__main__":
    run()
