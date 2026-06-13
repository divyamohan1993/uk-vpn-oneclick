# Troubleshooting

## "AWS credentials not set" / it can't create the instance
Your `aws configure` isn't done, or was set up under a different Windows user.
Open a new terminal and run `aws configure` (region `eu-west-2`). Verify with:
```
aws sts get-caller-identity
```
If that prints your account, `connect.bat` will work. The IAM user needs the
`lightsail:*` policy from the README.

## The streaming app still says "you're not in the UK" / proxy detected
This is the big one, and it isn't a bug. Major platforms (Netflix, Disney+, etc.)
block known **datacenter IP ranges**, and AWS is a datacenter. A fresh Lightsail
IP often works for a while, but it can be flagged.

Things to try:
- Run `destroy.bat` then `connect.bat` again, you'll usually get a different IP.
- Confirm the tunnel itself is up: visit https://ifconfig.me, it should show a
  UK IP. If it does, the VPN works and the block is the streaming service's
  IP intelligence, not your connection.
- If a specific platform persistently blocks all cloud IPs, a self-hosted VPN
  can't reliably beat it; that's the one case where a commercial streaming VPN
  (which rotates residential IPs) is the better tool.

## WireGuard says "connected" but nothing loads
The tunnel handshakes but the server isn't forwarding your traffic out. This was a
bug fixed in **v1.1.1** (the WireGuard firewall rules now sit *above* hwdsl2's
catch-all FORWARD DROP). If your server was built before that fix, run `destroy.bat`
then `connect.bat` to rebuild it. To confirm a server is forwarding:
`sudo iptables -S FORWARD | head` should show `-i wg0 -j ACCEPT` *before* any `DROP`.

## Error 809 when connecting
You're on an old L2TP connection. This tool uses **IKEv2** specifically to avoid
809 (L2TP fails behind AWS NAT). Make sure you're connecting to
**"UK VPN (one-click)"**, delete any L2TP connection you made by hand.

## "Cannot connect" / error 13801 / 13806 (IKE auth failed)
The certificate didn't import or doesn't match the server. Fix by rebuilding:
```
destroy.bat   (clears old certs + server)
connect.bat   (fresh certs + server)
```

## A second device knocks the first offline (IKEv2 / Windows native VPN)
Fixed in **v1.2.1**. Cause: every IKEv2 device used to share one client cert, so two
devices (especially behind the same router, hence the same public IP) collapsed into
one connection slot on the server and evicted each other, the newer connection kicked
the older to "connection timed out". The fix gives each device its **own** identity
(`device-1`..`device-10`), exactly like the WireGuard peers, so they coexist. Rebuild an
old server (`destroy.bat` then `connect.bat`) to get the per-device certs.

Then make sure **each device uses a different number**: the creating laptop is
`device-1`; an additional laptop is asked for its own number; phones pick a distinct
`device-N.mobileconfig`. Two devices on the *same* `device-N` will still fight, just like
reusing a WireGuard QR. Confirm on the server: `sudo ipsec trafficstatus` should list one
line per connected device, each with a **different** `lease=` address.

## SSH errors during install ("UNPROTECTED PRIVATE KEY FILE")
The tool restricts the key's permissions automatically. If you hit this, the
`icacls` step was blocked, run `connect.bat` again as admin (via the .bat, which
self-elevates), don't run the `.ps1` directly from a non-admin shell.

## The install hangs or fails partway
First connect compiles Libreswan and takes ~5 minutes, that's normal. If it
genuinely errors out, just run `destroy.bat` (it cleans up partial setups and
stops billing), then `connect.bat` again.

## Adding more devices / a phone won't connect
- **Another laptop with AWS access:** just run `connect.bat` there. It detects the
  existing UK server and **joins** this device to it (no new server, no extra cost).
  It asks once for this laptop's device number (2-10), pick one no other device uses.
- **A laptop without AWS access:** copy the repo + the `uk-vpn-devices` folder onto
  it and run `add-windows-device.bat`.
- **Phone on mobile data:** this is expected to work, the VPN ports are open to the
  whole internet (cert/key-protected). If it won't connect, scan a **different**
  `device-N` QR (don't reuse one already active on another device).

## Re-running connect.bat
Running it again is safe: if the server exists it just reconnects this device; if
not, it recreates it. To actually stop billing you must run `destroy.bat`.

## Did I leave anything running? (peace of mind)
```
aws lightsail get-instances --region eu-west-2 --query "instances[].name"
```
Empty result = nothing running = zero cost. `destroy.bat` guarantees this.
