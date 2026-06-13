# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [1.2.1] - 2026-06-13

### Fixed
- **A second IKEv2 device no longer knocks the first offline.** Every IKEv2 device
  shared one client cert (`vpnclient`), so two devices, especially behind one
  router/public IP, collapsed into a single connection slot on the server and evicted
  each other (the newer connection kicked the older to "connection timed out"). The
  server now generates **10 distinct IKEv2 identities** (`device-1`..`device-10`), one
  per device, mirroring the WireGuard peers, so they get distinct leases and coexist.
  Root-caused from the live pluto log (every device landed on the same lease
  `192.168.43.10`); fix **verified live before shipping**: two real laptops on the same
  WiFi (same public IP), distinct certs, held concurrent tunnels (leases `.10` + `.11`)
  with zero cross-eviction while a 4K stream kept running.

### Changed
- **IKEv2 is now per-device, like WireGuard.** `connect.bat`: the laptop that creates
  the server takes `device-1`; an additional laptop is asked once for its own number
  (2-10, cached in state). `add-windows-device.bat` asks which `device-N` to use. The
  device bundle now ships `device-1.p12`..`device-10.p12` + matching
  `.mobileconfig`/`.sswan` instead of a single `vpnclient.*`. A lost device can be
  revoked on its own (`ikev2.sh --revokeclient device-N`).

## [1.2.0] - 2026-06-13

### Added
- **Tag-gated teardown.** Every instance this tool creates is stamped with a
  `created-by=uk-vpn-oneclick` tag *at creation* (atomic, so even a half-finished
  create is cleanable). `destroy.bat` now deletes **only** instances carrying that
  tag, so a same-named Lightsail instance you made by hand is never touched. If an
  untagged same-named instance exists, destroy refuses and prints the exact manual
  delete command instead. `connect.bat` self-heals the tag on the join path for any
  instance that predates this change. Verified live: real create stamps the tag,
  `Get-OurInstances` matches exactly the one box.

### Changed
- **Default bundle `micro_3_0` -> `nano_3_0`** ($7 -> $5/mo, ~₹0.82 -> ₹0.58/hr).
  Verified end-to-end on a live box: Libreswan compiles on 512 MB via the existing
  2 GB swap, VPN connects with a GB exit IP. One line in `connect.ps1` reverts to
  `micro_3_0` for more RAM headroom if ever needed.
- `destroy.bat` reads region/instance from saved state (falling back to defaults)
  rather than assuming hardcoded values; deletion is driven by the ownership tag.

## [1.1.1] - 2026-06-13

### Fixed
- **WireGuard "connected but no internet."** The WireGuard FORWARD ACCEPT rules
  were appended *after* hwdsl2's catch-all `FORWARD -j DROP`, so forwarded packets
  were dropped, the tunnel handshook but no traffic flowed. They're now inserted at
  the top of the chain (`-I FORWARD`). IKEv2 was unaffected. Found via a phone on
  mobile data; fixed on the live server and in the install script.

## [1.1.0] - 2026-06-12

### Added
- **Multi-device support.** The server now also runs **WireGuard** alongside IKEv2
  and pre-generates 10 ready peers, each as a scannable **QR code**.
- `connect.bat` now drops a `uk-vpn-devices` folder on the Desktop with every
  client config: WireGuard QRs/`.conf`, the iPhone one-tap `.mobileconfig`, the
  Android strongSwan `.sswan`, the Windows/Linux `.p12` + CA, and the server IP.
- `add-windows-device.bat` - puts an extra Windows laptop on the running VPN
  (no AWS needed; reads the device bundle).
- `setup-linux.sh` - one-click WireGuard for Linux.
- `docs/devices-guide.md` - per-device steps (Android/iPhone/Windows/Linux/Mac),
  copied into the bundle as `READ-ME-FIRST.md`.
- `.gitattributes` - keeps `*.sh` LF so it runs on Linux when cloned on Windows.

### Changed
- Firewall now also opens UDP 51820 (WireGuard).
- `destroy.bat` also wipes the `uk-vpn-devices` bundle (those keys are secrets).

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
