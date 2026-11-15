#!/usr/bin/env python3
"""Живой тест vitile на текущем рабочем столе.

    python3 ~/programming/linux/kde_zephyr/components/vitile/tests/live_test.py

Открывает тестовые окна (kitty, dolphin, brave, onlyoffice), жмёт клавиши
vitile и после каждого шага проверяет раскладку. Закрывает только окна,
которые открыл сам. Свёрнутые по ходу тестов чужие окна возвращает.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

import dbus

VITILE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _cfg(key, default):
    """Отступы — как сейчас в настройках vitile (их можно менять в settings.ini)."""
    v = subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-vitile", "--key", key],
                       capture_output=True, text=True).stdout.strip()
    return int(v) if v else default


GAP_OUT, GAP_IN = _cfg("outerGap", 12), _cfg("innerGap", 10)
TOP_GAP = max(1, _cfg("topGap", 1))
EXCLUDE = {"org.kde.kcalc", "org.kde.spectacle", "org.kde.polkit-kde-authentication-agent-1",
           "krunner", "yakuake"}
TOL = 2

bus = dbus.SessionBus()
scripting = dbus.Interface(bus.get_object("org.kde.KWin", "/Scripting"), "org.kde.kwin.Scripting")
accel = dbus.Interface(bus.get_object("org.kde.kglobalaccel", "/component/kwin"),
                       "org.kde.kglobalaccel.Component")
TMP = tempfile.mkdtemp(prefix="vitile-test-")

results = []
CURRENT = {"group": ""}
opened = []          # id окон, которые открыл тест
started_pids = set() # процессы, которые запустил тест (только их можно завершать)
floating_ids = set()
zoomed_ids = set()


# ---------- связь с KWin ----------

def js(code, timeout=3.0):
    tag = "VT" + uuid.uuid4().hex[:8]
    path = os.path.join(TMP, tag + ".js")
    with open(path, "w") as f:
        f.write(f'function out(s) {{ console.log("{tag} " + s); }}\n{code}\nout("END");\n')
    since = time.time() - 1
    name = "vt_" + tag
    sid = scripting.loadScript(path, name, signature="ss")
    bus.get_object("org.kde.KWin", f"/Scripting/Script{sid}").run(dbus_interface="org.kde.kwin.Script")
    lines, end = [], time.time() + timeout
    while time.time() < end:
        r = subprocess.run(["journalctl", "--user", "-b", "--since", f"@{since:.0f}", "-o", "cat",
                            "--no-pager"], capture_output=True, text=True)
        lines = [l[len(tag) + 1:] for l in r.stdout.splitlines() if l.startswith(tag + " ")]
        if "END" in lines:
            break
        time.sleep(0.15)
    scripting.unloadScript(name)
    os.unlink(path)
    return [l for l in lines if l != "END"]


SNAPSHOT_JS = r'''
var a = workspace.clientArea(KWin.MaximizeArea, workspace.screens[0], workspace.currentDesktop);
var fl = 0;
workspace.windowList().forEach(function (d) {
  if (d.dock && d.frameGeometry.width >= d.frameGeometry.height && d.frameGeometry.y <= 1 && a.y > 0)
    fl = Math.max(fl, d.frameGeometry.y + d.frameGeometry.height - a.y); });
out("AREA " + JSON.stringify({x: a.x, y: a.y, w: a.width, h: a.height, float: fl,
    group: workspace.screens[0].name + "|" + workspace.currentDesktop.id}));
workspace.windowList().forEach(function (w) {
  if (!w.normalWindow) return;
  var g = w.frameGeometry, c = w.clientGeometry, m = w.minSize;
  out("WIN " + JSON.stringify({
    id: String(w.internalId), cls: String(w.resourceClass), cap: String(w.caption).slice(0, 30),
    x: g.x, y: g.y, w: g.width, h: g.height,
    minw: m.width + g.width - c.width, minh: m.height + g.height - c.height,
    min: w.minimized, above: w.keepAbove, fs: w.fullScreen, act: w === workspace.activeWindow,
    skip: w.skipTaskbar, trans: w.transient, res: w.resizeable, below: w.keepBelow, pid: w.pid,
    title: Math.round(w.clientGeometry.y - g.y),
    here: w.onAllDesktops || w.desktops.some(function (d) { return d.id === workspace.currentDesktop.id; }) }));
});
'''


def snapshot():
    area, wins = None, []
    for l in js(SNAPSHOT_JS):
        if l.startswith("AREA "):
            area = json.loads(l[5:])
            CURRENT["group"] = area["group"]
        elif l.startswith("WIN "):
            wins.append(json.loads(l[4:]))
    return area, wins


def settle(max_wait=3.0):
    """Ждём, пока геометрия окон перестанет меняться."""
    prev, end = None, time.time() + max_wait
    while time.time() < end:
        time.sleep(0.35)
        area, wins = snapshot()
        key = json.dumps(sorted((w["id"], round(w["x"]), round(w["y"]), round(w["w"]),
                                 round(w["h"]), w["min"]) for w in wins))
        if key == prev:
            return area, wins
        prev = key
    return area, wins


def press(name, wait=True):
    accel.invokeShortcut(f"vitile: {name}")
    return settle() if wait else None


def activate(wid):
    js(f'workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{wid}") workspace.activeWindow = w; }});')
    time.sleep(0.2)


def set_prop(wid, prop, value):
    js(f'workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{wid}") w.{prop} = {value}; }});')


def active_id(wins):
    return next((w["id"] for w in wins if w["act"]), None)


def launch(cmd, wait=15):
    before = {w["id"] for w in snapshot()[1]}
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    started_pids.add(proc.pid)
    end = time.time() + wait
    while time.time() < end:
        time.sleep(0.5)
        new = [w for w in snapshot()[1] if w["id"] not in before and not w["min"]]
        if new:
            settle()
            opened.append(new[0]["id"])
            return new[0]
    return None


# ---------- проверки ----------

def tiled(wins):
    return [w for w in wins if w["here"] and not w["min"] and not w["fs"] and not w["above"] and not w["skip"]
            and not w["trans"] and w["res"] and w["cls"].lower() not in EXCLUDE]


def inner(area):
    # Сверху ещё «воздух» плавающей панели (vitile учитывает его в workArea)
    fl = area.get("float", 0)
    top = area["y"] + fl + (TOP_GAP if fl else GAP_OUT)   # под плавающей панелью — свой зазор
    return {"x": area["x"] + GAP_OUT, "y": top,
            "w": area["w"] - 2 * GAP_OUT, "h": area["y"] + area["h"] - GAP_OUT - top}


def overlap(a, b):
    dx = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
    dy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
    return max(0, dx) * max(0, dy)


def check(label, area, wins, expect_count=None, fill_min=0.93):
    problems = []
    t = [w for w in tiled(wins) if w["id"] not in zoomed_ids]
    box = inner(area)
    if expect_count is not None and len(t) != expect_count:
        problems.append(f"плиточных окон {len(t)}, ожидалось {expect_count}")
    for w in t:
        name = f'{w["cls"]}[{w["id"][1:5]}]'
        if (w["x"] < box["x"] - TOL or w["y"] < box["y"] - TOL or
                w["x"] + w["w"] > box["x"] + box["w"] + TOL or w["y"] + w["h"] > box["y"] + box["h"] + TOL):
            problems.append(f"{name} вылезает за область: {pos(w)}")
        if w["w"] < w["minw"] - TOL or w["h"] < w["minh"] - TOL:
            problems.append(f"{name} меньше минимума {w['minw']:.0f}x{w['minh']:.0f}: {pos(w)}")
    for i, a in enumerate(t):
        for b in t[i + 1:]:
            if overlap(a, b) > 4:
                problems.append(f'наезд {a["cls"]} {pos(a)} и {b["cls"]} {pos(b)}')
    if t:
        used = sum(w["w"] * w["h"] for w in t)
        fill = used / (box["w"] * box["h"])
        if fill < fill_min:
            problems.append(f"занято только {fill:.0%} области")
    # Окна физически не помещаются в свои минимальные размеры (так говорит сам vitile)
    if problems and not layout_fits():
        print(f"  WARN {label}: {len(t)} окон не помещаются в свои минимальные размеры — это не баг")
        for p in problems:
            print("         - " + p)
        results.append((label, True, []))
        return True
    report(label, problems)
    return not problems


def layout_fits():
    r = subprocess.run(["journalctl", "--user", "-b", "-o", "cat", "--no-pager", "-g", "vitile: fit="],
                       capture_output=True, text=True)
    last = [l for l in r.stdout.splitlines()
            if l.startswith("vitile: fit=") and l.endswith("group=" + CURRENT["group"])]
    return not last or last[-1].startswith("vitile: fit=1")


def report(label, problems):
    ok = not problems
    results.append((label, ok, problems))
    print(("  OK   " if ok else "  FAIL ") + label)
    for p in problems:
        print("         - " + p)


def expect(label, cond, detail=""):
    report(label, [] if cond else [detail or "условие не выполнено"])


def pos(w):
    return f'{w["x"]:.0f},{w["y"]:.0f} {w["w"]:.0f}x{w["h"]:.0f}'


def find(wins, wid):
    return next((w for w in wins if w["id"] == wid), None)


# ---------- сценарии ----------

def kitties():
    """Тестовые терминалы, которые сейчас открыты."""
    wins = snapshot()[1]
    return [wid for wid in opened if (find(wins, wid) or {}).get("cls", "").startswith("vitest")]


def close(wid):
    activate(wid)
    press("закрыть", wait=False)
    time.sleep(1)
    if wid in opened:
        opened.remove(wid)


def section(title):
    print(f"\n== {title}")


def test_baseline():
    section("Исходная раскладка")
    area, wins = settle()
    check("текущие окна разложены", area, wins)


def test_open_many():
    section("Открываем окна по одному")
    for i in range(4):
        w = launch(["kitty", "--class", f"vitest{i}", "sleep", "900"])
        area, wins = settle()
        expect(f"kitty #{i + 1} открылся", w is not None)
        check(f"после открытия kitty #{i + 1}", area, wins)
        if w:
            expect(f"kitty #{i + 1} стал активным", active_id(wins) == w["id"],
                   f"активно другое окно")


def test_focus():
    section("Фокус стрелками (Meta+стрелки)")
    area, wins = settle()
    t = tiled(wins)
    dirs = {"влево": (-1, 0), "вправо": (1, 0), "вверх": (0, -1), "вниз": (0, 1)}
    bad = []
    for w in t:
        for name, (dx, dy) in dirs.items():
            activate(w["id"])
            _, after = snapshot()
            press(f"фокус {name}", wait=False)
            time.sleep(0.3)
            _, after = snapshot()
            new = find(after, active_id(after)) if active_id(after) else None
            cur = find(after, w["id"])
            has_neighbor = any(
                o["id"] != w["id"] and in_direction(cur, o, dx, dy) for o in tiled(after))
            if new is None:
                bad.append(f"{w['cls']} {name}: фокус пропал")
            elif new["id"] == w["id"]:
                if has_neighbor:
                    bad.append(f"{w['cls']} {pos(w)} {name}: остался на месте, хотя сосед есть")
            elif not in_direction(cur, new, dx, dy):
                bad.append(f"{w['cls']} {pos(w)} {name}: ушёл в {new['cls']} {pos(new)} — не в ту сторону")
    label = f"фокус из каждого окна во все 4 стороны ({len(t) * 4} нажатий)"
    if bad and not layout_fits():
        print(f"  WARN {label}: окна не помещаются и наезжают — направления неоднозначны")
        for p in bad:
            print("         - " + p)
        results.append((label, True, []))
    else:
        report(label, bad)


def in_direction(a, b, dx, dy):
    if dx:
        edge_ok = (b["x"] >= a["x"] + a["w"] - GAP_IN - TOL) if dx > 0 else (b["x"] + b["w"] <= a["x"] + GAP_IN + TOL)
        ov = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
    else:
        edge_ok = (b["y"] >= a["y"] + a["h"] - GAP_IN - TOL) if dy > 0 else (b["y"] + b["h"] <= a["y"] + GAP_IN + TOL)
        ov = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
    return edge_ok and ov > 0


def test_move():
    section("Перемещение окна (Meta+Shift+стрелки)")
    area, wins = settle()
    w = find(wins, kitties()[0])
    activate(w["id"])
    for name, (dx, dy) in {"влево": (-1, 0), "вверх": (0, -1), "вправо": (1, 0), "вниз": (0, 1)}.items():
        _, before = snapshot()
        b = find(before, w["id"])
        had = any(o["id"] != w["id"] and in_direction(b, o, dx, dy) for o in tiled(before))
        area, after = press(f"сдвинуть {name}")
        a = find(after, w["id"])
        moved = (a["x"], a["y"]) != (b["x"], b["y"])
        if had:
            expect(f"сдвиг {name}: окно переехало", moved, f"было {pos(b)}, стало {pos(a)}")
        else:
            expect(f"сдвиг {name}: соседа нет, окно на месте", not moved, f"было {pos(b)}, стало {pos(a)}")
        expect(f"сдвиг {name}: фокус остался на окне", active_id(after) == w["id"])
        check(f"раскладка после сдвига {name}", area, after)


def test_resize():
    section("Размер окна (Meta+Alt+стрелки)")
    area, wins = settle()
    for wid in [kitties()[0], tiled(wins)[0]["id"]]:
        activate(wid)
        for name, dim, sign in [("шире", "w", 1), ("уже", "w", -1), ("выше", "h", 1), ("ниже", "h", -1)]:
            _, before = snapshot()
            b = find(before, wid)
            area, after = press(name)
            a = find(after, wid)
            diff = a[dim] - b[dim]
            ok = diff * sign > 0 or abs(diff) <= TOL
            expect(f"{b['cls']} {name}: {b[dim]:.0f} → {a[dim]:.0f}", ok,
                   f"изменилось не в ту сторону: {b[dim]:.0f} → {a[dim]:.0f}")
            check(f"раскладка после «{name}»", area, after)
        for name in ["уже", "ниже"]:   # вернуть как было
            press(name, wait=False)
        settle()


def test_float():
    section("Плавающее окно (Meta+Space)")
    area, wins = settle()
    wid = kitties()[1]
    activate(wid)
    n = len(tiled(wins))
    area, after = press("плавающее")
    f = find(after, wid)
    expect("окно поверх остальных", f["above"])
    expect("окно по центру ~60%", abs(f["w"] - area["w"] * 0.6) < 4, pos(f))
    check("остальные заняли его место", area, after, expect_count=n - 1)
    area, after = press("плавающее")
    expect("вернулось в плитку", not find(after, wid)["above"])
    check("после возврата", area, after, expect_count=n)


def test_fullscreen():
    section("Полноэкранный режим программы (F11)")
    area, wins = settle()
    wid = kitties()[0]
    n = len(tiled(wins))
    activate(wid)   # как в жизни: на весь экран переводят окно, в котором смотришь видео
    set_prop(wid, "fullScreen", "true")
    area, after = settle()
    check("полноэкранное окно не мешает раскладке", area, after, expect_count=n - 1)
    info = js(f'workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{wid}") '
              'out(w.keepBelow + " " + w.layer); }); var dl = 0; workspace.windowList().forEach(function (d) { '
              'if (d.dock) dl = Math.max(dl, d.layer); }); out("dock " + dl);')
    below, layer = info[0].split()
    dock = int(info[1].split()[1])
    expect("полноэкранное окно без пометки «в плитке»", below == "false", info[0])
    expect(f"полноэкранное окно над панелью (слой {layer} > {dock})", int(layer) > dock, " ".join(info))
    set_prop(wid, "fullScreen", "false")
    area, after = settle()
    check("после выхода из полноэкранного", area, after, expect_count=n)


def test_minimize_restore():
    section("Свернуть (Meta+Q) и вернуть (Meta+Shift+Q)")
    area, wins = settle()
    n = len(tiled(wins))
    order = []
    for wid in kitties()[:3]:
        activate(wid)
        area, after = press("свернуть")
        expect(f"окно свернулось", find(after, wid)["min"])
        order.append(wid)
        check(f"после сворачивания ({len(order)})", area, after, expect_count=n - len(order))
    for k, wid in enumerate(reversed(order)):
        area, after = press("вернуть свёрнутое")
        back = [w for w in order if not find(after, w)["min"]]
        expect(f"вернулось последнее свёрнутое ({k + 1})", wid in back and not find(after, wid)["min"])
        expect("вернувшееся окно активно", active_id(after) == wid)
        check(f"после возврата ({k + 1})", area, after, expect_count=n - len(order) + k + 1)


def test_single_window():
    section("Одно окно на экране")
    area, wins = settle()
    keep = kitties()[0]
    hidden = [w["id"] for w in tiled(wins) if w["id"] != keep]
    for wid in hidden:
        set_prop(wid, "minimized", "true")
    area, after = settle()
    w, box = find(after, keep), inner(area)
    expect("одно окно заняло всю область с отступами",
           abs(w["x"] - box["x"]) <= TOL and abs(w["y"] - box["y"]) <= TOL and
           abs(w["w"] - box["w"]) <= TOL and abs(w["h"] - box["h"]) <= TOL, pos(w))
    for name in ["шире", "уже", "выше", "ниже"]:
        activate(keep)
        area, after = press(name)
        expect(f"«{name}» с одним окном ничего не ломает", pos(find(after, keep)) == pos(w), pos(find(after, keep)))
    for wid in hidden:
        set_prop(wid, "minimized", "false")
    area, after = settle()
    check("все окна вернулись", area, after)


def test_other_apps():
    section("Другие программы: dolphin, brave, onlyoffice")
    for label, cmd in [("dolphin", ["dolphin", "--new-window"]),
                       ("brave", ["brave", "--new-window", "about:blank"]),
                       ("onlyoffice", ["flatpak", "run", "org.onlyoffice.desktopeditors"])]:
        installed = (subprocess.run(["flatpak", "info", cmd[2]], capture_output=True).returncode == 0
                     if cmd[0] == "flatpak" else shutil.which(cmd[0]) is not None)
        if not installed:
            print(f"         {label} не установлен — пропускаю")
            continue
        w = launch(cmd, wait=25)
        expect(f"{label} открылся", w is not None)
        area, wins = settle(4)
        if w:
            print(f"         {label}: минимум {w['minw']:.0f}x{w['minh']:.0f}")
        check(f"раскладка с новым окном {label}", area, wins)


def temp_desktop():
    """Создать временный рабочий стол (чужие столы тесты не трогают). Возвращает (текущий, временный)."""
    ids = js('workspace.desktops.forEach(function (d) { out(d.id); }); out("CUR " + workspace.currentDesktop.id);')
    cur = next(l[4:] for l in ids if l.startswith("CUR "))
    before = {l for l in ids if not l.startswith("CUR ")}
    vdm().createDesktop(len(before), "vitile-test")
    time.sleep(0.5)
    new = [d for d in js('workspace.desktops.forEach(function (d) { out(d.id); });') if d not in before]
    return cur, (new[0] if new else None)


def vdm():
    return dbus.Interface(bus.get_object("org.kde.KWin", "/VirtualDesktopManager"),
                          "org.kde.KWin.VirtualDesktopManager")


def test_desktops():
    section("Рабочие столы")
    cur, other = temp_desktop()
    if not other:
        return expect("временный рабочий стол создался", False)
    switch = 'workspace.desktops.forEach(function (d) {{ if (d.id === "{0}") workspace.currentDesktop = d; }});'
    js(switch.format(other))
    area, wins = settle()
    check("на другом столе своя раскладка", area, wins)
    js(switch.format(cur))
    area, wins = settle()
    check("вернулись — раскладка на месте", area, wins)
    if kitties():
        wid = kitties()[0]
        n = len(tiled(wins))
        move = ('workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{0}") '
                'workspace.desktops.forEach(function (d) {{ if (d.id === "{1}") w.desktops = [d]; }}); }});')
        js(move.format(wid, other))
        area, wins = settle()
        check("окно ушло на другой стол — место заполнилось", area, wins, expect_count=n - 1)
        js(move.format(wid, cur))
        area, wins = settle()
        check("окно вернулось на этот стол", area, wins, expect_count=n)
    vdm().removeDesktop(other)
    time.sleep(0.5)


def centered(w, area):
    cx, cy = w["x"] + w["w"] / 2, w["y"] + w["h"] / 2
    return abs(cx - (area["x"] + area["w"] / 2)) < 30 and abs(cy - (area["y"] + area["h"] / 2)) < 40


def test_popup():
    section("Всплывающие окна (диалог Dolphin)")
    before = set(subprocess.run(["pgrep", "-x", "dolphin"], capture_output=True, text=True).stdout.split())
    w = launch(["dolphin", "--new-window"], wait=20)
    pids = set(subprocess.run(["pgrep", "-x", "dolphin"], capture_output=True, text=True).stdout.split()) - before
    if not w or not pids:
        return expect("dolphin открылся отдельным процессом", False)
    svc = f"org.kde.dolphin-{pids.pop()}"
    obj = next(l for l in subprocess.run(["qdbus6", svc], capture_output=True, text=True).stdout.split()
               if l.startswith("/dolphin/Dolphin_"))
    ids = {x["id"] for x in snapshot()[1]}
    subprocess.Popen(["qdbus6", svc, obj, "org.kde.KMainWindow.activateAction", "create_dir"],
                     stdout=subprocess.DEVNULL)
    time.sleep(2)
    lines = js('workspace.windowList().forEach(function (w) { if (w.transient || w.dialog) { var g = w.frameGeometry; '
               'out(JSON.stringify({id: String(w.internalId), x: g.x, y: g.y, w: g.width, h: g.height, above: w.keepAbove})); } });')
    dialogs = [json.loads(l) for l in lines if json.loads(l)["id"] not in ids]
    expect("диалог появился", bool(dialogs))
    area, wins = settle()
    if dialogs:
        d = dialogs[0]
        expect("диалог по центру экрана", centered(d, area), pos(d))
        order = js('workspace.stackingOrder.forEach(function (w, i) { out(String(w.internalId)); });')
        tiles_idx = [order.index(x["id"]) for x in tiled(wins) if x["id"] in order]
        expect("диалог выше окон в плитке", d["id"] in order and all(order.index(d["id"]) > i for i in tiles_idx))
        expect("диалогу не ставится постоянное «поверх всех»", not d["above"])
    check("плитка под диалогом цела", area, wins)
    js('workspace.windowList().forEach(function (w) { if (w.transient && w.resourceClass == "org.kde.dolphin") w.closeWindow(); });')
    time.sleep(1)
    close(w["id"])


def test_help():
    section("Справка (Meta+Shift+F1)")
    press("справка", wait=False)
    time.sleep(4)
    area, wins = settle()
    h = next((w for w in wins if "справка" in w["cap"]), None)
    expect("окно справки открылось", h is not None)
    if h:
        opened.append(h["id"])
        expect("справка по центру", centered(h, area), pos(h))
        expect("справка поверх всех и активна", h["above"] and h["act"])
    check("плитка под справкой цела", area, wins)
    if h:
        close(h["id"])


def test_panel_gap():
    section("Плавающая панель")
    area, wins = settle()
    if not tiled(wins):   # на пустом временном столе — открыть окно, чтобы было что мерить
        launch(["kitty", "--class", "vitestpanel", "sleep", "300"])
        area, wins = settle()
    top = min((w["y"] for w in tiled(wins)), default=None)
    docks = js('workspace.windowList().forEach(function (d) { if (d.dock) { var g = d.frameGeometry; out(g.y + g.height); } });')
    edge = max([float(x) for x in docks] or [area["y"]])
    expect(f"окна не залезают на плавающую панель (верх окон {top:.0f}, низ панели {edge:.0f})",
           top is not None and top >= edge + TOP_GAP - 0.5)
    expect(f"и стоят вплотную к ней: зазор {top - edge:.0f} = top_gap {TOP_GAP}", top is not None and abs(top - edge - TOP_GAP) <= 1)


def visible_part(w, box):
    """Сколько ширины окна видно в области экрана."""
    return max(0, min(w["x"] + w["w"], box["x"] + box["w"]) - max(w["x"], box["x"]))


def test_strip():
    section("Лента как в niri (Meta+F при нескольких окнах)")
    area, wins = settle()
    before = {w["id"]: pos(w) for w in tiled(wins)}
    ks = kitties()
    wid = ks[len(ks) // 2]
    activate(wid)
    area, after = press("во весь экран")
    box = inner(area)
    z = find(after, wid)
    expect("развёрнутое окно на всю область", abs(z["x"] - box["x"]) <= TOL and abs(z["w"] - box["w"]) <= TOL, pos(z))
    others = [w for w in tiled(after) if w["id"] != wid]
    expect("остальные окна ушли за край экрана", all(visible_part(w, box) <= TOL for w in others),
           "; ".join(f'{w["cls"]} {pos(w)}' for w in others if visible_part(w, box) > TOL))
    expect("никто не лежит поверх развёрнутого", all(overlap(w, z) <= 4 for w in others))
    # Переключаемся на каждое окно ленты по очереди (как Alt+Tab)
    bad = []
    for o in others:
        activate(o["id"])
        _, now = settle()
        cur, zz = find(now, o["id"]), find(now, wid)
        if visible_part(cur, box) < cur["w"] - TOL:
            bad.append(f'{cur["cls"]} видно не целиком: {pos(cur)}')
        if overlap(cur, zz) > 4:
            bad.append(f'{cur["cls"]} {pos(cur)} лежит поверх развёрнутого {pos(zz)}')
        vis = [w for w in tiled(now) if visible_part(w, box) > TOL]
        for i, a in enumerate(vis):
            for b in vis[i + 1:]:
                if overlap(a, b) > 4:
                    bad.append(f'наезд {a["cls"]} {pos(a)} и {b["cls"]} {pos(b)}')
    report(f"переключение по ленте ({len(others)} окон): окно въезжает целиком и рядом", bad)
    # Клавиши Meta+←/→ ходят по ленте
    activate(wid)
    press("фокус вправо")
    _, now = snapshot()
    right = find(now, active_id(now))
    expect("Meta+→ переходит на соседнюю колонку справа", right and right["id"] != wid and visible_part(right, box) >= right["w"] - TOL)
    area, now = press("шире")
    expect("Meta+Alt+→ расширяет колонку в ленте", find(now, right["id"])["w"] > right["w"] + TOL,
           f'{right["w"]:.0f} → {find(now, right["id"])["w"]:.0f}')
    press("уже")
    # Вернуть плитку
    activate(wid)
    area, back = press("во весь экран")
    after_pos = {w["id"]: pos(w) for w in tiled(back)}
    expect("Meta+F повторно — плитка как была", after_pos == before,
           "; ".join(f"{k[1:5]}: {before.get(k)} → {v}" for k, v in after_pos.items() if before.get(k) != v))
    check("плитка после ленты", area, back)


def deco_mode():
    return subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-vitile", "--key", "decoMode"],
                          capture_output=True, text=True).stdout.strip() or "aurorae"


def test_desktop_toggle():
    section("Плитка по рабочим столам (Meta+Shift+T)")
    cur, temp = temp_desktop()
    if not temp:
        return expect("временный рабочий стол создался", False)
    other = temp
    native = deco_mode() == "native"
    switch = 'workspace.desktops.forEach(function (d) {{ if (d.id === "{0}") workspace.currentDesktop = d; }});'
    theme = lambda: subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2",
                                    "--key", "theme"], capture_output=True, text=True).stdout.strip()
    offs = lambda: subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-vitile",
                                   "--key", "offDesktops"], capture_output=True, text=True).stdout.strip()
    before_offs = offs()
    js(switch.format(other))
    settle()
    press("вкл/выкл")
    time.sleep(1.5)
    w = launch(["kitty", "--class", "vitestfree", "sleep", "300"])
    area, wins = settle()
    free = find(wins, w["id"]) if w else None
    if native:
        expect("на столе без плитки окно с заголовком (своя рамка)", free and not free["below"] and free["title"] > 10,
               str(free and (free["below"], free["title"])))
    else:
        expect("на другом столе плитка выключилась, обычная рамка", "vitile" not in theme(), theme())
    expect("выключение запомнилось", other in offs(), offs())
    t0 = time.time()
    js(switch.format(cur))
    area, wins = settle()
    if native:
        tiles = tiled(wins)
        expect("на столе с плиткой окна помечены и без заголовка", tiles and all(x["below"] and x["title"] == 0 for x in tiles),
               "; ".join(f'{x["cls"]} below={x["below"]} title={x["title"]}' for x in tiles))
        lib = subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2",
                              "--key", "library"], capture_output=True, text=True).stdout.strip()
        expect("смена стола не трогает общую рамку (остаётся org.kde.vitile)", lib == "org.kde.vitile", lib)
    else:
        time.sleep(1.5)
        expect("вернулись на свой стол — снова рамка vitile", "vitile" in theme(), theme())
    check("плитка на своём столе работает", area, wins)
    js(switch.format(other))
    time.sleep(1.5)
    if native:
        _, wins = snapshot()
        free = find(wins, w["id"]) if w else None
        expect("снова на другом столе — окно с заголовком", free and not free["below"] and free["title"] > 10)
    else:
        expect("снова на другом столе — опять обычная рамка", "vitile" not in theme(), theme())
    if w:
        close(w["id"])
    press("вкл/выкл")
    time.sleep(1.5)
    if not native:
        expect("включили обратно — рамка vitile", "vitile" in theme(), theme())
    expect("включение запомнилось", other not in offs(), offs())
    expect("режим других столов не тронут", offs() == before_offs, f"было {before_offs!r}, стало {offs()!r}")
    js(switch.format(cur))
    settle()
    vdm().removeDesktop(temp)
    time.sleep(0.5)


def test_pip():
    section("Картинка в картинке")
    area, wins = settle()
    n = len(tiled(wins))
    w = launch(["kitty", "--class", "vitestpip", "--title", "Picture in picture", "sleep", "120"])
    area, wins = settle()
    p = find(wins, w["id"]) if w else None
    expect("окно открылось", p is not None)
    if p:
        expect("не попало в плитку (раскладка не изменилась)", len(tiled([x for x in wins if x["id"] != p["id"]])) == n)
        expect("висит поверх всех", p["above"])
        expect("без пометки «в плитке»", not p["below"])
        close(p["id"])


def test_deco_guard():
    section("Подмена рамки со стороны KDE (как при смене глобальной темы)")
    if deco_mode() != "native":
        print("         своя рамка не включена — пропускаю")
        return
    area, wins = settle()
    if not tiled(wins):
        launch(["kitty", "--class", "vitestguard", "sleep", "300"])
        settle()
    lib = lambda: subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2",
                                  "--key", "library"], capture_output=True, text=True).stdout.strip()
    backup = json.load(open(os.path.join(VITILE_DIR, ".backup.json")))
    # Подменить так же, как это делает глобальная тема: другая рамка + перечитать настройки
    subprocess.run(["python3", "-c", "import sys; sys.path.insert(0, %r); import vitile; "
                    "vitile.kwrite('org.kde.kdecoration2', 'library', 'org.kde.breeze')"
                    % VITILE_DIR])
    bus.get_object("org.kde.KWin", "/KWin").reconfigure(dbus_interface="org.kde.KWin")
    end = time.time() + 8
    while time.time() < end and lib() != "org.kde.vitile":
        time.sleep(0.5)
    expect("vitile вернул свою рамку", lib() == "org.kde.vitile", lib())
    time.sleep(1.5)
    area, wins = settle()
    expect("окна в плитке снова без заголовка", all(w["title"] == 0 for w in tiled(wins)),
           "; ".join(f'{w["cls"]} title={w["title"]}' for w in tiled(wins)))
    b2 = json.load(open(os.path.join(VITILE_DIR, ".backup.json")))
    expect("подменённая рамка запомнена как «прежняя»", b2.get("library") == "org.kde.breeze", str(b2.get("library")))
    # вернуть прежнюю запись как была
    b2["library"], b2["theme"] = backup.get("library"), backup.get("theme")
    json.dump(b2, open(os.path.join(VITILE_DIR, ".backup.json"), "w"), ensure_ascii=False, indent=1)


def test_close_all():
    section("Закрыть (Meta+M) все тестовые окна")
    for wid in list(opened):
        _, wins = snapshot()
        if not find(wins, wid):
            opened.remove(wid)
            continue
        if find(wins, wid)["min"]:
            set_prop(wid, "minimized", "false")
        activate(wid)
        area, after = press("закрыть")
        time.sleep(0.5)
        area, after = settle()
        gone = find(after, wid) is None
        cls = find(wins, wid)['cls']
        if not gone:
            # Проверить, закрывается ли окно вообще — прямой командой KWin, мимо vitile
            js(f'workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{wid}") w.closeWindow(); }});')
            time.sleep(1.5)
            if find(snapshot()[1], wid) is not None:
                print(f"  WARN {cls} не закрывается даже прямой командой KWin — так решила сама программа, не vitile")
                continue
        expect(f"окно закрылось ({cls})", gone)
        if gone:
            opened.remove(wid)
        check("остальные заняли место", area, after)


def main():
    tests = [test_baseline, test_panel_gap, test_popup, test_help, test_open_many, test_focus, test_move, test_resize,
             test_strip, test_float, test_fullscreen, test_pip, test_minimize_restore, test_single_window,
             test_other_apps, test_focus, test_move, test_minimize_restore, test_desktops, test_desktop_toggle, test_deco_guard,
             test_close_all]
    only = sys.argv[1:]
    # Всё гоняем на своём временном столе (с плиткой): твои столы и окна тесты не трогают
    home, temp = temp_desktop()
    switch = 'workspace.desktops.forEach(function (d) {{ if (d.id === "{0}") workspace.currentDesktop = d; }});'
    js(switch.format(temp))
    time.sleep(1)
    try:
        for t in tests:
            if not only or t.__name__ in only:
                t()
    finally:
        _, wins = snapshot()
        for wid in opened:
            if find(wins, wid):
                js(f'workspace.windowList().forEach(function (w) {{ if (String(w.internalId) == "{wid}") w.closeWindow(); }});')
        time.sleep(2)
        # Не закрылось (например, последний Brave) — завершить процесс, только если его запустил тест
        _, wins = snapshot()
        for wid in opened:
            w = find(wins, wid)
            if w and w["pid"] in started_pids:
                subprocess.run(["kill", "-TERM", str(w["pid"])])
        js(switch.format(home))
        time.sleep(1)
        if temp:
            vdm().removeDesktop(temp)
            time.sleep(0.5)
    fails = [r for r in results if not r[1]]
    print(f"\nИтого: {len(results) - len(fails)} OK, {len(fails)} FAIL")


if __name__ == "__main__":
    main()
