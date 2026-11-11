#!/bin/sh
# Exercise update decisions without Docker, networking, or a real database.
set -eu
SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/install"
export TCG_POS_DIR="$TEST_DIR/install" LOG="$TEST_DIR/log"
export PATH="$TEST_DIR/bin:$PATH"
cat > "$TEST_DIR/bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat > "$TEST_DIR/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
case "$*" in
    'compose pull api web') [ "$SCENARIO" != offline ] ;;
    'compose ps -q '*) echo container ;;
    'compose config --images '*) echo image:latest ;;
    'image inspect '*) echo new ;;
    'inspect '*) if [ "$SCENARIO" = unchanged ]; then echo new; else echo old; fi ;;
    'compose up -d --wait --wait-timeout 90 --pull never postgres')
        [ "$SCENARIO" != database-failure ] ;;
    'compose up '*) [ "$SCENARIO" != apply-failure ] ;;
    *) exit 99 ;;
esac
EOF
cat > "$TCG_POS_DIR/backup.sh" <<'EOF'
#!/bin/sh
echo backup >> "$LOG"
[ "$SCENARIO" != backup-failure ]
EOF
chmod +x "$TEST_DIR/bin/"* "$TCG_POS_DIR/backup.sh"
for SCENARIO in offline unchanged changed backup-failure database-failure apply-failure; do
    export SCENARIO
    : > "$LOG"
    result=0
    sh "$SOURCE_DIR/boot-update.sh" || result=$?
    case "$SCENARIO" in
        offline|unchanged)
            [ "$result" -eq 0 ]
            ! grep -q '^backup\|^compose up' "$LOG"
            ;;
        changed)
            [ "$result" -eq 0 ]
            grep -q '^backup' "$LOG"
            grep -q '^compose up .*--pull never' "$LOG"
            ;;
        backup-failure)
            [ "$result" -ne 0 ]
            ! grep -q '^compose up .*postgres api web' "$LOG"
            ;;
        database-failure)
            [ "$result" -ne 0 ]
            ! grep -q '^backup' "$LOG"
            ! grep -q '^compose up .*postgres api web' "$LOG"
            ;;
        apply-failure)
            [ "$result" -ne 0 ]
            grep -q '^backup' "$LOG"
            ;;
    esac
    printf 'PASS: %s\n' "$SCENARIO"
done
