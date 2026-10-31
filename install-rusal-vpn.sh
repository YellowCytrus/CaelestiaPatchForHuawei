#!/usr/bin/env bash
# RUSAL VPN (Cisco AnyConnect + USB-токен) и рабочий стол Omnissa Horizon.
#
# Ставит openconnect, PKCS#11-модуль токена (JaCarta или SafeNet eToken),
# корневой CA РУСАЛа, пропатченный vpnc-script (в туннель уходит только
# 10.0.0.0/8), команды rusal/rusal-vpn/rusal-view/rusal-term и бинд Super+Shift+R.
# Скрипт идемпотентен, перед изменением файлов делает бэкап.
#
# Использование:
#   ./install-rusal-vpn.sh                # установить
#   ./install-rusal-vpn.sh --no-packages  # без установки пакетов и модуля токена
#   ./install-rusal-vpn.sh --no-hypr      # без бинда Hyprland
#   ./install-rusal-vpn.sh --remove       # удалить (пакеты остаются)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rusal-vpn"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
HYPR_MAIN="$CONFIG_HOME/hypr/hyprland.lua"
USER_LUA="$CONFIG_HOME/caelestia/hypr-user.lua"
RULES_LUA="$CONFIG_HOME/hypr/hyprland/rules.lua"

VPN_HOST="sib02.vpn.rusal.com"
VPN_IP="91.216.121.208"
SERVER_PIN="pin-sha256:MQO2vG9o+VZVQy76UjNH1LWNsfCii5ZwxqnjyeF45Yg="
HORIZON_NAME="kraz-s-view01.hq.root.ad"
HORIZON_IP="10.12.22.145"

CA_URL="http://pki.rusal.com/CertData/UC_RUSAL_Root_CA.crt"
CA_FPR="E2:1A:57:F5:9B:0E:C9:55:06:F2:F9:8E:AC:6E:65:3A:79:0E:D7:0E:28:A0:93:00:F7:FA:BA:D6:82:AE:5E:2D"
CA_ANCHOR="/etc/ca-certificates/trust-source/anchors/uc-rusal-root.crt"

MARK_BEGIN="-- >>> rusal-vpn-horizon >>>"
MARK_END="-- <<< rusal-vpn-horizon <<<"

REMOVE=0
DO_PACKAGES=1
DO_HYPR=1

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)       REMOVE=1 ;;
        --no-packages)  DO_PACKAGES=0 ;;
        --no-hypr)      DO_HYPR=0 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '%s\n' "$*"; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }
die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "не найдена команда $1"; }

ROOT_READY=0
need_root() {
    [[ $ROOT_READY -eq 1 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "нужен sudo"
    sudo -v || die "не удалось получить права root"
    ROOT_READY=1
}

backup_file() {
    local src="$1" dst
    [[ -e "$src" ]] || return 0
    dst="${src}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$src" "$dst"
    log "Бэкап: $dst"
}

# ---------------------------------------------------------------- пакеты ----

install_packages() {
    log '== Пакеты'
    if ! command -v pacman >/dev/null 2>&1; then
        warn 'не pacman-дистрибутив — пакеты ставь вручную: ccid opensc openconnect vpnc'
        return 0
    fi

    local want=(pcsclite ccid opensc openconnect vpnc gnutls) p
    local missing=()
    for p in "${want[@]}"; do
        pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log 'уже установлены'
        return 0
    fi

    need_root
    log "ставлю: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}" >/dev/null
}

install_jacarta_module() {
    log '== PKCS#11-модуль JaCarta'
    if [[ -e /usr/lib/libjcPKCS11-2.so ]]; then
        log 'уже установлен'
        return 0
    fi

    if ! command -v makepkg >/dev/null 2>&1; then
        warn 'нет makepkg — пропускаю. Для JaCarta нужен пакет jcpkcs11-2 из files/packaging/'
        return 0
    fi

    local build_dir
    build_dir="$(mktemp -d)"
    cp "$FILES_DIR/packaging/jcpkcs11-2/PKGBUILD" "$build_dir/PKGBUILD"

    log 'собираю пакет из официального клиента JaCarta (Aladdin R.D.)...'
    if ! ( cd "$build_dir" && makepkg --nodeps --noconfirm >/dev/null 2>&1 ); then
        rm -rf "$build_dir"
        warn 'сборка jcpkcs11-2 не удалась — модуль токена придётся поставить вручную'
        return 0
    fi

    need_root
    sudo pacman -U --noconfirm "$build_dir"/jcpkcs11-2-*.pkg.tar.zst >/dev/null
    rm -rf "$build_dir"
}

enable_pcscd() {
    log '== pcscd'
    if systemctl is-enabled --quiet pcscd.socket 2>/dev/null &&
       systemctl is-active --quiet pcscd.socket 2>/dev/null; then
        log 'уже запущен'
        return 0
    fi
    need_root
    sudo systemctl enable --now pcscd.socket
}

register_pkcs11() {
    log '== p11-kit'
    local file mod
    for pair in "/etc/pkcs11/modules/jacarta.module:/usr/lib/libjcPKCS11-2.so" \
                "/etc/pkcs11/modules/etoken.module:/usr/lib/pkcs11/libeToken.so"; do
        file="${pair%%:*}"
        mod="${pair#*:}"
        [[ -e "$mod" ]] || continue
        [[ -f "$file" ]] && continue
        need_root
        printf 'module: %s\n' "$mod" | sudo tee "$file" >/dev/null
        log "зарегистрирован $mod"
    done
}

# ---------------------------------------------------------------- доверие ---

install_ca() {
    log '== Корневой CA РУСАЛа'
    if [[ -f "$CA_ANCHOR" ]]; then
        log 'уже установлен'
        return 0
    fi

    need_cmd curl
    need_cmd openssl

    local tmp fpr
    tmp="$(mktemp)"
    curl -fsS --max-time 30 "$CA_URL" -o "$tmp" || { rm -f "$tmp"; die "не удалось скачать $CA_URL"; }

    if ! openssl x509 -in "$tmp" -noout >/dev/null 2>&1; then
        openssl x509 -inform DER -in "$tmp" -out "$tmp.pem" || die 'не удалось прочитать сертификат CA'
        mv "$tmp.pem" "$tmp"
    fi

    fpr="$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | cut -d= -f2)"
    if [[ "$fpr" != "$CA_FPR" ]]; then
        rm -f "$tmp"
        die "отпечаток CA не совпал ($fpr)"
    fi

    need_root
    sudo install -Dm644 "$tmp" "$CA_ANCHOR"
    sudo update-ca-trust
    rm -f "$tmp"
    log 'добавлен в системное хранилище'
}

# ------------------------------------------------------------ vpnc-script ---

make_vpnc_script() {
    log '== vpnc-script (маршрут 10/8, default не трогаем)'
    local src=/etc/vpnc/vpnc-script
    local dst="$HOME/.local/share/rusal-vpn/vpnc-script"

    [[ -r "$src" ]] || die 'нет /etc/vpnc/vpnc-script (пакет vpnc не установлен)'

    python3 - "$src" "$dst" <<'PY'
import re
import sys
from pathlib import Path

src_path, dst_path = Path(sys.argv[1]), Path(sys.argv[2])
src = src_path.read_text()

# set_/reset_*_default_route в vpnc-script встречаются в нескольких
# реализациях (iproute2, busybox, net-tools), поэтому правим все.
src = re.sub(
    r'(?m)^([ \t]*)((?:set|reset)_(?:ipv4|ipv6)_default_route\(\) \{)\n',
    r'\1\2\n\1\t# RUSAL: default route не трогаем\n\1\treturn 0\n',
    src,
)

needle = '\tif [ -n "$INTERNAL_IP4_DNS" ]; then\n\t\t$MODIFYRESOLVCONF\n\tfi\n}'
insert = ('\t# RUSAL: корпоративные сети через VPN\n'
          '\tif [ -n "$INTERNAL_IP4_ADDRESS" ] && [ -n "$TUNDEV" ]; then\n'
          '\t\t/usr/bin/ip route replace 10.0.0.0/8 dev "$TUNDEV"\n'
          '\tfi\n\n')

if needle not in src:
    sys.exit("не найден ожидаемый блок в vpnc-script")

src = src.replace(needle, insert + needle, 1)
dst_path.parent.mkdir(parents=True, exist_ok=True)
dst_path.write_text(src)
dst_path.chmod(0o755)
PY
}

# ---------------------------------------------------------------- команды ---

install_scripts() {
    log '== Команды rusal'
    mkdir -p "$BIN_DIR"
    local f dst
    for f in rusal rusal-vpn rusal-term rusal-view; do
        dst="$BIN_DIR/$f"
        if [[ -f "$dst" ]] && ! cmp -s "$FILES_DIR/local-bin/$f" "$dst"; then
            backup_file "$dst"
        fi
        install -m755 "$FILES_DIR/local-bin/$f" "$dst"
    done
    log "установлены в $BIN_DIR"
}

# ------------------------------------------------------------------ hosts ---

configure_hosts() {
    log '== /etc/hosts'
    if grep -q "$HORIZON_NAME" /etc/hosts 2>/dev/null; then
        log 'запись уже есть'
        return 0
    fi
    need_root
    printf '\n# Omnissa Horizon (RUSAL VDI)\n%s\t%s\n' \
        "$HORIZON_IP" "$HORIZON_NAME" | sudo tee -a /etc/hosts >/dev/null
    log "$HORIZON_NAME -> $HORIZON_IP"
}

# --------------------------------------------------------------- Hyprland ---

detect_target() {
    if [[ -f "$HYPR_MAIN" ]] && grep -q 'require("hypr-user")' "$HYPR_MAIN"; then
        echo "$USER_LUA"; return 0
    fi
    [[ -f "$USER_LUA" ]] && { echo "$USER_LUA"; return 0; }
    [[ -f "$RULES_LUA" ]] && { echo "$RULES_LUA"; return 0; }
    return 1
}

validate_lua() {
    if command -v luac >/dev/null 2>&1; then
        luac -p "$1"
    elif command -v lua >/dev/null 2>&1; then
        T="$1" lua -e 'assert(loadfile(os.getenv("T")))'
    fi
}

reload_hyprland() {
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
        hyprctl reload >/dev/null && log 'Hyprland перезагрузил конфиг'
    else
        log 'Hyprland не запущен — бинд применится при следующем входе'
    fi
}

configure_hypr() {
    log '== Бинд Super+Shift+R'
    local target
    if ! target="$(detect_target)"; then
        warn 'не найден конфиг Hyprland/Caelestia — бинд не добавлен'
        return 0
    fi

    if grep -qF "rusal-term" "$target"; then
        log 'биндинг уже есть'
        return 0
    fi

    backup_file "$target"
    printf '\n' >> "$target"
    cat >> "$target" <<'EOF'
-- >>> rusal-vpn-horizon >>>
-- Super+Shift+R: корпоративный VPN + рабочий стол Horizon (Omnissa).
-- Открывает терминал с `rusal`; после подключения окно закрывается само.
local rusal_term = (vars and vars.terminal or "foot") .. " -e ~/.local/bin/rusal-term"
hl.unbind("SUPER + SHIFT + R")
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd(rusal_term))
-- <<< rusal-vpn-horizon <<<
EOF

    if ! validate_lua "$target"; then
        local bak
        bak="$(ls -t "$target".bak.* 2>/dev/null | head -1 || true)"
        [[ -n "$bak" ]] && cp -a "$bak" "$target"
        die 'ошибка синтаксиса Lua — вернул бэкап'
    fi

    reload_hyprland
}

# ------------------------------------------------------------------ откат ---

do_remove() {
    log '== Удаление'

    local target
    if target="$(detect_target)"; then
        if grep -qF -- "$MARK_BEGIN" "$target"; then
            backup_file "$target"
            awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
                $0 == b { skip = 1; next }
                $0 == e { skip = 0; next }
                !skip
            ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
            reload_hyprland
            log 'биндинг удалён'
        elif grep -qF 'rusal-term' "$target"; then
            warn "биндинг Super+Shift+R есть в $target вне маркеров — удали строку с rusal-term вручную"
        fi
    fi

    if [[ -f "$CA_ANCHOR" ]]; then
        need_root
        sudo rm -f "$CA_ANCHOR" && sudo update-ca-trust
        log 'корневой CA удалён'
    fi

    if grep -q '^# Omnissa Horizon (RUSAL VDI)' /etc/hosts 2>/dev/null; then
        need_root
        sudo sed -i '/^# Omnissa Horizon (RUSAL VDI)$/,+1d' /etc/hosts
        log 'запись /etc/hosts удалена'
    fi

    rm -rf "$HOME/.local/share/rusal-vpn"
    local f
    for f in rusal rusal-vpn rusal-term rusal-view; do
        rm -f "$BIN_DIR/$f"
    done
    log 'скрипты и vpnc-script удалены'

    log ''
    log 'Пакеты (openconnect, vpnc, opensc, ccid, jcpkcs11-2, sac-core) не удалялись.'
    log 'Модули p11-kit в /etc/pkcs11/modules/ тоже остались — они нужны для токена.'
}

# ------------------------------------------------------------------- main ---

if [[ $REMOVE -eq 1 ]]; then
    do_remove
    exit 0
fi

log 'RUSAL VPN + Omnissa Horizon'
need_cmd python3

if [[ $DO_PACKAGES -eq 1 ]]; then
    install_packages
    install_jacarta_module
fi

enable_pcscd
register_pkcs11
install_ca
make_vpnc_script
install_scripts
configure_hosts

if [[ $DO_HYPR -eq 1 ]]; then
    configure_hypr
fi

mkdir -p "$STATE_DIR"

log ''
log 'Готово.'
log ''
log '  rusal          — подключить VPN и открыть рабочий стол'
log '  rusal view     — только открыть рабочий стол'
log '  rusal down     — отключить VPN'
log '  Super+Shift+R  — то же, что rusal'
log ''
log "Лог VPN: $STATE_DIR/openconnect.log"

if ! p11tool --list-tokens 2>/dev/null | grep -qiE 'jacarta|safenet|etoken'; then
    log ''
    warn 'токен не виден. Вставь его и проверь: p11tool --list-tokens'
fi

if ! command -v vmware-view >/dev/null 2>&1; then
    log ''
    warn 'клиент Omnissa Horizon не установлен: yay -S vmware-horizon-client'
fi
