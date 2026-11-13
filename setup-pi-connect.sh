#!/bin/sh
# Run as the Pi login user, not root. Sudo is used only for system changes.
set -eu
if [ "$(id -u)" -eq 0 ]; then
    printf 'Run as your normal Pi user, without sudo.\n' >&2
    exit 1
fi
. /etc/os-release
case "${VERSION_ID:-}" in
    ''|*[!0-9]*) printf 'Cannot identify a supported Raspberry Pi OS release.\n' >&2; exit 1 ;;
esac
if [ "$VERSION_ID" -lt 12 ]; then
    printf 'Raspberry Pi Connect requires Raspberry Pi OS Bookworm or later.\n' >&2
    exit 1
fi
sudo apt-get update
# Preserve a full desktop Connect installation if already present.
if dpkg-query -W -f='${Status}' rpi-connect 2>/dev/null | grep -q 'install ok installed'; then
    sudo apt-get install -y rpi-connect
else
    sudo apt-get install -y rpi-connect-lite
fi
sudo loginctl enable-linger "$(id -un)"
rpi-connect on
printf '\nOpen the verification URL printed below in your browser and sign in to your Raspberry Pi account.\n'
rpi-connect signin
rpi-connect shell on
rpi-connect status
printf '\nVisit https://connect.raspberrypi.com and test Remote shell, then test again after reboot.\n'
