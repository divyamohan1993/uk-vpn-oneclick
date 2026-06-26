# Ephemeral self-deleting UK VPN + AWS-CLI-gated join — Design

- Date: 2026-06-26
- Status: APPROVED (user, in-conversation, 2026-06-26)
- Tier: Heavy (security, destructive automation, new IAM, cost)

## Problem

Adding a device today means copying the `uk-vpn-devices` bundle between machines by
hand, and a created VPS bills until someone remembers `destroy.bat`. The user wants:
a device with the AWS CLI already authenticated to just double-click and join (no
password, no file shuffling), the VPS to self-delete after ~5h so a forgotten box
can't run up a bill or stay attackable, and the public repo to stay worthless if
leaked. Destroying the VPS is the ultimate kill switch.

## Goals

1. **Ambient AWS creds are the only gate.** A laptop with `aws configure` done runs
   one script and joins; a laptop without creds does nothing (safe). No app password.
2. **Ephemeral VPS**: tagged `expires-at = now+5h`; auto-deleted within ~15 min of
   expiry, with a 24h hard backstop, by an off-VM janitor.
3. **Zero standing cost**, proven against AWS Always-Free (Lambda 1M req + 400k GB-s;
   CloudWatch Logs 5GB — perpetual; EventBridge scheduled rules carry no per-trigger
   charge). Lambda has no idle cost (no provisioned concurrency).
4. **Secret-free public repo**; no Cloudflare; the VPS holds only VPN config and never
   any credential that outlives it.
5. Adding a laptop is hands-off: auto-claim a device slot (no prompt), and the tool
   cleans up only the VPN entries it previously created on that device.

## Non-goals

- No passphrase / no `config.enc` / no external store (explicitly dropped by the user).
- No sliding TTL extension (hard 5h from creation; re-join after expiry = fresh box).
- No WireGuard-on-laptop (laptops use the native Windows IKEv2 VPN; phones use WG QR).
- >10 devices per VPS (cap at the 10 generated slots; expandable later).

## Architecture

### [A] Janitor (off-VM auto-delete) — one-time deploy
- **Trigger**: EventBridge scheduled rule, `rate(15 minutes)`. NOTE: the janitor scans
  one region (`TARGET_REGION`); it MUST match connect.ps1's `$Region` (both default
  eu-west-2) or instances in the other region never auto-delete.
- **Compute**: one Lambda (Python 3.12, 128 MB, on-demand — no provisioned concurrency).
- **Logic**: list Lightsail instances tagged `created-by=uk-vpn-oneclick`; delete any
  where `now >= expires-at`, OR where `now - createdAt > 24h` (hard backstop against a
  missing/tampered `expires-at`). Idempotent; delete-not-found is a no-op.
- **IAM**: execution role scoped to `lightsail:GetInstances`, `lightsail:DeleteInstance`,
  and CloudWatch Logs write. No stored access keys anywhere.
- **Cost controls baked in**: 1-day CloudWatch Logs retention; no provisioned
  concurrency; a `$0.01` AWS Budget alarm as a tripwire. Verified ₹0 within Always-Free.
- **Setup/teardown**: `setup-janitor.ps1` / `teardown-janitor.ps1`. Setup needs one-time
  admin-ish creds (CreateRole/CreateFunction/CreateSchedule); laptops never get these.

### [B] join — the double-click button (`connect.bat` / `join.bat` alias)
- Uses ambient AWS creds (existing `Assert-AwsCredentials`).
- create-or-join: find the account's instance tagged `created-by=uk-vpn-oneclick` and
  not expired → join; else create + tag `created-by` and `expires-at = now+5h`.
- **Auto-claim a device slot** from a VM-side registry keyed by this laptop's stable
  machine id (`Win32_ComputerSystemProduct.UUID`): same machine → same slot on re-runs;
  a fresh machine → lowest free slot. No prompt. flock'd on the VM against races.
- Pull `device-N.p12` + CA over SSH (existing), import, (re)create the single fixed-name
  Windows VPN entry, connect.
- **VPN-entry cleanup**: before creating, remove only entries this tool recorded in
  local state (`created-vpns.json`); never touches the user's other VPNs.

### [C] Phones — unchanged (WireGuard QR from the bundle).

### [D] `destroy.bat` — manual backstop (tag-gated delete + local cleanup). Janitor stays.

## Security model

- **Gate**: ambient AWS creds. Stolen unlocked laptop ⇒ attacker can spin/join (cost +
  VPN abuse); auto-delete caps the window; that is the user-accepted boundary.
- **Repo**: scripts + IaC only; `grep` shows zero secrets. Leak ⇒ nothing.
- **VPS**: only VPN config; no AWS/CF/personal data; root of VPS ⇒ throwaway VPN only.
- **Laptop creds** stay Lightsail-only (janitor adds none). **Janitor role** is delete-
  only on Lightsail; compromise ⇒ at worst deletes VPN instances (DoS), no data.
- **Tag tamper / missing tag** can't keep a box alive past the **24h hard cap**.

## Acceptance criteria (machine-checkable)

1. `connect` tags a created instance with `expires-at` = epoch(now)+18000 (±120s).
2. Janitor unit test: given instances with past/future `expires-at` and ages, it returns
   exactly the expired-or->24h ones for deletion and none else.
3. Deployed janitor deletes a backdated-tag test instance within ~15 min; spares a
   future-tag one.
4. Two machine-ids claim two distinct slots from the registry; the same machine-id
   re-claims its first slot. No IKEv2 lease collision.
5. Re-running join leaves exactly one VPN entry named `UK VPN (one-click)`.
6. `git grep -iE '(aws_secret|BEGIN .*PRIVATE|password=)'` over tracked files = empty.
7. `destroy.bat` removes the VPS and the local VPN entry; janitor untouched.
8. `setup-janitor` is idempotent (re-run = no duplicate role/schedule/function error).

## Assumption ledger

- A1 (CONFIRMED): user deploys `setup-janitor` once with admin creds; narrow
  `lightsail-vpn` user cannot create Lambda/IAM/Scheduler.
- A2 (CONFIRMED): hard 5h TTL from creation, no extension.
- A3 (CONFIRMED): cap 10 devices/VPS.
- A4 (CONFIRMED): janitor frequency 15 min.
- A5 (CONFIRMED): cost must be ₹0 forever — verified against AWS Always-Free pricing
  pages (Lambda idle = no charge; usage ≤0.3% of every relevant free limit).
- A6 (ASSUMED): the user's account keeps Always-Free (existing/legacy account). If it is
  a post-2025 new account on the Free *Plan*, Always-Free still applies; only the trial
  differs. Budget alarm is the safety net either way.

## Rollout

1. Land code + unit tests (no AWS).
2. User runs `setup-janitor.ps1` once (admin creds) → janitor live + budget alarm.
3. Live test: create with a backdated `expires-at`, confirm deletion ≤15 min.
4. `teardown-janitor.ps1` proven to remove everything.
