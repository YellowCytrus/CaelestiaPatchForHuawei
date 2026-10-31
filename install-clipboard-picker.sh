#!/usr/bin/env bash
# Caelestia: Imperial-style clipboard picker.
#
# Заменяет fuzzel-селектор `caelestia clipboard` на QML-оверлей Caelestia
# (сетка, поиск, превью, удаление). Скрипт идемпотентен, делает бэкап
# изменяемых файлов и по умолчанию НЕ перезапускает Quickshell.
#
# Использование:
#   ./install-clipboard-picker.sh                  # установить
#   ./install-clipboard-picker.sh --restart-shell  # установить и перезапустить Quickshell
#   ./install-clipboard-picker.sh --remove         # удалить патч
#   ./install-clipboard-picker.sh --no-hypr-reload # не делать hyprctl reload
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SHELL_DIR="${CAELESTIA_SHELL_DIR:-$CONFIG_HOME/quickshell/caelestia}"
HYPR_DIR="${HYPR_CONFIG_DIR:-$CONFIG_HOME/hypr}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia-patch"
REMOVE=0
RESTART_SHELL=0
HYPR_RELOAD=1

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)         REMOVE=1 ;;
        --restart-shell)  RESTART_SHELL=1 ;;
        --no-hypr-reload) HYPR_RELOAD=0 ;;
        --shell-dir)      SHELL_DIR="${2:?}"; shift ;;
        --hypr-dir)       HYPR_DIR="${2:?}"; shift ;;
        --bin-dir)        BIN_DIR="${2:?}"; shift ;;
        --state-dir)      STATE_DIR="${2:?}"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $1 (см. --help)" >&2
            exit 2
            ;;
    esac
    shift
done

log()  { printf '%s\n' "$*"; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }
die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "не найдена команда $1"
}

backup_file() {
    local src="$1" name="$2"
    [[ -e "$src" ]] || return 0
    cp -a "$src" "$BACKUP/$name"
}

ensure_shell_dir() {
    if [[ -f "$SHELL_DIR/shell.qml" ]]; then
        return 0
    fi

    local system_shell="/etc/xdg/quickshell/caelestia"
    if [[ -f "$system_shell/shell.qml" ]]; then
        log "Локальной копии Caelestia нет — создаю: $SHELL_DIR"
        mkdir -p "$SHELL_DIR"
        cp -a "$system_shell/." "$SHELL_DIR/"
        return 0
    fi

    die "не найден $SHELL_DIR/shell.qml. Укажите --shell-dir или CAELESTIA_SHELL_DIR"
}

patch_shell_qml() {
    python3 - "$SHELL_DIR/shell.qml" "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
remove = sys.argv[2] == "remove"
text = path.read_text(encoding="utf-8")
original = text

if remove:
    text = re.sub(r'^\s*import\s+"modules/clipboard"\s*\n', "", text, flags=re.M)
    text = re.sub(r'^\s*Clipboard\s*\{\s*\}\s*\n', "", text, flags=re.M)
else:
    if not re.search(r'^\s*import\s+"modules/clipboard"\s*$', text, flags=re.M):
        anchor = re.search(r'^\s*import\s+"modules/areapicker"\s*$', text, flags=re.M)
        if anchor:
            text = text[:anchor.end()] + '\nimport "modules/clipboard"' + text[anchor.end():]
        else:
            anchor = re.search(r'^import\s+QtQuick\s*$', text, flags=re.M)
            if not anchor:
                raise SystemExit("не найден якорь для import в shell.qml")
            text = text[:anchor.start()] + 'import "modules/clipboard"\n' + text[anchor.start():]

    if not re.search(r'^\s*Clipboard\s*\{\s*\}', text, flags=re.M):
        anchor = re.search(r'^(\s*)AreaPicker\s*\{\s*\}\s*$', text, flags=re.M)
        if not anchor:
            anchor = re.search(r'^(\s*)Background\s*\{\s*\}\s*$', text, flags=re.M)
        if not anchor:
            anchor = re.search(r'^(\s*)Lock\s*\{\s*$', text, flags=re.M)
        if not anchor:
            raise SystemExit("не найден якорь для Clipboard {} в shell.qml")
        indent = anchor.group(1)
        insert_at = anchor.end()
        text = text[:insert_at] + f'\n{indent}Clipboard {{}}' + text[insert_at:]

if text != original:
    path.write_text(text, encoding="utf-8")
    print(f"shell.qml: {'удалён патч' if remove else 'пропатчен'}")
else:
    print("shell.qml: без изменений")
PY
}

patch_keybinds() {
    python3 - "$HYPR_DIR/hyprland/keybinds.lua" "$HYPR_DIR/config/binds.lua" "$1" <<'PY'
import re
import sys
from pathlib import Path

active = Path(sys.argv[1])
extra = Path(sys.argv[2])
remove = sys.argv[3] == "remove"

old_active = [
    'create_bind(vars.kbClipboard, hl.dsp.exec_cmd("pkill fuzzel || caelestia clipboard"))',
    'create_bind(vars.kbClipboardDel, hl.dsp.exec_cmd("pkill fuzzel || caelestia clipboard -d"))',
]
new_active = [
    'create_bind(vars.kbClipboard, hl.dsp.global("caelestia:clipboard"))',
    'create_bind(vars.kbClipboardDel, hl.dsp.global("caelestia:clipboardDelete"))',
]

old_extra = 'hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("caelestia clipboard"))'
new_extra = 'hl.bind(mainMod .. " + V", hl.dsp.global("caelestia:clipboard"))'


def replace_literal(text: str, old: str, new: str) -> tuple[str, bool]:
    if old in text:
        return text.replace(old, new), True
    return text, False


def process_active() -> None:
    if not active.exists():
        print(f"{active}: не найден, пропускаю")
        return

    text = active.read_text(encoding="utf-8")
    changed = False

    if remove:
        for old, new in zip(new_active, old_active):
            text, did = replace_literal(text, old, new)
            changed |= did
    else:
        for old, new in zip(old_active, new_active):
            text, did = replace_literal(text, old, new)
            changed |= did
        if not changed and not all(line in text for line in new_active):
            print("keybinds.lua: шаблон не найден — поправьте бинды вручную (см. README)")

    if changed:
        active.write_text(text, encoding="utf-8")
        print(f"{active}: {'откатан' if remove else 'пропатчен'}")
    else:
        print(f"{active}: без изменений")


def process_extra() -> None:
    if not extra.exists():
        return

    text = extra.read_text(encoding="utf-8")
    changed = False

    if remove:
        text, did = replace_literal(text, new_extra, old_extra)
        changed |= did
    else:
        text, did = replace_literal(text, old_extra, new_extra)
        changed |= did

    if changed:
        extra.write_text(text, encoding="utf-8")
        print(f"{extra}: {'откатан' if remove else 'пропатчен'}")
    else:
        print(f"{extra}: без изменений")


process_active()
process_extra()
PY
}

install_files() {
    mkdir -p "$SHELL_DIR/modules/clipboard"
    if [[ -d "$SHELL_DIR/modules/clipboard" ]] && compgen -G "$SHELL_DIR/modules/clipboard/*" >/dev/null; then
        cp -a "$SHELL_DIR/modules/clipboard" "$BACKUP/clipboard-module-before-install"
    fi
    install -m 0644 "$FILES_DIR/modules/clipboard/Clipboard.qml" "$SHELL_DIR/modules/clipboard/Clipboard.qml"
    install -m 0644 "$FILES_DIR/modules/clipboard/Content.qml" "$SHELL_DIR/modules/clipboard/Content.qml"
    install -m 0755 "$FILES_DIR/modules/clipboard/clip_fetcher.py" "$SHELL_DIR/modules/clipboard/clip_fetcher.py"
    log "Файлы пикера: $SHELL_DIR/modules/clipboard"
}

remove_files() {
    if [[ -d "$SHELL_DIR/modules/clipboard" ]]; then
        cp -a "$SHELL_DIR/modules/clipboard" "$BACKUP/clipboard-module-removed"
        rm -rf "$SHELL_DIR/modules/clipboard"
        log "Удалён модуль: $SHELL_DIR/modules/clipboard"
    fi
}

install_wrapper() {
    mkdir -p "$BIN_DIR"
    local target="$BIN_DIR/caelestia"
    local source="$FILES_DIR/local-bin/caelestia"

    if [[ -e "$target" ]] && ! grep -q "caelestia-clipboard-patch" "$target" 2>/dev/null; then
        warn "$target уже существует и не принадлежит патчу — не перезаписываю."
        warn "Удалите/переименуйте его или удалите вручную. Обёртка не установлена."
        return 0
    fi

    install -m 0755 "$source" "$target"
    log "Обёртка: $target"
}

remove_wrapper() {
    local target="$BIN_DIR/caelestia"
    if [[ -f "$target" ]] && grep -q "caelestia-clipboard-patch" "$target" 2>/dev/null; then
        cp -a "$target" "$BACKUP/caelestia-wrapper"
        rm -f "$target"
        log "Удалена обёртка: $target"
    fi
}

reload_hypr() {
    if [[ "$HYPR_RELOAD" -eq 1 ]] && command -v hyprctl >/dev/null 2>&1; then
        if hyprctl reload >/dev/null 2>&1; then
            log "Hyprland: конфиг перезагружен"
        else
            warn "hyprctl reload не удался — перезагрузите Hyprland вручную"
        fi
    fi
}

restart_shell() {
    if [[ "$RESTART_SHELL" -ne 1 ]]; then
        return 0
    fi

    if ! command -v qs >/dev/null 2>&1; then
        warn "qs не найден — перезапустите Quickshell вручную"
        return 0
    fi

    log "Перезапускаю Quickshell (caelestia)…"
    qs -c caelestia kill >/dev/null 2>&1 || true
    sleep 1
    qs -c caelestia -n -d >/dev/null 2>&1 || true
}

need_cmd python3
[[ -f "$FILES_DIR/modules/clipboard/Clipboard.qml" ]] || die "не найдены файлы патча в $FILES_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE_DIR/backup-$TIMESTAMP"
if [[ -e "$BACKUP" ]]; then
    n=1
    while [[ -e "$STATE_DIR/backup-$TIMESTAMP-$n" ]]; do
        n=$((n + 1))
    done
    BACKUP="$STATE_DIR/backup-$TIMESTAMP-$n"
fi
mkdir -p "$BACKUP"

ensure_shell_dir
[[ -w "$SHELL_DIR" ]] || die "$SHELL_DIR недоступен для записи"

backup_file "$SHELL_DIR/shell.qml" "shell.qml"
backup_file "$HYPR_DIR/hyprland/keybinds.lua" "keybinds.lua"
backup_file "$HYPR_DIR/config/binds.lua" "binds.lua"
backup_file "$BIN_DIR/caelestia" "caelestia-wrapper"
log "Бэкап: $BACKUP"

if [[ "$REMOVE" -eq 1 ]]; then
    remove_wrapper
    remove_files
    patch_shell_qml remove
    patch_keybinds remove
    reload_hypr
    restart_shell
    log
    log "Патч удалён. Если Caelestia обновлялась — сверьте shell.qml с системной копией."
    exit 0
fi

for cmd in cliphist wl-copy python3; do
    command -v "$cmd" >/dev/null 2>&1 || warn "для работы пикера нужна команда $cmd"
done

install_files
patch_shell_qml install
patch_keybinds install
install_wrapper
reload_hypr
restart_shell

python3 - "$SHELL_DIR/modules/clipboard/clip_fetcher.py" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY


log
log "Готово. Патч установлен в: $SHELL_DIR"
log "Бинды: SUPER+V (история), SUPER+ALT+V (режим удаления)"
log
log "Чтобы применить QML, перезапустите Quickshell:"
log "  qs -c caelestia kill; sleep 1; qs -c caelestia -n -d"
log "Либо выполните этот скрипт с --restart-shell."
