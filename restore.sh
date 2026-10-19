#!/bin/sh
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
BACKUP_PATH=${1:-}

if [ -z "$BACKUP_PATH" ] || [ ! -f "$BACKUP_PATH/database.dump" ]; then
    printf 'Usage: sudo %s /path/to/backup-directory\n' "$0" >&2
    exit 1
fi

printf 'Restore is intentionally guarded because it replaces production data.\n'
printf 'Set CONFIRM_RESTORE=YES after verifying the target and backup.\n'
[ "${CONFIRM_RESTORE:-}" = YES ] || exit 1

cd "$INSTALL_DIR"
docker compose stop api web
docker compose exec -T postgres dropdb \
    -U "$(sed -n 's/^POSTGRES_USER=//p' .env)" --if-exists "$(sed -n 's/^POSTGRES_DB=//p' .env)"
docker compose exec -T postgres createdb \
    -U "$(sed -n 's/^POSTGRES_USER=//p' .env)" "$(sed -n 's/^POSTGRES_DB=//p' .env)"
docker compose exec -T postgres pg_restore \
    -U "$(sed -n 's/^POSTGRES_USER=//p' .env)" \
    -d "$(sed -n 's/^POSTGRES_DB=//p' .env)" \
    --exit-on-error --no-owner --no-privileges < "$BACKUP_PATH/database.dump"

if [ -f "$BACKUP_PATH/assets.tar.gz" ]; then
    docker run --rm \
        -v tcg-pos_asset-data:/destination \
        -v "$BACKUP_PATH:/backup:ro" \
        alpine:3.22 sh -c 'find /destination -mindepth 1 -delete && tar -C /destination -xzf /backup/assets.tar.gz'
fi

docker compose up -d
docker compose ps

