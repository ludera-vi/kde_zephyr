#!/bin/bash
# Испытательный стенд: отдельный невидимый KWin со своей рамкой и скриптом vitile,
# на своей шине D-Bus и со своими настройками. Если рамка уронит KWin — упадёт стенд,
# а не рабочий стол. Запускать после обновлений KDE, ДО включения рамки в сеансе:
#
#     dbus-run-session -- ~/programming/linux/kde_zephyr/components/vitile/tests/nested_test.sh [папка для результатов]
#
# Проверяет: KWin загрузил рамку; окна в плитке без заголовка, на столе без плитки — с ним;
# смена стола ничего не перестраивает. Снимки — в папке результатов.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$(mktemp -d /tmp/vitile-nested-XXXX)}
mkdir -p "$OUT/config"
W=wayland-vitile-test

cat > "$OUT/config/kwinrc" <<'EOF'
[org.kde.kdecoration2]
library=org.kde.vitile

[vitile-decoration]
BorderWidth=3
Radius=14
ActiveColor=#7aa2f7
InactiveColor=#3b4261

[Script-vitile]
decoMode=native
outerGap=12
innerGap=10

[Desktops]
Number=2
Rows=1
EOF

cat > "$OUT/dump.js" <<'EOF'
workspace.windowList().forEach(function (w) { if (w.normalWindow) { var f = w.frameGeometry, c = w.clientGeometry;
  console.log("NDUMP " + w.resourceClass + " desk=" + w.desktops.map(function (d) { return d.x11DesktopNumber; })
    + " keepBelow=" + w.keepBelow + " title=" + Math.round(c.y - f.y)); } });
EOF
cat > "$OUT/spy.js" <<'EOF'
var t0 = Date.now();
options.configChanged.connect(function () { console.log("NSPY CONFIG"); });
workspace.windowList().forEach(function (w) {
  if (!w.normalWindow) return;
  w.frameGeometryChanged.connect(function () { console.log("NSPY geom " + w.resourceClass); });
  w.keepBelowChanged.connect(function () { console.log("NSPY keepBelow " + w.resourceClass); });
});
EOF

export XDG_CONFIG_HOME="$OUT/config" QT_PLUGIN_PATH="$HERE/build/decoration/plugins:/usr/lib/qt6/plugins"
kwin_wayland --virtual --width 1100 --height 640 --scale 1.3 --socket $W > "$OUT/kwin.log" 2>&1 &
KPID=$!
sleep 3

js() { local id; id=$(dbus-send --session --print-reply --dest=org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "string:$1" "string:$2" | awk '/int32/{print $2}'); dbus-send --session --print-reply --dest=org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null; }
key() { dbus-send --session --print-reply --dest=org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut "string:vitile: $1" >/dev/null; }
desk() { dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.setCurrentDesktop "int32:$1" >/dev/null; }
shot() { WAYLAND_DISPLAY=$W timeout 15 spectacle -b -n -f -o "$OUT/$1.png" >/dev/null 2>&1; }
logs() { journalctl --user --since "@$START" -o cat --no-pager | grep -E "^$1" ; }
START=$(date +%s)

dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.supportInformation | grep -E "^Plugin:|Compositing Type" > "$OUT/support.txt"
js "$HERE/script/contents/code/main.js" vitile
for i in 1 2 3; do WAYLAND_DISPLAY=$W kitty --class tile$i -e sh -c "echo плитка $i; sleep 120" >/dev/null 2>&1 & sleep 1.2; done
sleep 2; shot tiles; js "$OUT/dump.js" d1
desk 2; sleep 1; key "вкл/выкл"; sleep 1
WAYLAND_DISPLAY=$W kitty --class free1 -e sh -c "echo стол без плитки; sleep 120" >/dev/null 2>&1 &
sleep 2.5; shot free; js "$OUT/dump.js" d2
js "$OUT/spy.js" spy; sleep 0.5; SPY=$(date +%s)
desk 1; sleep 1.5; desk 2; sleep 1.5; desk 1; sleep 1.5
alive=yes; kill -0 $KPID 2>/dev/null || alive=no
kill $(jobs -p) 2>/dev/null   # терминалы стенда и сам KWin

echo "== Результаты в $OUT"
echo "KWin дожил до конца: $alive"
cat "$OUT/support.txt"
logs NDUMP | sort -u
n=$(journalctl --user --since "@$SPY" -o cat --no-pager | grep -c "^NSPY")
echo "Изменений при смене стола: $n (должно быть 0)"
grep -iE "segfault|abort|vitile" "$OUT/kwin.log" | grep -viE "portal|a11y" | head -5
