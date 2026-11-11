# TCG POS — Raspberry Pi deployment

Run the POS on a Raspberry Pi and use it from devices on the same Wi-Fi or wired network. The Pi runs the web app, API, and PostgreSQL with Docker Compose.

**Local address:** `http://<pi-hostname>.local`, for example `http://raspi.local`.

No purchased domain, DuckDNS account, router port forwarding, or public HTTPS certificate is needed. Do not enable router forwarding for this installation. The installer does not change router or firewall settings.

## Requirements

- Raspberry Pi running Raspberry Pi OS 64-bit, with enough memory and storage for the application, database, images, and backups.
- A user with `sudo` access.
- Internet access during installation and updates to download system packages and Docker images.
- Client devices on the same local network, with communication between clients allowed.
- Published ARM64 API and web images in GHCR.

The local installer does not enforce hardware requirements. The POS can run from cached images when the internet is unavailable; automatic updates need internet access.

## 1. Publish the application images

The API and web repositories each contain `.github/workflows/publish-image.yml`. Push the workflow changes and publish a release in **both repositories** before installing from `latest`.

Each workflow runs checks and publishes images for `linux/amd64` and `linux/arm64`, with:

- A version tag, such as `1.0.0`.
- The moving `latest` tag, used by the Pi's boot updater.

Trigger a release with a Git tag such as `v1.0.0`, or run the workflow manually with a version such as `1.0.0`. Publish compatible API and web versions together. The workflows publish independently, so the two `latest` tags are not an atomic release pair.

Default image names:

```text
ghcr.io/tu787878/tcg-pos-api
ghcr.io/tu787878/tcg-pos-web
```

## 2. Choose the Pi's local name

Set the hostname in Raspberry Pi Imager before installing the OS, or use:

```bash
sudo raspi-config
```

Choose a hostname such as `raspi`, then reboot if requested. Use a unique hostname for each Pi.

The installer enables Avahi for local name discovery. A Pi named `raspi` is reached at `http://raspi.local`, without a `www` prefix. Its IP address can change without changing this name. Changing the Pi's hostname changes its `.local` name.

Devices must support mDNS. Guest Wi-Fi, client isolation, or separate network segments may prevent discovery or connection. Use the Pi's local IP address as a fallback.

## 3. Install

Copy or extract this deployment repository onto the Pi. From the repository directory, run:

```bash
sudo sh ./install.sh
```

The installer:

1. Refreshes package lists and upgrades installed system packages.
2. Installs dependencies, Avahi, and Docker/Compose if missing.
3. Creates `/opt/tcg-pos`, generates a database password and JWT keys, and writes configuration.
4. Pulls PostgreSQL, API, and web images and starts the containers.
5. Enables Docker startup and the boot-time application updater.

It does not perform a final application readiness check. Verify the installation using the commands below.

For private GHCR images, authenticate as root after Docker is available, then rerun the installer:

```bash
sudo docker login ghcr.io --username YOUR_GITHUB_USERNAME
```

At the password prompt, enter a token with permission to read the packages. Do not store this token in `.env`. Boot updates use the root user's saved Docker credentials.

To override the initial image names or tag:

```bash
sudo env APP_VERSION=1.0.0 \
  API_IMAGE=ghcr.io/YOUR_ORGANIZATION/tcg-pos-api \
  WEB_IMAGE=ghcr.io/YOUR_ORGANIZATION/tcg-pos-web \
  sh ./install.sh
```

These overrides populate a new installation. An existing `.env` is preserved. The boot updater follows `latest` even if the initial installation used a version tag; disable it to keep a version pinned.

Rerunning the installer preserves existing configuration, keys, and data, replaces the installed Compose/scripts and local HTTP Nginx configuration, and re-enables boot updates. It also runs system package upgrades again.

## 4. Open and verify the POS

From another device on the same network, open:

```text
http://raspi.local
```

Replace `raspi` with your Pi's hostname. On the Pi itself, `http://localhost` also works. If asked for an API server address, use the same Pi address; the web app sends API requests through Nginx.

Verify on the Pi:

```bash
cd /opt/tcg-pos
sudo docker compose ps
curl --fail http://localhost/healthz
curl --fail http://localhost/actuator/health/readiness
curl --fail http://localhost/api/v1/system/info
```

The web health endpoint should return `ok`, API readiness should report `UP`, and the identity endpoint should identify `simple-pos-backend` with API version `v1`.

HTTP port 80 serves the local POS. API port 8080 and database port 5432 are not published to the host. The shared Compose file also publishes port 443 for the separate HTTPS installation, but the local installer configures HTTP only.

## Automatic updates at reboot

`tcg-pos-update.service` runs once at boot after Docker and the network-online target. Docker restarts the cached containers while the updater checks for new API and web images tagged `latest`.

1. Download both application images, with a three-minute overall download limit.
2. If downloading fails, keep the installed containers running.
3. Compare downloaded image IDs with the running containers. If unchanged, finish without a backup or restart.
4. If changed, wait for PostgreSQL, then back up the database, uploaded assets, configuration, and JWT keys.
5. If the backup succeeds, recreate the services and wait for health checks.

An update can briefly interrupt service while containers are recreated. A failed database check or backup prevents application replacement. A failure after replacement is reported in the journal; there is no automatic application or database rollback.

Check or run the updater manually:

```bash
sudo systemctl status tcg-pos-update.service
sudo journalctl -u tcg-pos-update.service -n 100 --no-pager
sudo systemctl start tcg-pos-update.service
```

An inactive service after a successful run is normal for this one-shot service. A skipped download is recorded in the journal. There is no periodic retry during the same boot; trigger another check manually or reboot.

Boot updates change application images only. They do not update this repository's deployment scripts, Compose file, operating system, or PostgreSQL image automatically.

## Manual version updates

To keep a particular API/web version across reboots, disable boot updates first:

```bash
sudo systemctl disable --now tcg-pos-update.service
sudo /opt/tcg-pos/update.sh 1.0.0
```

The version must exist for both images. The manual updater backs up first, changes `APP_VERSION` in `.env`, pulls images, and runs Compose. It does not wait for application health checks. If the pull or Compose command fails, it restores the previous `.env`; that does not guarantee running containers or database migrations were rolled back. Inspect the stack before retrying.

Re-enable boot updates when ready to follow `latest` again:

```bash
sudo systemctl enable tcg-pos-update.service
sudo systemctl start tcg-pos-update.service
```

## Backups and recovery

Create a backup:

```bash
sudo /opt/tcg-pos/backup.sh
```

Backups are saved under `/opt/tcg-pos/backups/<UTC-timestamp>/` and contain:

- `database.dump`: PostgreSQL database dump.
- `assets.tar.gz`: uploaded assets.
- `.env` and `compose.yaml`: configuration.
- `secrets/`: JWT keys.

Treat backups as sensitive. Copy them securely off the Pi and manage retention; the scripts do not delete old backups. Database and asset backups are taken separately while the app can still write. Use a quiet maintenance period when a consistent recovery point is required. The asset archive helper may need to download `alpine:3.22` if it is not cached.

To restore an existing, configured installation, verify the backup and target first. This replaces the current database and, when present in the backup, uploaded assets:

```bash
sudo systemctl disable --now tcg-pos-update.service
sudo env CONFIRM_RESTORE=YES /opt/tcg-pos/restore.sh \
  /opt/tcg-pos/backups/REPLACE_WITH_BACKUP_TIMESTAMP
```

PostgreSQL must already be running. The restore script stops API/web, restores data, and starts services again. It does **not** automatically restore the backed-up `.env`, Compose file, or JWT keys, or select an older application version. For replacement hardware or a database rollback, restore the matching configuration, keys, and compatible application images as part of recovery. Keep boot updates disabled until recovery has been verified.

## Troubleshooting

| Problem | Check |
| --- | --- |
| `.local` address does not resolve | Confirm the hostname with `hostname -s`, check `sudo systemctl status avahi-daemon`, and ensure clients share the local network. |
| Need the local IP address | Run `hostname -I` on the Pi, then open `http://<pi-ip>`. |
| Image pull says unauthorized | Run `sudo docker login ghcr.io` and verify package access. |
| Image/tag not found | Publish both application images and confirm their `latest` tags include ARM64. |
| POS page opens but connection fails | Check API readiness and `sudo docker compose logs --tail=100 api web` from `/opt/tcg-pos`. |
| Update did not apply | Read `sudo journalctl -u tcg-pos-update.service -n 100 --no-pager`; check internet, credentials, backup errors, and free disk space. |
| Pi storage is filling up | Inspect `df -h`, backup retention, and `sudo docker system df`. Preserve required backups and recovery images. |

On Bullseye, the local installer repairs archived Debian security repository URLs before installing packages and saves changed APT source files beside the originals.

## Repository files

| File | Purpose |
| --- | --- |
| `install.sh` | Local Raspberry Pi installation and boot-updater registration. |
| `compose.yaml` | PostgreSQL, API, web, networks, persistent volumes, and optional Certbot helper. |
| `boot-update.sh` | Boot-time update from API/web `latest` tags. |
| `update.sh` | Manual version-tag update. |
| `backup.sh` / `restore.sh` | Backup and guarded data recovery. |
| `test-boot-update.sh` | Mocked update-decision tests, without Docker or network access. |
| `.env.example` | Configuration reference, currently using public HTTPS examples; the local installer generates its own `.env`. |
| `nginx/` | Nginx templates for the separate public installation. |
| `install-production.sh` | Optional public-domain HTTPS installer; not needed for this local setup. |

For the separate public-server procedure, see [FUTURE-PHYSICAL-SERVER-DEPLOYMENT.md](FUTURE-PHYSICAL-SERVER-DEPLOYMENT.md). That route has different DNS, certificate, and router requirements.

## Validation and deployment status

Run the local script checks from this repository:

```bash
for script in *.sh; do sh -n "$script" || exit; done
sh test-boot-update.sh
```

The mocked tests cover failed downloads, unchanged images, changed images, failed backups, unavailable PostgreSQL, and failed application startup. They do not replace a real ARM64 Docker installation and reboot test.

Repository changes alone do not deploy to the Pi. Publish the application images, run the updated installer on the Pi, verify local access, and perform a reboot test before treating the installation as complete.
