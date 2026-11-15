#!/bin/sh
# Температура и память: "temps.sh cpu" — градусы CPU; "temps.sh gpu" — у NVIDIA
# "градусы занято_МиБ всего_МиБ", или "off" (карты нет на шине — выключена через
# gpu-eco/BIOS, или нет драйвера), или "sleep" (карта в простое, RTD3);
# "temps.sh gpuapps" — кто занимает её память. Спящую карту не трогаем: любой
# запрос её разбудит.

# Состояние NVIDIA без её пробуждения: on / sleep / off
nvidia_state() {
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor")" = 0x10de ] || continue
        case $(cat "$d/class") in 0x03*) ;; *) continue ;; esac
        [ "$(cat "$d/power/runtime_status" 2>/dev/null)" = suspended ] && { echo sleep; return; }
        # Драйвер не загружен — спрашивать некого
        [ -e "$d/driver" ] && echo on || echo off
        return
    done
    echo off
}

case "$1" in
cpu)
    # Intel — «Package id 0» у coretemp, AMD — Tctl у k10temp, иначе первая зона ACPI
    for h in /sys/class/hwmon/hwmon*; do
        case $(cat "$h/name" 2>/dev/null) in coretemp|k10temp|zenpower) ;; *) continue ;; esac
        for l in "$h"/temp*_label; do
            case $(cat "$l" 2>/dev/null) in
            "Package id 0"|Tctl|Tdie)
                echo $(( $(cat "${l%_label}_input") / 1000 )); exit 0 ;;
            esac
        done
    done
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) && echo $((t / 1000))
    ;;
gpu)
    # Одним вызовом nvidia-smi: температура и память
    state=$(nvidia_state)
    [ "$state" = on ] || { echo "$state"; exit 0; }
    r=$(timeout 3 nvidia-smi --query-gpu=temperature.gpu,memory.used,memory.total \
            --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | tr ',' ' ')
    echo "${r:-?}" | awk '{ if ($1 ~ /^[0-9.]+$/) $1 = int($1 + 0.5); print }'
    ;;
gpuapps)
    # Кто занимает память NVIDIA: "МиБ имя" построчно, больше — выше. Берём таблицу
    # nvidia-smi, а не --query-compute-apps: там нет программ, что только рисуют (G).
    [ "$(nvidia_state)" = on ] || exit 0
    timeout 3 nvidia-smi 2>/dev/null |
        awk '/^\|.*[0-9]+MiB *\|$/ && $6 ~ /^(C|G|C\+G)$/ { m = $(NF - 1); sub(/MiB/, "", m); print $5, m }' |
        while read -r pid mib; do
            # Имя — по командной строке; у интерпретаторов (python, node…) ещё и скрипт
            set -- $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            [ $# -gt 0 ] || continue
            name=${1##*/}
            case $name in
            python*|node|java|ruby|perl|bun|deno)
                [ "$2" = -m ] && shift
                [ -n "$2" ] && name="$name ${2##*/}" ;;
            esac
            echo "$mib $name"
        done | sort -rn
    ;;
esac
