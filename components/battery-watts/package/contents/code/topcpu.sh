#!/bin/sh
# Топ-3 программ по загрузке CPU за последнюю секунду: "процент имя" построчно.
# Процент — от одного ядра (как в top). Процессы с одним именем суммируются.
# Читает только /proc/*/stat, ничего не будит.

snap() {
    awk '{
        # Имя в скобках может содержать пробелы и ")", поэтому режем по последней ")"
        n = split($0, a, ")"); rest = a[n]
        i = index($0, "(")
        comm = substr($0, i + 1, length($0) - length(rest) - i - 1)
        split(rest, f, " ")              # f[1] — поле 3 (state), значит utime = f[12], stime = f[13]
        print $1, f[12] + f[13], comm
    }' /proc/[0-9]*/stat 2>/dev/null
}

a=$(snap)
sleep 1
b=$(snap)

printf '%s\n---\n%s\n' "$a" "$b" | awk -v hz="$(getconf CLK_TCK)" '
    /^---$/ { second = 1; next }
    { pid = $1; t = $2; $1 = $2 = ""; name = substr($0, 3) }
    !second { t0[pid] = t; next }
    (pid in t0) { d = t - t0[pid]; if (d > 0) sum[name] += d }
    END { for (n in sum) printf "%.0f %s\n", sum[n] * 100 / hz, n }
' | sort -rn | head -3
