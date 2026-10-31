#!/usr/bin/env bash
# Caelestia: Imperial-style wallpaper picker with local wallpapers, colour
# filters, DuckDuckGo search and animated wallpaper transitions.
#
# Устанавливает модуль modules/wallpaper, патчит shell.qml, shell.json и
# hypr-user.lua. Скрипт идемпотентен, делает бэкапы изменяемых файлов и
# по умолчанию НЕ перезапускает Quickshell.
#
# Использование:
#   ./install-wallpaper-picker.sh
#   ./install-wallpaper-picker.sh --restart-shell
#   ./install-wallpaper-picker.sh --remove
#   ./install-wallpaper-picker.sh --wallpaper-dir ~/Pictures/Wallpapers
#   ./install-wallpaper-picker.sh --keybind "SUPER + SHIFT + W"
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SHELL_DIR="${CAELESTIA_SHELL_DIR:-$CONFIG_HOME/quickshell/caelestia}"
HYPR_DIR="${HYPR_CONFIG_DIR:-$CONFIG_HOME/hypr}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia-patch"
WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Pictures/Wallpapers}"
KEYBIND="${WALLPAPER_KEYBIND:-SUPER + SHIFT + W}"
WALLPAPER_DIR_SET=0
case "$WALLPAPER_DIR" in
    "~/"*) WALLPAPER_DIR="$HOME/${WALLPAPER_DIR#\~/}" ;;
esac
REMOVE=0
RESTART_SHELL=0
HYPR_RELOAD=1

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)          REMOVE=1 ;;
        --restart-shell)   RESTART_SHELL=1 ;;
        --no-hypr-reload)  HYPR_RELOAD=0 ;;
        --shell-dir)       SHELL_DIR="${2:?}"; shift ;;
        --hypr-dir)        HYPR_DIR="${2:?}"; shift ;;
        --state-dir)       STATE_DIR="${2:?}"; shift ;;
        --wallpaper-dir)   WALLPAPER_DIR="${2:?}"; WALLPAPER_DIR_SET=1; shift ;;
        --keybind)         KEYBIND="${2:?}"; shift ;;
        -h|--help)         usage; exit 0 ;;
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
    text = re.sub(r'^\s*import\s+"modules/wallpaper"\s*\n', "", text, flags=re.M)
    text = re.sub(r'^\s*WallpaperPicker\s*\{\s*\}\s*\n', "", text, flags=re.M)
else:
    if not re.search(r'^\s*import\s+"modules/wallpaper"\s*$', text, flags=re.M):
        anchors = [
            r'^\s*import\s+"modules/clipboard"\s*$',
            r'^\s*import\s+"modules/areapicker"\s*$',
            r'^\s*import\s+"modules"\s*$',
        ]
        anchor = next((m for p in anchors if (m := re.search(p, text, flags=re.M))), None)
        if anchor:
            text = text[:anchor.end()] + '\nimport "modules/wallpaper"' + text[anchor.end():]
        else:
            anchor = re.search(r'^import\s+QtQuick\s*$', text, flags=re.M)
            if not anchor:
                raise SystemExit("не найден якорь для import в shell.qml")
            text = text[:anchor.start()] + 'import "modules/wallpaper"\n' + text[anchor.start():]

    if not re.search(r'^\s*WallpaperPicker\s*\{\s*\}', text, flags=re.M):
        anchors = [
            r'^(\s*)Clipboard\s*\{\s*\}\s*$',
            r'^(\s*)AreaPicker\s*\{\s*\}\s*$',
            r'^(\s*)Background\s*\{\s*\}\s*$',
            r'^(\s*)Lock\s*\{\s*$',
        ]
        anchor = next((m for p in anchors if (m := re.search(p, text, flags=re.M))), None)
        if not anchor:
            raise SystemExit("не найден якорь для WallpaperPicker {} в shell.qml")
        indent = anchor.group(1)
        text = text[:anchor.end()] + f'\n{indent}WallpaperPicker {{}}' + text[anchor.end():]

if text != original:
    path.write_text(text, encoding="utf-8")
    print(f"shell.qml: {'удалён патч' if remove else 'пропатчен'}")
else:
    print("shell.qml: без изменений")
PY
}

patch_shell_json() {
    python3 - "$CONFIG_HOME/caelestia/shell.json" "$WALLPAPER_DIR" "$1" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
wallpaper_dir = sys.argv[2]
remove = sys.argv[3] == "remove"

if path.exists():
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
elif not remove:
    data = {}
else:
    raise SystemExit(0)

changed = False
paths = data.get("paths")

if remove:
    if isinstance(paths, dict) and paths.get("wallpaperDir") == wallpaper_dir:
        paths.pop("wallpaperDir", None)
        changed = True
        if not paths:
            data.pop("paths", None)
else:
    if not isinstance(paths, dict):
        paths = {}
        data["paths"] = paths
    if paths.get("wallpaperDir") != wallpaper_dir:
        paths["wallpaperDir"] = wallpaper_dir
        changed = True

if changed:
    fd, tmp = tempfile.mkstemp(
        dir=os.path.dirname(os.path.abspath(path)),
        prefix=".shell.json.",
        text=True,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(f"shell.json: {'удалён патч' if remove else 'пропатчен'}")
else:
    print("shell.json: без изменений")
PY
}

patch_hypr_user() {
    local target="$CONFIG_HOME/caelestia/hypr-user.lua"
    mkdir -p "$(dirname "$target")"
    [[ -e "$target" ]] || : > "$target"

    python3 - "$target" "$KEYBIND" "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
keybind = sys.argv[2]
remove = sys.argv[3] == "remove"

begin = "-- >>> caelestia-wallpaper-picker >>>"
end = "-- <<< caelestia-wallpaper-picker <<<"

text = path.read_text(encoding="utf-8")
block = (
    f"{begin}\n"
    f'hl.bind("{keybind}", hl.dsp.global("caelestia:wallpaper"))\n'
    f"{end}\n"
)
block_re = re.compile(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    flags=re.S,
)
bind_re = re.compile(
    r'^[ \t]*hl\.bind\([^\n]*caelestia:wallpaper[^\n]*\)[ \t]*\n?',
    flags=re.M,
)

if remove:
    new = bind_re.sub("", block_re.sub("", text)).rstrip()
    if new:
        new += "\n"
    changed = new != text
    if changed:
        path.write_text(new, encoding="utf-8")
    print(f"hypr-user.lua: {'удалён бинд' if changed else 'без изменений'}")
    raise SystemExit(0)

# Remove an existing managed block and any old manual bind, then add one block.
cleaned = bind_re.sub("", block_re.sub("", text)).rstrip()
new = (cleaned + "\n\n" if cleaned else "") + block

if new != text:
    path.write_text(new, encoding="utf-8")
    print("hypr-user.lua: бинд обновлён")
else:
    print("hypr-user.lua: без изменений")
PY
}

install_files() {
    mkdir -p "$SHELL_DIR/modules/wallpaper"
    if compgen -G "$SHELL_DIR/modules/wallpaper/*" >/dev/null; then
        cp -a "$SHELL_DIR/modules/wallpaper" "$BACKUP/wallpaper-module-before-install"
    fi
    cp -a "$FILES_DIR/modules/wallpaper/." "$SHELL_DIR/modules/wallpaper/"
    chmod 0644 "$SHELL_DIR/modules/wallpaper/"*.qml
    chmod 0755 "$SHELL_DIR/modules/wallpaper/"*.sh "$SHELL_DIR/modules/wallpaper/"*.py
    log "Файлы пикера: $SHELL_DIR/modules/wallpaper"
}

remove_files() {
    if [[ -d "$SHELL_DIR/modules/wallpaper" ]]; then
        cp -a "$SHELL_DIR/modules/wallpaper" "$BACKUP/wallpaper-module-removed"
        rm -rf "$SHELL_DIR/modules/wallpaper"
        log "Удалён модуль: $SHELL_DIR/modules/wallpaper"
    fi
}

prepare_cache() {
    local prep="$SHELL_DIR/modules/wallpaper/wallpaper-prep.sh"
    [[ -x "$prep" ]] || return 0
    log "Создаю миниатюры для $WALLPAPER_DIR…"
    bash "$prep" "$WALLPAPER_DIR" || warn "не удалось создать миниатюры — они создадутся при открытии пикера"
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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATE_DIR"
BACKUP="$(mktemp -d "$STATE_DIR/backup-$TIMESTAMP-XXXXXX")"

# On removal, reuse the wallpaper directory recorded during install unless the
# caller explicitly supplied one.
if [[ "$REMOVE" -eq 1 && "$WALLPAPER_DIR_SET" -eq 0 && -f "$STATE_DIR/wallpaper-picker.state" ]]; then
    saved_dir="$(sed -n 's/^WALLPAPER_DIR=//p' "$STATE_DIR/wallpaper-picker.state" | head -n1)"
    [[ -n "$saved_dir" ]] && WALLPAPER_DIR="$saved_dir"
fi

ensure_shell_dir
[[ -w "$SHELL_DIR" ]] || die "$SHELL_DIR недоступен для записи"

mkdir -p "$CONFIG_HOME/caelestia"
backup_file "$SHELL_DIR/shell.qml" "shell.qml"
backup_file "$CONFIG_HOME/caelestia/shell.json" "shell.json"
backup_file "$CONFIG_HOME/caelestia/hypr-user.lua" "hypr-user.lua"
log "Бэкап: $BACKUP"

if [[ "$REMOVE" -eq 1 ]]; then
    remove_files
    patch_shell_qml remove
    patch_shell_json remove
    patch_hypr_user remove
    reload_hypr
    restart_shell
    rm -f "$STATE_DIR/wallpaper-picker.state"
    log
    log "Патч удалён. Если Caelestia обновлялась — сверьте shell.qml с системной копией."
    exit 0
fi

for cmd in curl file awk; do
    command -v "$cmd" >/dev/null 2>&1 || warn "для пикера нужна команда $cmd"
done
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    warn "нужен ImageMagick (magick или convert) для миниатюр и цветовых фильтров"
fi
command -v caelestia >/dev/null 2>&1 || warn "не найден caelestia CLI — установка обоев не заработает"

install_files
patch_shell_qml install
patch_shell_json install
patch_hypr_user install
prepare_cache
reload_hypr
restart_shell

python3 -m json.tool "$CONFIG_HOME/caelestia/shell.json" >/dev/null
printf 'WALLPAPER_DIR=%s\nKEYBIND=%s\n' "$WALLPAPER_DIR" "$KEYBIND" > "$STATE_DIR/wallpaper-picker.state"

log
log "Готово. Патч установлен в: $SHELL_DIR"
log "Бинд: $KEYBIND"
log "IPC:  caelestia shell wallpaperPicker toggle"
log
log "Чтобы применить QML, перезапустите Quickshell:"
log "  qs -c caelestia kill; sleep 1; qs -c caelestia -n -d"
log "Либо выполните этот скрипт с --restart-shell."
