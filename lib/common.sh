# Общие функции установщика kde_zephyr: оформление, вопросы, проверка системы, пакеты.
# Подключается из install.sh; компоненты пользуются этими функциями в своих component.sh.

# ---------- оформление ----------
if [ -t 1 ]; then
    B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BLUE=$'\e[34m'
else
    B=; D=; R=; GREEN=; YELLOW=; RED=; BLUE=
fi
OK="${GREEN}✔${R}"; WARN="${YELLOW}!${R}"; FAIL="${RED}✖${R}"; INFO="${BLUE}•${R}"

title()   { echo; echo "${B}${BLUE}━━ $* ━━${R}"; }
ok()      { echo "  $OK $*"; }
warn()    { echo "  $WARN $*"; }
fail()    { echo "  $FAIL $*"; }
info()    { echo "  $INFO $*"; }
explain() { echo "    ${D}$*${R}"; }

# ask "вопрос" [Y|N] — да/нет; при --yes сразу ответ по умолчанию
ask() {
    local def=${2:-Y} hint ans
    [ "$def" = Y ] && hint="[Д/н]" || hint="[д/Н]"
    if [ "${ASSUME_YES:-0}" = 1 ]; then
        [ "$def" = Y ]; return
    fi
    read -rp "  ${B}?${R} $1 $hint " ans
    ans=${ans:-$def}
    [[ "$ans" =~ ^([YyДд]|yes|да|Да)$ ]]
}

# run "описание" команда… — выполнить, вывод в лог, на экран только итог
run() {
    local desc=$1; shift
    echo "### $desc: $*" >> "$LOG"
    if "$@" >> "$LOG" 2>&1; then
        ok "$desc"
    else
        fail "$desc ${D}(подробности: $LOG)${R}"
        return 1
    fi
}

# ---------- что за система ----------
detect_system() {
    OS_ID=unknown OS_NAME="неизвестная ОС" OS_LIKE=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
        OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-$ID}}")
        OS_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
    fi
    HAS_PACMAN=0; command -v pacman >/dev/null && HAS_PACMAN=1

    # Plasma: версия из plasmashell, сеанс — из переменных окружения
    PLASMA_VER=""
    command -v plasmashell >/dev/null && PLASMA_VER=$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    PLASMA_MAJOR=${PLASMA_VER%%.*}
    IS_KDE=0; [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] && IS_KDE=1
    SESSION=${XDG_SESSION_TYPE:-unknown}

    # Железо
    DMI=/sys/class/dmi/id
    VENDOR=$(cat $DMI/sys_vendor 2>/dev/null || echo "?")
    PRODUCT=$(cat $DMI/product_name 2>/dev/null || echo "?")
    CHASSIS=$(cat $DMI/chassis_type 2>/dev/null || echo 0)
    IS_LAPTOP=0
    case $CHASSIS in 8|9|10|11|14|30|31|32) IS_LAPTOP=1 ;; esac
    HAS_BATTERY=0; ls -d /sys/class/power_supply/BAT* >/dev/null 2>&1 && HAS_BATTERY=1
    [ $HAS_BATTERY = 1 ] && IS_LAPTOP=1
    IS_ASUS=0; [[ "$VENDOR" == ASUS* ]] && IS_ASUS=1
    HAS_NVIDIA=0
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
        case $(cat "$d/class" 2>/dev/null) in 0x03*) HAS_NVIDIA=1 ;; esac
    done
    # Выключенной дискретки (gpu-eco/BIOS) на шине нет — тогда смотрим, стоит ли драйвер
    [ $HAS_NVIDIA = 0 ] && command -v nvidia-smi >/dev/null && HAS_NVIDIA=1
    TOUCHPAD=$(touchpad_name)
}

# Имя первого тачпада с мультитачем из /proc/bus/input/devices (пусто — нет)
touchpad_name() {
    awk '/^N: Name=/ { n = substr($0, 10); gsub(/^"|"$/, "", n) }
         /^B: ABS=/  { if (tolower(n) ~ /touchpad/) { print n; exit } }' /proc/bus/input/devices 2>/dev/null
}

is_arch() { [ "$HAS_PACMAN" = 1 ]; }
is_plasma6() { [ "${PLASMA_MAJOR:-0}" -ge 6 ] 2>/dev/null; }
is_wayland() { [ "$SESSION" = wayland ]; }

print_system() {
    title "Система"
    local yn
    if is_arch; then ok "ОС: $OS_NAME ${D}(pacman есть — зависимости поставятся сами)${R}"
    else warn "ОС: $OS_NAME ${D}(не Arch: зависимости придётся ставить руками)${R}"; fi
    if is_plasma6; then ok "KDE Plasma $PLASMA_VER"
    elif [ -n "$PLASMA_VER" ]; then warn "KDE Plasma $PLASMA_VER ${D}(нужна 6-я)${R}"
    else warn "KDE Plasma не найдена"; fi
    [ $IS_KDE = 1 ] || warn "Текущий сеанс — не KDE (${XDG_CURRENT_DESKTOP:-?})"
    if is_wayland; then ok "Сеанс: Wayland"; else warn "Сеанс: $SESSION ${D}(всё проверялось на Wayland)${R}"; fi
    [ $IS_LAPTOP = 1 ] && yn="ноутбук" || yn="не ноутбук"
    info "Компьютер: $VENDOR $PRODUCT ${D}($yn)${R}"
    [ $HAS_BATTERY = 1 ] && info "Батарея: есть" || info "Батарея: нет"
    [ -n "$TOUCHPAD" ] && info "Тачпад: $TOUCHPAD" || info "Тачпад: не найден"
    [ $HAS_NVIDIA = 1 ] && info "Видеокарта NVIDIA: есть"
}

# ---------- пакеты ----------
# missing_pkgs пакет… — каких пакетов нет (pacman -T понимает и «provides»)
missing_pkgs() {
    [ $# -gt 0 ] || return 0
    if is_arch; then
        pacman -T "$@" 2>/dev/null
    fi
}

# ensure_pkgs пакет… — поставить недостающие; без pacman — показать и спросить, продолжать ли
ensure_pkgs() {
    local miss
    miss=$(missing_pkgs "$@" | tr '\n' ' ')
    miss=${miss% }
    if ! is_arch; then
        warn "Нужны пакеты (имена как в Arch): $*"
        ask "Они уже стоят — продолжить?" Y
        return
    fi
    [ -z "$miss" ] && return 0
    info "Не хватает пакетов: ${B}$miss${R}"
    if ask "Поставить их (sudo pacman -S)?" Y; then
        # shellcheck disable=SC2086
        sudo pacman -S --needed --noconfirm $miss
    else
        return 1
    fi
}

# Перезапустить plasmashell один раз в конце, если какой-то компонент попросил
want_plasma_restart() { touch "$RUNTIME/restart-plasma"; }
restart_plasma() {
    systemctl --user restart plasma-plasmashell.service 2>/dev/null \
        || { kquitapp6 plasmashell 2>/dev/null || true; (setsid kstart plasmashell >/dev/null 2>&1 &); }
}

# ---------- виджеты Plasma ----------
plasmoid_installed() { kpackagetool6 -t Plasma/Applet -s "$1" >/dev/null 2>&1; }
plasmoid_install() {   # plasmoid_install id папка_package «как называется в списке виджетов»
    if plasmoid_installed "$1"; then
        run "Обновить виджет" kpackagetool6 -t Plasma/Applet -u "$2" || return 1
    else
        run "Поставить виджет" kpackagetool6 -t Plasma/Applet -i "$2" || return 1
        explain "Добавить на панель: ПКМ по панели → «Добавить виджеты…» → «$3»"
    fi
    want_plasma_restart
}
plasmoid_uninstall() {
    plasmoid_installed "$1" || { info "Виджет $1 не установлен"; return 0; }
    explain "Сначала убери его с панели, если он там стоит"
    run "Удалить виджет" kpackagetool6 -t Plasma/Applet -r "$1" && want_plasma_restart
}
