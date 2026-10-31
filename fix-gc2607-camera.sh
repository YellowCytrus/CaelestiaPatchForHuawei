#!/usr/bin/env bash
# Включает встроенную камеру Huawei MateBook GT (GalaxyCore GC2607 / Intel IPU6).
#
# Почему без этого не работает:
#   * камера подключена не по USB, а по MIPI CSI-2 через Intel IPU6;
#   * в ядре нет драйвера сенсора GC2607 (ACPI HID GCTI2607), поэтому
#     в системе нет камеры, а только 48 сырых узлов /dev/video0..47 «ipu6»;
#   * Telegram/OBS эти узлы открыть не могут — отсюда «камера не открывается».
#
# Скрипт ставит неофициальный, но рабочий стек:
#   intel-ipu6-dkms (PSYS) + gc2607 (драйвер сенсора) + патченный ipu-bridge
#   + Intel HAL с тюнингом GC2607 + icamerasrc + v4l2-relayd.
#   На выходе — обычная V4L2-камера «GC2607 Virtual Camera» (/dev/video60),
#   которую видят Telegram, OBS, браузеры и Discord.
#
# Использование:
#   ./fix-gc2607-camera.sh                  # установить и настроить
#   ./fix-gc2607-camera.sh --check          # только проверить, ничего не менять
#   ./fix-gc2607-camera.sh --flip none      # ориентация: none|horizontal-flip|...
#   ./fix-gc2607-camera.sh --port 4         # CSI-порт сенсора (по умолчанию 4)
#   ./fix-gc2607-camera.sh --rebuild        # пересобрать пакеты заново
#   ./fix-gc2607-camera.sh --yes            # без вопросов (для автоматизации)
#   ./fix-gc2607-camera.sh --restart-telegram  # применить и перезапустить Telegram
#   ./fix-gc2607-camera.sh --remove         # удалить стек и вернуть стоковый HAL
set -euo pipefail

SENSOR_HID="GCTI2607"
REPO_URL="https://github.com/AlexDaichendt/gc2607-camera-linux"
SRC_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gc2607-camera-linux"
PROFILE="/etc/camera/ipu6epmtl/libcamhal_profile.xml"
RELAYD_CONF="/etc/v4l2-relayd.d/gc2607.conf"
RELAYD_UNIT="v4l2-relayd@gc2607.service"
CARD_LABEL="GC2607 Virtual Camera"
DISPLAY_NODE="/dev/video60"
PSYS_NODE="/dev/ipu-psys0"

PACKAGES=(gc2607-dkms gc2607-ipu-bridge-dkms gc2607-ipu6-camera-hal gc2607-virtual-camera)
INSTALLED=(gc2607-dkms-git gc2607-ipu-bridge-dkms-git gc2607-ipu6-camera-hal-git gc2607-virtual-camera-git)

DEFAULT_FLIP="horizontal-flip"
DEFAULT_PORT="4"

MODE="install"
FLIP="$DEFAULT_FLIP"
CSI_PORT=""
REBUILD=0
ASSUME_YES=0
RESTART_TG=0

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR == 1 { next }
         /^set -euo pipefail/ { exit }
         { sub(/^# ?/, ""); print }' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   MODE="check" ;;
        --remove)  MODE="remove" ;;
        --rebuild) REBUILD=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --restart-telegram) RESTART_TG=1 ;;
        --flip)
            [[ -n "${2:-}" ]] || die "--flip требует значение"
            FLIP="$2"; shift ;;
        --port)
            [[ -n "${2:-}" ]] || die "--port требует значение"
            CSI_PORT="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
done

VALID_FLIPS=(none horizontal-flip vertical-flip rotate-180 clockwise counterclockwise
             upper-left-diagonal upper-right-diagonal lower-left-diagonal lower-right-diagonal)
is_valid_flip() {
    local f
    for f in "${VALID_FLIPS[@]}"; do [[ "$f" == "$1" ]] && return 0; done
    return 1
}

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    [[ -t 0 ]] || return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "да" ]]
}

have_pkg() { pacman -Q "$1" >/dev/null 2>&1; }

aur_helper() {
    if command -v paru >/dev/null 2>&1; then echo paru
    elif command -v yay  >/dev/null 2>&1; then echo yay
    else return 1
    fi
}

as_root() { sudo "$@"; }

# --- проверки железа и окружения -------------------------------------------

check_host() {
    bold "Проверяю железо"
    [[ "$(id -u)" -ne 0 ]] || die "запусти скрипт от обычного пользователя, не от root"

    if [[ ! -d /sys/bus/acpi/devices/$SENSOR_HID:00 ]] &&
       ! ls /sys/bus/i2c/devices/ 2>/dev/null | grep "$SENSOR_HID" >/dev/null; then
        die "сенсор $SENSOR_HID не найден — это не MateBook GT с GC2607 (или камера выключена в BIOS)"
    fi
    local status
    status="$(cat "/sys/bus/acpi/devices/$SENSOR_HID:00/status" 2>/dev/null || echo '?')"
    ok "сенсор $SENSOR_HID найден (ACPI status=$status)"

    command -v pacman >/dev/null 2>&1 || die "нужен Arch/CachyOS (pacman)"
    command -v sudo   >/dev/null 2>&1 || die "нужен sudo"
    command -v makepkg >/dev/null 2>&1 || die "нужен base-devel (makepkg)"
    command -v dkms    >/dev/null 2>&1 || die "нужен dkms (sudo pacman -S dkms)"

    [[ -d "/lib/modules/$(uname -r)/build" ]] ||
        die "нет заголовков ядра для $(uname -r) — установи linux-cachyos-headers"

    if ! have_pkg base-devel; then
        warn "пакет base-devel не установлен — ставлю"
        as_root pacman -S --needed --noconfirm base-devel
    fi
}

# --- определение CSI-порта --------------------------------------------------

detect_csi_port() {
    command -v media-ctl >/dev/null 2>&1 || return 1
    media-ctl -d /dev/media0 -p 2>/dev/null | awk '
        /^- entity [0-9]+: Intel IPU6 CSI2 [0-9]+/ {
            match($0, /CSI2 [0-9]+/)
            port = substr($0, RSTART + 5, RLENGTH - 5)
        }
        /gc2607/ && port != "" { print port; exit }
    '
}

resolve_port() {
    if [[ -n "$CSI_PORT" ]]; then
        echo "$CSI_PORT"
        return
    fi
    local detected
    detected="$(detect_csi_port || true)"
    echo "${detected:-$DEFAULT_PORT}"
}

# --- установка зависимостей и пакетов ---------------------------------------

install_deps() {
    bold "Зависимости из репозиториев и AUR"
    local helper
    helper="$(aur_helper)" || die "нужен AUR-хелпер (paru или yay)"

    as_root pacman -S --needed --noconfirm \
        dkms git cmake ninja pkgconf v4l-utils gst-plugins-good gstreamer \
        gst-plugins-base gst-plugins-bad linux-firmware

    "$helper" -S --needed --noconfirm \
        intel-ipu6-camera-bin icamerasrc-git v4l2-relayd
}

remove_stock_hal() {
    if have_pkg gc2607-ipu6-camera-hal-git; then
        return 0
    fi
    if have_pkg intel-ipu6-camera-hal-git; then
        bold "Убираю стоковый HAL (его заменит патченный под GC2607)"
        # -Rdd: зависимость icamerasrc-git будет закрыта пакетом gc2607-ipu6-camera-hal
        as_root pacman -Rdd --noconfirm intel-ipu6-camera-hal-git
    fi
}

clone_repo() {
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" pull --ff-only --quiet || warn "не удалось обновить $SRC_DIR (продолжаю)"
    else
        bold "Клонирую bring-up проект"
        git clone --depth=1 "$REPO_URL" "$SRC_DIR"
    fi
}

build_packages() {
    local p dir
    for p in "${PACKAGES[@]}"; do
        dir="$SRC_DIR/packaging/aur/$p"
        [[ -d "$dir" ]] || die "нет каталога пакета: $dir"

        if [[ "$REBUILD" -eq 0 ]] && have_pkg "${p}-git"; then
            ok "пакет ${p}-git уже установлен (--rebuild чтобы пересобрать)"
            continue
        fi

        bold "Собираю ${p}-git"
        ( cd "$dir" && makepkg -si --noconfirm )
    done
}

# --- правки конфигов --------------------------------------------------------

patch_hal_profile() {
    local port="$1" entry="gc2607-uf-${port}"

    [[ -f "$PROFILE" ]] || die "нет $PROFILE — HAL не установился"

    if grep -q "$entry" "$PROFILE"; then
        ok "HAL-профиль уже знает $entry"
        return 0
    fi

    bold "Добавляю $entry в список сенсоров HAL"
    warn "в bring-up проекте прописан только CSI-порт 0, у MateBook GT — порт ${port}"

    local stamp tmp
    stamp="$(date +%Y%m%d-%H%M%S)"
    as_root cp -a "$PROFILE" "${PROFILE}.bak.${stamp}"
    echo "  бэкап: ${PROFILE}.bak.${stamp}"

    tmp="$(mktemp)"
    python3 - "$PROFILE" "$entry" > "$tmp" <<'PY'
import re
import sys

path, entry = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

m = re.search(r'availableSensors\s+value="([^"]*)"', text, re.S)
if not m:
    sys.exit("не нашёл availableSensors в профиле HAL")

if entry in [item.strip() for item in m.group(1).split(",")]:
    sys.stdout.write(text)
    raise SystemExit

if "gc2607-uf-0," in text:
    text = text.replace("gc2607-uf-0,", f"gc2607-uf-0,{entry},", 1)
else:
    text = text.replace('availableSensors value="',
                        f'availableSensors value="{entry},', 1)

sys.stdout.write(text)
PY
    as_root install -m644 "$tmp" "$PROFILE"
    rm -f "$tmp"
    ok "профиль обновлён: $entry"
}

patch_relayd_flip() {
    local method="$1"

    [[ -f "$RELAYD_CONF" ]] || die "нет $RELAYD_CONF — пакет gc2607-virtual-camera не установился"

    if grep -q "videoflip method=${method}\b" "$RELAYD_CONF"; then
        ok "ориентация уже: $method"
        return 0
    fi

    grep -q 'videoflip method=' "$RELAYD_CONF" ||
        die "в $RELAYD_CONF нет videoflip — нечего настраивать"

    bold "Ставлю ориентацию: $method"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    as_root cp -a "$RELAYD_CONF" "${RELAYD_CONF}.bak.${stamp}"
    echo "  бэкап: ${RELAYD_CONF}.bak.${stamp}"

    as_root sed -i -E "s/videoflip method=[a-z0-9-]+/videoflip method=${method}/" "$RELAYD_CONF"
    as_root systemctl daemon-reload
    as_root systemctl restart "$RELAYD_UNIT" >/dev/null 2>&1 || true
    ok "ориентация обновлена: $method"
}

# --- перезагрузка модулей и сервисов ---------------------------------------

reload_stack() {
    bold "Перезагружаю модули ядра"
    local failed=0

    as_root systemctl stop "$RELAYD_UNIT" >/dev/null 2>&1 || true

    # Порядок важен: isys/intel_ipu6 держат ipu_bridge, v4l2loopback — relayd.
    for m in v4l2loopback intel_ipu6_isys ipu_bridge intel_ipu6; do
        as_root modprobe -r "$m" >/dev/null 2>&1 || failed=1
    done

    for m in ipu_bridge gc2607 intel_ipu6_isys intel_ipu6_psys v4l2loopback; do
        if ! as_root modprobe "$m" >/dev/null 2>&1; then
            warn "не удалось загрузить модуль $m"
            failed=1
        fi
    done

    as_root systemctl start "$RELAYD_UNIT" >/dev/null 2>&1 || true

    if [[ "$failed" -eq 1 ]]; then
        warn "модули заняты (обычно Telegram держит /dev/video0). Нужна перезагрузка."
        return 1
    fi
    ok "модули перезагружены"
}

restart_desktop_services() {
    bold "Обновляю WirePlumber (скрывает 48 сырых узлов ipu6)"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet wireplumber 2>/dev/null; then
        systemctl --user restart wireplumber || warn "не удалось перезапустить WirePlumber"
        ok "WirePlumber перезапущен"
    else
        warn "WirePlumber не запущен — пропускаю"
    fi
}

restart_telegram() {
    local tg_bin
    tg_bin="$(command -v Telegram || command -v telegram-desktop || true)"
    [[ -n "$tg_bin" ]] || { warn "Telegram не найден в PATH — перезапусти его вручную"; return 0; }

    if pgrep -x Telegram >/dev/null 2>&1; then
        echo "Перезапускаю Telegram..."
        pkill -x Telegram >/dev/null 2>&1 || true
        for _ in $(seq 1 40); do
            pgrep -x Telegram >/dev/null 2>&1 || break
            sleep 0.25
        done
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
        hyprctl dispatch exec "$tg_bin" >/dev/null
    else
        setsid -f "$tg_bin" >/dev/null 2>&1 || nohup "$tg_bin" >/dev/null 2>&1 &
    fi
    ok "Telegram перезапущен"
}

# --- проверка результата ----------------------------------------------------

verify() {
    bold "Проверка"
    local fail=0

    lsmod | grep '^gc2607 ' >/dev/null && ok "драйвер gc2607 загружен" || { warn "модуль gc2607 не загружен"; fail=1; }
    media-ctl -d /dev/media0 -p 2>/dev/null | grep 'gc2607' >/dev/null &&
        ok "сенсор виден в media-графе" || { warn "сенсора нет в media-графе"; fail=1; }
    [[ -e "$PSYS_NODE" ]] && ok "$PSYS_NODE есть" || { warn "нет $PSYS_NODE"; fail=1; }
    [[ -e "$DISPLAY_NODE" ]] && ok "$DISPLAY_NODE есть" || { warn "нет $DISPLAY_NODE"; fail=1; }
    systemctl is-active --quiet "$RELAYD_UNIT" &&
        ok "v4l2-relayd работает" || { warn "v4l2-relayd не запущен"; fail=1; }

    if [[ -e "$DISPLAY_NODE" ]]; then
        if v4l2-ctl -d "$DISPLAY_NODE" --info 2>/dev/null | grep "$CARD_LABEL" >/dev/null; then
            ok "карточка «$CARD_LABEL» на месте"
        else
            warn "на $DISPLAY_NODE нет карточки «$CARD_LABEL»"
            fail=1
        fi
    fi

    # Живой кадр: relayd сначала отдаёт чёрную заглушку, потом реальный сенсор,
    # поэтому смотрим самый большой JPEG — у настоящего кадра много деталей.
    if [[ -e "$DISPLAY_NODE" ]] && systemctl is-active --quiet "$RELAYD_UNIT"; then
        local tmp count biggest=0 f size
        tmp="$(mktemp -d)"
        if timeout 45 gst-launch-1.0 -q v4l2src device="$DISPLAY_NODE" num-buffers=40 \
                ! 'video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1' \
                ! jpegenc ! multifilesink location="$tmp/f-%03d.jpg" >/dev/null 2>&1; then
            count="$(find "$tmp" -name 'f-*.jpg' | wc -l)"
            for f in "$tmp"/f-*.jpg; do
                [[ -e "$f" ]] || continue
                size="$(stat -c %s "$f")"
                (( size > biggest )) && biggest="$size"
            done
            if (( count >= 5 && biggest > 10000 )); then
                ok "живой кадр получен ($count кадров, макс. $biggest Б)"
            else
                warn "кадры не получены ($count кадров, макс. $biggest Б)"
                fail=1
            fi
        else
            warn "тестовый захват с $DISPLAY_NODE не удался"
            fail=1
        fi
        rm -rf "$tmp"
    fi

    if [[ "$fail" -eq 0 ]]; then
        printf '\n\033[32mВсё работает.\033[0m В Telegram/OBS выбирай «%s».\n' "$CARD_LABEL"
    else
        printf '\n\033[33mЕсть проблемы\033[0m — см. вывод выше и команды диагностики в README.\n'
    fi
    return "$fail"
}

# --- удаление ---------------------------------------------------------------

remove_stack() {
    bold "Удаляю стек GC2607"

    confirm "Удалить пакеты GC2607 и вернуть стоковый HAL?" || { echo "Отменено."; exit 0; }

    as_root systemctl stop "$RELAYD_UNIT" >/dev/null 2>&1 || true
    as_root systemctl disable "$RELAYD_UNIT" >/dev/null 2>&1 || true

    # HAL удаляем через -Rdd: его зависимость тянет icamerasrc-git.
    if have_pkg gc2607-ipu6-camera-hal-git; then
        as_root pacman -Rdd --noconfirm gc2607-ipu6-camera-hal-git || true
    fi
    for pkg in "${INSTALLED[@]}"; do
        have_pkg "$pkg" || continue
        as_root pacman -Rns --noconfirm "$pkg" || as_root pacman -Rdd --noconfirm "$pkg" || true
    done

    local helper
    if helper="$(aur_helper)"; then
        bold "Возвращаю стоковый intel-ipu6-camera-hal-git"
        "$helper" -S --needed --noconfirm intel-ipu6-camera-hal-git || warn "не удалось вернуть стоковый HAL"
    fi

    warn "модули остаются загруженными до перезагрузки — перезагрузись, чтобы всё вернуть как было"
    echo "Кэш исходников остался в $SRC_DIR (можно удалить вручную)."
    exit 0
}

# --- main -------------------------------------------------------------------

if [[ "$MODE" == "remove" ]]; then
    [[ "$(id -u)" -ne 0 ]] || die "запусти скрипт от обычного пользователя, не от root"
    command -v pacman >/dev/null 2>&1 || die "нужен Arch/CachyOS (pacman)"
    command -v sudo   >/dev/null 2>&1 || die "нужен sudo"
    remove_stack
fi

if [[ "$MODE" == "check" ]]; then
    if verify; then exit 0; else exit 1; fi
fi

is_valid_flip "$FLIP" || die "неизвестная ориентация «$FLIP» (варианты: ${VALID_FLIPS[*]})"
[[ -z "$CSI_PORT" || "$CSI_PORT" =~ ^[0-5]$ ]] || die "--port: ожидается номер CSI-порта 0..5"

check_host
CSI_PORT="$(resolve_port)"
ok "CSI-порт сенсора: $CSI_PORT"

confirm "Установить/обновить стек камеры GC2607? Понадобятся sudo и сборка из AUR." ||
    { echo "Отменено."; exit 0; }

install_deps
remove_stock_hal
clone_repo
build_packages

patch_hal_profile "$CSI_PORT"
patch_relayd_flip "$FLIP"

stack_running() {
    lsmod | grep '^gc2607 ' >/dev/null 2>&1 &&
        [[ -e "$DISPLAY_NODE" ]] &&
        systemctl is-active --quiet "$RELAYD_UNIT" 2>/dev/null
}

if stack_running && [[ "$REBUILD" -eq 0 ]]; then
    ok "стек уже загружен — модули не трогаю"
    NEED_REBOOT=0
    restart_desktop_services
elif ! reload_stack; then
    NEED_REBOOT=1
else
    NEED_REBOOT=0
    restart_desktop_services
fi

verify || true

if [[ "$RESTART_TG" -eq 1 && "$NEED_REBOOT" -eq 0 ]]; then
    restart_telegram
fi

echo
echo "Дальше:"
if [[ "$NEED_REBOOT" -eq 1 ]]; then
    echo "  1. Перезагрузи ноутбук: sudo reboot"
    echo "  2. После ребута прогони: ./fix-gc2607-camera.sh --check"
else
    echo "  1. Перезапусти Telegram (камера подхватывается при старте приложения)."
fi
echo "  В Telegram/OBS в списке камер выбирай «$CARD_LABEL»."
echo
echo "Ориентация: $FLIP  (поменять: ./fix-gc2607-camera.sh --flip none|horizontal-flip|rotate-180|vertical-flip)"
echo "Полное удаление: ./fix-gc2607-camera.sh --remove"
