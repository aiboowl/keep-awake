#!/bin/bash
# macOS only. Uses native system power-management utilities.
set -euo pipefail
umask 077

LABEL="local.amster-apart.keep-awake"
STATE_DIR="$HOME/Library/Application Support/AmsterApart/keep-awake"
SAVED_SETTING="$STATE_DIR/original-sleep-disabled"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUARD_LABEL="$LABEL.battery"
GUARD_PLIST="$HOME/Library/LaunchAgents/$GUARD_LABEL.plist"
ECO_LIMIT="$STATE_DIR/eco-limit"
DOMAIN="gui/$(/usr/bin/id -u)"
CURRENT_UID="$(/usr/bin/id -u)"
case "$CURRENT_UID" in ''|*[!0-9]*) printf '%s\n' "Не удалось определить пользователя." >&2; exit 1 ;; esac
ACCESS_FILE="/private/etc/sudoers.d/amster-keep-awake-$CURRENT_UID"

fail() { printf '%s\n' "$*" >&2; exit 1; }

passwordless_ready() {
    local rules
    rules=$(/usr/bin/sudo -n -l 2>/dev/null | /usr/bin/tr -s '[:space:]' ' ') || return 1
    case "$rules" in
        *"NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"*) return 0 ;;
        *) return 1 ;;
    esac
}

administrator_command() {
    if [ -t 0 ]; then
        /usr/bin/sudo /bin/sh -c "$1"
    else
        /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
    do shell script (item 1 of argv) with administrator privileges
end run
APPLESCRIPT
    fi
}

setup_access() {
    lock_state
    if passwordless_ready; then
        printf '%s\n' "Переключение без пароля уже настроено."
        return
    fi
    local installation
    installation=$(/bin/cat <<INSTALL
set -eu
if ! /usr/bin/grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+(/private)?/etc/sudoers[.]d([[:space:]]|\$)' /private/etc/sudoers; then
    printf '%s\\n' 'В системе отсутствует стандартное подключение sudoers.d. Конфигурация не изменена.' >&2
    exit 1
fi
/bin/mkdir -p /private/etc/sudoers.d
candidate=\$(/usr/bin/mktemp /private/etc/sudoers.d/amster-keep-awake.XXXXXX)
trap '/bin/rm -f "\$candidate"' EXIT
printf '%s\\n' '#$CURRENT_UID ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > "\$candidate"
/usr/sbin/visudo -c -f "\$candidate"
if [ -e '$ACCESS_FILE' ]; then
    /usr/bin/cmp -s "\$candidate" '$ACCESS_FILE' || { printf '%s\\n' 'Существующее правило отличается. Оно не изменено.' >&2; exit 1; }
else
    /usr/bin/install -o root -g wheel -m 0440 "\$candidate" '$ACCESS_FILE'
    if ! /usr/sbin/visudo -c -f /private/etc/sudoers; then
        /bin/rm -f '$ACCESS_FILE'
        exit 1
    fi
fi
INSTALL
)
    printf '%s\n' "Однократная настройка: macOS запросит пароль администратора."
    administrator_command "$installation"
    passwordless_ready || fail "Правило установлено, но macOS не подтвердила доступ без пароля."
    printf '%s\n' "Готово. Включение и выключение запрета сна больше не требуют пароль."
}

remove_access() {
    lock_state
    administrator_command "/bin/rm -f '$ACCESS_FILE'"
    printf '%s\n' "Разрешение переключать сон без пароля удалено."
}

sleep_disabled() {
    local value
    value=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
    case "$value" in
        0|1) printf '%s\n' "$value" ;;
        *) fail "macOS не сообщила SleepDisabled. Настройки сна не изменены." ;;
    esac
}

set_sleep_disabled() {
    # Only this fixed system command gets administrator privileges.
    case "$1" in 0|1) ;; *) fail "Некорректное значение SleepDisabled." ;; esac
    if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep "$1" 2>/dev/null; then
        :
    elif [ "${AUTOMATIC:-0}" = 1 ]; then
        fail "Battery guard: нет доступа к восстановлению сна без пароля."
    elif [ -t 0 ]; then
        /usr/bin/sudo /usr/bin/pmset -a disablesleep "$1"
    else
        /usr/bin/osascript -e "do shell script \"/usr/bin/pmset -a disablesleep $1\" with administrator privileges"
    fi
    [ "$(sleep_disabled)" = "$1" ] || fail "macOS не применила SleepDisabled=$1. Сохранённая настройка оставлена для повторной попытки."
}

agent_loaded() { /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

agent_running() {
    /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | /usr/bin/awk '
        $1 == "state" && $2 == "=" && $3 == "running" { found = 1 }
        END { exit !found }'
}

start_agent() {
    # Migrate our old -ims agent; keep one idle assertion and allow disk idle.
    if [ -f "$PLIST" ] && /usr/bin/grep -q '<string>-ims</string>' "$PLIST"; then
        if agent_loaded; then /bin/launchctl bootout "$DOMAIN/$LABEL"; fi
        /bin/rm "$PLIST"
    fi
    if [ ! -f "$PLIST" ]; then
        /bin/mkdir -p "$(/usr/bin/dirname "$PLIST")"
        /bin/cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>local.amster-apart.keep-awake</string>
    <key>ProgramArguments</key><array>
        <string>/usr/bin/caffeinate</string><string>-i</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict></plist>
PLIST
    fi
    /bin/launchctl enable "$DOMAIN/$LABEL"
    if ! agent_loaded; then /bin/launchctl bootstrap "$DOMAIN" "$PLIST"; fi
    if ! agent_running; then /bin/launchctl kickstart "$DOMAIN/$LABEL"; fi
    local attempt
    for attempt in 1 2 3 4 5; do
        if agent_running; then return; fi
        /bin/sleep 1
    done
    fail "Не удалось запустить caffeinate. Проверьте launchctl print $DOMAIN/$LABEL."
}

lock_state() {
    /bin/mkdir -p "$STATE_DIR"
    /bin/mkdir "$STATE_DIR/lock" 2>/dev/null || fail "Другой запуск меняет настройки. Если он аварийно завершился, удалите: $STATE_DIR/lock"
    trap '/bin/rmdir "$STATE_DIR/lock" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

disable_guard() {
    /bin/rm -f "$GUARD_PLIST" "$ECO_LIMIT"
    if /bin/launchctl print "$DOMAIN/$GUARD_LABEL" >/dev/null 2>&1; then
        # bootout terminates the automatic stop shell too; do not strand its lock.
        if [ "${AUTOMATIC:-0}" = 1 ]; then /bin/rmdir "$STATE_DIR/lock"; fi
        /bin/launchctl bootout "$DOMAIN/$GUARD_LABEL"
    fi
}

install_guard() {
    local limit="$1" resources worker
    passwordless_ready || fail "Сначала выполните setup: автоматическое восстановление сна требует доступа без пароля."
    resources="$(cd -- "$(/usr/bin/dirname "$0")" && pwd)"
    worker="$resources/BatteryGuard"
    [ -x "$worker" ] || worker="$resources/macos-keep-awake/BatteryGuard"
    [ -x "$worker" ] || worker="$HOME/Applications/Не засыпать.app/Contents/Resources/BatteryGuard"
    [ -x "$worker" ] || fail "Сначала пересоберите приложение: BatteryGuard отсутствует."
    # Copy to a stable private path so reinstalling the app cannot remove the guard.
    /bin/cp "$worker" "$STATE_DIR/BatteryGuard.new"
    /bin/chmod 700 "$STATE_DIR/BatteryGuard.new"
    /bin/mv "$STATE_DIR/BatteryGuard.new" "$STATE_DIR/BatteryGuard"
    /bin/cp "$0" "$STATE_DIR/guard-control.sh"
    disable_guard
    printf '%s\n' "$limit" > "$ECO_LIMIT"
    # Escape the home path for XML (spaces and non-ASCII characters are valid).
    local xml_dir
    xml_dir=$(printf '%s' "$STATE_DIR" | /usr/bin/sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    /bin/cat > "$GUARD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$GUARD_LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$xml_dir/BatteryGuard</string>
        <string>$xml_dir/guard-control.sh</string><string>$limit</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
    /bin/launchctl enable "$DOMAIN/$GUARD_LABEL"
    if ! /bin/launchctl bootstrap "$DOMAIN" "$GUARD_PLIST"; then
        /bin/rm -f "$GUARD_PLIST" "$ECO_LIMIT"
        fail "Контроль батареи не запустился. Осталась обычная защита без лимита батареи."
    fi
}

eco() {
    # Validate prerequisites before replacing a working unrestricted session.
    passwordless_ready || fail "Для эко-режима сначала выполните setup."
    local resources original
    resources="$(cd -- "$(/usr/bin/dirname "$0")" && pwd)"
    [ -x "$resources/BatteryGuard" ] || [ -x "$resources/macos-keep-awake/BatteryGuard" ] || [ -x "$HOME/Applications/Не засыпать.app/Contents/Resources/BatteryGuard" ] || fail "Сначала пересоберите приложение: BatteryGuard отсутствует."
    if [ -f "$SAVED_SETTING" ]; then original=$(/bin/cat "$SAVED_SETTING"); else original=$(sleep_disabled); fi
    [ "$original" = 0 ] || fail "Исходный SleepDisabled=1: другой запрет сна не позволит защитить батарею. Сначала отключите его."
    start ""
    # start already holds the state lock. A guard callback retries if it races it.
    install_guard "$1"
    printf 'Эко-режим включён. Лимит батареи: %s (100 = только зарядка).\n' "$1"
}

start() {
    lock_state
    disable_guard
    start_agent
    if [ "$1" = "--idle" ]; then
        if [ -f "$SAVED_SETTING" ]; then
            local original
            original=$(/bin/cat "$SAVED_SETTING")
            case "$original" in 0|1) ;; *) fail "Повреждена сохранённая настройка." ;; esac
            if [ "$(sleep_disabled)" != "$original" ]; then set_sleep_disabled "$original"; fi
            /bin/rm "$SAVED_SETTING"
        fi
        printf '%s\n' "Защита от сна по бездействию включена."
        return
    fi
    local current
    current=$(sleep_disabled)
    if [ ! -f "$SAVED_SETTING" ]; then
        printf '%s\n' "$current" > "$SAVED_SETTING.tmp"
        /bin/mv "$SAVED_SETTING.tmp" "$SAVED_SETTING"
    fi
    if [ "$current" != 1 ]; then
        if ! passwordless_ready; then
            printf '%s\n' "Для работы с закрытой крышкой macOS запросит пароль администратора."
        fi
        set_sleep_disabled 1
    fi
    printf '%s\n' "Включено: caffeinate работает, SleepDisabled=1 (батарея и зарядка)." \
        "Терминал можно закрыть. Режим сохраняется после входа в macOS, пока не выполнен stop." \
        "Оставляйте нужные программы открытыми."
}

stop() {
    lock_state
    if [ "${AUTOMATIC:-0}" = 1 ]; then
        [ -f "$ECO_LIMIT" ] || fail "Эко-режим уже отключён."
    fi
    if [ -f "$SAVED_SETTING" ]; then
        local original
        original=$(/bin/cat "$SAVED_SETTING")
        case "$original" in 0|1) ;; *) fail "Повреждена сохранённая настройка: $SAVED_SETTING" ;; esac
        if [ "$(sleep_disabled)" != "$original" ]; then set_sleep_disabled "$original"; fi
        /bin/rm "$SAVED_SETTING"
        printf 'Исходное значение SleepDisabled=%s восстановлено.\n' "$original"
    fi
    if agent_loaded; then /bin/launchctl bootout "$DOMAIN/$LABEL"; fi
    /bin/rm -f "$PLIST"
    printf '%s\n' "Защита «Не засыпать» выключена, автозапуск удалён."
    # All restoration/removal must precede bootout of the guard's own process tree.
    disable_guard
}

status() {
    if agent_running; then
        printf '%s\n' "Защита от сна по бездействию: работает (caffeinate)."
    else
        printf '%s\n' "Защита от сна по бездействию: не работает."
    fi
    printf 'SleepDisabled=%s\n' "$(sleep_disabled)"
    if passwordless_ready; then printf '%s\n' "Passwordless=1"; else printf '%s\n' "Passwordless=0"; fi
    if [ -f "$SAVED_SETTING" ]; then
        printf 'Исходная настройка для stop: %s\n' "$(/bin/cat "$SAVED_SETTING")"
    fi
    if [ -f "$ECO_LIMIT" ]; then
        printf 'EcoLimit=%s\n' "$(/bin/cat "$ECO_LIMIT")"
        if /bin/launchctl print "$DOMAIN/$GUARD_LABEL" 2>/dev/null | /usr/bin/awk '$1 == "state" && $3 == "running" { found = 1 } END { exit !found }'; then
            printf '%s\n' "BatteryGuard=1"
        else
            printf '%s\n' "BatteryGuard=0"
        fi
    fi
    /usr/bin/pmset -g batt
}

usage() {
    printf '%s\n' \
        "Использование: $0 start | start --idle | eco [20|--ac-only] | stop | status | screen-off | setup | remove-access" \
        "  start         Не засыпать, включая закрытую крышку (нужен администратор)." \
        "  start --idle  Не засыпать по бездействию (без администратора)." \
        "  eco           Не спать до 20% батареи; --ac-only — только от зарядки." \
        "  stop          Восстановить исходную настройку и удалить автозапуск." \
        "  status        Показать реальное состояние и заряд батареи." \
        "  screen-off    Погасить экран, сохранив текущую защиту от сна." \
        "  setup         Один раз разрешить переключение сна без пароля." \
        "  remove-access Удалить это разрешение (нужен администратор)."
}

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "Скрипт предназначен для macOS."
[ "$EUID" -ne 0 ] || fail "Запускайте без sudo: скрипт сам запросит права только для pmset."
case "${1:-}" in
    start)
        [ "$#" -le 2 ] || { usage; exit 2; }
        case "${2:-}" in ""|--idle) start "${2:-}" ;; *) usage; exit 2 ;; esac
        ;;
    eco)
        [ "$#" -le 2 ] || { usage; exit 2; }
        case "${2:-20}" in 20) eco 20 ;; --ac-only) eco 100 ;; *) usage; exit 2 ;; esac
        ;;
    stop)
        [ "$#" -le 2 ] || { usage; exit 2; }
        case "${2:-}" in "") stop ;; --automatic) AUTOMATIC=1; stop ;; *) usage; exit 2 ;; esac
        ;;
    status|setup|remove-access)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        case "$1" in setup) setup_access ;; remove-access) remove_access ;; *) "$1" ;; esac
        ;;
    screen-off)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        /usr/bin/pmset displaysleepnow
        ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
