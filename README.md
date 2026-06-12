# UK VPN, one click

Spin up your own **United Kingdom VPN** on AWS, connect Windows to it, stream in 4K, then delete it, all from two double-clicks. No monthly subscription. You pay AWS for the few hours you actually use it (literally pennies), and `destroy.bat` makes sure nothing is left running.

```
connect.bat   ->  builds a London server + connects you      (~5 min, one UAC click)
destroy.bat   ->  deletes everything, billing back to zero    (~20 sec, one UAC click)
```

It uses the **VPN client already built into Windows 11** (IKEv2/IPsec). Nothing else to install on your PC.

---

## Why this exists

Commercial VPNs are a recurring bill for something you might use a few hours a month. This gives you a private UK exit IP on demand: created when you want it, destroyed when you are done, billed by the hour. A 3-hour 4K session costs roughly **₹2-3** of server time, and the data transfer sits inside AWS's free allowance.

## What you need (one-time, ~5 minutes)

1. **An AWS account.**
2. **An IAM user with Lightsail access** (don't use root keys):
   - AWS Console -> IAM -> Users -> **Create user** (no console access needed).
   - Permissions -> **Attach policies directly** -> **Create inline policy** -> JSON tab:
     ```json
     { "Version": "2012-10-17",
       "Statement": [ { "Effect": "Allow", "Action": "lightsail:*", "Resource": "*" } ] }
     ```
     Name it `lightsailvpn` and create.
   - That user -> **Security credentials** -> **Create access key** -> **Command Line Interface (CLI)**.
3. **Configure the key locally.** Open a terminal and run:
   ```
   aws configure
   ```
   Paste the Access key ID + Secret, set region `eu-west-2`, output `json`.
   (No AWS CLI yet? `connect.bat` installs it for you on first run.)

That's it. Your secret key stays on your machine and is never in this repo.

## Use it

1. **Double-click `connect.bat`** -> click **Yes** on the admin prompt -> wait ~5 minutes.
   When it finishes it prints: *"You are now in London, United Kingdom."*
2. Open Netflix / your streaming app and watch.
3. **Double-click `destroy.bat`** when you're done. Billing stops.

To reconnect later **without** rebuilding (while the server still exists): open
**Settings -> Network -> VPN** and click **UK VPN (one-click)**. To stop paying, run `destroy.bat`.

## What it costs

| Item | Cost |
|---|---|
| Server (Lightsail `micro_3_0`, billed hourly) | ~$0.01/hr -> **~₹3 for 3-4 hrs** |
| Data transfer (3 hrs of 4K ~ 27 GB; bundle includes 2 TB) | **included** |
| After `destroy.bat` | **₹0** |

> The only way this gets expensive is forgetting to run `destroy.bat`. A forgotten instance bills the full ~$5/month. Set a reminder, or just run it right after watching.

## How it works (short version)

`connect.bat` -> `scripts/connect.ps1`:
1. Creates an Ubuntu 24.04 Lightsail instance in London (`eu-west-2`).
2. Locks the firewall: SSH only from your current IP; VPN ports (UDP 500/4500) open but certificate-protected.
3. Installs an IKEv2/IPsec server (Libreswan, via the well-known [hwdsl2 installer](https://github.com/hwdsl2/setup-ipsec-vpn)).
4. Pulls down a client certificate, imports it, and creates the Windows IKEv2 connection.
5. Connects and confirms your public IP is now in the UK.

Full details: **[docs/how-it-works.md](docs/how-it-works.md)** · Security model: **[docs/security.md](docs/security.md)** · Problems: **[docs/troubleshooting.md](docs/troubleshooting.md)**.

## Honest limitations

- **Some streaming services block datacenter IPs.** A fresh AWS IP usually works, but big platforms actively block cloud ranges. If a service won't play, that's why, it's not a bug in this tool. See troubleshooting.
- **Windows only** (uses the native Windows VPN + PowerShell).
- **First connect takes ~5 minutes** because the VPN server compiles from source on a fresh box. Reconnecting to an existing server is instant.
- Respect the terms of service of whatever you access. This is a tool for running your own VPN; what you do through it is your responsibility.

## License

MIT, see [LICENSE](LICENSE).
