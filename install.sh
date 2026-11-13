#!/bin/sh
# Local Raspberry Pi OS / Debian installation: sudo ./install.sh
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
APP_RELEASE=${APP_VERSION:-latest}
case "$APP_RELEASE" in
    ''|*[!A-Za-z0-9._-]*|-*|.*)
        printf 'Invalid application image tag: %s\n' "$APP_RELEASE" >&2
        exit 1
        ;;
esac
API_IMAGE=${API_IMAGE:-ghcr.io/tu787878/tcg-pos-api}
WEB_IMAGE=${WEB_IMAGE:-ghcr.io/tu787878/tcg-pos-web}

case "${1:-}" in
    -h|--help)
        printf 'Usage: sudo ./install.sh\nLocal network installation at http://<pi-hostname>.local; no public domain or router port forwarding.\n'
        exit 0
        ;;
    '') ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this installer with sudo.\n' >&2
    exit 1
fi

# Update system packages and install dependencies; no hardware or network preflight checks.
# Bullseye security packages have moved to Debian's archive.
# Handle both traditional sources.list entries and deb822 .sources files.
repair_bullseye_security() {
    for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$source" ] || continue
        temporary=$(mktemp)
        case "$source" in
            *.sources) record_separator='' ;;
            *) record_separator='\n' ;;
        esac
        awk -v RS="$record_separator" '
            /bullseye-security/ {
                gsub(/https?:\/\/(security|deb)\.debian\.org\/debian-security/, "https://archive.debian.org/debian-security")
            }
            { print; if (RS == "") print "" }
        ' "$source" > "$temporary"
        if ! cmp -s "$source" "$temporary"; then
            cp -p "$source" "$source.before-tcg-pos-$(date +%s)"
            cat "$temporary" > "$source"
            printf 'Updated Bullseye security repository: %s\n' "$source"
            # Discard indexes referring to the previous mirror.
            rm -rf /var/lib/apt/lists/*
        fi
        rm -f "$temporary"
    done
}

repair_bullseye_security

refresh_packages() {
    apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update
}

install_packages() {
    if apt-get -o Acquire::Retries=3 install -y "$@"; then
        return 0
    fi
    printf 'Refreshing stale APT package lists and retrying once...\n'
    # These are downloaded indexes only; installed packages and sources stay intact.
    rm -rf /var/lib/apt/lists/*
    refresh_packages
    apt-get -o Acquire::Retries=3 install -y "$@"
}

refresh_packages
printf 'Upgrading installed system packages...\n'
apt-get -o Acquire::Retries=3 upgrade -y
install_packages ca-certificates curl openssl avahi-daemon util-linux coreutils
systemctl enable --now avahi-daemon
LOCAL_DOMAIN=$(hostname -s).local
. /etc/os-release

install_docker() {
    install -m 0755 -d /etc/apt/keyrings
    DOCKER_DISTRO=$ID
    [ "$DOCKER_DISTRO" = raspbian ] && DOCKER_DISTRO=debian
    curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ARCHITECTURE=$(dpkg --print-architecture)
    CODENAME=${VERSION_CODENAME:-}
    [ -n "$CODENAME" ] || { printf 'Operating-system codename is unavailable.\n' >&2; exit 1; }
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$ARCHITECTURE" "$DOCKER_DISTRO" "$CODENAME" > /etc/apt/sources.list.d/docker.list
    refresh_packages
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
docker compose version >/dev/null

systemctl enable --now docker

mkdir -p "$INSTALL_DIR/nginx" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
if [ "$SOURCE_DIR" != "$INSTALL_DIR" ]; then
    install -m 0644 "$SOURCE_DIR/compose.yaml" "$INSTALL_DIR/compose.yaml"
    for script in update.sh backup.sh restore.sh boot-update.sh; do
        install -m 0755 "$SOURCE_DIR/$script" "$INSTALL_DIR/$script"
    done
fi

ENV_FILE=$INSTALL_DIR/.env
if [ ! -f "$ENV_FILE" ]; then
    DB_PASSWORD=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
APP_VERSION=$APP_RELEASE
API_IMAGE=$API_IMAGE
WEB_IMAGE=$WEB_IMAGE
POSTGRES_IMAGE=postgres:17-alpine
DOMAIN=$LOCAL_DOMAIN
PUBLIC_URL=http://$LOCAL_DOMAIN
CORS_ALLOWED_ORIGINS=http://$LOCAL_DOMAIN,http://localhost
POSTGRES_DB=simple_pos
POSTGRES_USER=simple_pos
POSTGRES_PASSWORD=$DB_PASSWORD
DB_URL=jdbc:postgresql://postgres:5432/simple_pos
DB_USERNAME=simple_pos
DB_PASSWORD=$DB_PASSWORD
DB_MAX_POOL_SIZE=5
DB_MIN_IDLE=0
JWT_ISSUER=simple-pos-api
JWT_AUDIENCE=simple-pos-app
JWT_ACCESS_TOKEN_TTL=PT15M
JWT_REFRESH_TOKEN_TTL=P30D
OPENAPI_ENABLED=false
RATE_LIMIT_ENABLED=true
AUTH_RATE_LIMIT_REQUESTS=20
AUTH_RATE_LIMIT_WINDOW=PT1M
SIGNUP_RATE_LIMIT_REQUESTS=5
SIGNUP_RATE_LIMIT_WINDOW=PT10M
GENERAL_RATE_LIMIT_REQUESTS=600
GENERAL_RATE_LIMIT_WINDOW=PT1M
EOF
    chmod 600 "$ENV_FILE"
else
    # Repair installations made when /etc/os-release overwrote the image tag.
    INSTALLED_RELEASE=$(sed -n 's/^APP_VERSION=//p' "$ENV_FILE")
    if [ -n "${VERSION:-}" ] && [ "$INSTALLED_RELEASE" = "$VERSION" ] &&
        printf '%s' "$INSTALLED_RELEASE" | grep -q '[^A-Za-z0-9._-]'; then
        cp -p "$ENV_FILE" "$ENV_FILE.before-image-tag-fix-$(date +%s)"
        sed -i "s/^APP_VERSION=.*/APP_VERSION=$APP_RELEASE/" "$ENV_FILE"
        printf 'Repaired OS version used as image tag; now using %s.\n' "$APP_RELEASE"
    fi
fi

PRIVATE_KEY=$INSTALL_DIR/secrets/simple-pos-jwt-private.pem
PUBLIC_KEY=$INSTALL_DIR/secrets/simple-pos-jwt-public.pem
if [ ! -f "$PRIVATE_KEY" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$PRIVATE_KEY"
    chmod 600 "$PRIVATE_KEY"
fi
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY"
chmod 644 "$PUBLIC_KEY"

cat > "$INSTALL_DIR/nginx/default.conf" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name _;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location = /actuator/health/readiness {
        proxy_pass http://api:8080;
        access_log off;
    }

    location /actuator/ {
        return 403;
    }

    location / {
        root /usr/share/nginx/html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://api:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

NGINX
chmod 644 "$INSTALL_DIR/nginx/default.conf"

cd "$INSTALL_DIR"
docker compose pull postgres api web
if [ "${TCG_POS_DATABASE_ONLY:-0}" = 1 ]; then
    systemctl disable --now tcg-pos-update.service 2>/dev/null || true
    docker compose stop api web
    docker compose up -d --wait --wait-timeout 90 postgres
else
    docker compose up -d postgres api web
fi

cat > /etc/systemd/system/tcg-pos-update.service <<EOF
[Unit]
Description=Check for TCG POS application updates at boot
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment="TCG_POS_DIR=$INSTALL_DIR"
ExecStart=/bin/sh "$INSTALL_DIR/boot-update.sh"
TimeoutStartSec=10min

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if [ "${TCG_POS_DATABASE_ONLY:-0}" != 1 ]; then
    systemctl enable tcg-pos-update.service
else
    printf '\nDatabase ready for import; application startup and boot updates are deferred.\n'
    exit 0
fi
printf '\nTCG POS started. Open http://localhost on the Raspberry Pi.\n'
printf 'On the same local network, open http://%s (no www prefix).\n' "$LOCAL_DOMAIN"
printf 'From another device, open http://<raspberry-pi-ip>.\n'
