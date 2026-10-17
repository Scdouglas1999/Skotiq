#!/bin/sh
# Container healthcheck for the Skotiq headless appliance.
#
# GET /api/status is registered as a public (no-auth) route in
# apps/desktop/lib/headless_api/routes/system_routes.dart, so this works
# even when SKOTIQ_AUTH_TOKEN is set. The server serves either plain
# HTTP or HTTPS (self-signed by default) on the same port depending on
# SKOTIQ_TLS*, so probe http first and fall back to https with -k
# (the cert is self-signed; identity is pinned by clients via the SPKI
# fingerprint, not a CA chain — `-k` here is fine for a liveness probe).
set -eu

PORT="${SKOTIQ_PORT:-8080}"

if curl -fsS -m 4 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
  exit 0
fi
if curl -fsSk -m 4 "https://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
  exit 0
fi
echo "healthcheck: /api/status unreachable on port ${PORT} (http and https)" >&2
exit 1
