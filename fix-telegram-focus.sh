#!/usr/bin/env bash
# Не даёт Telegram забирать фокус при входящих уведомлениях.
#
# Причина: в Qt 6.12 QWindow::alert() (настройка Telegram «Привлекать внимание
# к окну») уходит в xdg-activation, а Hyprland при misc:focus_on_activate = true
# фокусирует окно. Правило ниже подавляет такую активацию для класса
# org.telegram.desktop.
#
# Использование:
#   ./fix-telegram-focus.sh                     # применить
#   ./fix-telegram-focus.sh --restart-telegram  # применить и перезапустить Telegram
#   ./fix-telegram-focus.sh --remove            # убрать правило
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
USER_LUA="$CONFIG_DIR/caelestia/hypr-user.lua"
HYPR_MAIN="$CONFIG_DIR/hypr/hyprland.lua"
RULES_LUA="$CONFIG_DIR/hypr/hyprland/rules.lua"

MARK_BEGIN="-- >>> telegram-no-focus-on-activate >>>"
MARK_END="-- <<< telegram-no-focus-on-activate <<<"

REMOVE=0
RESTART_TG=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --remove)           REMOVE=1 ;;
        --restart-telegram) RESTART_TG=1 ;;
        -h|--help)          usage; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $arg (см. --help)" >&2
            exit 2
            ;;
    esac
done

detect_target() {
    # Основной вариант — пользовательский override Caelestia, который
    # подключается последним и не перезаписывается обновлениями.
    if [[ -f "$HYPR_MAIN" ]]; then
        if grep -q 'require("hypr-user")' "$HYPR_MAIN"; then
            echo "$USER_LUA"
            return 0
        fi
        # hypr-user.lua не подключён — пишем в rules.lua рядом с конфигом.
        if [[ -f "$RULES_LUA" ]]; then
            echo "$RULES_LUA"
            return 0
        fi
    fi

    if [[ -f "$USER_LUA" ]]; then
        echo "$USER_LUA"
        return 0
    fi

    if [[ -f "$RULES_LUA" ]]; then
        echo "$RULES_LUA"
        return 0
    fi

    return 1
}

if ! TARGET="$(detect_target)"; then
    echo "Ошибка: не найден конфиг Hyprland/Caelestia." >&2
    echo "Ожидался один из файлов:" >&2
    echo "  $USER_LUA" >&2
    echo "  $RULES_LUA" >&2
    exit 1
fi

if [[ "$TARGET" == "$RULES_LUA" ]]; then
    echo "Внимание: используется $RULES_LUA — обновление Caelestia может его перезаписать."
fi

mkdir -p "$(dirname "$TARGET")"
[[ -e "$TARGET" ]] || : > "$TARGET"

BACKUP=""

make_backup() {
    BACKUP="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$TARGET" "$BACKUP"
    echo "Бэкап: $BACKUP"
}

validate_lua() {
    if command -v luac >/dev/null 2>&1; then
        luac -p "$TARGET"
    elif command -v lua >/dev/null 2>&1; then
        TARGET="$TARGET" lua -e 'assert(loadfile(os.getenv("TARGET")))'
    else
        echo "Предупреждение: нет luac/lua, синтаксис не проверен." >&2
    fi
}

reload_hyprland() {
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
        hyprctl reload >/dev/null
        echo "Hyprland перезагрузил конфиг."
    else
        echo "Hyprland не запущен — конфиг применится при следующем входе."
    fi
}

restart_telegram() {
    local tg_bin
    tg_bin="$(command -v Telegram || command -v telegram-desktop || true)"

    if [[ -z "$tg_bin" ]]; then
        echo "Telegram не найден в PATH — перезапусти его вручную." >&2
        return 0
    fi

    if pgrep -x Telegram >/dev/null 2>&1; then
        echo "Перезапускаю Telegram..."
        pkill -x Telegram >/dev/null 2>&1 || true
        for _ in $(seq 1 40); do
            pgrep -x Telegram >/dev/null 2>&1 || break
            sleep 0.25
        done
    else
        echo "Telegram не запущен — запускаю..."
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
        hyprctl dispatch exec "$tg_bin" >/dev/null
    else
        setsid -f "$tg_bin" >/dev/null 2>&1 || nohup "$tg_bin" >/dev/null 2>&1 &
    fi
    echo "Telegram запущен — правило применится к новому окну."
}

if [[ "$REMOVE" -eq 1 ]]; then
    if ! grep -qF -- "$MARK_BEGIN" "$TARGET"; then
        echo "Правило не найдено в $TARGET — ничего не меняю."
        exit 0
    fi

    make_backup
    TMP="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$TARGET" > "$TMP"
    mv "$TMP" "$TARGET"

    if ! validate_lua; then
        echo "Ошибка проверки Lua — возвращаю бэкап." >&2
        cp -a "$BACKUP" "$TARGET"
        exit 1
    fi

    reload_hyprland
    echo "Правило удалено."
    echo "Если Telegram открыт, перезапусти его, чтобы вернуть прежнее поведение."
    exit 0
fi

if grep -qF "telegram-no-focus-on-activate" "$TARGET"; then
    echo "Уже применено: $TARGET"
else
    make_backup

    # Гарантируем перевод строки перед новым блоком.
    printf '\n' >> "$TARGET"

    cat >> "$TARGET" <<'EOF'
-- >>> telegram-no-focus-on-activate >>>
-- Telegram (Qt 6.12) при уведомлении шлёт xdg-activation из-за настройки
-- «Привлекать внимание к окну», и Hyprland фокусирует окно.
hl.window_rule({
    name           = "telegram-no-focus-on-activate",
    match          = { class = "^(org\\.telegram\\.desktop)$" },
    suppress_event = "activatefocus",
})
-- <<< telegram-no-focus-on-activate <<<
EOF

    if ! validate_lua; then
        echo "Ошибка проверки Lua — возвращаю бэкап." >&2
        cp -a "$BACKUP" "$TARGET"
        exit 1
    fi

    reload_hyprland
    echo "Правило добавлено: $TARGET"
fi

echo
echo "Правило статическое: применяется при создании окна Telegram."
echo "Если Telegram уже запущен — перезапусти его (или запусти скрипт с --restart-telegram)."
echo
echo "Нюанс: клик по уведомлению тоже перестанет поднимать окно Telegram."
echo "Если фокус по клику нужен, выключи в Telegram:"
echo "  Настройки → Уведомления → «Привлекать внимание к окну»"
echo "и удали правило:  ./fix-telegram-focus.sh --remove"

if [[ "$RESTART_TG" -eq 1 ]]; then
    restart_telegram
fi
