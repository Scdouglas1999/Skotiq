#!/bin/sh
# Accept the flat build-script archive or the release workflow's single folder.
set -eu

source_dir=$1
bundle_dir=$2

fail() {
  echo "Invalid Skotiq bundle layout: $*" >&2
  exit 1
}

[ ! -e "$bundle_dir" ] || fail "destination already exists"
if [ -f "$source_dir/skotiq" ] && [ -x "$source_dir/skotiq" ]; then
  for entry in "$source_dir"/skotiq-*-linux-*; do
    [ ! -e "$entry" ] || fail "both flat and versioned bundle roots are present"
  done
  mv "$source_dir" "$bundle_dir"
  exit 0
fi

count=0
candidate=
for entry in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  count=$((count + 1))
  candidate=$entry
done
[ "$count" -eq 1 ] || fail "expected one versioned bundle directory"
case "$candidate" in
  "$source_dir"/skotiq-*-linux-*) ;;
  *) fail "unexpected top-level directory" ;;
esac
[ -d "$candidate" ] || fail "versioned bundle root is not a directory"
[ -f "$candidate/skotiq" ] && [ -x "$candidate/skotiq" ] ||
  fail "skotiq executable is missing or not executable"
mv "$candidate" "$bundle_dir"
rmdir "$source_dir"
