#!/bin/sh
# Сколько ноутбук реально работает от батареи с последнего отключения зарядки.
# Аргумент (необязательный): когда виджет сам видел отключение (unix-время).
# Выводит "T S A P": T — когда отключили (unix-время), S — секунд работы с тех пор
# без сна и без времени, когда был выключен, A — 1, если данных не хватило и S —
# оценка снизу, P — заряд в процентах в момент отключения. Ничего не выводит,
# если не на батарее.
#
# Момент отключения — из истории UPower (она переживает перезагрузки). Если шнур
# выдернули во сне или выключенным, UPower узнаёт об этом при пробуждении/загрузке —
# раньше и не нужно, время сна и выключения всё равно не считаем. Если заряд между
# записями вырос (заряжали выключенным или во сне) — разряд считается заново оттуда.
#
# Время работы — по монотонным часам из журнала systemd: они идут, только пока
# система не спит, и не прыгают, когда системное время переводится (при загрузке
# часы бывают сбиты на часы, пока не синхронизируются по сети).

live=${1:-0}

bat=$(upower -e 2>/dev/null | grep -m1 'battery_BAT')
[ -n "$bat" ] || bat=$(upower -e 2>/dev/null | grep -m1 'battery_')
[ -n "$bat" ] || exit 0

# Начало текущего разряда: идём с конца истории, пока состояние «разряжается» (2)
# или служебная отметка запуска upower (0). Порядок — как записано, не по времени:
# при скачках часов история бывает не отсортирована.
# Выводит "T B C P": B — 1, если разряд начался с загрузки; C — 1, если история кончилась
# раньше, чем нашлось начало (её хранят ограниченное время); P — заряд при отключении.
run=$(gdbus call --system --dest org.freedesktop.UPower --object-path "$bat" \
        --method org.freedesktop.UPower.Device.GetHistory charge 0 100000 2>/dev/null |
    grep -oE '\((uint32 )?[0-9]+, [0-9.]+, (uint32 )?[0-9]+\)' | sed 's/uint32 //g' | tr -d '(),' |
    awk -v live="$live" '{ t[NR] = $1; v[NR] = $2; s[NR] = $3 }
         END {
             if (NR == 0 || s[NR] != 2) exit
             i = NR; cur = v[NR]; cut = 1
             while (i > 1) {
                 if (s[i - 1] != 2 && s[i - 1] != 0) { cut = 0; break }
                 # Заряд вырос между записями — заряжали выключенным или во сне
                 if (s[i - 1] == 2 && v[i - 1] < cur - 1) { cut = 0; break }
                 i--
                 if (s[i] == 2) cur = v[i]
             }
             # Заряд при отключении — первая запись разряда. Если виджет сам видел
             # отключение позже — последняя запись до этого момента: записи появляются,
             # только когда процент меняется, так что это и есть заряд в тот момент.
             first = before = ""
             for (j = i; j <= NR; j++) if (s[j] == 2) {
                 if (first == "") first = v[j]
                 if (t[j] <= live) before = v[j]
             }
             print t[i], (s[i] == 0 ? 1 : 0), cut, int(live > t[i] && before != "" ? before : first)
         }')
[ -n "$run" ] || exit 0
set -- $run
T=$1 atboot=$2 cut=$3 pct=$4

# Виджет сам видел, как выдернули шнур, позже, чем думает UPower: при лимите заряда
# батарея иногда на полминуты пишет «разряжается», хотя шнур воткнут.
if [ "$live" -gt "$T" ]; then T=$live atboot=0 cut=0; fi

now=$(date +%s)

# Последняя запись загрузки: "реальное_время монотонное" в секундах
last() {
    journalctl -b "$1" -n1 -o json --no-pager -q 2>/dev/null | awk '{
        match($0, /"__REALTIME_TIMESTAMP":"[0-9]+"/);  r = substr($0, RSTART + 24, RLENGTH - 25)
        match($0, /"__MONOTONIC_TIMESTAMP":"[0-9]+"/); m = substr($0, RSTART + 25, RLENGTH - 26)
        printf "%d %d\n", r / 1e6, m / 1e6 }'
}

# Сколько секунд загрузка проспала (с момента $2, если задан) — по сообщениям ядра
slept() {
    journalctl -b "$1" ${2:+--since "@$2"} _TRANSPORT=kernel --no-pager -q -o short-unix \
               -g 'PM: (hibernation: )?(suspend|hibernation) (entry|exit)' 2>/dev/null |
        awk '$NF == "exit" { if (on) { d += $1 - from; on = 0 }; next }
             !on { on = 1; from = $1 }
             END { printf "%d\n", d }'
}

# Загрузки по порядку: "id первая_запись последняя_запись" (реальное время, секунды)
boots=$(journalctl --list-boots -o json --no-pager 2>/dev/null |
    grep -oE '"boot_id":"[0-9a-f]+","first_entry":[0-9]+,"last_entry":[0-9]+' |
    sed -E 's/.*"boot_id":"([0-9a-f]+)","first_entry":([0-9]+),"last_entry":([0-9]+)/\1 \2 \3/' |
    awk '{ printf "%s %d %d\n", $1, $2 / 1e6, $3 / 1e6 }')

if [ -z "$boots" ]; then           # журнала нет — считаем просто по часам, как оценку
    echo "$T $((now - T)) 1 $pct"
    exit 0
fi

# В какой загрузке начался разряд. С загрузки — ищем ту, что началась тогда же
# (время отметки upower и первой записи журнала сбиты одинаково, если часы были
# сбиты). Посреди работы — первая загрузка, которая закончилась позже T.
n=$(printf '%s\n' "$boots" | wc -l)
start=$(printf '%s\n' "$boots" | awk -v T="$T" -v atboot="$atboot" -v n="$n" -v now="$now" '
    { if (NR == n) $3 = now }
    atboot { d = T - $2; if (d >= -5 && d <= 600) found = NR; next }
    !found && $3 >= T { found = NR }
    END { print found + 0 }')

approx=$cut
if [ "$start" -eq 0 ]; then
    # Начало разряда старше журнала (его чистили) — считаем то, что есть, как оценку снизу
    start=1 atboot=1 approx=1
fi

total=0
i=0
for id in $(printf '%s\n' "$boots" | awk '{ print $1 }'); do
    i=$((i + 1))
    [ "$i" -lt "$start" ] && continue
    set -- $(last "$id")
    R=$1 M=$2
    [ "$i" -eq "$n" ] && { M=$((M + now - R)); R=$now; }   # текущая загрузка — до «сейчас»

    if [ "$i" -eq "$start" ] && [ "$atboot" -eq 1 ]; then
        # Настоящее время загрузки — от последней записи, часы к тому времени уже верны
        T=$((R - M - $(slept "$id")))
        add=$M
    elif [ "$i" -eq "$start" ]; then
        add=$((R - T - $(slept "$id" "$T")))
        [ "$add" -lt 0 ] && add=0
        [ "$add" -gt "$M" ] && add=$M
    else
        add=$M
    fi
    total=$((total + add))
done

echo "$T $total $approx $pct"
