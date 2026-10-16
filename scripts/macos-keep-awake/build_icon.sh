#!/bin/bash
set -euo pipefail

SOURCE_DIR="$(cd -- "$(/usr/bin/dirname "$0")" && pwd)"
ICON_SOURCE="$SOURCE_DIR/AppIcon.png"
ICON_BUILD=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/amster-icon.XXXXXX")
trap '/bin/rm -rf "$ICON_BUILD"' EXIT
ICONSET="$ICON_BUILD/AppIcon.iconset"
/bin/mkdir -p "$ICONSET"

for ICON_SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_DOUBLE=$((ICON_SIZE * 2))
    /usr/bin/sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$SOURCE_DIR/AppIcon.icns" "$ICONSET"
printf 'Иконка собрана: %s\n' "$SOURCE_DIR/AppIcon.icns"
