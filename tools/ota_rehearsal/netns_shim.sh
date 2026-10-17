#!/usr/bin/env bash
# Run a command where GitHub is the rehearsal server, without root.
#
#   netns_shim.sh <keys-dir> <command> [args...]
#
# Re-executes itself inside an unprivileged user + mount + network namespace
# and, only inside it:
#   - brings up loopback (the namespace has no other interface, so nothing
#     can reach the real GitHub by accident);
#   - bind-mounts an /etc/hosts that sends api.github.com, github.com and
#     objects.githubusercontent.com to 127.0.0.1, and an nsswitch.conf that
#     consults it before systemd-resolved;
#   - bind-mounts the system CA bundle with the rehearsal CA appended, because
#     Dart's TLS on Linux reads the system bundle and ignores SSL_CERT_FILE.
#
# The host's files are untouched; everything unwinds when the command exits.
set -euo pipefail

KEYS="$(readlink -f "$1")"; shift

if [ "${SK_OTA_IN_SHIM:-}" != "1" ]; then
  export SK_OTA_IN_SHIM=1
  exec unshare --user --map-root-user --mount --net -- "$0" "$KEYS" "$@"
fi

SHIM="$KEYS/shim"
mkdir -p "$SHIM"

ip link set lo up

{
  printf '127.0.0.1 localhost\n::1 localhost\n'
  printf '127.0.0.1 api.github.com github.com objects.githubusercontent.com\n'
} > "$SHIM/hosts"
mount --bind "$SHIM/hosts" /etc/hosts

sed -E 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf > "$SHIM/nsswitch.conf"
mount --bind "$SHIM/nsswitch.conf" /etc/nsswitch.conf

BUNDLE="$(readlink -f /etc/ssl/certs/ca-certificates.crt)"
cat "$BUNDLE" "$KEYS/tls/ca.crt" > "$SHIM/ca-bundle.pem"
mount --bind "$SHIM/ca-bundle.pem" "$BUNDLE"

exec "$@"
