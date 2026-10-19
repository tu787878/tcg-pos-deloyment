# TCG POS deployment

This repository is the production boundary for one TCG POS installation. It contains no API or React source code. The server pulls immutable API and web images and runs them with PostgreSQL through Docker Compose.

See [FUTURE-PHYSICAL-SERVER-DEPLOYMENT.md](FUTURE-PHYSICAL-SERVER-DEPLOYMENT.md) for the complete release, installation, verification, update, backup, and recovery procedure.

## Files

- `compose.yaml`: PostgreSQL, API, web, and the one-shot Certbot helper.
- `.env.example`: documented non-secret configuration template.
- `install.sh`: first installation and HTTPS setup.
- `update.sh`: manual, version-pinned server update.
- `backup.sh` and `restore.sh`: database, assets, and configuration recovery tools.
- `nginx/`: HTTP bootstrap and HTTPS templates rendered by the installer.

## First installation

Create the DuckDNS hostname and point it to the server before installation. Open or forward TCP ports 80 and 443. Then extract a versioned copy of this repository on the server and run:

```bash
sudo ./install.sh \
  --domain restaurant-one.duckdns.org \
  --email owner@example.com \
  --version 1.0.0 \
  --api-image ghcr.io/YOUR_ORGANIZATION/tcg-pos-api \
  --web-image ghcr.io/YOUR_ORGANIZATION/tcg-pos-web
```

For private GHCR packages, authenticate first with a dedicated read-only package token:

```bash
printf '%s' "$GHCR_READ_TOKEN" | sudo docker login ghcr.io --username DEPLOY_USER --password-stdin
```

Do not place the registry token in `.env`.

The installation directory is `/opt/tcg-pos`. The populated `.env`, JWT private key, PostgreSQL volume, uploaded assets, and certificates exist only on the server and must be backed up securely.
