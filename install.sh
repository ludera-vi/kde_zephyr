#!/usr/bin/env bash
# kde_zephyr — мой набор программ для KDE Plasma: ставит всё сразу или по выбору.
#
#   ./install.sh                     проверить систему и выбрать, что ставить (меню)
#   ./install.sh --all               поставить всё, что подходит этой системе
#   ./install.sh vitile edge-swipe   поставить только эти компоненты
#   ./install.sh --check             только проверить систему и показать, что подходит
#   ./install.sh --list              список компонентов
#   ./install.sh --uninstall [имя…]  удалить (без имён — выбрать из установленных)
#   -y, --yes                        не задавать вопросов (ответы по умолчанию)
#   --force                          ставить и то, что системе не подходит
#
# Запускать обычным пользователем: sudo спросится сам, когда нужен.
# Папку с репозиторием после установки не перемещать: vitile и edge-swipe запускаются отсюда.

set -uo pipefail

ROOT=$(dirname "$(readlink -f "$0")")
COMP_DIR="$ROOT/components"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/kde-zephyr-install.log"
RUNTIME=$(mktemp -d)
trap 'rm -rf "$RUNTIME"' EXIT
mkdir -p "$(dirname "$LOG")"
export ROOT COMP_DIR LOG RUNTIME

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

# Порядок в меню. Новые папки в components/ с component.sh добавятся в конец сами.
ORDER=(asus-helper vitile zephyr-search edge-swipe battery-watts desktop-units minimized-dot)

all_components() {
    local seen=" " c
    for c in "${ORDER[@]}"; do
        [ -f "$COMP_DIR/$c/component.sh" ] && { echo "$c"; seen+="$c "; }
    done
    for c in "$COMP_DIR"/*/component.sh; do
        c=$(basename "$(dirname "$c")")
        [[ "$seen" == *" $c "* ]] || echo "$c"
    done
}

# В отдельной оболочке: компоненты не мешают друг другу своими переменными и функциями
in_component() {   # in_component имя функция [аргументы…]
    local id=$1; shift
    (
        DIR="$COMP_DIR/$id"
        NAME=$id DESC="" PKGS=()
        c_check()     { return 0; }
        c_installed() { return 1; }
        c_uninstall() { warn "Удаление не предусмотрено"; }
        # shellcheck disable=SC1090
        . "$DIR/component.sh"
        "$@"
    )
}

# ---------- аргументы ----------
MODE=menu ASSUME_YES=0 FORCE=0 PICKED=()
while [ $# -gt 0 ]; do
    case $1 in
        --all|-a)        MODE=all ;;
        --check|-c)      MODE=check ;;
        --list|-l)       MODE=list ;;
        --uninstall|-u)  MODE=uninstall ;;
        --yes|-y)        ASSUME_YES=1 ;;
        --force|-f)      FORCE=1 ;;
        --help|-h)       sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)              echo "Неизвестный ключ: $1 (см. --help)"; exit 1 ;;
        *)               PICKED+=("$1") ;;
    esac
    shift
done
export ASSUME_YES
[ ${#PICKED[@]} -gt 0 ] && [ "$MODE" = menu ] && MODE=picked

mapfile -t COMPONENTS < <(all_components)
for c in "${PICKED[@]}"; do
    [ -f "$COMP_DIR/$c/component.sh" ] || { echo "Нет такого компонента: $c. Есть: ${COMPONENTS[*]}"; exit 1; }
done

if [ "$MODE" = list ]; then
    for c in "${COMPONENTS[@]}"; do
        printf '  %-16s %s\n' "$c" "$(in_component "$c" eval 'echo "$DESC"')"
    done
    exit 0
fi

if [ "$(id -u)" = 0 ]; then
    echo "Запусти обычным пользователем, без sudo: всё ставится в домашнюю папку, sudo спросится сам."
    exit 1
fi

detect_system
export OS_ID OS_NAME OS_LIKE HAS_PACMAN PLASMA_VER PLASMA_MAJOR IS_KDE SESSION \
       VENDOR PRODUCT IS_LAPTOP HAS_BATTERY IS_ASUS HAS_NVIDIA TOUCHPAD
print_system

# ---------- проверка компонентов ----------
# STATUS[c]: 0 — подходит, 1 — подходит с оговорками (по умолчанию не выбран), 2 — не встанет
declare -A STATUS REASON INSTALLED DESCS NAMES
title "Компоненты"
for c in "${COMPONENTS[@]}"; do
    REASON[$c]=$(in_component "$c" c_check 2>&1 | tr '\n' ' ' | sed 's/ *$//')
    STATUS[$c]=$(in_component "$c" c_check >/dev/null 2>&1; echo $?)
    INSTALLED[$c]=$(in_component "$c" c_installed >/dev/null 2>&1 && echo 1 || echo 0)
    NAMES[$c]=$(in_component "$c" eval 'echo "$NAME"')
    DESCS[$c]=$(in_component "$c" eval 'echo "$DESC"')
    [ "${INSTALLED[$c]}" = 1 ] && inst=" ${GREEN}[установлен]${R}" || inst=""
    case ${STATUS[$c]} in
        0) ok   "${B}$c${R}$inst — ${DESCS[$c]}" ;;
        1) warn "${B}$c${R}$inst — ${DESCS[$c]}" ;;
        *) fail "${B}$c${R}$inst — ${DESCS[$c]}" ;;
    esac
    [ -n "${REASON[$c]}" ] && explain "${REASON[$c]}"
done

[ "$MODE" = check ] && exit 0

# ---------- выбор ----------
# choose "заголовок" id:ON|OFF… → выбранные id в SELECTED
choose() {
    local head=$1; shift
    local ids=() states=() i n
    for i in "$@"; do ids+=("${i%%:*}"); states+=("${i##*:}"); done
    n=${#ids[@]}
    SELECTED=()
    [ "$n" = 0 ] && return
    if [ "$ASSUME_YES" = 1 ]; then
        for i in $(seq 0 $((n - 1))); do [ "${states[$i]}" = ON ] && SELECTED+=("${ids[$i]}"); done
        return
    fi
    if command -v whiptail >/dev/null && [ -t 0 ] && [ -t 1 ]; then
        local args=() out cols lines tagw=0 descw=0 w h d
        # Окно по размеру терминала; whiptail не обрезает строки — обрезаем сами
        read -r lines cols < <(stty size 2>/dev/null || echo "24 80")
        for i in "${ids[@]}"; do [ ${#i} -gt $tagw ] && tagw=${#i}; done
        for i in "${ids[@]}"; do d=${DESCS[$i]}; [ ${#d} -gt $descw ] && descw=${#d}; done
        w=$((tagw + descw + 14))                    # рамка, отступы, «[*] », промежуток
        [ $w -lt 60 ] && w=60
        [ $w -gt $((cols - 4)) ] && w=$((cols - 4))
        descw=$((w - tagw - 14))
        h=$((n + 9)); [ $h -gt $((lines - 2)) ] && h=$((lines - 2))
        for i in $(seq 0 $((n - 1))); do
            d=${DESCS[${ids[$i]}]}
            [ ${#d} -gt $descw ] && d="${d:0:$((descw - 1))}…"
            args+=("${ids[$i]}" "$d" "${states[$i]}")
        done
        out=$(whiptail --title " kde_zephyr " --checklist "$head\n(пробел — отметить, Enter — дальше)" \
              $h $w $((h - 9 > 0 ? h - 9 : 1)) "${args[@]}" 3>&1 1>&2 2>&3) || { echo "  Отменено."; exit 0; }
        eval "SELECTED=($out)"
        return
    fi
    # Текстовое меню: номера переключают отметку
    while true; do
        echo; echo "  ${B}$head${R}"
        for i in $(seq 0 $((n - 1))); do
            [ "${states[$i]}" = ON ] && mark="[x]" || mark="[ ]"
            printf '    %2d) %s %-16s %s\n' $((i + 1)) "$mark" "${ids[$i]}" "${DESCS[${ids[$i]}]}"
        done
        read -rp "  Номера через пробел — переключить, a — все, n — ничего, Enter — дальше, q — выход: " ans
        case $ans in
            "") break ;;
            q|Q) echo "  Отменено."; exit 0 ;;
            a|A) for i in $(seq 0 $((n - 1))); do states[$i]=ON; done ;;
            n|N) for i in $(seq 0 $((n - 1))); do states[$i]=OFF; done ;;
            *) for k in $ans; do
                   [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "$n" ] || continue
                   [ "${states[$((k - 1))]}" = ON ] && states[$((k - 1))]=OFF || states[$((k - 1))]=ON
               done ;;
        esac
    done
    for i in $(seq 0 $((n - 1))); do [ "${states[$i]}" = ON ] && SELECTED+=("${ids[$i]}"); done
}

if [ "$MODE" = uninstall ]; then
    if [ ${#PICKED[@]} -gt 0 ]; then
        SELECTED=("${PICKED[@]}")
    else
        items=()
        for c in "${COMPONENTS[@]}"; do [ "${INSTALLED[$c]}" = 1 ] && items+=("$c:OFF"); done
        [ ${#items[@]} -gt 0 ] || { echo; info "Ничего из набора не установлено."; exit 0; }
        choose "Что удалить?" "${items[@]}"
    fi
    [ ${#SELECTED[@]} -gt 0 ] || { info "Ничего не выбрано."; exit 0; }
    ask "Удалить: ${SELECTED[*]}?" Y || exit 0
    for c in "${SELECTED[@]}"; do
        title "Удаление: $c"
        in_component "$c" c_uninstall || fail "$c: удаление закончилось с ошибкой"
    done
    [ -e "$RUNTIME/restart-plasma" ] && ask "Перезапустить панель Plasma, чтобы виджеты пропали из списка?" Y && restart_plasma
    exit 0
fi

case $MODE in
    all)
        SELECTED=()
        for c in "${COMPONENTS[@]}"; do
            [ "${STATUS[$c]}" = 0 ] || { [ "$FORCE" = 1 ] && [ "${STATUS[$c]}" = 1 ]; } && SELECTED+=("$c")
        done ;;
    picked)
        SELECTED=()
        for c in "${PICKED[@]}"; do
            if [ "${STATUS[$c]}" = 2 ] && [ "$FORCE" = 0 ]; then
                fail "$c не встанет на эту систему: ${REASON[$c]} ${D}(--force — всё равно ставить)${R}"
            else
                SELECTED+=("$c")
            fi
        done ;;
    menu)
        items=()
        for c in "${COMPONENTS[@]}"; do
            case ${STATUS[$c]} in
                0) items+=("$c:ON") ;;
                1) items+=("$c:OFF") ;;
                *) [ "$FORCE" = 1 ] && items+=("$c:OFF") ;;
            esac
        done
        choose "Что поставить или обновить?" "${items[@]}" ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { echo; info "Ничего не выбрано."; exit 0; }

# ---------- установка ----------
echo "=== kde_zephyr $(date) ===" >> "$LOG"
DONE=() FAILED=()
for c in "${SELECTED[@]}"; do
    title "${NAMES[$c]}"
    if in_component "$c" eval 'ensure_pkgs "${PKGS[@]}"' && in_component "$c" c_install; then
        DONE+=("$c")
    else
        fail "$c не установлен"
        FAILED+=("$c")
    fi
done

if [ -e "$RUNTIME/restart-plasma" ]; then
    echo
    if ask "Перезапустить панель Plasma, чтобы подхватились виджеты?" Y; then restart_plasma; fi
fi

title "Итог"
for c in "${DONE[@]}";   do ok "$c"; done
for c in "${FAILED[@]}"; do fail "$c ${D}(лог: $LOG)${R}"; done
[ ${#FAILED[@]} = 0 ]
