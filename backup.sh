#!/bin/sh
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
BACKUP_DIR=${BACKUP_DIR:-$INSTALL_DIR/backups}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DESTINATION=$BACKUP_DIR/$STAMP

cd "$INSTALL_DIR"
mkdir -p "$DESTINATION"
chmod 700 "$BACKUP_DIR" "$DESTINATION"

docker compose exec -T postgres pg_dump \
    -U "$(sed -n 's/^POSTGRES_USER=//p' .env)" \
    -d "$(sed -n 's/^POSTGRES_DB=//p' .env)" \
    --format=custom --no-owner --no-privileges > "$DESTINATION/database.dump"

docker run --rm \
    -v tcg-pos_asset-data:/source:ro \
    -v "$DESTINATION:/backup" \
    alpine:3.22 tar -C /source -czf /backup/assets.tar.gz .

cp .env compose.yaml "$DESTINATION/"
cp -R secrets "$DESTINATION/secrets"
chmod -R go-rwx "$DESTINATION"
printf 'Backup created: %s\n' "$DESTINATION"
printf 'Copy and encrypt this directory on storage outside this server.\n'

