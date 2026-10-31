#!/usr/bin/env bash
# Жёстко задаёт Красноярск как город для погоды в Caelestia Shell.
# Координаты: центр Красноярска, 56.0106 / 92.8526.
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/shell.json"
COORDS="56.0106,92.8526"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Ошибка: нужен python3" >&2
    exit 1
fi

mkdir -p "$(dirname "$CONFIG")"

if [[ ! -f "$CONFIG" ]]; then
    printf '{}\n' > "$CONFIG"
fi

BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG" "$BACKUP"

if command -v jq >/dev/null 2>&1; then
    TMP="$(mktemp)"
    jq --arg loc "$COORDS" \
        '.services = ((.services // {}) | .weatherLocation = $loc)' \
        "$CONFIG" > "$TMP"
    mv "$TMP" "$CONFIG"
else
    python3 - "$CONFIG" "$COORDS" <<'PY'
import json
import os
import sys
import tempfile

path, loc = sys.argv[1], sys.argv[2]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

services = data.get("services")
if not isinstance(services, dict):
    services = {}
    data["services"] = services

services["weatherLocation"] = loc

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
PY
fi

python3 -m json.tool "$CONFIG" >/dev/null

echo "Готово: $CONFIG"
echo "Бэкап:  $BACKUP"
echo "Погода: Красноярск ($COORDS)"
echo
echo "Чтобы применить сразу:  caelestia shell -r"
echo "Либо просто открой дашборд заново."
