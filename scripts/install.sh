#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(/usr/bin/dirname "$0")/.." && pwd)"
APP="$ROOT/build/Не засыпать.app"
DEST="$HOME/Applications/Не засыпать.app"
[ -d "$APP" ] || /bin/bash "$ROOT/scripts/build.sh"
if [ -e "$DEST" ]; then
    ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
    [ "$ID" = local.amster-apart.keep-awake.control ] || { echo 'Путь занят другим приложением.' >&2; exit 1; }
fi
/bin/mkdir -p "$HOME/Applications"
STAGING=$(/usr/bin/mktemp -d "$HOME/Applications/.keep-awake.XXXXXX")
trap '/bin/rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/Не засыпать.app"
if [ -e "$DEST" ]; then /bin/mv "$DEST" "$STAGING/previous.app"; fi
if ! /bin/mv "$STAGING/Не засыпать.app" "$DEST"; then
    if [ -d "$STAGING/previous.app" ]; then /bin/mv "$STAGING/previous.app" "$DEST"; fi
    exit 1
fi
printf 'Установлено: %s\n' "$DEST"
/usr/bin/open "$DEST"
