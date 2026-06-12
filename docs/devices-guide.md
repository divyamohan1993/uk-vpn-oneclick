# Connect any device to your UK VPN

After `connect.bat` finishes, this `uk-vpn-devices` folder (on your Desktop) holds everything you need for **every other device**. There are two ways to connect anything:

- **WireGuard (easiest):** install the free WireGuard app, scan a QR code. Works on every platform.
- **IKEv2 (no app on iPhone/Windows):** use the built-in VPN with the profile files here.

> **One rule:** give each device a **different** WireGuard config (`device-1`, `device-2`, ...). Don't use the same QR on two devices at the same time, they'd fight over the same address.

The server's IP is in `server-ip.txt`. These files are **secrets**, don't post them publicly. `destroy.bat` deletes this folder.

---

## 📱 Android phone/tablet
**Easiest, WireGuard:**
1. Install **WireGuard** from the Play Store.
2. Open it → **+** → **Scan from QR code**.
3. Scan `wireguard/device-1.png` (use a different number per device).
4. Toggle it on. Done.

**Or built-in (strongSwan):** install the **strongSwan** app → import `ikev2/vpnclient.sswan`.

## 📱 iPhone / iPad
**No app needed (built-in IKEv2):**
1. Send `ikev2/vpnclient.mobileconfig` to the phone (AirDrop, email, or iCloud).
2. Tap it → **Settings** shows "Profile Downloaded" → **Install**.
3. Settings → VPN → toggle it on.

**Or WireGuard:** install the WireGuard app → scan `wireguard/device-2.png`.

## 💻 Another Windows laptop
**Easiest (if that laptop can use your AWS account):** copy/clone the `uk-vpn-oneclick`
repo there and double-click **`connect.bat`**. It detects the existing UK server and
**joins** this laptop to it (no new server, no extra cost), exactly like your first laptop.

**No AWS access on that laptop?** Copy the repo **and** this `uk-vpn-devices` folder onto
it, then double-click **`add-windows-device.bat`** (uses the bundle, no AWS needed).

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
- **Or built-in:** double-click `ikev2/vpnclient.mobileconfig` → install in System Settings.

---

## Check it worked
On any connected device, visit **https://ifconfig.me**, it should show a UK IP. If a streaming app still says you're not in the UK, that's the streaming service blocking the datacenter IP (see the repo's `docs/troubleshooting.md`), not a broken tunnel.

## Need more than 10 devices?
There are 10 ready WireGuard slots (`device-1` ... `device-10`). If you need more, re-run `connect.bat` after a `destroy.bat` (fresh batch), or ask for an `add-peer` helper.
