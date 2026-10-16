#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(/usr/bin/dirname "$0")/.." && pwd)"
APP="$ROOT/build/Не засыпать.app"
[ -d "$APP" ] || { echo 'Сначала выполните bash scripts/build.sh' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="KeepAwake-$VERSION-universal.zip"
/usr/bin/codesign --verify --deep --strict "$APP"
/bin/mkdir -p "$ROOT/dist"
/bin/rm -f "$ROOT/dist/$NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/$NAME"
(cd "$ROOT/dist" && /usr/bin/shasum -a 256 "$NAME" > SHA256SUMS.txt)
printf 'Архив: %s/dist/%s\n' "$ROOT" "$NAME"
