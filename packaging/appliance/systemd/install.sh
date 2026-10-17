#!/usr/bin/env bash
# Install the Skotiq headless appliance on a systemd Linux host.
#
# Usage:
#   sudo ./install.sh --tarball /path/to/skotiq-linux-<arch>-<ver>.tar.gz
#   sudo ./install.sh --bundle-dir /path/to/build/linux/<arch>/release/bundle
#   sudo ./install.sh                # unit/user/dirs only, bundle already in place
#
# What it does:
#   1. Creates the dedicated `skotiq` system user (+ device-access groups).
#   2. Creates /opt/skotiq/bundle, /var/lib/skotiq, /etc/skotiq.
#   3. Unpacks the release tarball (from scripts/docker_build_linux.sh) into
#      /opt/skotiq/bundle.
#   4. Installs skotiq-headless.service and /etc/skotiq/headless.env
#      (generating a random auth token on first install), plus udev rules for
#      astronomy USB devices.
#   5. Enables + starts the service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT=/opt/skotiq
BUNDLE_DIR="$INSTALL_ROOT/bundle"
STATE_DIR=/var/lib/skotiq
CONF_DIR=/etc/skotiq
ENV_FILE="$CONF_DIR/headless.env"
UNIT_NAME=skotiq-headless.service
SERVICE_USER=skotiq
SERVICE_GROUP=skotiq
UDEV_RULE_NAME=99-skotiq-astro.rules

TARBALL=""
SRC_BUNDLE_DIR=""
NO_START=0

usage() { sed -n '2,12p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball)    TARBALL="${2:?--tarball needs a path}"; shift 2 ;;
    --bundle-dir) SRC_BUNDLE_DIR="${2:?--bundle-dir needs a path}"; shift 2 ;;
    --no-start)   NO_START=1; shift ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (sudo $0 ...)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found — this installer targets systemd hosts." >&2
  exit 1
fi

if ! command -v xvfb-run >/dev/null 2>&1 || ! command -v xauth >/dev/null 2>&1; then
  echo "WARNING: xvfb-run/xauth not found. The unit wraps the daemon in xvfb-run" >&2
  echo "         (the Flutter GTK embedder needs a display even headless)." >&2
  echo "         Install them first: Debian/RPi OS: apt install xvfb xauth" >&2
  echo "                             Arch:          pacman -S xorg-server-xvfb xorg-xauth" >&2
fi

echo "== [1/5] service user =="
if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
  groupadd --system "$SERVICE_GROUP"
  echo "Created system group '$SERVICE_GROUP'"
fi
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$STATE_DIR" --create-home \
    --gid "$SERVICE_GROUP" --shell /usr/sbin/nologin "$SERVICE_USER"
  echo "Created system user '$SERVICE_USER'"
else
  echo "User '$SERVICE_USER' already exists"
  usermod -aG "$SERVICE_GROUP" "$SERVICE_USER"
fi
# Device-access groups for cameras / mounts / focusers. Not all distros have
# all three; add the ones that exist. The appliance udev rules additionally
# grant direct access to the dedicated skotiq group.
for grp in dialout video plugdev; do
  if getent group "$grp" >/dev/null 2>&1; then
    usermod -aG "$grp" "$SERVICE_USER"
  fi
done

echo "== [2/5] directories =="
mkdir -p "$BUNDLE_DIR" "$STATE_DIR" "$CONF_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR"
chmod 750 "$STATE_DIR"

echo "== [3/5] application bundle =="
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || { echo "ERROR: tarball not found: $TARBALL" >&2; exit 1; }
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"
  tar -xzf "$TARBALL" -C "$BUNDLE_DIR"
elif [ -n "$SRC_BUNDLE_DIR" ]; then
  [ -d "$SRC_BUNDLE_DIR" ] || { echo "ERROR: bundle dir not found: $SRC_BUNDLE_DIR" >&2; exit 1; }
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"
  cp -a "$SRC_BUNDLE_DIR/." "$BUNDLE_DIR/"
else
  echo "No --tarball/--bundle-dir given; assuming bundle already at $BUNDLE_DIR"
fi
if [ ! -x "$BUNDLE_DIR/skotiq" ]; then
  echo "ERROR: $BUNDLE_DIR/skotiq missing or not executable." >&2
  echo "Build it with scripts/docker_build_linux.sh and pass --tarball." >&2
  exit 1
fi
# Bundle is read-only at runtime; root-owned keeps the OTA updater honest
# (in-place OTA from the service is not possible with this layout — apply
# updates by re-running install.sh with a new tarball, or relax ownership).
chown -R root:root "$INSTALL_ROOT"

echo "== [4/5] config + unit =="
if [ ! -f "$ENV_FILE" ]; then
  install -m 0640 -o root -g "$SERVICE_USER" \
    "$SCRIPT_DIR/headless.env.example" "$ENV_FILE"
  # First install: replace the placeholder with a real random token so the
  # box is never accidentally exposed with a known credential.
  TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i "s/^SKOTIQ_AUTH_TOKEN=.*/SKOTIQ_AUTH_TOKEN=$TOKEN/" "$ENV_FILE"
  echo "Wrote $ENV_FILE with a freshly generated auth token."
  echo "Read it with: sudo grep SKOTIQ_AUTH_TOKEN $ENV_FILE"
else
  echo "$ENV_FILE already exists — leaving it untouched."
fi
install -m 0644 "$SCRIPT_DIR/skotiq-headless.service" \
  "/etc/systemd/system/$UNIT_NAME"
install -m 0644 "$SCRIPT_DIR/$UDEV_RULE_NAME" \
  "/etc/udev/rules.d/$UDEV_RULE_NAME"
# Static Avahi advertisement. The in-app `nsd` mDNS registration has no Linux
# implementation, so without this the appliance is only discoverable over the
# fragile UDP broadcast beacon. Drop the service file into Avahi's pickup dir;
# avahi-daemon advertises `_skotiq._tcp` for us. Best-effort: only if Avahi
# is present (RPi OS ships it; minimal hosts may not).
AVAHI_SRC="$SCRIPT_DIR/../avahi/skotiq.service"
if [ -d /etc/avahi/services ] || command -v avahi-daemon >/dev/null 2>&1; then
  install -d -m 0755 /etc/avahi/services
  install -m 0644 "$AVAHI_SRC" /etc/avahi/services/skotiq.service
  # The template carries a @PORT@ placeholder. Substitute the configured
  # SKOTIQ_PORT (default 8080) so the seed advertisement is correct before
  # the first daemon start; the daemon then rewrites this file on every boot to
  # track the live bound port + scheme (see main_headless.dart).
  AVAHI_PORT="$( (grep -E '^SKOTIQ_PORT=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2) || true )"
  AVAHI_PORT="${AVAHI_PORT:-8080}"
  sed -i "s/@PORT@/$AVAHI_PORT/" /etc/avahi/services/skotiq.service
  echo "Installed Avahi mDNS advertisement (/etc/avahi/services/skotiq.service, port $AVAHI_PORT)."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload avahi-daemon 2>/dev/null \
      || systemctl restart avahi-daemon 2>/dev/null || true
  fi
else
  echo "NOTE: Avahi not detected — mDNS discovery will be unavailable; the UDP"
  echo "      broadcast beacon (45679) remains. Install avahi-daemon for mDNS."
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
  udevadm trigger --subsystem-match=usb --subsystem-match=tty \
    --subsystem-match=hidraw || true
fi
systemctl daemon-reload

echo "== [5/5] enable + start =="
systemctl enable "$UNIT_NAME"
if [ "$NO_START" -eq 1 ]; then
  echo "Skipping start (--no-start). Start later with:"
  echo "  sudo systemctl start $UNIT_NAME"
else
  systemctl restart "$UNIT_NAME"
  sleep 2
  systemctl --no-pager --lines=10 status "$UNIT_NAME" || true
fi

echo
echo "Done. Useful commands:"
echo "  journalctl -fu $UNIT_NAME        # live logs (pairing codes print here)"
echo "  sudo systemctl restart $UNIT_NAME"
echo "  curl http://127.0.0.1:\${SKOTIQ_PORT:-8080}/api/status"
