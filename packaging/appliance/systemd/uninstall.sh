#!/usr/bin/env bash
# Uninstall the Skotiq headless appliance.
#
# Usage:
#   sudo ./uninstall.sh           # remove service + /opt/skotiq, keep data
#   sudo ./uninstall.sh --purge   # also delete /var/lib/skotiq,
#                                 # /etc/skotiq and the service user
set -euo pipefail

UNIT_NAME=skotiq-headless.service
SERVICE_USER=skotiq
UDEV_RULE_NAME=99-skotiq-astro.rules
PURGE=0

case "${1:-}" in
  --purge) PURGE=1 ;;
  "") ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (sudo $0)" >&2
  exit 1
fi

echo "== stopping service =="
systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$UNIT_NAME"
systemctl daemon-reload

echo "== removing application bundle =="
rm -rf /opt/skotiq
rm -f "/etc/udev/rules.d/$UDEV_RULE_NAME"
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi

if [ "$PURGE" -eq 1 ]; then
  echo "== purging data, config and user =="
  rm -rf /var/lib/skotiq /etc/skotiq
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    userdel "$SERVICE_USER" || true
  fi
  echo "Purged. All captured-image metadata, pairing DB and tokens are gone."
else
  echo "Kept /var/lib/skotiq (sequences, pairing DB, logs) and"
  echo "/etc/skotiq (tokens). Re-run with --purge to delete them."
fi

echo "Done."
