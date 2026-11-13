# TCG POS — Customer guide

Your Raspberry Pi is supplied with the POS already installed. Use this guide to connect it at your shop, open the POS, and get help when needed. You do not need to copy software, run an installer, or configure Docker.

You do not need to buy a domain or open ports on your Wi-Fi router. Your devices and the Pi must be on the same local network.

## Before you start

Ask your installer for these details:

| Detail | Example |
| --- | --- |
| Pi hostname | `raspi` |
| Pi username | `shopadmin` |
| Pi login method | Your assigned password or SSH key |
| POS address | `http://raspi.local` |
| Support contact | Supplied by your installer |

The examples below use `raspi` and `shopadmin`. Replace these with your actual details. Your Pi login and POS application login are separate accounts. Do not assume the username is `pi` or that there is a default password.

Start with **Connect and power on the Pi**, then **Open the POS**. SSH is optional for everyday use; use it for maintenance or when support asks.

## 1. Connect and power on the Pi

1. Connect the Pi to a LAN port on your shop router using Ethernet. If using Wi-Fi, your installer must configure your shop Wi-Fi details before delivery or arrange setup with you. Wi-Fi configured for another location will not connect automatically.
2. Connect its power supply and allow a few minutes for startup.
3. Connect your computer to the same network. Avoid guest Wi-Fi, which may block access to other devices.

Internet access is needed to download updates. Normal local use can continue without internet when the Pi and your devices remain connected to the local network.

## 2. Open the POS

On your computer or tablet, open a browser and enter:

```text
http://raspi.local
```

Use your actual Pi hostname. Include `http://`; there is no `www` prefix. Sign in with the POS account supplied by your installer.

If the POS asks for a server address, enter the same address:

```text
http://raspi.local
```

Bookmark this page on each device. No SSH session needs to stay open for the POS to work.

If the name does not work, run this in SSH, or ask your installer for the Pi's address:

```bash
hostname -I
```

Find the Pi's address on your shop network, then open it in the browser, for example:

```text
http://192.168.1.50
```

This IP address is only an example. Your actual address may differ and can change. The `.local` name is preferable when supported by your network and devices.

## 3. Connect through SSH — when needed

SSH lets you type commands on the Pi from your computer.

On Windows, open **PowerShell** or **Windows Terminal**. On macOS or Linux, open **Terminal**. Enter:

```bash
ssh shopadmin@raspi.local
```

On your first connection, SSH may ask whether you trust the device. Confirm the hostname and fingerprint with your installer, then type `yes` if they match.

Enter your Pi password when prompted. No characters appear while you type the password; this is normal. Press Enter when finished. If your installer configured an SSH key, use the key they arranged instead.

When connected, the prompt usually looks similar to:

```text
shopadmin@raspi:~ $
```

All Pi commands in the following sections are entered in this SSH session. A command starting with `sudo` may ask for your Pi password again.

To leave SSH without shutting down the Pi:

```bash
exit
```

If SSH is unavailable, contact your installer. SSH access should be configured and tested before delivery.

## 4. Understand updates

Each time the Pi starts, it checks for newer POS application images tagged `latest`. The existing POS starts while this check runs.

- If there is no internet or the download fails, the installed version stays running.
- If nothing changed, no application restart is needed.
- If new images are available, the Pi backs up data before applying them.
- Applying an update may briefly interrupt access. Restart the Pi outside trading hours when possible.

A failed backup prevents the update. If an installed update fails to start, contact support; recovery is not automatic. The boot check updates the POS application, not the Pi operating system or installation scripts.

To request another update check without rebooting, run in SSH:

```bash
sudo systemctl start tcg-pos-update.service
```

To read its result:

```bash
sudo journalctl -u tcg-pos-update.service -n 50 --no-pager
```

You normally do not need to choose version tags or run manual version updates. Ask your installer to handle these.

## 5. Restart or shut down safely

To restart from SSH:

```bash
sudo reboot
```

SSH disconnects during restart. Wait a few minutes, then reopen the POS in your browser. Connect through SSH again if needed.

To turn off the Pi:

```bash
sudo poweroff
```

Wait for shutdown to complete before disconnecting power. Ask your installer how to recognise a completed shutdown on your Pi model. Reconnect power to start it again.

## 6. Back up your shop data

Automatic backups are made before an application update is applied. They are not a daily backup schedule.

To create a backup manually, run in SSH:

```bash
sudo /opt/tcg-pos/backup.sh
```

The command reports the backup location under `/opt/tcg-pos/backups/`. Arrange with your installer to copy backups securely to another device or storage location, and keep a regular backup schedule. A backup stored only on the Pi does not protect against loss or failure of the Pi's storage.

Backups contain private data and credentials. Do not email or share them openly. Ask support to restore data; restoring replaces current shop data.

## If something does not work

| Problem | What to do |
| --- | --- |
| `Could not resolve hostname` | Check the Pi name and that both devices use the same local network. Try its current local IP address. |
| SSH says `Connection refused` | Ask your installer to check that SSH is enabled. |
| SSH times out | Check Pi power, Ethernet/Wi-Fi, and guest-network restrictions. |
| SSH says `Permission denied` | Check the assigned Pi username, password, or key. The POS login is different. |
| SSH warns that the host identification changed | Ask your installer to verify the Pi before changing saved SSH settings. |
| Browser cannot open the POS | Wait for startup/update to finish, confirm the address, and check the Pi is powered on and connected. |
| POS opens but cannot connect to its server | Check the configured server address, then contact support with the error. |
| An update fails | Keep the Pi powered on. Send the updater's error output to support. |
| You are away from the shop | This setup works on the local network. Return to that network or ask your installer about an approved support method. Do not forward router ports. |

Support may ask you to run:

```bash
sudo docker compose --project-directory /opt/tcg-pos ps
sudo docker compose --project-directory /opt/tcg-pos logs --tail=100 api web
sudo journalctl -u tcg-pos-update.service -n 50 --no-pager
```

Share relevant errors privately. Do not share `.env`, private keys, passwords, registry tokens, or full backups.

## Delivery checklist

Confirm these items with your installer after delivery:

- Your computer or tablet opens the POS using the Pi's `.local` name.
- Your POS login works.
- You have the Pi's hostname, SSH login details, and support contact stored securely.
- The POS works again after a reboot.
- You know where backups go and who copies them off the Pi.
- No router port forwarding was required.

