# How it works

## The picture

```
   Your Windows PC (Delhi)                         AWS Lightsail (London)
  +-----------------------+                       +------------------------+
  |  Native Windows VPN   |   IKEv2/IPsec tunnel  |  Libreswan (strongSwan |
  |  client (IKEv2)       |======================>|  family) IKEv2 server  |
  |  full-tunnel: ALL     |   UDP 500 + 4500      |                        |
  |  traffic goes to UK   |   AES-256 / SHA-256   |  NATs your traffic out |
  +-----------------------+                       |  a UK public IP        |
            |                                     +-----------+------------+
            | all your internet traffic                      |
            | now exits from London  <-----------------------+
            v
        Netflix / websites see a UK IP
```

You connect to the London box over an encrypted IKEv2 tunnel. Because it's a
**full tunnel**, every packet from your PC goes to London first and exits to the
internet from there, so the outside world sees a UK IP, and your ISP only sees
encrypted traffic to one address.

## What `connect.ps1` does, step by step

1. **Checks prerequisites** - admin rights (needed to install a machine
   certificate), the AWS CLI (installs it via winget if missing), and that your
   AWS credentials work (`aws sts get-caller-identity`).

2. **Create-or-join** - if an instance named `uk-vpn-oneclick` already exists, it
   **joins** this device to it (no new server, no extra cost) instead of spending on
   a second one; otherwise it creates one. Either way, only `destroy.bat` stops billing.

3. **Creates the server** - `aws lightsail create-instances`, Ubuntu 24.04,
   bundle `nano_3_0` in `eu-west-2` (London), dual-stack so it gets a public
   IPv4 your home connection can reach. The instance is **tagged**
   `created-by=uk-vpn-oneclick` at creation, which is the only thing teardown
   trusts (see below).

4. **Locks the firewall** - `put-instance-public-ports` sets the *complete*
   rule set: SSH (22/TCP) only from your PC's current public IP, and the VPN
   ports (500/UDP, 4500/UDP) open to the internet but protected by certificate
   auth. Nothing else is reachable.

5. **Gets an SSH key** - downloads the Lightsail default key pair and restricts
   its file permissions with `icacls` (OpenSSH refuses a world-readable key).

6. **Installs the VPN** - over SSH it runs the
   [hwdsl2 IPsec installer](https://github.com/hwdsl2/setup-ipsec-vpn), which
   compiles and configures Libreswan, then generates **10 distinct IKEv2 client
   identities** (`device-1`..`device-10`) - one per device, mirroring the WireGuard
   peers - alongside the WireGuard setup. The script is sent **base64-encoded** and
   piped to `sudo bash` so PowerShell never mangles the quoting.

7. **Exports this device's identity** - each `device-N` is bundled three ways: a
   `.p12` re-exported with a freshly generated, *known* password (for Windows import),
   plus the iOS `.mobileconfig` / Android `.sswan` straight from the installer. This
   laptop pulls down its own `device-N.p12` and the CA certificate.

8. **Configures Windows** - imports the CA into *Trusted Root* (so the server
   cert validates), imports this device's `device-N` `.p12` into the machine's
   *Personal* store, then creates an IKEv2 connection using **machine-certificate**
   auth and a crypto policy proven to match the server.

9. **Connects and verifies** - dials the connection and queries a geo-IP API.
   If your IP now resolves to `GB`, you're set.

## Why these specific choices

- **IKEv2, not L2TP.** The Windows built-in client also speaks L2TP/IPsec, but
  L2TP to a cloud server behind 1:1 NAT (which AWS uses) fails with *error 809*
  unless you edit the registry and reboot. IKEv2 handles NAT natively and uses
  certificate auth, no reboot, more secure.

- **One identity per device.** Every device gets its own IKEv2 client cert
  (`device-1`..`device-10`), like the WireGuard peers. A single shared cert made two
  devices behind one NAT collapse into one server slot and evict each other (the newer
  connection kicked the older to a "connection timed out"); distinct identities get
  distinct leases and coexist. A lost device can also be revoked on its own
  (`ikev2.sh --revokeclient device-N`) without disturbing the others.

- **`nano_3_0` (512 MB RAM) + a 2 GB swap file.** The installer compiles
  Libreswan from source, which 512 MB alone can't hold, so we add a 2 GB swap
  before the build. With that swap, the cheapest IPv4 bundle compiles and runs
  the VPN fine (verified end-to-end). One line in `connect.ps1` switches to
  `micro_3_0` (1 GB) if you ever want more headroom. *(The even cheaper
  `nano_ipv6` bundles are IPv6-only, no public IPv4, so an IPv4-only home or
  mobile network can't reach them; not usable here.)*

- **Tag-gated teardown.** The server is tagged `created-by=uk-vpn-oneclick` the
  moment it's created. `destroy.bat` deletes **only** instances carrying that
  exact tag, so it can never remove a same-named instance you made by hand; if it
  finds one untagged, it refuses and prints the manual delete command. The teardown
  is driven by the tag, not by a hardcoded name.

- **Ephemeral, create-and-destroy.** Lightsail bills even *stopped* instances,
  so "stop when idle" saves nothing. Deleting is the only way to reach zero, so
  the model is: build on demand, destroy after. First build ~5 min; teardown
  ~20 sec.

- **Full tunnel.** So streaming, DNS, and everything else exit from the UK, not
  just browser traffic.

## State and where things live

Runtime files (SSH key, certs, `state.json`, log) are written to
`%LOCALAPPDATA%\uk-vpn-oneclick\`, deliberately **outside** this repo so secrets
can't be committed. `destroy.ps1` wipes them.
