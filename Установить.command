#!/bin/bash
set -euo pipefail
cd -- "$(/usr/bin/dirname "$0")"
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Для сборки нужны Apple Command Line Tools. Установите их и запустите этот файл повторно.'
    /usr/bin/xcode-select --install || true
    read -r -p 'Нажмите Enter, чтобы закрыть окно…'
    exit 1
fi
/bin/bash scripts/build.sh
/bin/bash scripts/install.sh
