#!/bin/sh
# Skotiq Pi appliance — Wi-Fi hotspot fallback provisioning.
#
# Flow (every boot, cheap when already online):
#   1. Wait up to WAIT_SECS for NetworkManager to bring up any connection
#      (known Wi-Fi profile, or Ethernet). Online -> exit 0.
#   2. No network: bring up an open... no — a WPA2 hotspot "Skotiq-XXXX"
#      (XXXX = last 4 hex of the wlan MAC, password "skotiq") via
#      `nmcli device wifi hotspot`. NM shared mode hands out DHCP and the
#      dnsmasq-shared.d captive config resolves every name to 10.42.0.1.
#   3. Run provision_portal.py (foreground). The portal serves the
#      credentials form on http://10.42.0.1:80, and on submit writes
#      "<ssid>\n<psk>" to $CREDS_FILE and exits 0.
#   4. Tear the hotspot down, try `nmcli dev wifi connect`. Success ->
#      profile persists (autoconnect) and we exit. Failure -> hotspot back
#      up, portal again (with the failure shown), forever. Robust > clever.
#
# The headless server itself has no Wi-Fi provisioning mode (verified
# against apps/desktop/lib/main_headless.dart), hence this standalone
# portal. Requires NetworkManager (default on Raspberry Pi OS Bookworm)
# and python3 (in the base image).
set -u

WAIT_SECS="${SKOTIQ_PROVISION_WAIT:-90}"
HOTSPOT_CON=skotiq-setup
HOTSPOT_PASS="${SKOTIQ_HOTSPOT_PASS:-skotiq}"
PORTAL=/usr/local/lib/skotiq/provision_portal.py
RUN_DIR=/run/skotiq-provision
CREDS_FILE="$RUN_DIR/creds"
STATUS_FILE="$RUN_DIR/last_error"

log() { echo "netprovision: $*"; }

is_online() {
  # "full" or "limited" connectivity, or any active non-hotspot connection
  # (Ethernet plugged in, or a known Wi-Fi joined).
  state="$(nmcli -t -f STATE general status 2>/dev/null | head -n1)"
  case "$state" in
    connected|connected\ *) return 0 ;;
  esac
  return 1
}

wifi_ifname() {
  nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
    | awk -F: '$2 == "wifi" { print $1; exit }'
}

hotspot_down() {
  nmcli connection down "$HOTSPOT_CON" >/dev/null 2>&1
  nmcli connection delete "$HOTSPOT_CON" >/dev/null 2>&1
}

# ── 1. Grace period for a known network ─────────────────────────────────────
log "waiting up to ${WAIT_SECS}s for a known network..."
elapsed=0
while [ "$elapsed" -lt "$WAIT_SECS" ]; do
  if is_online; then
    log "online — no provisioning needed."
    exit 0
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

IFNAME="$(wifi_ifname)"
if [ -z "$IFNAME" ]; then
  log "no Wi-Fi interface found; cannot start fallback hotspot. Giving up."
  exit 0
fi

MAC_SUFFIX="$(tr -d ':' < "/sys/class/net/$IFNAME/address" 2>/dev/null \
  | tail -c 5 | tr '[:lower:]' '[:upper:]')"
SSID="Skotiq-${MAC_SUFFIX:-SETUP}"
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

# ── 2..4. Hotspot/portal/join loop ──────────────────────────────────────────
while :; do
  rm -f "$CREDS_FILE"
  log "starting hotspot '$SSID' on $IFNAME"
  hotspot_down  # clear any stale profile from a previous round
  if ! nmcli device wifi hotspot ifname "$IFNAME" con-name "$HOTSPOT_CON" \
        ssid "$SSID" password "$HOTSPOT_PASS"; then
    log "hotspot failed to start (regulatory domain not set? rfkill?)."
    log "retrying in 60s; check 'rfkill list' and the Wi-Fi country setting."
    sleep 60
    continue
  fi
  log "hotspot up. Join '$SSID' (password: $HOTSPOT_PASS) and browse to http://10.42.0.1"

  # Portal blocks until credentials are submitted, then exits 0. Non-zero
  # exit (crash) -> loop restarts the hotspot+portal.
  if ! python3 "$PORTAL" --creds-file "$CREDS_FILE" --status-file "$STATUS_FILE"; then
    log "portal exited abnormally; restarting cycle."
    sleep 5
    continue
  fi
  [ -s "$CREDS_FILE" ] || { log "portal exited without creds; restarting."; continue; }

  TARGET_SSID="$(sed -n '1p' "$CREDS_FILE")"
  TARGET_PSK="$(sed -n '2p' "$CREDS_FILE")"
  rm -f "$CREDS_FILE"

  log "attempting to join '$TARGET_SSID'..."
  hotspot_down
  sleep 3  # let the radio leave AP mode

  if nmcli device wifi connect "$TARGET_SSID" password "$TARGET_PSK" \
       ifname "$IFNAME"; then
    log "joined '$TARGET_SSID'. Profile saved; will autoconnect on boot."
    rm -f "$STATUS_FILE"
    exit 0
  fi

  log "join failed; bringing the hotspot back."
  # NM saves a profile even for the failed attempt; delete it so it does
  # not shadow future attempts or autoconnect-loop against a bad PSK.
  nmcli connection delete "$TARGET_SSID" >/dev/null 2>&1
  printf 'Could not join "%s" — wrong password or out of range. Try again.\n' \
    "$TARGET_SSID" > "$STATUS_FILE"
done
