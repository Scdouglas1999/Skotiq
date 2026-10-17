#!/bin/sh
# Skotiq Pi appliance — one-shot first-boot setup.
#
# Runs once (stamp file guarded, plus ConditionPathExists in the unit).
# Its only real job is to make sure xvfb-run and xauth exist: the systemd unit
# wraps the Flutter daemon in xvfb-run (the GTK embedder needs a display even
# in headless app mode), and build_pi_image.sh can only bake those packages
# into the image when the build host has qemu-user-static binfmt set up.
#
# It deliberately does NOT create the skotiq user or directories —
# systemd-sysusers (/etc/sysusers.d/skotiq.conf) and the unit's
# StateDirectory= handle those declaratively.
set -eu

STAMP=/var/lib/skotiq-firstboot.done

if [ -f "$STAMP" ]; then
  exit 0
fi

if command -v xvfb-run >/dev/null 2>&1 && command -v xauth >/dev/null 2>&1; then
  echo "skotiq-firstboot: xvfb/xauth already present (baked into image)."
else
  echo "skotiq-firstboot: installing xvfb/xauth (needs network)..."
  # Wait briefly for apt to be able to resolve/download — first boot races
  # the Wi-Fi provisioning service. The unit also orders itself after
  # network-online.target, so this loop is a belt-and-braces retry.
  tries=0
  until apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xvfb xauth; do
    tries=$((tries + 1))
    if [ "$tries" -ge 10 ]; then
      echo "skotiq-firstboot: FAILED to install xvfb/xauth after $tries tries." >&2
      echo "skotiq-headless will not start until 'apt install xvfb xauth'" >&2
      echo "succeeds. NOT writing the stamp so this retries next boot." >&2
      exit 1
    fi
    echo "skotiq-firstboot: apt failed (no network yet?), retry $tries/10 in 30s"
    sleep 30
  done
fi

touch "$STAMP"
echo "skotiq-firstboot: done."
