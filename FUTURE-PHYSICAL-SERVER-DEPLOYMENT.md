# Future Physical Server Deployment

This is the simple deployment flow for new Raspberry Pi, mini-PC, and VPS installations.

The existing OVH server continues using the old source-build flow:

```bash
bash deploy.sh
```

Do not run the new installer on the existing OVH server.

## How the new flow works

```text
Push API and web code
        ↓
Create the same version tag in both repositories
        ↓
GitHub Actions publishes both images to GHCR
        ↓
The physical server pulls and runs that version
```

The physical server contains no API or React source code.

## 1. Publish a release

Push the API and web changes normally:

```bash
cd tcg-pos-api
git add .
git commit -m "Update API"
git push origin main
```

```bash
cd tcg-pos-web
git add .
git commit -m "Update web"
git push origin master
```

For the first `1.0.0` image publication, open the **Actions** page in each repository, select the image publishing workflow, choose **Run workflow**, and enter:

```text
1.0.0
```

The API repository already contains an older `v1.0.0` Git tag, so do not move, delete, or recreate that tag. Run the manual workflow from the repository's default branch to publish image version `1.0.0` safely.

For later releases, create the same new tag in both repositories, for example `v1.0.1`.

GitHub Actions should publish:

```text
ghcr.io/tu787878/tcg-pos-api:1.0.0
ghcr.io/tu787878/tcg-pos-web:1.0.0
```

Do not use `latest`. Deploy a specific version such as `1.0.0`.

## 2. Prepare a new server

Use a 64-bit server with:

- 4 GB RAM or more;
- SSD storage;
- Ubuntu Server 24.04, Debian 12, or Raspberry Pi OS 64-bit;
- TCP ports 80 and 443 available.

Before installation:

1. Create a DuckDNS hostname such as `restaurant-one.duckdns.org`.
2. Point it to the server's public IP.
3. Forward ports 80 and 443 when the server is behind a router.
4. Copy the `tcg-pos-deployment` release folder to the server.

## 3. Log in to GHCR

For private images, log in using a read-only package token:

```bash
read -rsp "GHCR token: " GHCR_READ_TOKEN
printf '\n'
printf '%s' "$GHCR_READ_TOKEN" | \
  sudo docker login ghcr.io \
    --username YOUR_DEPLOY_USER \
    --password-stdin
unset GHCR_READ_TOKEN
```

Do not put the registry token in `.env`.

## 4. Install the system

From the deployment folder on the new server:

```bash
sudo ./install.sh \
  --domain restaurant-one.duckdns.org \
  --email owner@example.com \
  --version 1.0.0 \
  --api-image ghcr.io/tu787878/tcg-pos-api \
  --web-image ghcr.io/tu787878/tcg-pos-web
```

The installer installs Docker when necessary, generates secrets, pulls the images, starts the system, configures HTTPS, and saves everything under `/opt/tcg-pos`.

## 5. Verify the installation

```bash
cd /opt/tcg-pos
sudo docker compose ps
curl --fail https://restaurant-one.duckdns.org/
curl --fail https://restaurant-one.duckdns.org/actuator/health/readiness
```

Then open the web application, log in, and create a test order.

Build the Flutter APK with the same hostname:

```bash
cd tcg-pos-app
flutter build apk \
  --release \
  --build-name 1.0.0 \
  --build-number 100 \
  --dart-define API_BASE_URL=https://restaurant-one.duckdns.org
```

Install the APK manually on the Android POS devices.

## 6. Update the server later

First publish matching new images, for example:

```text
ghcr.io/tu787878/tcg-pos-api:1.0.1
ghcr.io/tu787878/tcg-pos-web:1.0.1
```

Then update the server:

```bash
cd /opt/tcg-pos
sudo ./update.sh 1.0.1
```

The update script creates a backup, pulls version `1.0.1`, and restarts the application. PostgreSQL data and uploaded assets remain in Docker volumes.

Verify the application after every update:

```bash
sudo docker compose ps
curl --fail https://restaurant-one.duckdns.org/actuator/health/readiness
```

## Short version

First installation:

```text
Create DuckDNS → publish images → log in to GHCR → run install.sh
```

Future update:

```text
Push code → tag both repositories → images are published → run update.sh VERSION
```
