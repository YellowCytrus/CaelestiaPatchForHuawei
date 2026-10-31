#!/bin/bash
# Переинициализация тачскрина FocalTech FTSC1000 (Huawei MateBook 14).
#
# ACPI-прошивка Huawei рассчитана на Windows и не даёт Linux достаточно
# времени на старт контроллера: i2c-hid опрашивает его слишком рано, обмен
# по I2C рвётся (lost arbitration / failed to get a report), и hid-multitouch
# оставляет устройство полуинициализированным — события не приходят.
# Повторный probe через несколько секунд после загрузки работает.
#
# Скрипт вызывается systemd при загрузке (и, опционально, после сна).
# Настройки читаются из /etc/default/ftsc1000-touch (см. README).

set -u

MODULE="i2c_hid_acpi"
MATCH="${FTSC1000_MATCH:-FTSC1000}"
ATTEMPTS="${FTSC1000_ATTEMPTS:-3}"
BASE_DELAY="${FTSC1000_BASE_DELAY:-2}"

log() { logger -t ftsc1000-touch -- "$*"; }

# Ищем именно тачскрин, а не его «Stylus»-устройство.
touch_input_present() {
    local d name
    for d in /sys/class/input/input*/; do
        name="$(cat "$d/name" 2>/dev/null || true)"
        [[ "$name" == *"$MATCH"* ]] || continue
        [[ "$name" == *Stylus* ]] && continue
        compgen -G "$d"event* >/dev/null && return 0
    done
    return 1
}

log "re-initializing $MATCH (attempts=$ATTEMPTS, base_delay=$BASE_DELAY)"

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    /usr/bin/modprobe -r "$MODULE" 2>/dev/null
    # Даём контроллеру время завершить собственный старт.
    sleep $((BASE_DELAY + attempt - 1))
    /usr/bin/modprobe "$MODULE" 2>/dev/null
    sleep 1

    if touch_input_present; then
        log "touchscreen initialized (attempt $attempt)"
        exit 0
    fi
    log "attempt $attempt failed, retrying"
done

log "touchscreen did not initialize"
exit 1
