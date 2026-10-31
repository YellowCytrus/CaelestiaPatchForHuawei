#!/usr/bin/env bash
# Возвращает штатный PAM-стек sudo/polkit и отключает 10-минутную блокировку
# после неудачных паролей — НЕ трогая /etc/pam.d/system-auth.
#
# Почему так:
#   В Linux-PAM 1.7.x удаление строк pam_faillock из system-auth ломает
#   переходы [success=N]: pam_authenticate начинает возвращать PAM_PERM_DENIED
#   даже при верном пароле. В результате sudo и polkit не пускают вообще,
#   а su/passwd/greetd работают (у них собственные стеки без этих переходов).
#   Правильный способ — deny = 0 в /etc/security/faillock.conf: попытки
#   продолжают записываться, но блокировки нет.
#
# Использование:
#   sudo ./fix-sudo-pam-faillock.sh            # починить + отключить блокировку
#   sudo ./fix-sudo-pam-faillock.sh --revert   # вернуть сток и лок по умолчанию
#   sudo ./fix-sudo-pam-faillock.sh --help
set -euo pipefail

PAM_FILE="/etc/pam.d/system-auth"
FAILLOCK_CONF="/etc/security/faillock.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

MODE=apply
for arg in "$@"; do
    case "$arg" in
        --revert)  MODE=revert ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $arg (см. --help)" >&2
            exit 2
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root — перезапускаю через sudo..."
    exec sudo -- "$0" "$@"
fi

command -v bsdtar >/dev/null 2>&1 || die "нужен bsdtar (пакет libarchive)"

# Стоковый system-auth из пакета pambase: сначала из кэша pacman,
# при отсутствии — докачиваем пакет.
stock_pam() {
    local pkg
    pkg="$(ls -t /var/cache/pacman/pkg/pambase-*.pkg.tar.zst 2>/dev/null | head -1 || true)"

    if [[ -z "${pkg:-}" ]]; then
        echo "В кэше нет pambase — скачиваю..." >&2
        pacman -Sw --noconfirm pambase >/dev/null 2>&1 \
            || die "не удалось скачать pambase (нужна сеть/pacman)"
        pkg="$(ls -t /var/cache/pacman/pkg/pambase-*.pkg.tar.zst 2>/dev/null | head -1 || true)"
    fi

    [[ -n "${pkg:-}" ]] || die "не найден пакет pambase в /var/cache/pacman/pkg"
    bsdtar -xOf "$pkg" etc/pam.d/system-auth
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
stock_pam > "$TMP"
[[ -s "$TMP" ]] || die "не удалось извлечь system-auth из pambase"

if [[ "$MODE" == "revert" ]]; then
    cp -a "$PAM_FILE" "$PAM_FILE.bak.$STAMP"
    install -m 0644 -o root -g root "$TMP" "$PAM_FILE"
    echo "system-auth возвращён к стоку (бэкап: $PAM_FILE.bak.$STAMP)"

    if grep -qE '^[[:space:]]*deny[[:space:]]*=[[:space:]]*0[[:space:]]*$' "$FAILLOCK_CONF" 2>/dev/null; then
        cp -a "$FAILLOCK_CONF" "$FAILLOCK_CONF.bak.$STAMP"
        sed -i -E 's|^[[:space:]]*deny[[:space:]]*=[[:space:]]*0[[:space:]]*$|# deny = 0 (отключение блокировки убрано)|' "$FAILLOCK_CONF"
        echo "faillock: deny = 0 закомментирован (бэкап: $FAILLOCK_CONF.bak.$STAMP)"
        echo "Теперь работает штатная блокировка: 3 попытки, 10 минут."
    fi
    exit 0
fi

echo "== 1/2  system-auth =="
if cmp -s "$TMP" "$PAM_FILE"; then
    echo "Уже стоковый — ничего не меняю."
else
    cp -a "$PAM_FILE" "$PAM_FILE.bak.$STAMP"
    install -m 0644 -o root -g root "$TMP" "$PAM_FILE"
    echo "Восстановлен из pambase (бэкап: $PAM_FILE.bak.$STAMP)"
fi

echo
echo "== 2/2  блокировка после неудачных паролей =="
if grep -qE '^[[:space:]]*deny[[:space:]]*=[[:space:]]*0[[:space:]]*$' "$FAILLOCK_CONF" 2>/dev/null; then
    echo "deny = 0 уже стоит — блокировки нет."
elif grep -qE '^[[:space:]]*deny[[:space:]]*=' "$FAILLOCK_CONF" 2>/dev/null; then
    cp -a "$FAILLOCK_CONF" "$FAILLOCK_CONF.bak.$STAMP"
    sed -i -E 's|^[[:space:]]*deny[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$|deny = 0|' "$FAILLOCK_CONF"
    echo "deny заменён на 0 (бэкап: $FAILLOCK_CONF.bak.$STAMP)"
else
    cp -a "$FAILLOCK_CONF" "$FAILLOCK_CONF.bak.$STAMP"
    {
        printf '\n# Блокировка после неудачных паролей отключена\n'
        printf '# (CaelestiaPatchForHuawei / fix-sudo-pam-faillock.sh).\n'
        printf '# Попытки пишутся в tally, но аккаунт не блокируется.\n'
        printf 'deny = 0\n'
    } >> "$FAILLOCK_CONF"
    echo "Добавлено deny = 0 (бэкап: $FAILLOCK_CONF.bak.$STAMP)"
fi

echo
echo "== проверка =="
if cmp -s "$TMP" "$PAM_FILE"; then
    echo "system-auth совпадает с pambase"
else
    die "system-auth не совпал со стоком — проверь вручную"
fi
if grep -qE '^auth.*pam_faillock' "$PAM_FILE"; then
    echo "строки pam_faillock на месте (стек не тронут)"
else
    die "в system-auth нет активных строк pam_faillock — что-то не так"
fi
if grep -qE '^[[:space:]]*deny[[:space:]]*=[[:space:]]*0[[:space:]]*$' "$FAILLOCK_CONF"; then
    echo "faillock: deny = 0 (блокировки нет)"
else
    die "не удалось выставить deny = 0"
fi

echo
echo "Готово. Проверь вход по паролю:"
echo "    sudo -k; sudo -v"
echo "Ожидаемо: пароль принимается; после 3+ ошибок блокировки нет."
