# Admin commands — Raspberry Pi POS

Run these commands in PowerShell from the `tcg-pos-deloyment` folder.
Replace `192.168.0.97` and `pi` with your Pi's IP address and username.
The Pi needs Raspberry Pi OS 64-bit, SSH enabled, and network access.
Both application images must have published ARM64 `latest` tags.

## 1. Find the Pi

```powershell
.\find-pi.ps1
# Or specify your network:
.\find-pi.ps1 -Subnet 192.168.0
```

Devices with SSH open are candidates, not confirmed Pis. Check your router's device list if unsure.

## 2. Set up SSH key — first time

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action SetupKey
```

Verify the SSH fingerprint and enter the Pi password when asked.
The script creates a local key and copies only its public key to the Pi.
Installation also runs key setup automatically if needed. Sudo may still ask for your Pi password.

For an encrypted key, run these once in **PowerShell as Administrator** to enable passphrase caching:

```powershell
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

## 3. Install a new POS

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Install
```

Copies deployment files from Windows to the Pi and installs the POS.
An existing database is preserved. Create your shop/account in the app on a fresh installation.

If image downloads say `unauthorized`, run this, then repeat installation:

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action RegistryLogin -RegistryUser tu787878
```

At Docker's password prompt, enter a GitHub **classic token** with `read:packages`, belonging to the named GitHub user. That user needs access to both packages. Do not enter your Pi password at this prompt.

If an image says `not found`, publish both API and web `latest` images through their GitHub Actions release workflows first.

## 4. OR import an old POS backup

### A. Create the backup — run on the Ubuntu VPS

These commands use the existing database container `tcg-pos-api-postgres-1`.
Pause use of the old POS before taking the final migration backup so new sales are not missed.

```bash
mkdir -p ~/pos-backup
chmod 700 ~/pos-backup

docker exec tcg-pos-api-postgres-1 sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges' \
  > ~/pos-backup/database.dump
```

Continue only if the dump finishes without errors. Check that PostgreSQL can read the archive:

```bash
docker exec -i tcg-pos-api-postgres-1 pg_restore --list \
  < ~/pos-backup/database.dump > ~/pos-backup/contents.txt
```

Continue only if that command also succeeds. If Docker requires administrator access on your VPS, use `sudo docker` instead of `docker`.

### B. Download the backup — run in Windows PowerShell

Open a separate terminal on your Windows computer. Do not run these commands in the Ubuntu SSH session.
Replace `YOUR_VPS_IP` with the VPS public IP address; enter the VPS SSH password or use your configured SSH key.

```powershell
New-Item -ItemType Directory -Force C:\Backups\old-pos

scp ubuntu@YOUR_VPS_IP:~/pos-backup/database.dump C:\Backups\old-pos\
if ($LASTEXITCODE -ne 0) { throw 'Backup download failed. Do not import.' }

Get-Item C:\Backups\old-pos\database.dump
```

This is a database-only backup. Uploaded images/files are stored separately; ask support to migrate them too. Keep the backup private.

### C. Install and import — run in Windows PowerShell

```powershell
cd C:\Users\vantu\Desktop\shared\tcg-pos-deloyment
```

This **replaces the target database**, not a merge. The target is backed up first.
Use a compatible TCG POS PostgreSQL custom-format dump, not plain SQL or MySQL.

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Install `
  -DataMode Import -BackupPath 'C:\Backups\old-pos' -ReplaceExistingData
```

The folder must contain `database.dump`; include `assets.tar.gz` for uploaded files.
You can also pass a standalone `.dump` file. Target credentials and JWT keys are preserved.
Sign in with accounts from the imported database. If import fails, boot updates remain disabled; inspect the error and recover before retrying. No automatic rollback.

## 5. Open and test

Open `http://pi.local` or `http://192.168.0.97` in your browser.
The `.local` name follows the Pi's actual hostname. No router port forwarding is needed.

```powershell
Invoke-RestMethod http://192.168.0.97/actuator/health/readiness
Invoke-RestMethod http://192.168.0.97/api/v1/system/info
```

Expected: `UP`, then `simple-pos-backend` / `v1`.

## Status

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Status
```

## Logs

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Logs
```

## Check for an update now

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Update
```

The Pi also checks at boot. Failed downloads keep the installed app running.
Read the printed journal to see whether an update was applied or skipped.

## Back up the database and assets

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Backup
```

Backups are created on the Pi under `/opt/tcg-pos/backups/`. Copy them securely off the Pi separately. Backups are not automatically scheduled daily.

## Open a Pi terminal

```powershell
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Shell
```

Inside that terminal:

```bash
hostname
hostname -I
sudo reboot
# Or shut down:
sudo poweroff
```

## Optional connection settings

```powershell
# Existing private key:
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Status -IdentityFile "$env:USERPROFILE\.ssh\id_ed25519"

# Custom SSH port:
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Status -Port 2222

# Skip automatic key setup:
.\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Status -SkipKeySetup

# If PowerShell blocks the script:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\admin-pi.ps1 -PiHost 192.168.0.97 -User pi -Action Install
```

## Before customer delivery

Test login and normal POS operations, reboot and test again, verify backups, and configure the customer's Wi-Fi or use Ethernet. Provide their address, logins securely, and [CUSTOMER-README.md](CUSTOMER-README.md).

For detailed deployment, backup, and recovery limitations, see [README.md](README.md). The import flow has mocked checks; test a real backup restore before using it for customer migration.
