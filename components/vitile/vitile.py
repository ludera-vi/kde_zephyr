#!/usr/bin/env python3
"""vitile: установка, применение настроек и удаление.

    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py install    — поставить и включить
    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py apply      — применить settings.ini
    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py uninstall  — убрать всё и вернуть как было
    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py help       — справка (то же, что Meta+Shift+F1)
    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py build      — пересобрать свою рамку (C++)
    python3 ~/programming/linux/kde_zephyr/components/vitile/vitile.py deco on|off — рамка vitile / твоя прежняя рамка
                                             (это вызывает сам скрипт по Meta+Shift+T)

Всё ставится только в домашнюю папку:
    ~/.local/share/kwin/scripts/vitile          — скрипт
    ~/.local/share/aurorae/themes/vitile-a|b    — рамка
    ~/.local/share/kwin/effects/vitile_motion   — анимации
    ~/.config/systemd/user/vitile-deco@.service — переключатель рамки
    ~/.config/kwinrc                            — пара строк настроек
"""
import configparser
import fcntl
import json
import os
import threading
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SETTINGS = HERE / "settings.ini"
BACKUP = HERE / ".backup.json"
STATE = HERE / ".theme"
HOME = Path.home()
UNIT = HOME / ".config/systemd/user/vitile-deco@.service"
HELP_UNIT = HOME / ".config/systemd/user/vitile-help.service"
DESK_UNIT = HOME / ".config/systemd/user/vitile-desk@.service"
HELP_PAGE = HERE / "help.html"
PRETTY = "~/" + str(HERE.relative_to(HOME)) if HERE.is_relative_to(HOME) else str(HERE)
KWINRC = HOME / ".config/kwinrc"
# Своя рамка на C++ (каталог decoration/): собирается в build/, ставится в домашнюю папку,
# а KWin узнаёт о ней из QT_PLUGIN_PATH (environment.d, действует после входа в систему)
DECO_SRC = HERE / "decoration"
DECO_BUILD = HERE / "build" / "decoration"
DECO_STAMP = HERE / "build" / ".kdecoration-version"
DECO_ID = "org.kde.vitile"
DECO_CFG_GROUP = "vitile-decoration"
PLUGIN_DIR = HOME / ".local/lib/qt6/plugins"
PLUGIN_DST = PLUGIN_DIR / "org.kde.kdecoration3" / f"{DECO_ID}.so"
ENV_FILE = HOME / ".config/environment.d/vitile.conf"
CHECK_UNIT = HOME / ".config/systemd/user/vitile-check.service"
SCRIPT_DST = HOME / ".local/share/kwin/scripts/vitile"
EFFECT_ID = "vitile_motion"
EFFECT_DST = HOME / ".local/share/kwin/effects" / EFFECT_ID
EFFECT_GROUP = f"Effect-{EFFECT_ID}"
# Встроенные эффекты, которые делают то же самое (появление/закрытие) — на время выключаем
REPLACED_EFFECTS = {"scale": True, "fade": False}  # имя -> включён ли в KDE по умолчанию
THEMES = HOME / ".local/share/aurorae/themes"
THEME_SLOTS = ("vitile-a", "vitile-b")
DECO_GROUP = "org.kde.kdecoration2"
SCRIPT_GROUP = "Script-vitile"

# Клавиши, которые vitile забирает у KDE (при удалении возвращаются как были)
TAKEOVER = [
    ("kwin", "Window Quick Tile Left"), ("kwin", "Window Quick Tile Right"),
    ("kwin", "Window Quick Tile Top"), ("kwin", "Window Quick Tile Bottom"),
    ("kwin", "Window to Next Screen"), ("kwin", "Window to Previous Screen"),
    ("plasmashell", "manage activities"),
    ("kwin", "Switch Window Left"), ("kwin", "Switch Window Right"),
    ("kwin", "Switch Window Up"), ("kwin", "Switch Window Down"),
]
# Действия vitile и их клавиши по умолчанию. Свои клавиши — в settings.ini, раздел [keys].
# (ключ в settings.ini, действие в KWin «vitile: …», по умолчанию, что делает, группа в справке)
KEY_ACTIONS = [
    ("focus_left", "фокус влево", "Meta+Left", "перейти на окно слева", "Окна"),
    ("focus_right", "фокус вправо", "Meta+Right", "перейти на окно справа", "Окна"),
    ("focus_up", "фокус вверх", "Meta+Up", "перейти на окно сверху", "Окна"),
    ("focus_down", "фокус вниз", "Meta+Down", "перейти на окно снизу", "Окна"),
    ("move_left", "сдвинуть влево", "Meta+Shift+Left", "поменять окно с соседом слева", "Окна"),
    ("move_right", "сдвинуть вправо", "Meta+Shift+Right", "поменять окно с соседом справа", "Окна"),
    ("move_up", "сдвинуть вверх", "Meta+Shift+Up", "поменять окно с соседом сверху", "Окна"),
    ("move_down", "сдвинуть вниз", "Meta+Shift+Down", "поменять окно с соседом снизу", "Окна"),
    ("wider", "шире", "Meta+Alt+Right", "окно шире", "Размер"),
    ("narrower", "уже", "Meta+Alt+Left", "окно уже", "Размер"),
    ("taller", "выше", "Meta+Alt+Up", "окно выше", "Размер"),
    ("shorter", "ниже", "Meta+Alt+Down", "окно ниже", "Размер"),
    ("fullscreen", "во весь экран", "Meta+F",
     "развернуть окно; остальные уезжают в ленту за край (как в niri). Повторно — обратно в плитку", "Размер"),
    ("float", "плавающее", "Meta+Space", "открепить окно (плавает по центру поверх всех) и обратно", "Размер"),
    ("minimize", "свернуть", "Meta+Q", "свернуть окно", "Свернуть и закрыть"),
    ("restore", "вернуть свёрнутое", "Meta+Shift+Q", "вернуть последнее свёрнутое", "Свернуть и закрыть"),
    ("close", "закрыть", "Meta+M", "закрыть окно", "Свернуть и закрыть"),
    ("toggle", "вкл/выкл", "Meta+Shift+T",
     "выключить / включить плитку на этом рабочем столе (запоминается; без плитки — обычные заголовки)", "vitile"),
    ("help", "справка", "Meta+Shift+F1", "эта справка", "vitile"),
]
OUR_KEYS = [action for _, action, _, _, _ in KEY_ACTIONS]

# Сочетание «Meta+Shift+Left» -> код клавиши, как его понимает KDE (Qt)
MODS = {"meta": 0x10000000, "super": 0x10000000, "win": 0x10000000, "shift": 0x02000000,
        "ctrl": 0x04000000, "control": 0x04000000, "alt": 0x08000000}
NAMED_KEYS = {"left": 0x01000012, "up": 0x01000013, "right": 0x01000014, "down": 0x01000015,
              "space": 0x20, "return": 0x01000004, "enter": 0x01000004, "tab": 0x01000001,
              "esc": 0x01000000, "escape": 0x01000000, "backspace": 0x01000003, "delete": 0x01000007,
              "del": 0x01000007, "insert": 0x01000006, "home": 0x01000010, "end": 0x01000011,
              "pgup": 0x01000016, "pageup": 0x01000016, "pgdown": 0x01000017, "pagedown": 0x01000017,
              "print": 0x01000009, "plus": ord("+"), "minus": ord("-")}
ARROWS = {"left": "←", "right": "→", "up": "↑", "down": "↓"}


def parse_combo(text):
    """'Meta+Shift+Left' -> int. 'none' или пусто -> None (без клавиши). Ошибка -> ValueError."""
    text = text.strip()
    if text.lower() in ("", "none", "нет"):
        return None
    text = text.replace(" ", "")
    if text.endswith("++"):          # сама клавиша «+»: Meta++
        *mods, key = text[:-2].split("+") + ["+"]
    else:
        *mods, key = text.split("+")
    code = 0
    for m in mods:
        if m.lower() not in MODS:
            raise ValueError(f"непонятная клавиша-модификатор «{m}» (бывают Meta, Shift, Ctrl, Alt)")
        code |= MODS[m.lower()]
    k = key.lower()
    if k in NAMED_KEYS:
        return code | NAMED_KEYS[k]
    if k.startswith("f") and k[1:].isdigit() and 1 <= int(k[1:]) <= 35:
        return code | (0x01000030 + int(k[1:]) - 1)
    if len(key) == 1:
        return code | ord(key.upper())
    raise ValueError(f"непонятная клавиша «{key}»")


def pretty_combo(text):
    if text.strip().lower() in ("", "none", "нет"):
        return "—"
    parts = [p.strip() for p in text.split("+") if p.strip()]
    return " + ".join(ARROWS.get(p.lower(), p) for p in parts) if parts else "—"


# Клавиши из прошлых версий vitile — их убираем из системы
OLD_ACTIONS = ["развернуть", "в половину", "влево", "вправо", "больше", "меньше"]


# ---------- kwinrc и D-Bus ----------

def kwrite(group, key, value):
    """Записать ключ в kwinrc (None — убрать). Не через kwriteconfig6: он не держит
    блокировку на всё «прочитал-изменил-записал», и одновременные правки терялись."""
    edit_kwinrc(lambda lines: set_line(lines, group, key, None if value is None else str(value)))


class KwinrcLock:
    """Та же блокировка, что у KDE (QLockFile kwinrc.lck): пока держим её, KWin
    и наши же службы не пишут kwinrc одновременно с нами."""
    def __init__(self):
        self.path = KWINRC.with_name(KWINRC.name + ".lck")

    def __enter__(self):
        deadline = time.time() + 5
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                # Формат QLockFile: pid, имя программы, хост. Имя должно совпадать с настоящим
                # (Qt сверяет его с /proc/<pid>/exe и иначе считает блокировку брошенной)
                app = os.path.basename(os.readlink("/proc/self/exe"))
                # Qt считает живой только блокировку, на которой висит flock владельца
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.write(fd, f"{os.getpid()}\n{app}\n{os.uname().nodename}\n".encode())
                self.fd = fd
                return self
            except FileExistsError:
                if self._stale():
                    self.path.unlink(missing_ok=True)
                    continue
                if time.time() > deadline:
                    raise TimeoutError(f"kwinrc занят: {self.path}")
                time.sleep(0.02)

    def _stale(self):
        """Брошенная блокировка: её процесса нет или она висит дольше 10 секунд.
        Только что созданную (ещё пустую) блокировку брошенной не считаем."""
        try:
            age = time.time() - self.path.stat().st_mtime
        except OSError:
            return False   # уже отпустили — просто попробуем снова
        try:
            os.kill(int(self.path.read_text().split()[0]), 0)
        except ProcessLookupError:
            return True
        except (OSError, ValueError, IndexError):
            pass
        return age > 10

    def __exit__(self, *exc):
        self.path.unlink(missing_ok=True)
        os.close(self.fd)


def edit_kwinrc(change):
    """Прочитать kwinrc, поменять строки функцией change(lines) и записать атомарно
    (временный файл + подмена) под блокировкой — так файл никогда не виден наполовину."""
    with KwinrcLock():
        lines = KWINRC.read_text().splitlines(keepends=True) if KWINRC.exists() else []
        out = change(lines)
        tmp = KWINRC.with_name(f"{KWINRC.name}.vitile-{os.getpid()}-{threading.get_ident()}")
        tmp.write_text("".join(out))
        os.replace(tmp, KWINRC)


def kdelete(group, key):
    """Просто убрать строку. kwriteconfig6 --delete пишет key[$d], а это
    прячет и значение по умолчанию из ~/.config/kdedefaults — так нельзя."""
    edit_kwinrc(lambda lines: set_line(lines, group, key, None))


def set_line(lines, group, key, value):
    """Вернуть строки kwinrc, где у [group] ключ key = value (None — убрать ключ)."""
    out, current, done, seen = [], None, False, False
    for line in lines:
        st = line.strip()
        if st.startswith("["):
            if current == group and not done and value is not None:
                out.append(f"{key}={value}\n")
                done = True
            current = st[1:-1]
            seen = seen or current == group
        elif current == group and ("=" in st or st.endswith("[$d]")):
            k = st.split("=", 1)[0].strip()
            if k == key or k.startswith(key + "["):
                if value is not None and not done:
                    out.append(f"{key}={value}\n")
                    done = True
                continue
        out.append(line)
    if value is not None and not done:
        if not seen:
            out.append(f"\n[{group}]\n")
        out.append(f"{key}={value}\n")
    return out


def kread_raw(group, key):
    """Значение ключа или None, если ключа нет (kreadconfig6 это не различает)."""
    if not KWINRC.exists():
        return None
    current = None
    for line in KWINRC.read_text().splitlines():
        line = line.strip()
        if line.startswith("["):
            current = line[1:-1]
        elif current == group and "=" in line:
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v
    return None


def drop_group(group):
    """Убрать из kwinrc целую группу [group] со всеми ключами."""
    def change(lines):
        out, skip = [], False
        for line in lines:
            s = line.strip()
            if s.startswith("["):
                skip = s == f"[{group}]"
            if not skip:
                out.append(line)
        return out
    edit_kwinrc(change)


def effects_call(method, name):
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", "/Effects",
                        f"org.kde.kwin.Effects.{method}", f"string:{name}"], capture_output=True, text=True)
    return "true" in r.stdout


def apply_animations(s, backup):
    """Включить/выключить эффект vitile_motion и встроенные эффекты, которые он заменяет."""
    saved = backup.setdefault("effects", {})
    for e in REPLACED_EFFECTS:
        saved.setdefault(e, kread_raw("Plugins", f"{e}Enabled"))
    kwrite(EFFECT_GROUP, "Duration", s["anim_ms"])
    kwrite(EFFECT_GROUP, "PopinScale", s["anim_scale"])
    kwrite(EFFECT_GROUP, "AnimateMove", "true" if s["anim_move"] else "false")
    if s["anim"]:
        kwrite("Plugins", f"{EFFECT_ID}Enabled", "true")
        for e in REPLACED_EFFECTS:
            kwrite("Plugins", f"{e}Enabled", "false")
            effects_call("unloadEffect", e)
        effects_call("unloadEffect", EFFECT_ID)  # перечитать код эффекта, если он обновился
        effects_call("loadEffect", EFFECT_ID)
    else:
        restore_effects(backup)


def restore_effects(backup):
    kwrite("Plugins", f"{EFFECT_ID}Enabled", None)
    effects_call("unloadEffect", EFFECT_ID)
    for e, value in backup.get("effects", {}).items():
        kwrite("Plugins", f"{e}Enabled", value)
        was_on = value == "true" or (value is None and REPLACED_EFFECTS.get(e, False))
        if was_on:
            effects_call("loadEffect", e)


def kwin(path, method, *args):
    cmd = ["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", path, method]
    cmd += [f"string:{a}" for a in args]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def run_kwin_js(code):
    """Выполнить кусок JS внутри KWin одноразовым скриптом."""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(code)
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", "/Scripting",
                        "org.kde.kwin.Scripting.loadScript", f"string:{f.name}", "string:vitile_once"],
                       capture_output=True, text=True)
    sid = r.stdout.split()[-1] if "int32" in r.stdout else None
    if sid:
        kwin(f"/Scripting/Script{sid}", "org.kde.kwin.Script.run")
        time.sleep(0.5)
    kwin("/Scripting", "org.kde.kwin.Scripting.unloadScript", "vitile_once")
    os.unlink(f.name)


def reload_kwin():
    kwin("/KWin", "org.kde.KWin.reconfigure")
    time.sleep(1.5)  # KWin перечитывает kwinrc с задержкой
    kwin("/Scripting", "org.kde.kwin.Scripting.unloadScript", "vitile")
    kwin("/Scripting", "org.kde.kwin.Scripting.start")
    time.sleep(1)


def script_loaded():
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin",
                        "/Scripting", "org.kde.kwin.Scripting.isScriptLoaded",
                        "string:vitile"], capture_output=True, text=True)
    return "true" in r.stdout


# ---------- горячие клавиши (kglobalaccel) ----------

def accel():
    import dbus
    bus = dbus.SessionBus()
    return dbus, dbus.Interface(bus.get_object("org.kde.kglobalaccel", "/kglobalaccel"),
                                "org.kde.KGlobalAccel")


def set_keys(component, action, keys):
    """keys — список сочетаний (каждое — список int), пустой список снимает клавишу."""
    dbus, g = accel()
    value = dbus.Array([dbus.Struct([dbus.Array(k, signature="i")]) for k in keys],
                       signature="(ai)")
    g.setForeignShortcutKeys([component, action, "", ""], value)


def take_keys(backup):
    dbus, g = accel()
    saved = backup.setdefault("shortcuts", {})
    for component, action in TAKEOVER:
        name = f"{component}/{action}"
        if name not in saved:
            saved[name] = [[int(i) for i in seq[0]]
                           for seq in g.shortcutKeys([component, action, "", ""])]
        set_keys(component, action, [])
    for old in OLD_ACTIONS:
        g.unregister("kwin", f"vitile: {old}")


def assign_our_keys(keys):
    """Назначить клавиши из settings.ini. Занятые другими программами KDE не отбираем —
    говорим, кем заняты. Возвращает список проблем."""
    dbus, g = accel()
    problems, wanted, seen = [], {}, {}
    for cfg, action, default, _, _ in KEY_ACTIONS:
        text = keys.get(cfg, default)
        try:
            code = parse_combo(text)
        except ValueError as e:
            problems.append(f"{cfg} = {text}: {e}")
            continue
        if code is not None and code in seen:
            problems.append(f"{cfg} = {text}: это же сочетание уже у {seen[code]}")
            continue
        if code is not None:
            seen[code] = cfg
        wanted[action] = (cfg, text, code)
    for action in OUR_KEYS:   # сначала снять все свои — чтобы при перестановке не было конфликтов
        set_keys("kwin", f"vitile: {action}", [])
    for action, (cfg, text, code) in wanted.items():
        if code is None:
            continue
        owners = [f"«{o[1]}» ({o[3]})" for o in g.getGlobalShortcutsByKey(code)
                  if not str(o[0]).startswith("vitile: ")]
        if owners:
            problems.append(f"{cfg} = {text}: уже занято — {', '.join(owners)}")
            continue
        set_keys("kwin", f"vitile: {action}", [[code, 0, 0, 0]])
        got = [[int(i) for i in seq[0]] for seq in g.shortcutKeys(["kwin", f"vitile: {action}", "", ""])]
        if not got or got[0][0] != code:
            problems.append(f"{cfg} = {text}: KDE не принял сочетание")
    return problems


def give_back_keys(backup):
    dbus, g = accel()
    for name in OUR_KEYS + OLD_ACTIONS:
        g.unregister("kwin", f"vitile: {name}")
    for name, keys in backup.get("shortcuts", {}).items():
        component, action = name.split("/", 1)
        set_keys(component, action, keys)


# ---------- настройки ----------

def load_settings():
    cp = configparser.ConfigParser()
    cp.read(SETTINGS, encoding="utf-8")
    b = cp["border"]
    width = max(1, b.getint("width", 3))
    radius_native = max(0, b.getint("radius", 8))   # своя рамка скругляет само окно — без ограничений
    # Тема Aurorae (запасной путь) скругляет только внешний край рамки
    radius = min(max(width, radius_native), int(width * 3.4))
    an = cp["animation"] if cp.has_section("animation") else {}
    yes = lambda v: str(v).strip().lower() in ("yes", "true", "1", "да")
    return {
        "anim": yes(an.get("enabled", "yes")),
        "anim_ms": int(an.get("duration", 220)),
        "anim_scale": float(an.get("popin_scale", 0.85)),
        "anim_move": yes(an.get("move", "yes")),
        "outer_gap": cp["layout"].getint("outer_gap", 12),
        "top_gap": max(1, cp["layout"].getint("top_gap", 1)),
        "keys": dict(cp["keys"]) if cp.has_section("keys") else {},
        "inner_gap": cp["layout"].getint("inner_gap", 10),
        "exclude": cp["layout"].get("exclude", ""),
        "width": width,
        "radius": radius,
        "radius_native": radius_native,
        "title_height": b.getint("title_height", 30),
        "active": b.get("active_color", "#7aa2f7"),
        "inactive": b.get("inactive_color", "#3b4261"),
    }


def color(c):
    c = c.strip().lstrip("#")
    alpha = int(c[6:8], 16) / 255 if len(c) == 8 else 1
    return f'fill="#{c[:6]}" fill-opacity="{alpha:.3f}"'


# ---------- тема рамки (Aurorae SVG) ----------

def frame_svg(prefix, oy, b, R, fill):
    """9 частей рамки: углы R×R со скруглением снаружи, края толщиной b."""
    L = 4
    S = 2 * R + L
    clear = 'fill="#000000" fill-opacity="0"'
    parts = []

    def box(name, x, y, w, h, inner):
        parts.append(f'<g id="{prefix}-{name}">'
                     f'<rect x="{x}" y="{y + oy}" width="{w}" height="{h}" {clear}/>'
                     f'{inner}</g>')

    def rect(x, y, w, h):
        return f'<rect x="{x}" y="{y + oy}" width="{w}" height="{h}" {fill}/>'

    def corner(ox, oy2, fx, fy):
        # Кольцо в координатах левого верхнего угла, затем отражаем
        pts = [(0, R), (R, 0), (R, b), (b, b), (b, R)]
        m = [(ox + (R - u if fx else u), oy2 + oy + (R - v if fy else v)) for u, v in pts]
        sweep = 0 if fx != fy else 1
        d = (f"M{m[0][0]},{m[0][1]} A{R},{R} 0 0 {sweep} {m[1][0]},{m[1][1]} "
             f"L{m[2][0]},{m[2][1]} L{m[3][0]},{m[3][1]} L{m[4][0]},{m[4][1]} Z")
        return f'<path d="{d}" {fill}/>'

    box("topleft", 0, 0, R, R, corner(0, 0, False, False))
    box("topright", R + L, 0, R, R, corner(R + L, 0, True, False))
    box("bottomleft", 0, R + L, R, R, corner(0, R + L, False, True))
    box("bottomright", R + L, R + L, R, R, corner(R + L, R + L, True, True))
    box("top", R, 0, L, R, rect(R, 0, L, b))
    box("bottom", R, R + L, L, R, rect(R, S - b, L, b))
    box("left", 0, R, R, L, rect(0, R, b, L))
    box("right", R + L, R, R, L, rect(S - b, R, b, L))
    box("center", R, R, L, L, "")
    return parts, S


def write_theme(name, s):
    b, R = s["width"], s["radius"]
    active, S = frame_svg("decoration", 0, b, R, color(s["active"]))
    inactive, _ = frame_svg("decoration-inactive", S + 10, b, R, color(s["inactive"]))
    svg = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{2 * S + 10}">\n'
           + "\n".join(active + inactive) + "\n</svg>\n")

    d = THEMES / name
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    (d / "decoration.svg").write_text(svg)
    (d / "metadata.desktop").write_text(
        "[Desktop Entry]\nName=vitile\n"
        f"X-KDE-PluginInfo-Name={name}\nX-KDE-PluginInfo-Author=vi\n"
        "X-KDE-PluginInfo-Version=0.1\nX-KDE-PluginInfo-License=MIT\n")
    layout = {
        "BorderLeft": b, "BorderRight": b, "BorderBottom": b,
        "TitleHeight": b, "TitleBorderLeft": 0, "TitleBorderRight": 0,
        "ButtonWidth": 1, "ButtonHeight": 1, "ButtonSpacing": 0,
        "ButtonMarginTop": 0, "ExplicitButtonSpacer": 0,
    }
    for edge in ("Top", "Bottom", "Left", "Right"):
        layout[f"Padding{edge}"] = 0
        layout[f"TitleEdge{edge}"] = 0
        layout[f"TitleEdge{edge}Maximized"] = 0
    rc = ("[General]\nActiveTextColor=0,0,0,0\nInactiveTextColor=0,0,0,0\n"
          "UseTextShadow=false\nShadow=false\nAnimation=0\n"
          "LeftButtons=\nRightButtons=\n\n[Layout]\n"
          + "".join(f"{k}={v}\n" for k, v in layout.items()))
    (d / f"{name}rc").write_text(rc)


# ---------- справка ----------

MOUSE_HELP = [
    ("Meta + левая кнопка", "перетащить окно; бросить на другое — поменяются местами"),
    ("Meta + правая кнопка", "тянуть за край — изменить размер"),
]


def help_keys(keys):
    """Группы клавиш для справки — с теми сочетаниями, что сейчас в settings.ini."""
    groups = {}
    for cfg, _, default, what, group in KEY_ACTIONS:
        groups.setdefault(group, []).append((pretty_combo(keys.get(cfg, default)), what))
    return list(groups.items()) + [("Мышь", MOUSE_HELP)]


def write_help(s):
    from html import escape as e
    keys = "".join(
        f"<h2>{e(group)}</h2><table>" +
        "".join(f"<tr><td><kbd>{e(k)}</kbd></td><td>{e(d)}</td></tr>" for k, d in rows) +
        "</table>" for group, rows in help_keys(s["keys"]))
    settings = [
        ("outer_gap", s["outer_gap"], "отступ от краёв экрана и от панели, пиксели"),
        ("inner_gap", s["inner_gap"], "расстояние между окнами, пиксели"),
        ("top_gap", s["top_gap"], "зазор от плавающей панели сверху или сбоку; 1 — ближе всего, пока панель ещё плавает"),
        ("width", s["width"], "толщина рамки, пиксели"),
        ("radius", s["radius_native"], "скругление углов окна (своя рамка скругляет само окно)"),
        ("title_height", s["title_height"], "высота заголовка у окон вне плитки"),
        ("active_color", s["active"], "цвет рамки активного окна, #RRGGBB или #RRGGBBAA"),
        ("inactive_color", s["inactive"], "цвет рамки остальных окон"),
        ("exclude", s["exclude"], "программы, которые плитка не трогает (класс окна через запятую)"),
        ("[animation] enabled", "yes" if s["anim"] else "no", "анимации в духе Hyprland: yes / no"),
        ("duration", s["anim_ms"], "длительность анимаций, мс (меньше — быстрее)"),
        ("popin_scale", s["anim_scale"], "с какого размера «выпрыгивает» новое окно (0.85 = 85%)"),
        ("move", "yes" if s["anim_move"] else "no", "плавно двигать окна при перестройке плитки"),
    ]
    def value(k, v):
        sw = f'<span class="sw" style="background:{e(str(v))}"></span>' if k.endswith("color") else ""
        return f"{sw}<code>{e(str(v))}</code>"
    conf = "".join(f"<tr><td><code>{k}</code></td><td>{value(k, v)}</td><td>{e(d)}</td></tr>"
                   for k, v, d in settings)
    page = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>vitile — справка</title><style>
:root {{ --bg:#1a1b26; --fg:#c0caf5; --dim:#7a83a8; --line:#2c3047; --acc:{e(s['active'][:7])}; }}
body {{ margin:0; padding:28px 36px; background:var(--bg); color:var(--fg);
       font:15px/1.5 "Noto Sans",system-ui,sans-serif; }}
h1 {{ margin:0 0 4px; font-size:22px; }} h1 span {{ color:var(--acc); }}
.sub {{ color:var(--dim); margin-bottom:18px; }}
h2 {{ font-size:13px; text-transform:uppercase; letter-spacing:.08em; color:var(--dim);
      margin:22px 0 6px; }}
table {{ border-collapse:collapse; width:100%; }}
td {{ padding:7px 10px; border-bottom:1px solid var(--line); vertical-align:top; }}
td:first-child {{ white-space:nowrap; width:1%; }}
kbd, code {{ font-family:"JetBrains Mono",monospace; font-size:13px; background:#24283b;
             border:1px solid var(--line); border-radius:6px; padding:2px 7px; }}
kbd {{ border-bottom-width:2px; }}
.sw {{ display:inline-block; width:14px; height:14px; border-radius:4px; vertical-align:-2px;
       margin-right:6px; border:1px solid var(--line); }}
.steps li {{ margin:4px 0; }} .note {{ color:var(--dim); font-size:13px; }}
</style></head><body>
<h1><span>vitile</span> — справка</h1>
<div class="sub">Закрыть это окно: <kbd>Meta + M</kbd></div>
{keys}
<h2>Настройки — файл {PRETTY}/settings.ini</h2>
<table>{conf}</table>
<h2>Как поменять</h2>
<ol class="steps">
<li>Открой файл: <code>kate {PRETTY}/settings.ini</code></li>
<li>Поменяй числа или цвета и сохрани.</li>
<li>Примени: <code>python3 {PRETTY}/vitile.py apply</code></li>
</ol>
<p class="note">Например, отступы больше: <code>outer_gap = 20</code>, <code>inner_gap = 16</code>.
Рамка толще и круглее: <code>width = 4</code>, <code>radius = 12</code>.
Удалить vitile целиком и вернуть всё как было: <code>python3 {PRETTY}/vitile.py uninstall</code>.
Клавиши можно переназначить в «Параметры системы → Комбинации клавиш», поиск по «vitile».</p>
</body></html>"""
    HELP_PAGE.write_text(page, encoding="utf-8")


def show_help():
    write_help(load_settings())
    url = HELP_PAGE.as_uri()
    browser = subprocess.run(["xdg-settings", "get", "default-web-browser"],
                             capture_output=True, text=True).stdout
    if "brave" in browser and shutil.which("brave"):
        cmd = ["brave", f"--app={url}"]
    else:
        cmd = ["xdg-open", url]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ---------- команды ----------

# ---------- своя рамка (C++) ----------

def kdecoration_version():
    r = subprocess.run(["pacman", "-Q", "kdecoration"], capture_output=True, text=True)
    return r.stdout.strip()


def build():
    """Собрать рамку и поставить модуль в ~/.local/lib/qt6/plugins. True — получилось.

    Кэш сборки (CMakeCache) помнит точные пути к библиотекам KDE, например
    libkdecorations3.so.6.7.5. После обновления KDE этих файлов уже нет, поэтому
    при смене версии (или если сборка не удалась) собираем начисто."""
    version = kdecoration_version()
    stale = not DECO_STAMP.exists() or DECO_STAMP.read_text() != version
    err = None
    for clean in ((True,) if stale else (False, True)):
        if clean:
            shutil.rmtree(DECO_BUILD, ignore_errors=True)
        try:
            if not (DECO_BUILD / "CMakeCache.txt").exists():
                subprocess.run(["cmake", "-S", DECO_SRC, "-B", DECO_BUILD, "-DCMAKE_BUILD_TYPE=Release"],
                               check=True, capture_output=True, text=True)
            subprocess.run(["cmake", "--build", DECO_BUILD, "-j8"], check=True, capture_output=True, text=True)
            err = None
            break
        except subprocess.CalledProcessError as e:
            err = e
    if err:
        print("Рамка не собралась:\n" + (err.stdout or "")[-1500:] + (err.stderr or "")[-1500:])
        return False
    built = DECO_BUILD / "plugins" / "org.kde.kdecoration3" / f"{DECO_ID}.so"
    PLUGIN_DST.parent.mkdir(parents=True, exist_ok=True)
    # Подменой, а не перезаписью: KWin держит старый файл открытым, его трогать нельзя
    tmp = PLUGIN_DST.with_name(PLUGIN_DST.name + ".new")
    shutil.copy2(built, tmp)
    os.replace(tmp, PLUGIN_DST)
    DECO_STAMP.write_text(version)
    return True


def kwin_started_at():
    pid = subprocess.run(["pgrep", "-x", "kwin_wayland"], capture_output=True, text=True).stdout.split()
    if not pid:
        return 0
    ticks = int(Path(f"/proc/{pid[0]}/stat").read_text().rsplit(")", 1)[1].split()[19])
    boot = float(next(l.split()[1] for l in Path("/proc/stat").read_text().splitlines() if l.startswith("btime")))
    return boot + ticks / os.sysconf("SC_CLK_TCK")


def plugin_visible_to_kwin():
    """Видит ли запущенный KWin наш модуль: путь в окружении сеанса и KWin запущен после этого."""
    if not PLUGIN_DST.exists() or not ENV_FILE.exists():
        return False
    env = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, text=True).stdout
    if str(PLUGIN_DIR) not in env:
        return False
    return kwin_started_at() > ENV_FILE.stat().st_mtime


def native_active():
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", "/KWin",
                        "org.kde.KWin.supportInformation"], capture_output=True, text=True)
    return f"Plugin: {DECO_ID}" in r.stdout


def write_decoration_config(s):
    kwrite(DECO_CFG_GROUP, "BorderWidth", s["width"])
    kwrite(DECO_CFG_GROUP, "Radius", s["radius_native"])
    kwrite(DECO_CFG_GROUP, "ActiveColor", s["active"])
    kwrite(DECO_CFG_GROUP, "InactiveColor", s["inactive"])
    kwrite(DECO_CFG_GROUP, "TitleHeight", s["title_height"])


def deco_mode():
    return kread_raw(SCRIPT_GROUP, "decoMode") or "aurorae"


def use_aurorae(s):
    """Запасной путь: сгенерировать тему Aurorae и включить её (как до своей рамки)."""
    current = STATE.read_text().strip() if STATE.exists() else ""
    new = THEME_SLOTS[1] if current == THEME_SLOTS[0] else THEME_SLOTS[0]
    write_theme(new, s)  # новое имя каждый раз — иначе KWin держит старую тему в кэше
    STATE.write_text(new)
    kwrite(SCRIPT_GROUP, "decoMode", "aurorae")
    set_deco(True)
    for old in THEME_SLOTS:
        if old != new:
            shutil.rmtree(THEMES / old, ignore_errors=True)


def choose_deco(s):
    """Включить свою рамку, если KWin её видит и она действительно загрузилась; иначе Aurorae."""
    if plugin_visible_to_kwin():
        kwrite(SCRIPT_GROUP, "decoMode", "native")
        adopt_foreign_deco()
        set_deco(True)
        kwin("/KWin", "org.kde.KWin.reconfigure")
        time.sleep(1.5)
        if native_active():
            return "native"
        print("KWin не загрузил рамку vitile — остаюсь на запасной теме.")
    use_aurorae(s)
    return "aurorae"


def apply():
    if not BACKUP.exists():
        sys.exit(f"Сначала: python3 {PRETTY}/vitile.py install")
    s = load_settings()
    shutil.rmtree(SCRIPT_DST, ignore_errors=True)
    shutil.copytree(HERE / "script", SCRIPT_DST)
    shutil.rmtree(EFFECT_DST, ignore_errors=True)
    shutil.copytree(HERE / "effect", EFFECT_DST)
    write_decoration_config(s)
    mode = choose_deco(s)
    kwrite(SCRIPT_GROUP, "outerGap", s["outer_gap"])
    kwrite(SCRIPT_GROUP, "innerGap", s["inner_gap"])
    kwrite(SCRIPT_GROUP, "topGap", s["top_gap"])
    kwrite(SCRIPT_GROUP, "exclude", s["exclude"])
    backup = json.loads(BACKUP.read_text())
    apply_animations(s, backup)
    BACKUP.write_text(json.dumps(backup, ensure_ascii=False, indent=1))
    reload_kwin()
    problems = assign_our_keys(s["keys"])
    print("Настройки применены." + (" Рамка: своя (vitile)." if mode == "native" else
                                    " Рамка: запасная тема Aurorae."))
    if problems:
        print("Клавиши, которые не назначились (остальные работают):\n  " + "\n  ".join(problems))
    return mode


def set_deco(ours):
    """Переключить рамку. True — vitile (своя или Aurorae-тема), False — то, что было до установки."""
    if ours and deco_mode() == "native":
        want = {"library": DECO_ID, "theme": None}
    elif ours:
        want = {"library": "org.kde.kwin.aurorae.v2",
                "theme": f"__aurorae__svg__{STATE.read_text().strip()}"}
    else:
        old = json.loads(BACKUP.read_text())
        want = {"library": old["library"], "theme": old["theme"]}
    changed = False
    for key, value in want.items():
        if kread_raw(DECO_GROUP, key) != value:
            kwrite(DECO_GROUP, key, value)
            changed = True
    return changed


def desk(arg):
    """Запомнить, что на столе плитка вкл/выкл. arg: on-<id стола> или off-<id стола>."""
    mode, _, desk_id = arg.partition("-")
    if mode not in ("on", "off") or not desk_id:
        sys.exit("Использование: vitile.py desk on|off-<id стола>")
    # Прочитать и записать одним куском под блокировкой: две быстрые смены режима
    # (или наша же смена рамки в ту же секунду) не должны терять друг друга
    def change(lines):
        current, value = None, ""
        for line in lines:
            st = line.strip()
            if st.startswith("["):
                current = st[1:-1]
            elif current == SCRIPT_GROUP and st.split("=", 1)[0].strip() == "offDesktops":
                value = st.split("=", 1)[1] if "=" in st else ""
        offs = [d for d in value.split(",") if d and d != desk_id]
        if mode == "off":
            offs.append(desk_id)
        return set_line(lines, SCRIPT_GROUP, "offDesktops", ",".join(offs) if offs else None)
    edit_kwinrc(change)


def deco(mode):
    if mode not in ("on", "off") or not BACKUP.exists() or (deco_mode() != "native" and not STATE.exists()):
        sys.exit("Использование: vitile.py deco on|off (после install)")
    if mode == "on" and deco_mode() == "native":
        adopt_foreign_deco()
    if set_deco(mode == "on"):
        kwin("/KWin", "org.kde.KWin.reconfigure")


def adopt_foreign_deco():
    """Рамку подменили со стороны KDE (например, применили глобальную тему) — запомнить
    её как «прежнюю», чтобы после удаления vitile вернулась именно она."""
    lib, theme = kread_raw(DECO_GROUP, "library"), kread_raw(DECO_GROUP, "theme")
    if lib == DECO_ID or (theme or "").startswith("__aurorae__svg__vitile-"):
        return
    backup = json.loads(BACKUP.read_text())
    if (backup.get("library"), backup.get("theme")) != (lib, theme):
        backup["library"], backup["theme"] = lib, theme
        BACKUP.write_text(json.dumps(backup, ensure_ascii=False, indent=1))
        print(f"Запомнил новую прежнюю рамку: {lib} {theme or '(по умолчанию темы)'}")


def install():
    backup = json.loads(BACKUP.read_text()) if BACKUP.exists() else {
        "library": kread_raw(DECO_GROUP, "library"),
        "theme": kread_raw(DECO_GROUP, "theme"),
    }
    take_keys(backup)
    BACKUP.write_text(json.dumps(backup, ensure_ascii=False, indent=1))
    UNIT.parent.mkdir(parents=True, exist_ok=True)
    UNIT.write_text(
        "[Unit]\nDescription=vitile: переключить рамку окон (%i)\n\n"
        "[Service]\nType=oneshot\n"
        f"ExecStart=/usr/bin/python3 {HERE / 'vitile.py'} deco %i\n")
    DESK_UNIT.write_text(
        "[Unit]\nDescription=vitile: запомнить режим рабочего стола (%i)\n\n"
        "[Service]\nType=oneshot\n"
        f"ExecStart=/usr/bin/python3 {HERE / 'vitile.py'} desk %i\n")
    HELP_UNIT.write_text(
        "[Unit]\nDescription=vitile: справка\n\n"
        # KillMode=process: после выхода службы не убивать открытое окно справки
        "[Service]\nType=oneshot\nKillMode=process\n"
        f"ExecStart=/usr/bin/python3 {HERE / 'vitile.py'} help\n")
    CHECK_UNIT.write_text(
        "[Unit]\nDescription=vitile: проверить рамку после входа в систему\n"
        "After=graphical-session.target plasma-kwin_wayland.service\n\n"
        "[Service]\nType=oneshot\nExecStartPre=/usr/bin/sleep 5\n"
        f"ExecStart=/usr/bin/python3 {HERE / 'vitile.py'} check\n\n"
        "[Install]\nWantedBy=graphical-session.target\n")
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not ENV_FILE.exists():
        ENV_FILE.write_text("# vitile: KWin ищет рамку vitile ещё и здесь (удаляется vitile.py uninstall)\n"
                            f"QT_PLUGIN_PATH={PLUGIN_DIR}${{QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}}\n")
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "--user", "enable", "vitile-check.service"], capture_output=True)
    print("Собираю рамку vitile…")
    built = build()
    kwrite("Plugins", "vitileEnabled", "true")
    mode = apply()
    if not script_loaded():
        print("KWin не запустил скрипт — пришли этот вывод.")
        return
    print("vitile установлен и запущен.")
    if built and mode != "native":
        print("Чтобы включилась новая рамка (мгновенная смена столов, настоящие скругления),\n"
              "выйди из системы и зайди снова — один раз. До этого работает прежняя рамка.")


def check():
    """После входа в систему: KDE обновился — пересобрать рамку; рамка не загрузилась — перейти
    на неё или откатиться на запасную тему."""
    if not BACKUP.exists():
        return
    rebuilt = False
    if PLUGIN_DST.exists() and DECO_STAMP.exists() and DECO_STAMP.read_text() != kdecoration_version():
        print("KDE обновился — пересобираю рамку vitile.")
        rebuilt = build()
    want_native = plugin_visible_to_kwin()
    if rebuilt or (want_native and not native_active()) or (deco_mode() == "native") != native_active():
        apply()


def uninstall():
    kwrite("Plugins", "vitileEnabled", None)
    drop_group(SCRIPT_GROUP)
    if BACKUP.exists():
        set_deco(False)
        restore_effects(json.loads(BACKUP.read_text()))
    drop_group(EFFECT_GROUP)
    reload_kwin()
    # Старые версии vitile убирали рамку окнам других столов, а эта прячет окна на время
    # смены рамки. Если удалить в этот момент, вернуть рамку и видимость всем окнам
    # Своя рамка помечала окна в плитке через keepBelow — снять пометки
    # (рамку окнам не возвращаем: у программ со своим заголовком её нет намеренно)
    run_kwin_js('workspace.windowList().forEach(function (w) {'
                ' if ((w.normalWindow || w.dialog) && w.opacity === 0) w.opacity = 1;'
                ' if (w.normalWindow && w.keepBelow) w.keepBelow = false; });')
    drop_group(DECO_CFG_GROUP)
    subprocess.run(["systemctl", "--user", "disable", "vitile-check.service"], capture_output=True)
    CHECK_UNIT.unlink(missing_ok=True)
    ENV_FILE.unlink(missing_ok=True)
    PLUGIN_DST.unlink(missing_ok=True)
    if BACKUP.exists():
        give_back_keys(json.loads(BACKUP.read_text()))
        BACKUP.unlink()
    STATE.unlink(missing_ok=True)
    UNIT.unlink(missing_ok=True)
    HELP_UNIT.unlink(missing_ok=True)
    DESK_UNIT.unlink(missing_ok=True)
    HELP_PAGE.unlink(missing_ok=True)
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
    shutil.rmtree(SCRIPT_DST, ignore_errors=True)
    shutil.rmtree(EFFECT_DST, ignore_errors=True)
    for name in THEME_SLOTS:
        shutil.rmtree(THEMES / name, ignore_errors=True)
    print("vitile удалён, рамка окон возвращена как была.")


if __name__ == "__main__":
    if sys.argv[1:] == ["help"]:
        show_help()
        sys.exit()
    if len(sys.argv) == 3 and sys.argv[1] == "desk":
        desk(sys.argv[2])
        sys.exit()
    if len(sys.argv) == 3 and sys.argv[1] == "deco":
        deco(sys.argv[2])
        sys.exit()
    commands = {"install": install, "apply": apply, "uninstall": uninstall, "check": check,
                "build": build}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        print(__doc__)
        sys.exit(1)
    commands[sys.argv[1]]()
