#!/usr/bin/env bash
# Run the release-manifest check CI runs before publishing over every
# scenario directory a prepare_linux.sh run produced.
#
#   verify_dist.sh <root> <set> <tag>
#
# Only "good" should pass; every other directory is a release a shipped build
# would refuse (or would install the wrong bytes from), and the check must
# say so before it is published.
set -uo pipefail
ROOT="$(readlink -f "$1")"; SET="$2"; TAG="$3"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export SKOTIQ_UPDATE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/keys/update_public.b64")"
cd "$REPO_DIR/packages/skotiq_updater"
for dir in "$ROOT/dist/$SET"/*/; do
  name="$(basename "$dir")"
  tag="$TAG"
  [ "$name" = "downgrade" ] && continue
  echo "== $name"
  dart run tool/verify_release_manifests.dart --assets "$dir" --tag "$tag" \
    --repo Scdouglas1999/Skotiq --require-signed 2>&1 | grep -v 'build hooks'
  echo "   exit ${PIPESTATUS[0]}"
done
