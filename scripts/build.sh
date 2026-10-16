#!/bin/bash
# Build a portable universal bundle; never install or change sleep settings.
set -euo pipefail
ROOT="$(cd -- "$(/usr/bin/dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Не засыпать.app"
[ "$(/usr/bin/uname -s)" = Darwin ] || { echo 'Нужна macOS 13 или новее.' >&2; exit 1; }
/usr/bin/xcrun --find swiftc >/dev/null || { echo 'Установите Command Line Tools: xcode-select --install' >&2; exit 1; }
TEMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keep-awake-build.XXXXXX")
trap '/bin/rm -rf "$TEMP"' EXIT
BUNDLE="$TEMP/Не засыпать.app"
/bin/mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$OUT"
/bin/cp "$ROOT/scripts/macos-keep-awake/Info.plist" "$BUNDLE/Contents/Info.plist"
/bin/cp "$ROOT/scripts/keep_awake.sh" "$BUNDLE/Contents/Resources/keep_awake.sh"
/bin/cp "$ROOT/README.md" "$BUNDLE/Contents/Resources/Инструкция.md"
/bin/bash "$ROOT/scripts/macos-keep-awake/build_icon.sh"
/bin/cp "$ROOT/scripts/macos-keep-awake/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
for ARCH in arm64 x86_64; do
    /usr/bin/xcrun swiftc -O -target "$ARCH-apple-macos13.0" -framework IOKit \
        "$ROOT/scripts/macos-keep-awake/BatteryGuard.swift" -o "$TEMP/BatteryGuard-$ARCH"
    /usr/bin/xcrun swiftc -parse-as-library -O -target "$ARCH-apple-macos13.0" \
        -framework SwiftUI -framework AppKit "$ROOT/scripts/macos-keep-awake/KeepAwake.swift" \
        -o "$TEMP/KeepAwake-$ARCH"
done
/usr/bin/lipo -create "$TEMP/BatteryGuard-arm64" "$TEMP/BatteryGuard-x86_64" -output "$BUNDLE/Contents/Resources/BatteryGuard"
/usr/bin/lipo -create "$TEMP/KeepAwake-arm64" "$TEMP/KeepAwake-x86_64" -output "$BUNDLE/Contents/MacOS/KeepAwake"
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$BUNDLE/Contents/Resources/BatteryGuard"
/usr/bin/codesign --force --sign - "$BUNDLE"
/usr/bin/codesign --verify --deep --strict "$BUNDLE"
"$BUNDLE/Contents/Resources/BatteryGuard" --self-test
"$BUNDLE/Contents/MacOS/KeepAwake" --self-test
# Only replace the generated output after all checks succeed.
/bin/rm -rf "$APP"
/bin/mv "$BUNDLE" "$APP"
printf 'Готово: %s\n' "$APP"
