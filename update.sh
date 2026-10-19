#!/bin/sh
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
cd "$INSTALL_DIR"

if [ "$#" -ne 1 ]; then
    printf 'Usage: sudo %s VERSION\n' "$0" >&2
    exit 1
fi

NEW_VERSION=$1
case "$NEW_VERSION" in
    *[!A-Za-z0-9._-]*|'') printf 'Invalid version: %s\n' "$NEW_VERSION" >&2; exit 1 ;;
esac

./backup.sh
sed -i.bak "s/^APP_VERSION=.*/APP_VERSION=$NEW_VERSION/" .env

if ! docker compose pull || ! docker compose up -d --remove-orphans; then
    mv .env.bak .env
    printf 'Update failed. The previous version was restored in .env; inspect the stack before retrying.\n' >&2
    exit 1
fi

rm -f .env.bak
docker compose ps

