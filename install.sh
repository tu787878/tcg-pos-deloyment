#!/bin/sh
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DOMAIN=
EMAIL=
VERSION=1.0.0
API_IMAGE=ghcr.io/tu787878/tcg-pos-api
WEB_IMAGE=ghcr.io/tu787878/tcg-pos-web
REGISTRY_USER=shibawannafly

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh \
  --domain restaurant-one.duckdns.org \
  --email owner@example.com

Optional overrides:
  --version VERSION
  --api-image IMAGE
  --web-image IMAGE
  --registry-user GITHUB_USERNAME
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN=${2:-}; shift 2 ;;
        --email) EMAIL=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --api-image) API_IMAGE=${2:-}; shift 2 ;;
        --web-image) WEB_IMAGE=${2:-}; shift 2 ;;
        --registry-user) REGISTRY_USER=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this installer with sudo.\n' >&2
    exit 1
fi

case "$DOMAIN" in
    ''|*[!A-Za-z0-9.-]*|.*|*.) printf 'Invalid domain.\n' >&2; exit 1 ;;
esac
case "$EMAIL" in
    *@*.*) ;;
    *) printf 'Invalid certificate email.\n' >&2; exit 1 ;;
esac
case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*) printf 'Invalid version.\n' >&2; exit 1 ;;
esac
case "$API_IMAGE:$WEB_IMAGE" in
    *[!A-Za-z0-9._/:@-]*) printf 'Invalid image name.\n' >&2; exit 1 ;;
esac
case "$REGISTRY_USER" in
    ''|*[!A-Za-z0-9_-]*) printf 'Invalid registry username.\n' >&2; exit 1 ;;
esac
if [ -z "$API_IMAGE" ] || [ -z "$WEB_IMAGE" ]; then
    usage >&2
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64|arm64) ;;
    *) printf 'Unsupported CPU architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
else
    printf 'Cannot identify the operating system.\n' >&2
    exit 1
fi
case "${ID:-}" in
    ubuntu|debian|raspbian) ;;
    *) printf 'Supported systems are Debian, Ubuntu, and Raspberry Pi OS 64-bit.\n' >&2; exit 1 ;;
esac

MEMORY_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ "${MEMORY_KB:-0}" -lt 3500000 ]; then
    printf 'At least 4 GB RAM is required (detected %s kB).\n' "${MEMORY_KB:-unknown}" >&2
    exit 1
fi
AVAILABLE_KB=$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${AVAILABLE_KB:-}" ] && [ "$AVAILABLE_KB" -lt 10485760 ]; then
    printf 'At least 10 GB free space is required under /opt.\n' >&2
    exit 1
fi

install_docker() {
    apt-get update
    apt-get install -y ca-certificates curl gnupg openssl
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
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
docker compose version >/dev/null
if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl openssl
fi

PUBLIC_IP=$(curl -fsS --max-time 15 https://api.ipify.org) || {
    printf 'Could not determine the server public IPv4 address.\n' >&2
    exit 1
}
DOMAIN_IPS=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
if ! printf '%s\n' "$DOMAIN_IPS" | grep -Fx "$PUBLIC_IP" >/dev/null 2>&1; then
    printf 'Domain %s does not resolve to this server (%s).\n' "$DOMAIN" "$PUBLIC_IP" >&2
    printf 'Resolved IPv4 addresses: %s\n' "${DOMAIN_IPS:-none}" >&2
    exit 1
fi

printf 'GHCR token for %s: ' "$REGISTRY_USER"
trap 'stty echo </dev/tty' EXIT INT TERM
stty -echo </dev/tty
IFS= read -r GHCR_TOKEN </dev/tty
stty echo </dev/tty
trap - EXIT INT TERM
printf '\n'
if [ -z "$GHCR_TOKEN" ]; then
    printf 'A GHCR token with read:packages access is required.\n' >&2
    exit 1
fi
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io \
    --username "$REGISTRY_USER" --password-stdin
unset GHCR_TOKEN

mkdir -p "$INSTALL_DIR/nginx" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/secrets" "$INSTALL_DIR/backups"
install -m 0644 "$SOURCE_DIR/compose.yaml" "$INSTALL_DIR/compose.yaml"
install -m 0755 "$SOURCE_DIR/update.sh" "$INSTALL_DIR/update.sh"
install -m 0755 "$SOURCE_DIR/backup.sh" "$INSTALL_DIR/backup.sh"
install -m 0755 "$SOURCE_DIR/restore.sh" "$INSTALL_DIR/restore.sh"
install -m 0644 "$SOURCE_DIR/nginx/bootstrap.conf.template" "$INSTALL_DIR/nginx/bootstrap.conf.template"
install -m 0644 "$SOURCE_DIR/nginx/https.conf.template" "$INSTALL_DIR/nginx/https.conf.template"

ENV_FILE=$INSTALL_DIR/.env
if [ ! -f "$ENV_FILE" ]; then
    DB_PASSWORD=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
APP_VERSION=$VERSION
API_IMAGE=$API_IMAGE
WEB_IMAGE=$WEB_IMAGE
POSTGRES_IMAGE=postgres:17-alpine
CERTBOT_IMAGE=certbot/certbot:v5.1.0
DOMAIN=$DOMAIN
PUBLIC_URL=https://$DOMAIN
CORS_ALLOWED_ORIGINS=https://$DOMAIN
LETSENCRYPT_EMAIL=$EMAIL
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
    INSTALLED_DOMAIN=$(sed -n 's/^DOMAIN=//p' "$ENV_FILE")
    if [ "$INSTALLED_DOMAIN" != "$DOMAIN" ]; then
        printf 'This installation is already configured for %s, not %s.\n' "$INSTALLED_DOMAIN" "$DOMAIN" >&2
        exit 1
    fi
fi

PRIVATE_KEY=$INSTALL_DIR/secrets/simple-pos-jwt-private.pem
PUBLIC_KEY=$INSTALL_DIR/secrets/simple-pos-jwt-public.pem
if [ ! -f "$PRIVATE_KEY" ] || [ ! -f "$PUBLIC_KEY" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$PRIVATE_KEY"
    openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY"
    chmod 600 "$PRIVATE_KEY"
    chmod 644 "$PUBLIC_KEY"
fi

render_nginx() {
    sed "s/__DOMAIN__/$DOMAIN/g" "$1" > "$INSTALL_DIR/nginx/default.conf"
    chmod 644 "$INSTALL_DIR/nginx/default.conf"
}

cd "$INSTALL_DIR"
render_nginx "$INSTALL_DIR/nginx/bootstrap.conf.template"
docker compose config --quiet
docker compose pull
docker compose up -d postgres api web

docker compose --profile tools run --rm certbot certonly \
    --webroot --webroot-path /var/www/certbot \
    --domain "$DOMAIN" --email "$EMAIL" \
    --agree-tos --no-eff-email --non-interactive

render_nginx "$INSTALL_DIR/nginx/https.conf.template"
docker compose exec -T web nginx -t
docker compose exec -T web nginx -s reload

cat > /etc/cron.d/tcg-pos-cert-renew <<EOF
17 3 * * * root cd $INSTALL_DIR && docker compose --profile tools run --rm certbot renew --quiet && docker compose exec -T web nginx -s reload
EOF
chmod 644 /etc/cron.d/tcg-pos-cert-renew

wait_for_url() {
    URL=$1
    LABEL=$2
    ATTEMPT=1
    while [ "$ATTEMPT" -le 12 ]; do
        if curl --fail --silent --show-error --max-time 10 "$URL" >/dev/null; then
            printf '%s is ready.\n' "$LABEL"
            return 0
        fi
        printf 'Waiting for %s (%s/12)...\n' "$LABEL" "$ATTEMPT"
        sleep 5
        ATTEMPT=$((ATTEMPT + 1))
    done
    printf '%s did not become ready: %s\n' "$LABEL" "$URL" >&2
    return 1
}

wait_for_url "https://$DOMAIN/healthz" 'Web application'
wait_for_url "https://$DOMAIN/actuator/health/readiness" 'API'

docker compose ps
printf '\nTCG POS is available at https://%s\n' "$DOMAIN"
