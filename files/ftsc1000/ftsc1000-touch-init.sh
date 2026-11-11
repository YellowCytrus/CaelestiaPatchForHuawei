#!/bin/bash
# Переинициализация тачскрина FocalTech FTSC1000 (Huawei MateBook 14).
#
# Проблема: ACPI-прошивка Huawei рассчитана на Windows и не даёт Linux
# достаточно времени на старт контроллера. Первый probe при загрузке падает
# (failed to fetch HID descriptor / lost arbitration), а повторный probe через
# пару секунд иногда создаёт input-узел, но оставляет устройство «полуживым»:
# при инициализации снова рвётся I2C (spurious STOP, failed to get a report),
# и события не приходят, хотя устройство в системе есть.
#
# Поэтому здесь:
#   * переподключается только FTSC1000 (i2c-FTSC1000:00), тачпад не трогаем;
#   * LPSS-контроллеры удерживаются включёнными (без runtime-suspend);
#   * успех проверяется не только по наличию input-узла, но и по отсутствию
#     I2C-ошибок в dmesg за время попытки;
#   * попытки повторяются с растущей задержкой.
#
# Вызовы:
#   ftsc1000-touch-init.sh            # обычное восстановление
#   ftsc1000-touch-init.sh suspend    # перед сном: отцепить тачскрин
#   ftsc1000-touch-init.sh resume     # после сна: обычное восстановление
#
# Настройки: /etc/default/ftsc1000-touch

set -u

MODULE="i2c_hid_acpi"
I2C_ID="i2c-FTSC1000:00"
MATCH="${FTSC1000_MATCH:-FTSC1000}"
ATTEMPTS="${FTSC1000_ATTEMPTS:-5}"
BASE_DELAY="${FTSC1000_BASE_DELAY:-2}"
MAX_DELAY="${FTSC1000_MAX_DELAY:-30}"

PCI_POWER="/sys/bus/pci/devices/0000:00:15.1/power"
BUS_POWER="/sys/bus/platform/devices/i2c_designware.1/power"
DRIVER="/sys/bus/i2c/drivers/i2c_hid_acpi"
LOCK_FILE="/run/lock/ftsc1000-touch.lock"

log() { logger -t ftsc1000-touch -- "$*"; }

# Без этого контроллер уходит в runtime-suspend и тачскрин перестаёт
# просыпаться до следующего ручного переподключения.
keep_bus_awake() {
    local p
    for p in "$PCI_POWER" "$BUS_POWER"; do
        [[ -w "$p/control" ]] && printf 'on' > "$p/control" 2>/dev/null
    done
    return 0
}

# Тачскрин (не Stylus) с валидным event-узлом и тегом libinput.
touch_input_present() {
    local d name ev
    for d in /sys/class/input/input*/; do
        name="$(cat "$d/name" 2>/dev/null || true)"
        [[ "$name" == *"$MATCH"* ]] || continue
        [[ "$name" == *Stylus* ]] && continue
        ev="$(compgen -G "$d"event* | head -n 1 || true)"
        [[ -n "$ev" ]] || continue
        udevadm info --query=property --name="/dev/input/$(basename "$ev")" 2>/dev/null |
            grep -qx 'ID_INPUT_TOUCHSCREEN=1' && return 0
    done
    return 1
}

dmesg_lines() {
    local n
    n="$(dmesg 2>/dev/null | wc -l)" || return 1
    (( n > 0 )) || return 1
    printf '%s' "$n"
}

# Проверяем, что probe не оставил ошибок I2C. «failed to fetch feature N»
# сюда не входит: она бывает и на полностью рабочем устройстве.
probe_had_errors() {
    local from="${1:-}"
    [[ -n "$from" ]] || return 1
    dmesg 2>/dev/null | tail -n +"$((from + 1))" |
        grep -E 'FTSC1000|i2c_designware\.1' |
        grep -qE 'lost arbitration|spurious STOP|failed to get a report|ailed to fetch the HID Descriptor|ailed to fetch HID descriptor'
}

unbind_touchscreen() {
    if [[ -L "/sys/bus/i2c/devices/$I2C_ID/driver" ]]; then
        printf '%s' "$I2C_ID" > "$DRIVER/unbind" 2>/dev/null || return 1
        udevadm settle --timeout=5 2>/dev/null || true
    fi
    return 0
}

bind_touchscreen() {
    modprobe "$MODULE" 2>/dev/null || true
    keep_bus_awake
    if [[ ! -L "/sys/bus/i2c/devices/$I2C_ID/driver" ]]; then
        printf '%s' "$I2C_ID" > "$DRIVER/bind" 2>/dev/null || return 1
    fi
    udevadm settle --timeout=5 2>/dev/null || true
    keep_bus_awake
    return 0
}

recover() {
    local delay="$BASE_DELAY" attempt mark

    log "re-initializing $MATCH (attempts=$ATTEMPTS, base_delay=$BASE_DELAY)"

    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        sleep "$delay"
        keep_bus_awake

        mark="$(dmesg_lines || true)"

        unbind_touchscreen
        sleep 1
        keep_bus_awake
        bind_touchscreen

        # Даём udev создать event-узел.
        local i
        for i in 1 2 3 4 5; do
            touch_input_present && break
            sleep 1
        done

        if touch_input_present; then
            if ! probe_had_errors "${mark:-}"; then
                log "touchscreen initialized (attempt $attempt)"
                keep_bus_awake
                return 0
            fi
            log "attempt $attempt: probe left I2C errors, retrying in $((delay * 2))s"
        else
            log "attempt $attempt: input node missing, retrying in $((delay * 2))s"
        fi

        delay=$((delay * 2))
        (( delay > MAX_DELAY )) && delay="$MAX_DELAY"
    done

    log "touchscreen did not initialize after $ATTEMPTS attempts"
    return 1
}

# Сон и загрузка не должны выполняться одновременно.
exec 9>"$LOCK_FILE" 2>/dev/null || true
if [[ -e /proc/self/fd/9 ]]; then
    flock -w 30 9 || { log "lock timeout"; exit 1; }
fi

keep_bus_awake

case "${1:-recover}" in
    suspend)
        log "suspending: detaching touchscreen"
        unbind_touchscreen
        ;;
    resume|recover)
        recover
        ;;
    *)
        echo "usage: $0 [recover|suspend|resume]" >&2
        exit 2
        ;;
esac
