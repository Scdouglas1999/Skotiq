# Skotiq headless appliance — runtime container.
#
# This image does NOT compile anything. It consumes the release tarball that
# scripts/docker_build_linux.sh produces (that script runs the full
# rust + melos + `flutter build linux --release` pipeline inside the
# Debian Bookworm image (with the pinned Flutter SDK) and emits
# skotiq-linux-<arch>-<ver>.tar.gz). Two-step flow, from the repo root:
#
#   1. Build the release tarball (writes to ./dist-linux):
#        docker run --rm \
#          -v "$PWD":/host:ro \
#          -v "$PWD/dist-linux":/out \
#          debian:bookworm-slim \
#          bash /host/scripts/docker_build_linux.sh
#
#   2. Build this runtime image (BUNDLE_TARBALL is relative to the build
#      context, which should be the repo root):
#        docker build \
#          -f packaging/appliance/docker/Dockerfile \
#          --build-arg BUNDLE_TARBALL=dist-linux/skotiq-linux-x64-9.0.0.tar.gz \
#          -t skotiq-headless .
#
# Why no in-Dockerfile build stage: the build script intentionally snapshots
# the live working tree with rsync excludes and smoke-tests under xvfb; in a
# Dockerfile build stage every source change would invalidate a ~30 min layer
# and the tarball couldn't be reused for the systemd/Pi installs. Keeping the
# tarball as the single release artifact means systemd, Docker and Pi
# deployments all ship byte-identical bundles.

FROM debian:bookworm-slim

# Runtime counterparts of the build deps in scripts/docker_build_linux.sh
# (libgtk-3-dev -> libgtk-3-0, libsecret-1-dev -> libsecret-1-0, ...).
# xvfb + xauth: the Flutter GTK embedder initialises a display even in
# headless app mode, so the entrypoint wraps the daemon in xvfb-run — the
# same trick the build script's smoke test uses.
# Flutter loads GLES dynamically even in headless mode; Mesa supplies the
# software renderer when Xvfb has no GPU. These are not all visible to ldd.
# curl: healthcheck. ca-certificates: OTA update HTTPS + cloud push.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libgtk-3-0 \
    libsecret-1-0 \
    libjsoncpp25 \
    libssl3 \
    libudev1 \
    libusb-1.0-0 \
    libraw20 \
    libgl1 \
    libegl1 \
    libgles2 \
    libgl1-mesa-dri \
    xvfb \
    xauth \
    curl \
    ca-certificates \
    tini \
  && rm -rf /var/lib/apt/lists/*

# Path of the release tarball relative to the build context (repo root).
ARG BUNDLE_TARBALL=dist-linux/skotiq-linux-x64-9.0.0.tar.gz
# ADD auto-extracts local tarballs. The build script emits a flat archive;
# release.yml wraps the same files in skotiq-<version>-linux-<arch>/.
ADD ${BUNDLE_TARBALL} /opt/skotiq/unpacked/
COPY packaging/appliance/docker/normalize-bundle.sh /tmp/normalize-bundle.sh
RUN sh /tmp/normalize-bundle.sh /opt/skotiq/unpacked /opt/skotiq/bundle \
  && rm /tmp/normalize-bundle.sh

COPY packaging/appliance/docker/healthcheck.sh /usr/local/bin/skotiq-healthcheck
RUN chmod +x /usr/local/bin/skotiq-healthcheck \
  && useradd --system --uid 947 --user-group \
       --home-dir /var/lib/skotiq --create-home skotiq \
  && chmod 750 /var/lib/skotiq

# All persistent state lives under /var/lib/skotiq. App-support data comes
# from HOME; the Drift DB and native data roots are pinned explicitly so daemon
# runs never depend on a user Documents folder.
ENV HOME=/var/lib/skotiq \
    SKOTIQ_DATA_DIR=/var/lib/skotiq/data \
    SKOTIQ_DATABASE_DIR=/var/lib/skotiq/database \
    SKOTIQ_PORT=8080
VOLUME ["/var/lib/skotiq"]

USER skotiq
WORKDIR /var/lib/skotiq

# Headless API (TCP), UDP discovery beacons, LAN OTA push receiver.
# Only meaningful without host networking; with network_mode: host (the
# recommended mode, for mDNS/UDP discovery) these are informational.
EXPOSE 8080/tcp 45679/udp 45680/tcp

# GET /api/info is a public (unauthenticated) route, so the healthcheck
# works with auth enabled. The script falls back to https -k when TLS is on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/skotiq-healthcheck"]

# tini reaps the Xvfb child and forwards SIGTERM so main_headless.dart's
# shutdown path (mDNS unregister, API stop, OTA dispose) actually runs.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/xvfb-run", "-a", \
            "/opt/skotiq/bundle/skotiq", "--headless"]
