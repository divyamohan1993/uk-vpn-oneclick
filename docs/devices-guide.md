# Connect any device to your UK VPN

After `connect.bat` finishes, this `uk-vpn-devices` folder (on your Desktop) holds everything you need for **every other device**. There are two ways to connect anything:

- **WireGuard (easiest):** install the free WireGuard app, scan a QR code. Works on every platform.
- **IKEv2 (no app on iPhone/Windows):** use the built-in VPN with the `device-N` profile files here.

> **One rule:** give each device a **different** number (`device-1`, `device-2`, ...) - this applies to **both** WireGuard and IKEv2. Two devices sharing one profile fight over the same identity and knock each other offline.

The server's IP is in `server-ip.txt`. These files are **secrets**, don't post them publicly. `destroy.bat` deletes this folder.

---

## 📱 Android phone/tablet
**Easiest, WireGuard:**
1. Install **WireGuard** from the Play Store.
2. Open it → **+** → **Scan from QR code**.
3. Scan `wireguard/device-1.png` (use a different number per device).
4. Toggle it on. Done.

**Or built-in (strongSwan):** install the **strongSwan** app → import `ikev2/device-3.sswan` (any number no other device uses).

## 📱 iPhone / iPad
**No app needed (built-in IKEv2):**
1. Send `ikev2/device-2.mobileconfig` to the phone (AirDrop, email, or iCloud) - pick a number no other device is using.
2. Tap it → **Settings** shows "Profile Downloaded" → **Install**.
3. Settings → VPN → toggle it on.

**Or WireGuard:** install the WireGuard app → scan `wireguard/device-2.png`.

## 💻 Another Windows laptop
**Easiest (if that laptop can use your AWS account):** copy/clone the `uk-vpn-oneclick`
repo there and double-click **`connect.bat`**. It detects the existing UK server and
**joins** this laptop to it (no new server, no extra cost). It asks once for this laptop's
device number (2-10) so it gets its own IKEv2 identity; pick one no other device uses.

**No AWS access on that laptop?** Copy the repo **and** this `uk-vpn-devices` folder onto
it, then double-click **`add-windows-device.bat`** (uses the bundle, no AWS needed). It
asks which device number to use (1-10); give it one no other device is using.

**Or WireGuard:** install the WireGuard app → **Import tunnel(s) from file** → pick a `wireguard/device-N.conf`.

## 🐧 Linux
**WireGuard (one click):**
```bash
./setup-linux.sh 4        # uses wireguard/device-4.conf (pick a free number)
```
That installs WireGuard, brings the tunnel up, and routes everything through the UK.
Disconnect: `sudo wg-quick down uk-vpn`.

## 🖥️ macOS
- **WireGuard:** install WireGuard from the App Store → scan a QR / import a `device-N.conf`.
- **Or built-in:** double-click `ikev2/device-N.mobileconfig` (any free number) → install in System Settings.

---

## Check it worked
On any connected device, visit **https://ifconfig.me**, it should show a UK IP. If a streaming app still says you're not in the UK, that's the streaming service blocking the datacenter IP (see the repo's `docs/troubleshooting.md`), not a broken tunnel.

## Need more than 10 devices?
There are 10 ready WireGuard slots (`device-1` ... `device-10`). If you need more, re-run `connect.bat` after a `destroy.bat` (fresh batch), or ask for an `add-peer` helper.
