#!/usr/bin/env bash
# Тачскрин Huawei MateBook 14 (FocalTech FTSC1000 / Intel LPSS I2C).
#
# Симптом: тачскрин определяется (hyprctl devices / libinput его видят),
# но касания игнорируются. В журнале ядра при загрузке:
#   i2c_designware i2c_designware.1: i2c_dw_handle_tx_abort: lost arbitration
#   i2c_designware i2c_designware.1: spurious STOP detected
#   i2c_hid_acpi i2c-FTSC1000:00: failed to get a report from device: -5
#   hid-multitouch ...: failed to fetch feature 5 / 12
#
# Причина: ACPI-прошивка Huawei рассчитана на Windows и не даёт Linux
# достаточно времени на старт контроллера. i2c-hid опрашивает его слишком
# рано, обмен по I2C рвётся, устройство остаётся полуинициализированным и не
# присылает события. Повторный probe через несколько секунд после загрузки
# работает. Скрипт ставит сервис, который переподключает только тачскрин,
# удерживает шину I2C включённой и повторяет попытки, пока probe не пройдёт
# без ошибок.
#
# Использование:
#   ./fix-ftsc1000-touchscreen.sh                  # автозапуск + хук сна
#   ./fix-ftsc1000-touchscreen.sh --no-suspend     # без хука сна
#   ./fix-ftsc1000-touchscreen.sh --check          # только диагностика
#   ./fix-ftsc1000-touchscreen.sh --remove         # удалить патч
#   ./fix-ftsc1000-touchscreen.sh --yes            # без вопросов
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files/ftsc1000"

HID="FTSC1000"
MODULE="i2c_hid_acpi"
UNIT="ftsc1000-touch.service"
UNIT_DST="/etc/systemd/system/$UNIT"
INIT_DST="/usr/local/bin/ftsc1000-touch-init.sh"
SLEEP_HOOK_DST="/usr/lib/systemd/system-sleep/ftsc1000-touch"
DEFAULTS_DST="/etc/default/ftsc1000-touch"

MODE="install"
WITH_SUSPEND=1
ASSUME_YES=0

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '17,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)        MODE="check" ;;
        --remove)       MODE="remove" ;;
        --with-suspend) WITH_SUSPEND=1 ;;
        --no-suspend)   WITH_SUSPEND=0 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
done

as_root() { sudo "$@"; }

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    [[ -t 0 ]] || return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "да" ]]
}

need_tools() {
    [[ "$(id -u)" -ne 0 ]] || die "запусти скрипт от обычного пользователя, не от root"
    command -v sudo >/dev/null 2>&1 || die "нужен sudo"
    command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
    command -v modprobe >/dev/null 2>&1 || die "нужен kmod (modprobe)"
}

# --- железо и состояние -----------------------------------------------------

hardware_present() {
    [[ -d "/sys/bus/acpi/devices/${HID}:00" ]] && return 0
    compgen -G "/sys/bus/i2c/devices/i2c-${HID}*" >/dev/null && return 0
    return 1
}

# /dev/input/eventN тачскрина (не Stylus).
touch_event_node() {
    local d e name
    for d in /sys/class/input/input*/; do
        name="$(cat "$d/name" 2>/dev/null || true)"
        [[ "$name" == *"$HID"* ]] || continue
        [[ "$name" == *Stylus* ]] && continue
        for e in "$d"event*; do
            [[ -e "$e" ]] || continue
            echo "/dev/input/$(basename "$e")"
            return 0
        done
    done
    return 1
}

irq_counter() {
    # Суммируем только счётчики по CPU; строка выглядит так:
    #   178: 0 0 ... 1 0 0 intel-gpio 359 FTSC1000:00
    # (359 — номер GPIO-линии, его считать не нужно)
    awk -v id="$HID" '
        index($0, id) {
            sum = 0
            for (i = 2; i <= NF; i++) {
                if ($i !~ /^[0-9]+$/) break
                sum += $i
            }
            print sum
            exit
        }
    ' /proc/interrupts 2>/dev/null
}

last_service_log() {
    journalctl -b -t ftsc1000-touch -n 1 -o cat --no-pager 2>/dev/null || true
}

# --- проверки ---------------------------------------------------------------

check_host() {
    bold "Проверяю железо"
    if ! hardware_present; then
        die "устройство $HID не найдено — это не MateBook 14 с FTSC1000 или тачскрин выключен в BIOS"
    fi
    ok "контроллер $HID найден"
    local node
    if node="$(touch_event_node)"; then
        ok "input-узел: $node"
    else
        warn "input-узла тачскрина сейчас нет (сервис ещё не запускался?)"
    fi
}

verify() {
    bold "Проверка"
    local fail=0 node irq last

    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        ok "сервис включён в автозапуск"
    else
        warn "сервис НЕ включён в автозапуск"
        fail=1
    fi

    node="$(touch_event_node || true)"
    if [[ -n "$node" ]]; then
        ok "тачскрин виден: $node"
    else
        warn "input-узел тачскрина не найден"
        fail=1
    fi

    last="$(last_service_log)"
    if [[ "$last" == *"initialized"* ]]; then
        ok "последний запуск сервиса: $last"
    elif [[ -n "$last" ]]; then
        warn "последний запуск сервиса: $last"
        fail=1
    else
        warn "в журнале текущей загрузки нет записей сервиса"
    fi

    local pci_power bus_power svc_state
    pci_power="$(cat /sys/bus/pci/devices/0000:00:15.1/power/control 2>/dev/null || true)"
    bus_power="$(cat /sys/bus/platform/devices/i2c_designware.1/power/control 2>/dev/null || true)"
    if [[ "$pci_power" == on && "$bus_power" == on ]]; then
        ok "шина I2C удерживается включённой"
    else
        warn "шина может уходить в runtime-suspend (pci=${pci_power:-?}, bus=${bus_power:-?})"
    fi

    svc_state="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
    if [[ "$svc_state" == activating || "$svc_state" == active ]]; then
        ok "сервис сейчас выполняет попытки инициализации"
    fi

    irq="$(irq_counter)"
    if [[ -n "$irq" ]]; then
        ok "прерываний контроллера с загрузки: $irq (при касаниях должно расти)"
    fi

    if [[ "$fail" -eq 0 ]]; then
        printf '\n\033[32mВсё на месте.\033[0m Потрогай экран и, для полной проверки, перезагрузись.\n'
    else
        printf '\n\033[33mЕсть проблемы\033[0m — смотри журнал: journalctl -b -t ftsc1000-touch\n'
    fi
    return "$fail"
}

print_diagnostics() {
    bold "Диагностика"
    local irq
    irq="$(irq_counter)"
    echo "  прерываний FTSC1000: ${irq:-?}"
    if [[ -n "$irq" ]] && (( irq <= 2 )); then
        warn "похоже, события не приходят: при касаниях счётчик должен расти"
    fi
    echo "  последние сообщения ядра:"
    local klog
    klog="$(journalctl -b -k --no-pager 2>/dev/null |
        grep -E "FTSC1000|i2c_designware\.1" | tail -5 || true)"
    if [[ -n "$klog" ]]; then
        sed 's/^/    /' <<<"$klog"
        if [[ "$klog" == *failed* || "$klog" == *spurious* ]]; then
            echo "    (сбои в начале загрузки ожидаемы — их и лечит сервис,"
            echo "     важен успешный повторный probe после них)"
        fi
    else
        echo "    (сообщений нет — контроллер отработал без ошибок)"
    fi
}

# --- установка --------------------------------------------------------------

install_patch() {
    bold "Устанавливаю переинициализацию $HID"

    local f
    for f in ftsc1000-touch-init.sh "$UNIT" ftsc1000-touch-resume; do
        [[ -f "$FILES_DIR/$f" ]] || die "нет файла $FILES_DIR/$f"
    done

    confirm "Поставить сервис автозапуска? Понадобится sudo; тачскрин на несколько секунд пропадёт из системы." ||
        { echo "Отменено."; exit 0; }

    as_root install -m755 "$FILES_DIR/ftsc1000-touch-init.sh" "$INIT_DST"
    as_root install -m644 "$FILES_DIR/$UNIT" "$UNIT_DST"

    if [[ "$WITH_SUSPEND" -eq 1 ]]; then
        as_root install -m755 "$FILES_DIR/ftsc1000-touch-resume" "$SLEEP_HOOK_DST"
        ok "хук на выход из сна: $SLEEP_HOOK_DST"
    fi

    if [[ ! -f "$DEFAULTS_DST" ]]; then
        printf '%s\n' \
            '# Настройки переинициализации тачскрина FTSC1000.' \
            '# FTSC1000_ATTEMPTS   — сколько раз пробовать (по умолчанию 5)' \
            '# FTSC1000_BASE_DELAY — стартовая задержка в секундах (по умолчанию 2)' \
            '# FTSC1000_MAX_DELAY  — максимальная задержка между попытками (30)' \
            'FTSC1000_ATTEMPTS=5' \
            'FTSC1000_BASE_DELAY=2' \
            'FTSC1000_MAX_DELAY=30' |
            as_root tee "$DEFAULTS_DST" >/dev/null
        ok "настройки: $DEFAULTS_DST"
    fi

    as_root systemctl daemon-reload
    as_root systemctl enable --now "$UNIT"
    ok "сервис установлен и запущен"

    bold "Жду инициализацию (до 60 с)"
    local waited=0 last=""
    while (( waited < 60 )); do
        last="$(last_service_log)"
        [[ "$last" == *"initialized"* ]] && break
        [[ "$last" == *"did not initialize"* ]] && break
        sleep 2
        waited=$((waited + 2))
    done

    verify || true

    printf '\nДальше:\n'
    printf '  1. Потрогай экран — касания должны работать уже сейчас.\n'
    printf '  2. Перезагрузись и проверь ещё раз: ./%s --check\n' "$(basename "$0")"
    printf '  3. Журнал: journalctl -b -t ftsc1000-touch\n\n'
    printf 'Настроить задержку: %s (FTSC1000_ATTEMPTS, FTSC1000_BASE_DELAY, FTSC1000_MAX_DELAY)\n' "$DEFAULTS_DST"
    printf 'Удалить: ./%s --remove\n' "$(basename "$0")"
}

# --- удаление ---------------------------------------------------------------

remove_patch() {
    bold "Удаляю патч $HID"
    confirm "Отключить и удалить сервис переинициализации тачскрина?" || { echo "Отменено."; exit 0; }

    as_root systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    as_root rm -f "$UNIT_DST" "$INIT_DST" "$SLEEP_HOOK_DST" "$DEFAULTS_DST"
    as_root systemctl daemon-reload
    ok "сервис, скрипт и хук сна удалены"

    warn "переподключение больше не выполняется: тачскрин продолжит работать до перезагрузки"
    echo "После перезагрузки поведение вернётся к стоковому (тачскрин снова может не работать)."
}

# --- main -------------------------------------------------------------------

case "$MODE" in
    check)
        if hardware_present; then
            ok "контроллер $HID найден"
        else
            warn "устройство $HID не найдено — похоже, это другая модель"
        fi
        verify || true
        print_diagnostics
        ;;
    remove)
        need_tools
        remove_patch
        ;;
    install)
        need_tools
        check_host
        install_patch
        ;;
esac
