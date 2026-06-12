# Security model

A short, honest account of what's protected and how.

## Network exposure

The server's firewall (set declaratively each run) allows exactly three ports:

| Port | Who can reach it | Why |
|---|---|---|
| 22/TCP (SSH) | **Only your PC's current public IP** (`/32`) | one-time install; nobody else can even attempt SSH |
| 500/UDP (IKE) | Internet | VPN handshake, protected by certificate auth |
| 4500/UDP (IPsec NAT-T) | Internet | encrypted tunnel through home NAT |

Everything else is closed. The VPN ports are internet-facing by necessity, but
an attacker without the client certificate cannot establish a tunnel.

## Authentication & crypto

- **IKEv2 with X.509 machine certificates** (RSA). Only a device holding the
  client `.p12` can connect, there is no password to guess or spray.
- **Encryption:** AES-256 with SHA-256 integrity, DH Group 14. Negotiated
  parameters are pinned on the Windows side to match the server.
- The server CA is imported into *Trusted Root* on your machine **only** so your
  PC can validate this one server. `destroy.bat` removes it again.

## Secrets handling

- **Your AWS keys** live solely in your local `aws configure` profile
  (`%USERPROFILE%\.aws`). They are never read into, printed by, or stored by this
  tool, and never touch the repo.
- **The IPsec PSK and the client `.p12` password** are randomly generated on
  every run. The `.p12` password exists only in memory during setup; the cert
  files live in `%LOCALAPPDATA%\uk-vpn-oneclick\` and are wiped on teardown.
- **`.gitignore`** blocks `*.pem`, `*.p12`, `state.json`, etc. as a second line
  of defence, but secrets are kept outside the repo directory in the first place.
- **Least privilege:** the recommended IAM user is scoped to `lightsail:*` only.
  You can delete that user entirely when you stop using the tool.

## Teardown leaves nothing behind

`destroy.ps1` removes, in order: the Windows VPN connection, the client and CA
certificates, the Lightsail instance (stops billing), and all local key/cert/
state files. After it runs, there is no residual access path and no ongoing cost.

## Known trade-offs (no spin)

- **Supply chain:** the server install pulls the hwdsl2 installer from
  `get.vpnsetup.net` (a redirect to its GitHub `master`). It's a widely used,
  open-source project, but you are trusting it at install time. To harden, pin
  the install URL in `scripts/common.ps1` to a specific commit you've reviewed.
- **Single-tenant by IP:** the firewall pins SSH to the IP you had when you ran
  `connect`. If your home IP changes, SSH would be blocked, but you don't need
  SSH after setup, and the VPN itself keeps working.
- **Machine certificate store:** the client cert is installed machine-wide
  (required for the native IKEv2 connection). Any admin on the PC could use the
  connection until `destroy.bat` removes it.
