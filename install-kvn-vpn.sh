#!/usr/bin/env bash
# Полная настройка kvn-tui на Caelestia/Hyprland:
#   1) passwordless polkit для DNS (kvn setup --polkit);
#   2) дополнительное правило на flush-caches (его в kvn нет);
#   3) автозапуск демона kvn-tui.service;
#   4) ~/.local/bin/kvn-toggle (переключение + уведомление);
#   5) хоткей Super+Shift+V в пользовательском слое Hyprland.
# Опционально: killswitch (nftables) через --with-killswitch.
#
# Использование:
#   ./install-kvn-vpn.sh                   # поставить/обновить
#   ./install-kvn-vpn.sh --with-killswitch # ещё и killswitch
#   ./install-kvn-vpn.sh --remove          # убрать то, что добавил этот скрипт
#   ./install-kvn-vpn.sh --help
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
USER_LUA="$CONFIG_DIR/caelestia/hypr-user.lua"
HYPR_MAIN="$CONFIG_DIR/hypr/hyprland.lua"
RULES_LUA="$CONFIG_DIR/hypr/hyprland/rules.lua"
LOCAL_BIN="$HOME/.local/bin"
POLKIT_RULE="/etc/polkit-1/rules.d/50-kvn-flush-caches.rules"

MARK_BEGIN="-- >>> kvn-vpn-toggle >>>"
MARK_END="-- <<< kvn-vpn-toggle <<<"
# Биндинг, добавленный вручную (без маркеров) — чтобы не создать дубль.
MANUAL_BIND_RE='hl\.bind\("SUPER \+ SHIFT \+ V".*kvn-toggle'

WITH_KS=0
REMOVE=0

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --with-killswitch) WITH_KS=1 ;;
        --remove)          REMOVE=1 ;;
        -h|--help)         usage; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $arg (см. --help)" >&2
            exit 2
            ;;
    esac
done

detect_target() {
    # Пользовательский слой Caelestia: подключается последним, обновлениями
    # не перезаписывается.
    if [[ -f "$HYPR_MAIN" ]] && grep -q 'require("hypr-user")' "$HYPR_MAIN"; then
        echo "$USER_LUA"
        return 0
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

remove_keybind() {
    local target
    if ! target="$(detect_target)"; then
        echo "Конфиг Hyprland/Caelestia не найден — хоткей пропускаю."
        return 0
    fi
    TARGET="$target"

    local has_marker=0
    grep -qF -- "$MARK_BEGIN" "$TARGET" && has_marker=1

    if [[ "$has_marker" -eq 0 ]] && ! grep -qE "$MANUAL_BIND_RE" "$TARGET"; then
        echo "Хоткей не найден в $TARGET — ничего не меняю."
        return 0
    fi

    make_backup
    local tmp
    tmp="$(mktemp)"
    if [[ "$has_marker" -eq 1 ]]; then
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip
        ' "$TARGET" > "$tmp"
    else
        grep -vE "$MANUAL_BIND_RE" "$TARGET" > "$tmp" || true
    fi
    mv "$tmp" "$TARGET"

    if ! validate_lua; then
        echo "Ошибка проверки Lua — возвращаю бэкап." >&2
        cp -a "$BACKUP" "$TARGET"
        exit 1
    fi
    reload_hyprland
    echo "Хоткей удалён: $TARGET"
}

add_keybind() {
    local target
    if ! target="$(detect_target)"; then
        echo "Конфиг Hyprland/Caelestia не найден — хоткей не добавлен." >&2
        echo "Создай $USER_LUA и запусти скрипт снова." >&2
        return 0
    fi
    TARGET="$target"
    if [[ "$TARGET" == "$RULES_LUA" ]]; then
        echo "Внимание: используется $RULES_LUA — обновление Caelestia может его перезаписать." >&2
    fi

    mkdir -p "$(dirname "$TARGET")"
    [[ -e "$TARGET" ]] || : > "$TARGET"

    if grep -qF "kvn-vpn-toggle" "$TARGET"; then
        echo "Хоткей уже есть: $TARGET"
        return 0
    fi

    make_backup

    # Биндинг, добавленный вручную (без маркеров), заменяем на управляемый,
    # чтобы не было дубля и работал --remove.
    if grep -qE "$MANUAL_BIND_RE" "$TARGET"; then
        local tmp
        tmp="$(mktemp)"
        grep -vE "$MANUAL_BIND_RE" "$TARGET" > "$tmp" || true
        mv "$tmp" "$TARGET"
        echo "Ручной биндинг заменён на управляемый (бэкап: $BACKUP)"
    fi

    printf '\n' >> "$TARGET"
    cat >> "$TARGET" <<'EOF'
-- >>> kvn-vpn-toggle >>>
-- Super+Shift+V: включить/выключить VPN через kvn (+ уведомление).
-- Требуется ~/.local/bin/kvn-toggle (ставится install-kvn-vpn.sh).
hl.bind("SUPER + SHIFT + V", hl.dsp.exec_cmd("~/.local/bin/kvn-toggle"))
-- <<< kvn-vpn-toggle <<<
EOF

    if ! validate_lua; then
        echo "Ошибка проверки Lua — возвращаю бэкап." >&2
        cp -a "$BACKUP" "$TARGET"
        exit 1
    fi
    reload_hyprland
    echo "Хоткей добавлен: $TARGET"
}

if [[ "$REMOVE" -eq 1 ]]; then
    echo "== removal =="
    remove_keybind
    rm -f "$LOCAL_BIN/kvn-toggle" && echo "Удалён: $LOCAL_BIN/kvn-toggle"

    if sudo test -f "$POLKIT_RULE"; then
        sudo rm -f "$POLKIT_RULE"
        sudo systemctl restart polkit
        echo "Удалено правило: $POLKIT_RULE (polkit перезапущен)"
    else
        echo "Правила $POLKIT_RULE нет — пропускаю."
    fi

    echo
    echo "Готово. Интеграция самого kvn (правило 49-kvn-tui.rules и группа"
    echo "kvn-tui) не удаляется: её убирай через kvn, если понадобится."
    exit 0
fi

# ---------------------------------------------------------------------------

command -v kvn  >/dev/null 2>&1 || die "kvn не найден в PATH (пакет kvn-tui-bin)"
command -v sudo >/dev/null 2>&1 || die "нужен sudo"
[[ $EUID -ne 0 ]] || die "запусти от своего пользователя (скрипт сам вызывает sudo)"
[[ -f "$FILES_DIR/local-bin/kvn-toggle" ]] || die "нет файла $FILES_DIR/local-bin/kvn-toggle"
[[ -f "$FILES_DIR/polkit/50-kvn-flush-caches.rules" ]] || die "нет файла $FILES_DIR/polkit/50-kvn-flush-caches.rules"

echo "== 1/5  polkit для DNS (kvn setup --polkit) =="
sudo kvn setup --polkit

if [[ "$WITH_KS" -eq 1 ]]; then
    echo "== 1b   killswitch (kvn setup --killswitch) =="
    sudo kvn setup --killswitch
fi

echo
echo "== 2/5  правило на flush-caches =="
if sudo test -f "$POLKIT_RULE" &&
   sudo cmp -s "$FILES_DIR/polkit/50-kvn-flush-caches.rules" "$POLKIT_RULE"; then
    echo "Уже установлено: $POLKIT_RULE"
else
    sudo install -m 0644 -o root -g root \
        "$FILES_DIR/polkit/50-kvn-flush-caches.rules" "$POLKIT_RULE"
    sudo systemctl restart polkit
    echo "Установлено: $POLKIT_RULE (polkit перезапущен)"
fi

echo
echo "== 3/5  автозапуск демона =="
systemctl --user enable --now kvn-tui.service
echo "kvn-tui.service: $(systemctl --user is-enabled kvn-tui.service) / $(systemctl --user is-active kvn-tui.service)"

echo
echo "== 4/5  ~/.local/bin/kvn-toggle =="
install -d -m 0755 "$LOCAL_BIN"
install -m 0755 "$FILES_DIR/local-bin/kvn-toggle" "$LOCAL_BIN/kvn-toggle"
echo "Установлено: $LOCAL_BIN/kvn-toggle"

echo
echo "== 5/5  хоткей Super+Shift+V =="
add_keybind

echo
echo "== проверка =="
if id -nG | tr ' ' '\n' | grep -qx kvn-tui; then
    echo "группа kvn-tui: активна в текущей сессии"
else
    echo "ВНИМАНИЕ: группы kvn-tui нет в текущей сессии."
    echo "          Перелогинься (или перезагрузись), иначе polkit-правило не сработает."
fi

for action in \
    org.freedesktop.resolve1.set-dns-servers \
    org.freedesktop.resolve1.flush-caches
do
    if pkcheck -a "$action" -p $$ >/dev/null 2>&1; then
        echo "polkit ok: $action"
    else
        echo "polkit нет: $action (появится после перелогина)"
    fi
done

echo
echo "Проверь: Super+Shift+V. Если пароль всё ещё спрашивает — открой"
echo "«Подробности» в диалоге и посмотри action-id, добавь его в правило."
