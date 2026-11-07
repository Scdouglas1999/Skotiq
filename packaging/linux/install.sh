#!/usr/bin/env bash
# Install this Skotiq archive for the current user.
#
#   ./install.sh            copy to ~/.local/opt/skotiq-<version> and add a
#                           menu entry and icon
#   ./install.sh --remove   remove this version and its menu entry
#
# Nothing is written outside your home directory, and no root is needed. An
# older version's menu entry is replaced; the older version's files are left
# where they are (delete ~/.local/opt/skotiq-<old> yourself when you no longer
# need it). Your observing data lives elsewhere and is not touched.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NAME="$(basename "$HERE")"                      # skotiq-8.2.2-linux-x64
VERSION="${NAME#skotiq-}"; VERSION="${VERSION%-linux-x64}"
if [ -z "$VERSION" ] || [ "$VERSION" = "$NAME" ]; then
  echo "install.sh: run this from the extracted skotiq-<version>-linux-x64 folder" >&2
  exit 1
fi

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
OPT="$HOME/.local/opt"
DEST="$OPT/skotiq-$VERSION"
APPS="$DATA_HOME/applications"
ICONS="$DATA_HOME/icons/hicolor"
ENTRY="$APPS/skotiq.desktop"

refresh_menus() {
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
  gtk-update-icon-cache -q -t "$ICONS" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--remove" ]; then
  if [ -f "$ENTRY" ] && grep -q "^Exec=$DEST/" "$ENTRY"; then
    rm -f "$ENTRY"
  fi
  if [ "$(readlink "$HOME/.local/bin/skotiq" 2>/dev/null)" = "$DEST/skotiq" ]; then
    rm -f "$HOME/.local/bin/skotiq"
  fi
  rm -rf "$DEST"
  refresh_menus
  echo "Removed Skotiq $VERSION."
  exit 0
fi

if [ ! -x "$HERE/skotiq" ] || [ ! -f "$HERE/skotiq.bin" ]; then
  echo "install.sh: $HERE does not look like a Skotiq archive (no skotiq launcher)" >&2
  exit 1
fi

# 1. Files.
mkdir -p "$OPT"
if [ "$HERE" != "$DEST" ]; then
  rm -rf "$DEST.partial"
  cp -a "$HERE" "$DEST.partial"
  rm -rf "$DEST"
  mv "$DEST.partial" "$DEST"
fi

# 2. Icons.
for size in 16 32 48 64 128 256 512; do
  src="$DEST/icons/skotiq_${size}.png"
  [ -f "$src" ] || continue
  mkdir -p "$ICONS/${size}x${size}/apps"
  cp "$src" "$ICONS/${size}x${size}/apps/skotiq.png"
done

# 3. Menu entry. Older entries are removed first: the one an earlier
#    install.sh wrote (same file name), hand-made per-version entries
#    (skotiq-<version>.desktop) and the one the old manual instructions made
#    (com.skotiq.desktop.desktop), so the menu shows one Skotiq.
mkdir -p "$APPS"
for old in "$APPS"/skotiq-[0-9]*.desktop "$APPS/com.skotiq.desktop.desktop"; do
  [ -f "$old" ] || continue
  if grep -q "^Exec=.*skotiq" "$old"; then
    echo "Replacing older menu entry $(basename "$old")"
    rm -f "$old"
  fi
done
sed -e "s|^Exec=.*|Exec=$DEST/skotiq|" \
    -e "s|^Icon=.*|Icon=skotiq|" \
    -e "/^# install.sh rewrites/,/^# paths. As shipped/d" \
    "$DEST/skotiq.desktop" > "$ENTRY.tmp"
printf 'Path=%s\n' "$DEST" >> "$ENTRY.tmp"
mv "$ENTRY.tmp" "$ENTRY"
chmod 0644 "$ENTRY"

# 4. A `skotiq` command, when ~/.local/bin is where this user keeps them.
if [ -d "$HOME/.local/bin" ]; then
  ln -sfn "$DEST/skotiq" "$HOME/.local/bin/skotiq"
fi

refresh_menus
echo "Installed Skotiq $VERSION in $DEST"
echo "Start it from your application menu, or run $DEST/skotiq"
