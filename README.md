# CaelestiaPatchForHuawei

Набор мини-патчей для Caelestia Shell / Hyprland на Huawei-ноутбуке (CachyOS).
Каждый скрипт идемпотентен, перед изменением делает бэкап и не трогает
остальные настройки.

| Патч | Скрипт |
| --- | --- |
| Погода: фиксированный Красноярск | `set-krasnoyarsk-weather.sh` |
| Telegram не забирает фокус | `fix-telegram-focus.sh` |
| Тачскрин FocalTech FTSC1000 (MateBook 14) | `fix-ftsc1000-touchscreen.sh` |
| VPN РУСАЛ + рабочий стол Omnissa Horizon | `install-rusal-vpn.sh` |
| Селектор обоев с поиском и анимациями | `install-wallpaper-picker.sh` |
| Камера GC2607 (Telegram/OBS) | `fix-gc2607-camera.sh` |
| Клипборд: Imperial-style пикер | `install-clipboard-picker.sh` |
| VPN kvn-tui: DNS без пароля + хоткей | `install-kvn-vpn.sh` |
| sudo/PAM: без 10-минутной блокировки | `fix-sudo-pam-faillock.sh` |

---

## Погода: Красноярск

Фиксирует Красноярск как город погоды. Погода остаётся живой (Open-Meteo),
но IP-геолокация больше не используется.

### Запуск

```bash
chmod +x set-krasnoyarsk-weather.sh
./set-krasnoyarsk-weather.sh
caelestia shell -r
```

Если не перезапускать шелл — достаточно заново открыть дашборд.

### Что делает

Прописывает в `~/.config/caelestia/shell.json`:

```json
"services": {
    "weatherLocation": "56.0106,92.8526"
}
```

Перед изменением создаёт бэкап `shell.json.bak.ГОДМЕСЯЦДЕНЬ-ЧЧММСС`.
Остальные настройки не трогает. После записи проверяет валидность JSON.

### Требования

- Caelestia Shell (проверено на `caelestia-shell 2.5.0-1`, CachyOS)
- `python3`
- `jq` — опционально (без него используется Python-ветка)

### Откат

Взять нужный бэкап и вернуть на место:

```bash
cp ~/.config/caelestia/shell.json.bak.ГОДМЕСЯЦДЕНЬ-ЧЧММСС ~/.config/caelestia/shell.json
caelestia shell -r
```

---

## Telegram: не забирать фокус при уведомлениях

### Проблема

При входящем сообщении фокус перескакивает на окно Telegram.

Причина — связка Qt 6.12 и Hyprland:

- в Telegram включена настройка **«Привлекать внимание к окну»**
  (*Draw attention to the window*);
- Qt 6.12 на Wayland реализует её через `QWindow::alert()` →
  xdg-activation-запрос;
- Hyprland с `misc:focus_on_activate = true` выполняет этот запрос
  и фокусирует окно.

Скрипт добавляет window rule, который подавляет такую активацию только для
Telegram (class `org.telegram.desktop`):

```lua
hl.window_rule({
    name           = "telegram-no-focus-on-activate",
    match          = { class = "^(org\\.telegram\\.desktop)$" },
    suppress_event = "activatefocus",
})
```

На старом Qt (без такого поведения) патч не нужен.

### Запуск

```bash
chmod +x fix-telegram-focus.sh
./fix-telegram-focus.sh
```

Скрипт сам перезагрузит конфиг Hyprland. Правило статическое и применяется
при создании окна, поэтому **Telegram нужно перезапустить**. Это можно сделать
сразу:

```bash
./fix-telegram-focus.sh --restart-telegram
```

### Что делает

1. Проверяет, что в `~/.config/hypr/hyprland.lua` подключён
   `require("hypr-user")`, и использует пользовательский конфиг
   `~/.config/caelestia/hypr-user.lua` (он подключается последним
   и не перезаписывается обновлениями).
2. Если `hypr-user.lua` не подключён — использует
   `~/.config/hypr/hyprland/rules.lua` и предупреждает об этом.
3. Делает бэкап рядом с изменённым файлом:
   `hypr-user.lua.bak.ГОДМЕСЯЦДЕНЬ-ЧЧММСС`
   (или `rules.lua.bak.…` при фолбэке).
4. Добавляет блок с правилом между маркерами
   `telegram-no-focus-on-activate`.
5. Проверяет синтаксис Lua (`luac -p` или `lua`), при ошибке возвращает бэкап.
6. Выполняет `hyprctl reload`, если Hyprland запущен.

Повторный запуск ничего не дублирует.

### Важно

Правило подавляет **все** запросы активации Telegram, поэтому клик по
уведомлению тоже перестанет поднимать его окно. Если фокус по клику нужен:

1. Выключи в Telegram: **Настройки → Уведомления → «Привлекать внимание к окну»**.
2. Убери правило:

```bash
./fix-telegram-focus.sh --remove
```

После этого фокус не будет красться при уведомлении, но клик по уведомлению
снова будет открывать Telegram. Перезапусти Telegram, чтобы изменения
применились к его окну.

### Откат

```bash
./fix-telegram-focus.sh --remove
```

Либо вернуть бэкап:

```bash
cp ~/.config/caelestia/hypr-user.lua.bak.ГОДМЕСЯЦДЕНЬ-ЧЧММСС ~/.config/caelestia/hypr-user.lua
hyprctl reload
```

### Требования

- Hyprland + Caelestia Shell (проверено на CachyOS, Hyprland 0.56.2)
- Telegram Desktop (Wayland, class `org.telegram.desktop`)
- `bash`; `luac` или `lua` — опционально для проверки синтаксиса
- `hyprctl` — для применения без перезахода

---

## Тачскрин: FocalTech FTSC1000 (MateBook 14)

### Проблема

Тачскрин «есть», но не реагирует: `hyprctl devices` показывает
`ftsc1000:00-2808:5662`, libinput тегирует его как Touchscreen, а касания
ничего не делают.

Диагностика:

```bash
# прерывания контроллера: при касаниях счётчик должен расти
awk '/FTSC1000:00/ {s=0; for (i=2;i<=NF;i++) { if ($i !~ /^[0-9]+$/) break; s+=$i } print s}' /proc/interrupts

# ошибки инициализации в текущей загрузке
journalctl -b -k | grep -E 'FTSC1000|i2c_designware\.1'
```

В журнале при этом видно:

```
i2c_designware i2c_designware.1: i2c_dw_handle_tx_abort: lost arbitration
i2c_designware i2c_designware.1: spurious STOP detected
i2c_hid_acpi i2c-FTSC1000:00: failed to get a report from device: -5
hid-multitouch 0018:2808:5662.0002: failed to fetch feature 5
```

а счётчик прерываний после касаний не меняется (остаётся на уровне
1–2 с момента загрузки).

Бывает и «тихий» вариант: ошибки в журнале относятся только к первому probe,
input-узел в системе есть, `hyprctl devices` показывает тачскрин — но касания
не работают. Устройство создано, однако осталось полуинициализированным.

### Причина

ACPI-прошивка Huawei рассчитана на Windows и не гарантирует, что контроллер
готов к моменту, когда Linux запускает probe. i2c-hid обращается к нему
слишком рано, обмен по I2C рвётся (`lost arbitration`, `spurious STOP`,
`failed to get a report`), hid-multitouch оставляет устройство
полуинициализированным — события не приходят. Чистый повторный probe позже
работает.

Это не неисправность железа: на другой загрузке ошибка может выглядеть
иначе (`failed to fetch HID descriptor: -121`), но причина та же — гонка
при инициализации.

Дополнительно контроллер Intel LPSS (`0000:00:15.1`) по умолчанию уходит
в runtime-suspend. После этого FTSC1000 иногда не просыпается до
следующего переподключения, поэтому обходной путь держит шину включённой.

### Почему «отваливается» после перезагрузки

Первая версия патча перезагружала модуль `i2c_hid_acpi` через 2–4 секунды
после старта и считала успехом появление input-узла. При загрузке устройство
ещё не готово: probe проходит с ошибками I2C, узел создаётся, проверка
проходит — а касания не работают до ручного `modprobe -r/modprobe`.
Отсюда «то работает, то нет» после ребута.

Теперь успех проверяется по отсутствию I2C-ошибок в `dmesg` за время
попытки, а не только по наличию узла; попытки повторяются с растущей
задержкой.

### Запуск

```bash
chmod +x fix-ftsc1000-touchscreen.sh
./fix-ftsc1000-touchscreen.sh
```

Скрипт попросит sudo, поставит сервис и сразу его запустит. Сервис
переподключает только тачскрин (тачпад не трогает) и удерживает шину I2C
включённой. Инициализация может занять до минуты — скрипт дождётся результата.

По умолчанию ставится и хук сна; отключить: `--no-suspend`.

Проверка после перезагрузки:

```bash
./fix-ftsc1000-touchscreen.sh --check
journalctl -b -t ftsc1000-touch
```

Ожидаемо: `touchscreen initialized (attempt 1)` в журнале и растущий счётчик
прерываний при касаниях.

### Ручной вариант

Без установщика:

```bash
sudo install -m755 files/ftsc1000/ftsc1000-touch-init.sh /usr/local/bin/ftsc1000-touch-init.sh
sudo install -m644 files/ftsc1000/ftsc1000-touch.service /etc/systemd/system/ftsc1000-touch.service
sudo systemctl daemon-reload
sudo systemctl enable --now ftsc1000-touch.service
```

Разово, без автозапуска (до следующей перезагрузки):

```bash
sudo bash files/ftsc1000/ftsc1000-touch-init.sh
```

Скрипт сам переподключит тачскрин и проверит, что probe прошёл без ошибок.
Автозапуск нужен, чтобы повторять это на каждой загрузке.

Старый «грубый» вариант (перезагрузка общего модуля, на пару секунд
отключает и тачпад) тоже работает:

```bash
sudo modprobe -r i2c_hid_acpi && sleep 2 && sudo modprobe i2c_hid_acpi
```

### Что делает

1. Ставит `/usr/local/bin/ftsc1000-touch-init.sh`: переподключает только
   `i2c-FTSC1000:00`, удерживает `0000:00:15.1` и `i2c_designware.1`
   включёнными, проверяет `dmesg` на I2C-ошибки, повторяет с задержкой
   2 → 4 → 8 → 16 → 30 с (до 5 попыток).
2. Ставит `/etc/systemd/system/ftsc1000-touch.service` (`Type=simple`,
   `WantedBy=multi-user.target`). Он не блокирует загрузку; если все попытки
   провалились, systemd повторит запуск через 60 с.
3. Ставит хук сна: перед сном тачскрин отцепляется, после — восстанавливается.
4. Создаёт `/etc/default/ftsc1000-touch` с настройками, если его ещё нет.
5. Проверяет результат: сервис включён, input-узел на месте, последний
   запуск успешен, шина не в runtime-suspend.

Пока идут попытки, `systemctl status` показывает `active (running)`;
после успеха сервис завершается.

### Тонкая настройка

Если инициализация всё ещё не удаётся, увеличить число попыток и задержку
в `/etc/default/ftsc1000-touch`:

```bash
sudo nano /etc/default/ftsc1000-touch
# FTSC1000_ATTEMPTS=7
# FTSC1000_BASE_DELAY=4
# FTSC1000_MAX_DELAY=45
```

Затем перезапустить сервис или перезагрузиться:

```bash
sudo systemctl restart ftsc1000-touch.service
```

### Сон

Хук сна ставится по умолчанию, чтобы не ставить — `--no-suspend`. Он кладёт
`/usr/lib/systemd/system-sleep/ftsc1000-touch`:

- `pre` — отцепляет только тачскрин, чтобы ядро не поднимало его, пока
  шина Intel LPSS ещё не устоялась;
- `post` — переподключает тачскрин и проверяет probe.

### Требования

- Huawei MateBook 14 с FocalTech FTSC1000 (проверено на CachyOS,
  ядро 7.3.0, Hyprland + Caelestia)
- `systemd`, `kmod`, `sudo`
- для `--check` root не нужен

### Откат

```bash
./fix-ftsc1000-touchscreen.sh --remove
```

Удаляет сервис, скрипт, хук сна и `/etc/default/ftsc1000-touch`. Модуль
остаётся загруженным, поэтому тачскрин продолжит работать до перезагрузки;
после неё вернётся стоковое поведение.

### Ссылки

- <https://github.com/ninetofivedev/touchscreen-fix-for-matebook14-linux>
- <https://github.com/drkhn1234/huawei-touchscreen-fix>

---

## Клипборд: Imperial-style пикер

Заменяет fuzzel-селектор `caelestia clipboard` на QML-оверлей Caelestia:
сетка 3×4, поиск, превью по `Tab`/правому клику, копирование, удаление.
Дизайн и анимации — на токенах Caelestia (M3-цвета, `Anim`, `Tokens`,
`SearchBar`, `StyledRect`), логика и раскладка — из Imperial.

### Запуск

```bash
chmod +x install-clipboard-picker.sh
./install-clipboard-picker.sh
```

Скрипт сам делает `hyprctl reload`, но **Quickshell не перезапускает**.
Чтобы применить QML, перезапустите оболочку:

```bash
qs -c caelestia kill
sleep 1
qs -c caelestia -n -d
```

Либо сразу:

```bash
./install-clipboard-picker.sh --restart-shell
```

После перезапуска:

| Действие | Клавиши |
| --- | --- |
| История буфера | `Super+V` |
| История в режиме удаления | `Super+Alt+V` |
| Поиск | просто печатать |
| Превью | `Tab` или правый клик |
| Копировать | `Enter` или левый клик |
| Удалить | `Delete` |
| Закрыть | `Esc` или клик мимо |

`caelestia clipboard` тоже открывает новый пикер. Если шелл не запущен,
обёртка откатывается на старый fuzzel. `caelestia clipboard -d` открывает
режим удаления: в нём левый клик или `Enter` удаляет выбранный элемент.

### Что делает

1. Копирует модуль в `~/.config/quickshell/caelestia/modules/clipboard`:
   - `Clipboard.qml` — окно, IPC, глобальные шорткаты;
   - `Content.qml` — сетка, поиск, превью, копирование/удаление;
   - `clip_fetcher.py` — чтение `cliphist` и кэш картинок.
2. Патчит `shell.qml`: добавляет `import "modules/clipboard"` и `Clipboard {}`.
3. Патчит активные бинды Hyprland:
   `hyprland/keybinds.lua` — `Super+V` и `Super+Alt+V` переводятся на
   `caelestia:clipboard` / `caelestia:clipboardDelete`.
4. Если есть `hypr/config/binds.lua` — синхронизирует и его.
5. Ставит обёртку `~/.local/bin/caelestia`:
   перехватывает только `clipboard`, остальные команды уходят в
   `/usr/bin/caelestia`.
6. Делает бэкап изменяемых файлов в
   `~/.local/state/caelestia-patch/backup-ГОДМЕСЯЦДЕНЬ-ЧЧММСС`.

Повторный запуск ничего не дублирует. Если файлы модуля уже есть, старая
версия тоже попадает в бэкап.

### Опции

```bash
./install-clipboard-picker.sh --help
./install-clipboard-picker.sh --no-hypr-reload
./install-clipboard-picker.sh --shell-dir ~/.config/quickshell/caelestia
./install-clipboard-picker.sh --remove
```

`--restart-shell` — перезапустить Quickshell сразу.
`--remove` — убрать модуль, импорт, `Clipboard {}`, обёртку и вернуть бинды.

### Требования

- Caelestia Shell, проверено на `caelestia-shell 2.5.0-1`
- Quickshell `0.3.2`
- Hyprland с Lua-конфигом (Caelestia)
- `cliphist`, `wl-clipboard` (`wl-copy`), `python3`
- `qs`, `hyprctl`

### Откат

```bash
./install-clipboard-picker.sh --remove
hyprctl reload
```

Затем перезапустить Quickshell. Если нужно вернуть конкретный бэкап:

```bash
cp ~/.local/state/caelestia-patch/backup-ГОДМЕСЯЦДЕНЬ-ЧЧММСС/shell.qml \
   ~/.config/quickshell/caelestia/shell.qml
cp ~/.local/state/caelestia-patch/backup-ГОДМЕСЯЦДЕНЬ-ЧЧММСС/keybinds.lua \
   ~/.config/hypr/hyprland/keybinds.lua
```

### Важно при обновлении Caelestia

Патч живёт в пользовательской копии
`~/.config/quickshell/caelestia`. Если обновление Caelestia перезаписывает
эту копию или меняет API `Caelestia.Config`/`qs.*`, модуль нужно проверить
и при необходимости обновить вместе с вендоренным QML.

---

## Камера GC2607 (Telegram/OBS)

### Проблема

В MateBook GT камера подключена не по USB, а по MIPI CSI-2 через
Intel IPU6, сенсор — GalaxyCore **GC2607** (ACPI HID `GCTI2607`).

В ядре нет драйвера этого сенсора, поэтому камеры в системе нет вообще:
IPU6 поднимает только 6 CSI2-приёмников и **48 сырых узлов**
`/dev/video0..47` с именем `ipu6` (форматы Bayer: BG12/GB12/…).
Отсюда и «дофига одинаковых камер» в OBS, и «камера не открывается»
в Telegram: приложение открывает `/dev/video0`, а кадров там нет.

Быстрая диагностика «до»:

```bash
v4l2-ctl --list-devices | head -20        # одни "ipu6"
ls /sys/bus/acpi/devices | grep GCTI      # сенсор есть
lsmod | grep -E 'gc2607|ipu6'             # драйвера gc2607 нет
media-ctl -d /dev/media0 -p | grep gc2607 # пусто — сенсор не привязан
```

### Что делает скрипт

Ставит рабочий (неофициальный) стек из
[AlexDaichendt/gc2607-camera-linux](https://github.com/AlexDaichendt/gc2607-camera-linux)
и доводит его под MateBook GT:

1. Ставит зависимости: `dkms`, `base-devel`, `gst-plugins-good`,
   AUR-пакеты `intel-ipu6-camera-bin`, `icamerasrc-git`, `v4l2-relayd`.
2. Убирает конфликтующий стоковый `intel-ipu6-camera-hal-git`
   (его заменяет патченный HAL).
3. Собирает 4 пакета из git-репозитория:
   - `gc2607-dkms` — драйвер сенсора, привязывается к `i2c-GCTI2607:00`;
   - `gc2607-ipu-bridge-dkms` — патченный `ipu-bridge` с записью GC2607;
   - `gc2607-ipu6-camera-hal` — Intel HAL + тюнинг (AIQB/graph XML) под GC2607;
   - `gc2607-virtual-camera` — `v4l2-relayd` → `/dev/video60`
     «GC2607 Virtual Camera».
4. Добавляет `gc2607-uf-4` в `/etc/camera/ipu6epmtl/libcamhal_profile.xml`:
   в оригинальном проекте прописан только CSI-порт 0 (их тестовый MateBook Pro),
   а у MateBook GT сенсор висит на **порту 4**, и без этой строки HAL камеру
   не находит (`icamerasrc` показывает только внешние `ar0234_usb_*`).
5. Ставит ориентацию `horizontal-flip` (у MateBook GT картинка зеркальная;
   в оригинальном конфиге стоит `rotate-180` — это для другого ноутбука,
   с ним изображение вверх ногами).
6. Перезагружает модули и `v4l2-relayd` без ребута; если Telegram держит
   `/dev/video0` и модули не выгружаются — скажет перезагрузиться.
7. Проверяет результат: `/dev/ipu-psys0`, `/dev/video60`, снимает тестовый
   кадр (файлы сразу удаляются).

### Запуск

```bash
chmod +x fix-gc2607-camera.sh
./fix-gc2607-camera.sh
```

Нужен `sudo`, AUR-хелпер (`paru`/`yay`), интернет и ~10 минут на сборку HAL.
После установки перезапусти Telegram и выбери в настройках камеру
**«GC2607 Virtual Camera»**.

Если скрипт попросил перезагрузку (модули заняты приложением):

```bash
sudo reboot
./fix-gc2607-camera.sh --check
```

### Опции

```bash
./fix-gc2607-camera.sh --check            # только проверить, ничего не менять
./fix-gc2607-camera.sh --flip none        # ориентация без поворота
./fix-gc2607-camera.sh --flip rotate-180  # развернуть на 180°
./fix-gc2607-camera.sh --port 0           # другой CSI-порт сенсора
./fix-gc2607-camera.sh --rebuild          # пересобрать пакеты заново
./fix-gc2607-camera.sh --yes              # без вопросов (автоматизация)
./fix-gc2607-camera.sh --restart-telegram # применить и перезапустить Telegram
./fix-gc2607-camera.sh --remove           # удалить стек
```

Порог CSI-порта определяется автоматически из `media-ctl`, если сенсор уже
привязан; иначе берётся `--port` или значение по умолчанию `4`.

Допустимые значения `--flip`: `none`, `horizontal-flip`, `vertical-flip`,
`rotate-180`, `clockwise`, `counterclockwise`, диагональные варианты.
Меняется без пересборки: правится строка `videoflip` в
`/etc/v4l2-relayd.d/gc2607.conf` и перезапускается
`v4l2-relayd@gc2607.service`.

### Проверка

```bash
./fix-gc2607-camera.sh --check

v4l2-ctl --list-devices | grep -A1 GC2607
systemctl status v4l2-relayd@gc2607.service
journalctl -k -b --no-pager | grep -iE 'gc2607|ipu6|isys|psys'
```

Ожидаемо:

```text
gc2607 i2c-GCTI2607:00: GC2607 probed (SGRBG10 1920x1080@30fps)
intel-ipu6 0000:00:05.0: Found supported sensor GCTI2607:00
intel-ipu6 0000:00:05.0: Connected 1 cameras
```

### Нюансы

- Стек неофициальный: собирается из git, DKMS-модули пересобираются
  при обновлении ядра автоматически (pacman-хук `dkms`).
- Обновление `gc2607-ipu6-camera-hal-git` может положить рядом
  `libcamhal_profile.xml.pacnew` — после обновления прогони `--check`,
  и если камера пропала, запусти скрипт снова (он вернёт строку с портом).
- 48 узлов `ipu6` никуда не денутся — это сырые каналы IPU6. В OBS их
  по-прежнему видно в списке V4L2-устройств, выбирать нужно
  «GC2607 Virtual Camera» (или источник Camera (PipeWire): пакет добавляет
  правило WirePlumber, скрывающее `ipu6` от PipeWire-приложений).
- Сенсор включается только когда приложение открывает `/dev/video60`
  (relayd держит его выключенным в простое), поэтому индикатор камеры
  не горит постоянно.
- Если камера не нужна — `--remove` вернёт стоковый HAL; модули исчезнут
  после перезагрузки.

### Требования

- CachyOS/Arch, ядро с in-tree `intel_ipu6` (проверено на
  `7.3.0-4-cachyos`), заголовки `linux-cachyos-headers`
- `dkms`, `base-devel`, `paru` или `yay`, интернет
- Huawei MateBook GT (ENZH-XX) с сенсором `GCTI2607`, камера включена в BIOS

### Откат

```bash
./fix-gc2607-camera.sh --remove
sudo reboot
```


---

## Селектор обоев с поиском и анимациями

Переносит старый Imperial-style селектор обоев в Caelestia:

- горизонтальная карусель локальных обоев;
- фильтры по доминирующему цвету;
- поиск картинок в DuckDuckGo прямо из селектора;
- текущие обои как затемнённый фон панели (без монотонной заливки);
- случайная анимация смены обоев внутри селектора
  (fade / slide / zoom);
- открытие сразу на текущих обоях, закрытие по `Esc` или `×`.

### Запуск

```bash
chmod +x install-wallpaper-picker.sh

# установить и перезапустить шелл
./install-wallpaper-picker.sh --restart-shell

# или установить без перезапуска:
./install-wallpaper-picker.sh
```

После установки:

- `Super + Shift + W` — открыть/закрыть селектор;
- либо IPC:

```bash
caelestia shell wallpaperPicker toggle
```

Если `Super + Shift + W` уже занят, укажите другой бинд:

```bash
./install-wallpaper-picker.sh --keybind "SUPER + ALT + W"
hyprctl reload
```

### Папка с обоями

По умолчанию используется `~/Pictures/Wallpapers`. Если обои лежат в другом
месте:

```bash
./install-wallpaper-picker.sh --wallpaper-dir ~/Изображения/Wallpapers
```

Скрипт прописывает путь в `~/.config/caelestia/shell.json`:

```json
"paths": {
    "wallpaperDir": "~/Pictures/Wallpapers"
}
```

Миниатюры складываются в
`~/.cache/quickshell/wallpaper_picker/thumbs` и создаются автоматически.
Если добавили новые обои при открытом селекторе — переоткройте его.

### Что делает скрипт

1. Копирует модуль в
   `~/.config/quickshell/caelestia/modules/wallpaper/`.
2. Добавляет в `shell.qml`:

   ```qml
   import "modules/wallpaper"
   // ...
   WallpaperPicker {}
   ```

3. Прописывает `paths.wallpaperDir` в `~/.config/caelestia/shell.json`
   (существующие настройки не затирает).
4. Добавляет бинд в `~/.config/caelestia/hypr-user.lua` между маркерами
   `caelestia-wallpaper-picker`.
5. Создаёт миниатюры и делает `hyprctl reload`.
6. По флагу `--restart-shell` перезапускает Quickshell.
   Без флага QML применится после ручного перезапуска:

   ```bash
   qs -c caelestia kill; sleep 1; qs -c caelestia -n -d
   ```

Повторный запуск ничего не дублирует. Бэкапы:

```text
~/.local/state/caelestia-patch/backup-ГОДМЕСЯЦДЕНЬ-ЧЧММСС/
```

### Требования

- Caelestia Shell (проверено на `caelestia-shell 2.5.0-1`, CachyOS)
- `python3`, `curl`, `file`, `awk`
- ImageMagick (`magick` или `convert`)
- `caelestia` CLI и `qs` (Quickshell)
- сеть — только для онлайн-поиска

Для CachyOS/Arch:

```bash
sudo pacman -S python curl file imagemagick
```

### Удаление

```bash
./install-wallpaper-picker.sh --remove
```

Удаляется модуль, импорт/инстанс из `shell.qml`, бинд и (если он был
добавлен этим скриптом) `paths.wallpaperDir`. Затем можно перезапустить шелл.

### Ограничения

- Поддерживаются изображения; видео-обои не переносились.
- Обои глобальные — отдельные обои для каждого монитора не поддерживаются.
- DuckDuckGo может ограничивать частые поисковые запросы.
- После обновления Caelestia локальный `shell.qml` может измениться —
  просто запустите скрипт повторно.

---

## VPN kvn-tui: DNS без пароля + хоткей

### Проблема

`kvn-tui` при подключении меняет DNS через systemd-resolved, а polkit требует
на это пароль — при каждом подключении всплывает диалог. Отдельно всплывает
**«Authentication is required to flush DNS caches»**: `kvn setup --polkit`
создаёт правило только на четыре действия (`set-dns-servers`, `set-domains`,
`set-default-route`, `revert`), а `flush-caches` в него не входит.

### Запуск

```bash
chmod +x install-kvn-vpn.sh
./install-kvn-vpn.sh
```

С killswitch (блокировка трафика вне VPN при обрыве туннеля):

```bash
./install-kvn-vpn.sh --with-killswitch
```

Если скрипт пишет, что группы `kvn-tui` нет в текущей сессии — перелогинься
или перезагрузись (группа применяется только к новой сессии).

### Что делает

1. `sudo kvn setup --polkit` — создаёт группу `kvn-tui`, добавляет в неё
   пользователя и ставит правило `49-kvn-tui.rules` (DNS без пароля).
2. Ставит `/etc/polkit-1/rules.d/50-kvn-flush-caches.rules` — разрешает
   `org.freedesktop.resolve1.flush-caches` членам группы `kvn-tui`,
   перезапускает polkit. Правило самого kvn не перезаписывается.
3. Включает автозапуск демона: `systemctl --user enable --now kvn-tui.service`.
4. Ставит `~/.local/bin/kvn-toggle` — переключает VPN и показывает
   уведомление со статусом (`notify-send`).
5. Добавляет в `~/.config/caelestia/hypr-user.lua` биндинг между маркерами
   `kvn-vpn-toggle`, проверяет синтаксис Lua и делает `hyprctl reload`.

Повторный запуск ничего не дублирует.

### Хоткей

| Действие | Клавиши |
| --- | --- |
| Включить/выключить VPN (последний профиль) | `Super+Shift+V` |

`kvn toggle` подключает последний успешно использованный профиль.
Если нужен конкретный — в `~/.local/bin/kvn-toggle` замени
`kvn toggle` на `kvn connect <имя>`.

### Проверка

```bash
kvn doctor                                              # все пункты ✓
pkcheck -a org.freedesktop.resolve1.flush-caches -p $$   # result=yes
```

### Откат

```bash
./install-kvn-vpn.sh --remove
```

Убирает хоткей, `~/.local/bin/kvn-toggle` и правило `flush-caches`.
Интеграция самого kvn (правило `49-kvn-tui.rules`, группа `kvn-tui`,
killswitch) остаётся — её убирай средствами kvn.

### Требования

- `kvn-tui-bin` (проверено на 0.35.1), `systemd-resolved`, `polkit`
- Hyprland + Caelestia Shell; `luac`/`lua` — опционально
- `libnotify` (`notify-send`) для уведомлений

---

## sudo/PAM: убрать 10-минутную блокировку и не сломать sudo

### Проблема

После нескольких неверных паролей `pam_faillock` блокирует вход на 10 минут
(`deny=3`, `unlock_time=600`).

Очевидное решение — закомментировать строки `pam_faillock` в
`/etc/pam.d/system-auth` — **ломает систему**: в Linux-PAM 1.7.x меняются
цели переходов `[success=N]`, и `pam_authenticate` начинает возвращать
`PAM_PERM_DENIED` даже при верном пароле. При этом:

- `sudo` и `polkit` (используют `system-auth`) — не пускают вообще;
- `su`, `passwd`, `greetd` (свои стеки) — работают.

Симптом в журнале:

```
pam_unix(sudo:auth): conversation failed
pam_unix(sudo:auth): auth could not identify password for [user]
```

### Запуск

```bash
chmod +x fix-sudo-pam-faillock.sh
sudo ./fix-sudo-pam-faillock.sh
```

### Что делает

1. Достаёт эталонный `system-auth` из пакета `pambase`
   (кэш pacman, при отсутствии — `pacman -Sw pambase`) и сравнивает с текущим.
2. Если файл отличается — делает бэкап
   `system-auth.bak.ГОДМЕСЯЦДЕНЬ-ЧЧММСС` и возвращает сток.
3. В `/etc/security/faillock.conf` выставляет `deny = 0`
   (бэкап рядом): попытки продолжают записываться в tally, но блокировки нет.
   Стек PAM не трогается.
4. Проверяет, что файл совпал с пакетом и строки `pam_faillock` на месте.

### Проверка

```bash
sudo -k; sudo -v
```

Пароль должен приниматься; после 3+ ошибок блокировки нет
(`faillock --user "$USER"` показывает записи, но вход не блокируется).

### Откат

```bash
sudo ./fix-sudo-pam-faillock.sh --revert
```

Вернёт стоковый `system-auth` и штатную блокировку (3 попытки / 10 минут).

### Важно

- Не редактируй `system-auth` руками и не принимай `.pacnew` слепо:
  при обновлении `pambase` файл может отличаться.
- Проверить целостность: `pacman -Qkk pambase`.
- Если после правок PAM всё же «не пускает» — загрузиться в снапшот
  (у snapper есть pre/post на каждый `pacman`) либо GRUB → `init=/bin/bash`.

---

## VPN РУСАЛ + рабочий стол Omnissa Horizon

### Проблема

Корпоративный VPN — Cisco AnyConnect с клиентским сертификатом на USB-токене
(SafeNet eToken или JaCarta). Нужно, чтобы в туннель уходил только
корпоративный трафик `10.0.0.0/8`, а обычный интернет работал напрямую.

Рабочий стол — VDI Omnissa Horizon (бывший VMware Horizon), портал вида
`https://kraz-s-view01.hq.root.ad`.

Что мешает на Linux из коробки:

| Проблема | Решение в патче |
| --- | --- |
| нет клиента AnyConnect | `openconnect` + PKCS#11-модуль токена |
| сертификат и PIN на токене | p11-kit + `libjcPKCS11-2.so` (JaCarta) |
| OpenConnect заворачивает весь трафик | патч `vpnc-script`: только `10.0.0.0/8` |
| внутренний CA не в системном хранилище | корневой `UC RUSAL Root CA` в trust store |
| `hq.root.ad` не резолвится через VPN DNS | запись в `/etc/hosts` |
| VPN обрывается при закрытии терминала | OpenConnect в отдельной сессии |
| нужен быстрый запуск | команда `rusal` и бинд `Super+Shift+R` |

### Запуск

```bash
chmod +x install-rusal-vpn.sh
./install-rusal-vpn.sh
```

Скрипт спросит пароль sudo — для пакетов, корневого CA и `/etc/hosts`.

### Что делает

1. Ставит отсутствующие пакеты: `pcsclite ccid opensc openconnect vpnc gnutls`.
2. Собирает и ставит `jcpkcs11-2` — PKCS#11-модуль JaCarta из официального
   «Единого Клиента JaCarta» (Aladdin R.D.). Ставится именно пакетом, чтобы
   файлы в `/usr/lib` были под управлением pacman.
   Для eToken нужен `sac-core` из AUR (см. ниже), скрипт его не собирает.
3. Включает `pcscd.socket`.
4. Регистрирует модули в p11-kit (`/etc/pkcs11/modules/{jacarta,etoken}.module`).
5. Ставит корневой `UC RUSAL Root CA` в
   `/etc/ca-certificates/trust-source/anchors/` и обновляет `update-ca-trust`.
   Сертификат скачивается с `pki.rusal.com`, его SHA-256-отпечаток сверяется
   с зашитым в скрипт (`CA_FPR`).
6. Генерирует `~/.local/share/rusal-vpn/vpnc-script` из штатного:
   `set_*/reset_*_default_route` не трогают маршрут по умолчанию, а в
   `do_connect()` добавляется `ip route replace 10.0.0.0/8 dev $TUNDEV`.
   Патч пересоздаётся при каждом запуске, поэтому обновление `vpnc` не ломает
   split-tunnel.
7. Ставит команды в `~/.local/bin/` (существующие — в бэкап):
   `rusal`, `rusal-vpn`, `rusal-view`, `rusal-term`.
8. Добавляет в `/etc/hosts` запись `10.12.22.145 kraz-s-view01.hq.root.ad`.
9. Добавляет в `~/.config/caelestia/hypr-user.lua` бинд `Super+Shift+R`
   между маркерами `rusal-vpn-horizon`, проверяет синтаксис Lua и делает
   `hyprctl reload`.

Повторный запуск ничего не дублирует и не требует root, если всё уже на месте.

### Использование

```bash
rusal           # VPN + рабочий стол (пароль sudo, затем PIN токена)
rusal view      # только рабочий стол; уже открытое окно поднимет на передний план
rusal vpn       # только VPN
rusal down      # отключить VPN
rusal status    # состояние туннеля
```

`Super+Shift+R` делает то же, что `rusal`, в отдельном окне терминала.
VPN и клиент запускаются в собственной сессии (`setsid`), поэтому терминал
можно закрыть сразу — соединение не оборвётся. Если подключение не удалось,
окно терминала останется открытым с текстом ошибки.

PIN нигде не сохраняется: в фоновом режиме он передаётся OpenConnect через
stdin (в `ps` не виден), приватный ключ не покидает токен.

Логи: `~/.local/state/rusal-vpn/{openconnect,rusal,view}.log`.

### Проверка

```bash
ip -brief addr show tun0      # туннель поднят
ip route get 10.0.0.1         # должен идти через tun0
ip route | grep '^default'    # должен остаться через Wi-Fi/Ethernet
```

### Клиент Omnissa Horizon

Патч его не ставит — это проприетарный пакет ~270 МБ:

```bash
yay -S vmware-horizon-client
```

Если AUR-пакет не собирается (у Omnissa периодически отдаёт 404 на свежие
Linux-тарболлы), нужен бандл 2406 и зависимости сборки `patchelf`, `librsvg`,
`libxslt`, AUR-пакеты `vmware-keymaps` и `libudev0-shim`:

```bash
yay -S vmware-keymaps libudev0-shim patchelf
```

Источник бандла:
`https://download3.omnissa.com/software/CART25FQ2_LIN64_2406/VMware-Horizon-Client-2406-8.13.0-9995429239.x64.bundle`

Для eToken вместо JaCarta:

```bash
yay -S sac-core
```

Модуль `libeToken.so` появится в `/usr/lib/pkcs11/`, и скрипт при следующем
запуске зарегистрирует `etoken.module` сам.

### Особенности

- **Pin сервера.** `SERVER_PIN` — отпечаток публичного ключа VPN-шлюза
  (`pin-sha256:…`). Это не секрет: так OpenConnect защищается от подмены
  сервера, потому что шлюз отдаёт неполную цепочку сертификатов. При
  перевыпуске сертификата шлюза отпечаток изменится — новый OpenConnect
  покажет при подключении, его нужно вписать в `rusal-vpn`.
- **DNS.** Через VPN зона `hq.root.ad` не резолвится: DNS-серверы из VPN
  (`10.10.88.163`, `10.66.6.114`) корпоративную зону не обслуживают и
  отправляют запрос в публичный `.ad`. Поэтому имя Horizon-сервера прописано
  в `/etc/hosts`. Если админ выдаст внутренние DNS — запись можно заменить
  на нормальный резолв.
- **JaCarta видна и модулем SafeNet.** Один и тот же сертификат виден из
  обоих PKCS#11-модулей; скрипты предпочитают родной JaCarta и схлопывают
  дубли по ID сертификата.
- **Smart Logon.** Если политика Horizon требует вход по сертификату,
  токен доступен в сеансе (он виден системе через pcscd), иначе — доменный
  логин и пароль.
- **Hyprland.** Обычный `hyprctl dispatch focuswindow` на Lua-конфиге
  Caelestia не работает — используется `hyprctl eval` с
  `hl.dispatch(hl.dsp.focus(...))`.

### Опции

```bash
./install-rusal-vpn.sh             # всё
./install-rusal-vpn.sh --no-packages  # только конфиги, скрипты и бинд
./install-rusal-vpn.sh --no-hypr      # без бинда Hyprland
./install-rusal-vpn.sh --remove       # удалить
```

### Откат

```bash
./install-rusal-vpn.sh --remove
```

Удаляет бинд, запись `/etc/hosts`, корневой CA, команды и `vpnc-script`.
Пакеты и модули p11-kit остаются — они не мешают. Полное удаление:

```bash
sudo pacman -Rns jcpkcs11-2 sac-core openconnect vpnc
```

### Требования

- Arch Linux / CachyOS, `pacman`
- `python3`, `curl`, `openssl`, `sudo`
- `makepkg` (base-devel) — для сборки модуля JaCarta
- USB-токен с сертификатом VPN и PIN
- Hyprland + Caelestia Shell — для бинда (иначе `--no-hypr`)
