#!/bin/sh
# Best-effort application update. Existing containers keep running during pulls.
set -eu

INSTALL_DIR=${TCG_POS_DIR:-/opt/tcg-pos}
cd "$INSTALL_DIR"
exec 9>"$INSTALL_DIR/.update.lock"
flock -n 9 || exit 0

# The local boot updater follows latest independently of manual version pins.
export APP_VERSION=latest
if ! timeout 180 docker compose pull api web; then
    printf 'Update download failed or timed out; keeping the installed containers.\n' >&2
    exit 0
fi

changed=false
for service in api web; do
    container=$(docker compose ps -q "$service")
    # Inspect the configured image, not the currently running container image.
    image=$(docker compose config --images "$service")
    desired=$(docker image inspect --format '{{.Id}}' "$image")
    current=
    if [ -n "$container" ]; then
        current=$(docker inspect --format '{{.Image}}' "$container")
    fi
    [ "$current" = "$desired" ] || changed=true
done

if [ "$changed" = false ]; then
    printf 'POS images are already up to date.\n'
    exit 0
fi

# Never apply an update if the pre-update backup fails.
# Docker's reboot restart can race this service; wait for PostgreSQL first.
docker compose up -d --wait --wait-timeout 90 --pull never postgres
./backup.sh
docker compose up -d --wait --wait-timeout 180 --pull never postgres api web
printf 'POS updated successfully.\n'
