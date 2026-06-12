# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [1.0.0] - 2026-06-11

### Added
- `connect.bat` / `destroy.bat` one-click (self-elevating) launchers.
- `scripts/connect.ps1` - provisions a London AWS Lightsail box, installs an
  IKEv2/IPsec VPN (strongSwan/Libreswan via the hwdsl2 installer), locks the
  firewall, imports the client certificate, and connects Windows to it.
- `scripts/destroy.ps1` - removes the Windows VPN connection, certificates,
  the Lightsail instance, and all local secrets; returns ongoing cost to zero.
- `scripts/common.ps1` - shared helpers (aws wrapper, ssh/scp, state, logging).
- Docs: `README.md`, `docs/how-it-works.md`, `docs/security.md`,
  `docs/troubleshooting.md`.

### Notes
- Encodes hard-won lessons from a live setup: `micro_3_0` (1 GB) to survive the
  Libreswan compile, base64-piped remote scripts to avoid PowerShell->ssh
  quoting bugs, a re-exported client `.p12` with a known password, and IKEv2
  (not L2TP, which fails behind AWS NAT with error 809).
