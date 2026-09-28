#!/usr/bin/env bash
# Point a rooted Android emulator's view of GitHub at the rehearsal server.
#
#   android_prepare.sh <keys-dir> <serial> [host-port]
#
# Needs a google_apis (not google_play) system image, so `adb root` works.
# Nothing is written to the system image: both overrides are mounts that
# vanish when the emulator shuts down.
#   - The rehearsal CA is added to /system/etc/security/cacerts, which is the
#     store Dart's TLS reads on Android (it does not use the Java trust
#     manager, so network_security_config does not apply to it).
#   - /system/etc/hosts sends the three GitHub names to 127.0.0.1, and
#     `adb reverse` carries the emulator's port 443 to the host's
#     fake_github.py on [host-port] (default 8443).
set -euo pipefail

KEYS="$(readlink -f "$1")"; SERIAL="$2"; PORT="${3:-8443}"
ADB=(adb -s "$SERIAL")
WORK="$KEYS/android"
mkdir -p "$WORK"

HASH="$(openssl x509 -inform PEM -subject_hash_old -noout -in "$KEYS/tls/ca.crt")"
cp "$KEYS/tls/ca.crt" "$WORK/$HASH.0"
{
  printf '127.0.0.1 localhost\n::1 ip6-localhost\n'
  printf '127.0.0.1 api.github.com github.com objects.githubusercontent.com\n'
} > "$WORK/hosts"

"${ADB[@]}" root >/dev/null 2>&1 || true
sleep 2
"${ADB[@]}" push "$WORK/$HASH.0" /data/local/tmp/rehearsal-ca.0 >/dev/null
"${ADB[@]}" push "$WORK/hosts" /data/local/tmp/rehearsal-hosts >/dev/null
"${ADB[@]}" shell "
  set -e
  if ! grep -q ' /system/etc/security/cacerts ' /proc/mounts; then
    mkdir -p /data/local/tmp/cacerts
    cp /system/etc/security/cacerts/* /data/local/tmp/cacerts/
    mount -t tmpfs tmpfs /system/etc/security/cacerts
    cp /data/local/tmp/cacerts/* /system/etc/security/cacerts/
  fi
  cp /data/local/tmp/rehearsal-ca.0 /system/etc/security/cacerts/$HASH.0
  chmod 644 /system/etc/security/cacerts/*
  chcon u:object_r:system_file:s0 /system/etc/security/cacerts/* 2>/dev/null || true
  chmod 644 /data/local/tmp/rehearsal-hosts
  chcon u:object_r:system_file:s0 /data/local/tmp/rehearsal-hosts 2>/dev/null || true
  grep -q ' /system/etc/hosts ' /proc/mounts || mount -o bind /data/local/tmp/rehearsal-hosts /system/etc/hosts
"
"${ADB[@]}" reverse tcp:443 "tcp:$PORT"
echo "emulator $SERIAL now resolves GitHub to the rehearsal server on host port $PORT"
