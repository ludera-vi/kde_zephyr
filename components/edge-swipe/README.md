# edge-swipe — краевые жесты тачпада

Свайп вверх/вниз у края тачпада:

- **левый край** — яркость экрана (через KDE DBus, показывается стандартный OSD);
- **правый край** — громкость (через `wpctl`, потолок 100%).

Вверх = больше, вниз = меньше. Второй палец отменяет жест.

Проверено на: ASUS, тачпад `ASUF1207:00 2808:0219`, CachyOS, KDE Plasma (Wayland).

## Как работает

`edge_swipe.py` читает сырые события тачпада через `python-evdev`
(`/dev/input/eventN`, мультитач-оси `ABS_MT_*`). Если касание началось в крайних
8% ширины, вертикальное смещение пальца пересчитывается в значение яркости или
громкости. Курсор в этих зонах не двигается сам (так ведёт себя тачпад), поэтому
устройство не перехватывается.

## Зависимости

- `python-evdev`
- `wpctl` (PipeWire/WirePlumber)
- `busctl` (systemd), KDE Plasma с `org.kde.Solid.PowerManagement`

## Установка

### 1. Доступ к тачпаду (один раз)

По умолчанию `/dev/input/event*` доступны только `root:input`. Даём доступ
текущему пользователю только к этому тачпаду. Имя в правиле нужно взять из
`/proc/bus/input/devices`.

Важно: файл должен называться `70-...`, а не `99-...`. Тег `uaccess`
обрабатывается в `73-seat-late.rules`, и более позднее правило не сработает.

```
echo 'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="ASUF1207:00 2808:0219 Touchpad", TAG+="uaccess"' | sudo tee /etc/udev/rules.d/70-touchpad-edge.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=input --action=change
getfacl /dev/input/event20 | grep user:     # должна быть строка user:<вы>:rw-
```

### 2. Запуск вручную

```
python3 ~/programming/linux/kde_zephyr/components/edge-swipe/edge_swipe.py
```

### 3. Автозапуск (systemd user-сервис)

Файл `~/.config/systemd/user/edge-swipe.service`:

```
[Unit]
Description=Touchpad edge swipe: brightness (left) / volume (right)
After=graphical-session.target pipewire.service
PartOf=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 ~/programming/linux/kde_zephyr/components/edge-swipe/edge_swipe.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

```
systemctl --user daemon-reload
systemctl --user enable --now edge-swipe.service
```

## Управление

- Статус: `systemctl --user status edge-swipe`
- Логи: `journalctl --user -u edge-swipe -f`
- Перезапуск после правки параметров: `systemctl --user restart edge-swipe`
- Остановить и убрать из автозапуска: `systemctl --user disable --now edge-swipe`

## Настройка

Параметры в начале `edge_swipe.py`:

| Параметр         | По умолчанию | Смысл                                              |
|------------------|--------------|----------------------------------------------------|
| `EDGE`           | `0.08`       | ширина зоны у края (доля ширины тачпада)           |
| `FULL_SWIPE`     | `0.8`        | свайп на эту долю высоты = изменение на 100%       |
| `VOL_MAX`        | `1.0`        | потолок громкости (1.0 = 100%)                     |
| `MIN_BRIGHT_PCT` | `0`          | минимум яркости в % (0 = экран гаснет полностью)   |
| `DEADZONE`       | `0.04`       | доля высоты, которую палец должен пройти, чтобы жест принялся |
| `DIR_RATIO`      | `1.5`        | жест вертикальный, если `|dy| >= DIR_RATIO * |dx|`; иначе игнорируется |

## Защита от случайных касаний

- Мёртвая зона `DEADZONE`: короткий тап или касание ладонью не меняют значения.
- Проверка направления `DIR_RATIO`: диагональные и горизонтальные движения игнорируются.
- Касание, начатое не на краю, или отменённое жестом/вторым пальцем, игнорируется до отрыва всех пальцев.
- Если этого мало, следующий шаг: задержка старта жеста ~100 мс (удерживать палец на краю
  перед свайпом) — самый надёжный, но менее отзывчивый вариант.
- Блокировку на время печати (слушать клавиатуру) не делали намеренно, чтобы не добавлять лишний слушатель.

## Если что-то не работает

- **«нет прав на N устройств»** — не применилось udev-правило, см. шаг 1
  (проверьте имя файла `70-` и ACL через `getfacl`).
- **«тачпад не найден»** — имя устройства в `/proc/bus/input/devices` не содержит
  `touchpad` или у него нет мультитач-осей.
- **Яркость не меняется** — проверьте DBus:
  `busctl --user call org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl org.kde.Solid.PowerManagement.Actions.BrightnessControl brightness`
- **Курсор двигается в зоне края** — на другом тачпаде такого поведения может
  не быть; тогда нужен `device.grab()` и эмуляция мыши через `uinput`.
- Не переносите и не удаляйте скрипт, пока включён сервис: путь прописан в unit-файле.
