# TCG POS VPS Deployment Guide

This guide installs TCG POS `1.0.0` on a new VPS or physical server. The server runs PostgreSQL, the Spring Boot API, and the React web application through Docker Compose. It contains deployment configuration only—no API or web source code.

> Do not use this procedure on the existing OVH production server. That server continues to use its original source-build deployment with `bash deploy.sh`.

## Release components

| Component | Release |
| --- | --- |
| API image | `ghcr.io/tu787878/tcg-pos-api:1.0.0` |
| Web image | `ghcr.io/tu787878/tcg-pos-web:1.0.0` |
| Database image | `postgres:17-alpine` |
| Deployment repository | `tcg-pos-deployment` |
| Architectures | `linux/amd64`, `linux/arm64` |

The API and web packages are private. The server needs a GitHub deployment account with read access to both packages and a token containing `read:packages`.

## 1. Prepare the server

Use a clean 64-bit server with:

- Ubuntu Server 24.04, Debian 12, or Raspberry Pi OS 64-bit;
- at least 4 GB RAM;
- at least 10 GB free disk space, with 64 GB total storage recommended;
- SSD storage for PostgreSQL and Docker data;
- a fixed public IPv4 address;
- inbound TCP ports `80` and `443` available.

For a physical server behind a router, reserve its LAN address and forward TCP ports `80` and `443` to it. Confirm that the connection is not behind CGNAT when public access is required.

Do not install Node.js, npm, Maven, Java, Flutter, or application source code on the server.

## 2. Register the DuckDNS hostname

Before installation:

1. Sign in to DuckDNS.
2. Create a hostname such as `restaurant-one.duckdns.org`.
3. Point it to the server's public IPv4 address.
4. Allow inbound TCP ports `80` and `443` in the VPS firewall.
5. Wait for DNS to update.

Verify on the server:

```bash
curl -4 https://api.ipify.org
getent ahostsv4 restaurant-one.duckdns.org
```

Both commands must report the same public IPv4 address. Do not continue until DNS is correct, because Let's Encrypt must reach the server through port `80`.

## 3. Create a read-only GHCR token

GHCR is GitHub's container registry. Because the API and web images are private,
the installer needs a read-only token to download them.

Using the GitHub account that can access both packages:

1. Open GitHub **Settings**.
2. Open **Developer settings**.
3. Open **Personal access tokens**.
4. Create a token that has `read:packages` access.
5. Copy the token and keep it temporarily. GitHub will not show it again.

For the first test, you can use the `shibawannafly` account because it has
already been confirmed to read both images. For customer installations, use a
dedicated deployment account instead of a personal account.

The username must belong to the account that created the token. It does not need
to be the repository owner.

Keep the token available only while installing. Never put it in `.env`, the
deployment repository, a script, or a screenshot.

## 4. Copy the deployment bundle

Copy the tested `tcg-pos-deployment` folder to the server:

```bash
scp -r tcg-pos-deployment user@SERVER_IP:/tmp/
```

The copied folder should contain:

```text
compose.yaml
install.sh
update.sh
backup.sh
restore.sh
nginx/
```

Do not copy populated `.env` files, JWT keys, API source, or web source from another installation.

## 5. Run the single installer

On the server:

```bash
cd /tmp/tcg-pos-deployment

sudo ./install.sh \
  --domain restaurant-one.duckdns.org \
  --email owner@example.com
```

The script displays:

```text
GHCR token for shibawannafly:
```

Paste the read-only token and press Enter. Nothing appears while pasting—that
is intentional. The token is passed directly to Docker and is not written to
the application `.env` file.

The installer:

- validates the OS, CPU architecture, memory, and disk space;
- verifies that DuckDNS resolves to the server's public IPv4 address;
- installs Docker Engine and Docker Compose when absent;
- logs Docker into GHCR using the prompted token;
- creates `/opt/tcg-pos`;
- generates the PostgreSQL password and RSA JWT keys;
- pulls the pinned API and web images;
- starts PostgreSQL, API, and web;
- obtains a Let's Encrypt certificate;
- enables HTTPS and certificate renewal;
- preserves generated credentials when run again.

Customer configuration, credentials, persistent data, and certificates remain under `/opt/tcg-pos`. They are not stored in the images or deployment repository.

The optional flags `--version`, `--api-image`, `--web-image`, and
`--registry-user` are available for a different release or deployment account.

## 6. Verify the installation

```bash
cd /opt/tcg-pos
sudo docker compose ps
```

The `postgres`, `api`, and `web` services must be healthy. Inspect logs when necessary:

```bash
sudo docker compose logs --tail=100 postgres
sudo docker compose logs --tail=100 api
sudo docker compose logs --tail=100 web
```

Verify the public endpoints:

```bash
curl --fail https://restaurant-one.duckdns.org/
curl --fail https://restaurant-one.duckdns.org/actuator/health/readiness
```

Complete a functional test:

1. Open the web application and log in.
2. Select or create the shop.
3. Create categories, products, menus, dining areas, and tables.
4. Create, edit, send, and complete a test order.
5. Generate a receipt and kitchen ticket.
6. Verify printing from an Android POS device.
7. Restart the server and confirm automatic recovery.

```bash
sudo reboot
```

After reconnecting:

```bash
cd /opt/tcg-pos
sudo docker compose ps
curl --fail https://restaurant-one.duckdns.org/actuator/health/readiness
```

## 7. Build the Android application

Build the Flutter APK on a development or CI machine—not on the VPS. Use the same DuckDNS hostname:

```bash
cd tcg-pos-app
flutter pub get
flutter test
flutter analyze
flutter build apk \
  --release \
  --build-name 1.0.0 \
  --build-number 100 \
  --dart-define API_BASE_URL=https://restaurant-one.duckdns.org
```

Install the APK manually on each Android POS device. Confirm login, ordering, and printing before delivery.

## 8. Back up and restore

Create a backup:

```bash
cd /opt/tcg-pos
sudo ./backup.sh
```

The backup contains the PostgreSQL dump, uploaded assets, `.env`, Compose configuration, and JWT keys. Copy it to encrypted storage outside the server.

Perform at least one restore test with disposable data before onboarding a paying restaurant:

```bash
cd /opt/tcg-pos
sudo CONFIRM_RESTORE=YES ./restore.sh /opt/tcg-pos/backups/BACKUP_DIRECTORY
```

Restore replaces the current database and assets. Verify the backup directory carefully before running it.

## 9. Update the server

First publish matching API and web images under a new immutable version, such as:

```text
ghcr.io/tu787878/tcg-pos-api:1.0.1
ghcr.io/tu787878/tcg-pos-web:1.0.1
```

Then update during a maintenance window:

```bash
cd /opt/tcg-pos
sudo ./update.sh 1.0.1
```

The update script creates a backup, changes `APP_VERSION`, pulls both images, and reconciles the stack. PostgreSQL data, assets, credentials, and certificates remain persistent.

After every update:

```bash
sudo docker compose ps
curl --fail https://restaurant-one.duckdns.org/actuator/health/readiness
```

Perform a small transaction test. Do not automatically roll the API backward after a database migration unless the migration is known to be backward compatible.

## 10. Troubleshooting

### GHCR reports `unauthorized` or `denied`

Confirm that:

- the deployment account can access both packages;
- the token includes `read:packages`;
- Docker login used `sudo`, because installation also runs Docker with `sudo`;
- organization SSO authorization is complete when required.

Log in again and rerun the installer. It is idempotent and does not regenerate existing passwords or JWT keys.

### Let's Encrypt fails

Confirm that DuckDNS points to the correct public IPv4 address, port `80` is reachable, no other service occupies ports `80` or `443`, router forwarding is correct, and the connection is not behind CGNAT. Then rerun the installer.

### A container is unhealthy

```bash
cd /opt/tcg-pos
sudo docker compose ps
sudo docker compose logs --tail=200 postgres api web
```

Do not delete Docker volumes while troubleshooting.

## 11. Acceptance checklist

- [ ] DuckDNS resolves to the server's public IPv4 address.
- [ ] Only TCP ports `80` and `443` are publicly exposed.
- [ ] Docker can pull both private `1.0.0` images.
- [ ] PostgreSQL, API, and web containers are healthy.
- [ ] HTTPS is valid and HTTP redirects to HTTPS.
- [ ] Web login and shop selection work.
- [ ] Products, menus, tables, orders, and receipts work.
- [ ] Android login, ordering, and printing work.
- [ ] Containers recover after a server restart.
- [ ] Database and asset backup succeeds.
- [ ] Restore has been tested with disposable data.
- [ ] Backups are encrypted and copied off the server.

After the first clean installation passes this checklist, tag the exact tested deployment commit:

```bash
git tag -a v1.0.0 -m "TCG POS deployment 1.0.0"
git push origin v1.0.0
```
