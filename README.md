# kde_zephyr

Мой набор программ для KDE Plasma 6 (Wayland), настроенный под себя. Один скрипт проверяет
систему и ноутбук и ставит всё сразу или по выбору.

## Установка

На свежей системе сначала обнови её и поставь git; запускать — из сеанса Plasma, не из TTY:

```fish
sudo pacman -Syu git
git clone https://github.com/ludera-vi/kde_zephyr.git ~/programming/linux/kde_zephyr
cd ~/programming/linux/kde_zephyr
./install.sh
```

Скрипт сначала показывает, что за система (ОС, версия Plasma, Wayland или нет, модель ноутбука,
батарея, тачпад, NVIDIA), потом проверяет каждый компонент:

- ✔ подходит — в меню отмечен сразу;
- ! подходит с оговорками — в меню есть, но не отмечен;
- ✖ на этой системе не встанет (например, asus-helper не на ASUS) — в меню его нет.

Недостающие пакеты ставятся через `pacman` (спросит). На не-Arch системах скрипт покажет,
какие пакеты нужны, и спросит, продолжать ли.

```fish
./install.sh                     # меню: выбрать, что ставить
./install.sh --all               # всё, что подходит
./install.sh vitile edge-swipe   # только эти
./install.sh --check             # только проверка, ничего не ставит
./install.sh --list              # список компонентов
./install.sh --uninstall         # удалить (выбрать из установленных); или ./uninstall.sh
./install.sh -y --all            # без вопросов
```

Повторный запуск обновляет уже установленное. Лог — `~/.cache/kde-zephyr-install.log`.

**Папку после установки не перемещать**: vitile и edge-swipe запускаются прямо отсюда.
Если всё же переместил — запусти `./install.sh vitile edge-swipe` из нового места, они перепишут пути.

## Компоненты

| Компонент | Что это | Когда подходит | Куда ставится |
|---|---|---|---|
| [asus-helper](https://github.com/ludera-vi/asus-helper) | управление ноутбуком ASUS: режимы, GPU, подсветка, лимит заряда | только ноутбуки ASUS | отдельный репозиторий: скачивается в `components/asus-helper/src` и ставится своим установщиком |
| [vitile](components/vitile/README.md) | плитка окон для KWin в духе Hyprland | Plasma 6, Wayland | `~/.local/share/kwin`, `~/.config/systemd/user/vitile-*` |
| zephyr-search | поиск приложений, настроек и файлов по Alt+Space | Plasma 6, Wayland | `~/.local/bin`, автозапуск в `~/.config/autostart` |
| [edge-swipe](components/edge-swipe/README.md) | свайп у края тачпада: слева яркость, справа громкость | есть тачпад | служба `~/.config/systemd/user/edge-swipe.service` + правило udev в `/etc` |
| battery-watts | виджет: температуры, расход батареи в ваттах, время от батареи | Plasma 6; без батареи — только температуры | `~/.local/share/plasma/plasmoids` |
| desktop-units | виджет: переключатель рабочих столов цифрами | Plasma 6 | `~/.local/share/plasma/plasmoids` |
| minimized-dot | виджет: точка со счётчиком окон | Plasma 6 | `~/.local/share/plasma/plasmoids` |

Если рядом с `kde_zephyr` лежит рабочая копия `asus-helper` (как у меня в `~/programming/linux/`),
установщик берёт её, а не скачивает с GitHub: так не потеряются коммиты, которые ещё не запушены.
Другое место — `ASUS_HELPER_SRC=путь ./install.sh asus-helper`.

## Как добавить свой компонент

Папка `components/<имя>/` с файлом `component.sh` — установщик подхватит её сам (порядок в меню —
массив `ORDER` в `install.sh`, новые идут в конец). В `component.sh`:

```bash
NAME="Красивое имя"
DESC="одна строка для меню"
PKGS=(пакеты arch)              # поставятся перед c_install

c_check()     { ...; }          # 0 — подходит, 1 — с оговорками, 2 — не встанет; echo — причина
c_installed() { ...; }          # 0 — уже стоит
c_install()   { ...; }          # $DIR — папка компонента
c_uninstall() { ...; }
```

Доступны переменные проверки системы (`IS_ASUS`, `IS_LAPTOP`, `HAS_BATTERY`, `HAS_NVIDIA`,
`TOUCHPAD`, `PLASMA_VER`, `SESSION`, `VENDOR`, `PRODUCT`) и функции из `lib/common.sh`
(`is_plasma6`, `is_wayland`, `is_arch`, `ok`/`warn`/`fail`, `run`, `ask`, `plasmoid_install`…).
