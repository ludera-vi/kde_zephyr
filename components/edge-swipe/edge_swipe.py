#!/usr/bin/env python3
"""Левый край тачпада: свайп вверх/вниз = яркость. Правый край = громкость."""
import subprocess
import sys
import glob
from evdev import InputDevice, ecodes as e

EDGE = 0.08          # ширина зоны у края (доля ширины тачпада)
FULL_SWIPE = 0.8     # свайп на такую долю высоты = 100% изменения
VOL_MAX = 1.0        # потолок громкости (1.0 = 100%)
MIN_BRIGHT_PCT = 0   # минимум яркости в %, 0 = экран можно погасить полностью
DEADZONE = 0.04      # пока палец не прошёл эту долю высоты, ничего не меняем
DIR_RATIO = 1.5      # жест вертикальный, если |dy| >= DIR_RATIO * |dx|

BR = ["busctl", "--user"]
BR_OBJ = ["org.kde.Solid.PowerManagement",
          "/org/kde/Solid/PowerManagement/Actions/BrightnessControl",
          "org.kde.Solid.PowerManagement.Actions.BrightnessControl"]


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()


def br_get():
    return int(sh(*BR, "call", *BR_OBJ, "brightness").split()[-1]), \
           int(sh(*BR, "call", *BR_OBJ, "brightnessMax").split()[-1])


def br_set(v):
    subprocess.Popen([*BR, "call", *BR_OBJ, "setBrightness", "i", str(int(v))],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def vol_get():
    return float(sh("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@").split()[1])


def vol_set(v):
    subprocess.Popen(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{v:.3f}"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def find_touchpad():
    denied = 0
    for p in sorted(glob.glob('/dev/input/event*')):
        try:
            d = InputDevice(p)
        except PermissionError:
            denied += 1
            continue
        codes = [c[0] if isinstance(c, tuple) else c
                 for c in d.capabilities().get(e.EV_ABS, [])]
        if "touchpad" in d.name.lower() and e.ABS_MT_POSITION_X in codes:
            return d
    sys.exit(f"тачпад не найден; нет прав на {denied} устройств(а) в /dev/input"
             if denied else "тачпад не найден")


def main():
    dev = find_touchpad()
    ax = dev.absinfo(e.ABS_MT_POSITION_X)
    ay = dev.absinfo(e.ABS_MT_POSITION_Y)
    w, h = ax.max - ax.min, ay.max - ay.min
    left_x = ax.min + w * EDGE
    right_x = ax.max - w * EDGE
    print(f"{dev.name}: X {ax.min}..{ax.max}, Y {ay.min}..{ay.max}", flush=True)

    slot = 0
    fingers = {}      # slot -> {"x","y"}
    mode = None       # None | "bright" | "vol" | "ignore" (до отрыва всех пальцев)
    active = False    # мёртвая зона пройдена, жест принят
    slot_g = None     # слот, ведущий жест
    start_x = start_y = 0
    base = 0
    cap = 1

    for ev in dev.read_loop():
        if ev.type == e.EV_ABS:
            if ev.code == e.ABS_MT_SLOT:
                slot = ev.value
            elif ev.code == e.ABS_MT_TRACKING_ID:
                if ev.value == -1:
                    fingers.pop(slot, None)
                    if not fingers:
                        mode = slot_g = None
                        active = False
                else:
                    fingers[slot] = {"x": None, "y": None}
            elif ev.code == e.ABS_MT_POSITION_X and slot in fingers:
                fingers[slot]["x"] = ev.value
            elif ev.code == e.ABS_MT_POSITION_Y and slot in fingers:
                fingers[slot]["y"] = ev.value
        elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
            if mode is None and len(fingers) == 1:
                (s, f), = fingers.items()
                if f["x"] is None or f["y"] is None:
                    continue
                if f["x"] <= left_x:
                    mode, slot_g = "bright", s
                elif f["x"] >= right_x:
                    mode, slot_g = "vol", s
                else:
                    mode = "ignore"        # касание не с края — не наш жест
                start_x, start_y, active = f["x"], f["y"], False
            elif mode in ("bright", "vol") and len(fingers) > 1:
                mode, slot_g = "ignore", None   # второй палец — отмена жеста
            elif mode in ("bright", "vol") and slot_g in fingers:
                f = fingers[slot_g]
                if f["x"] is None or f["y"] is None:
                    continue
                dy = start_y - f["y"]               # вверх = +
                if not active:
                    if abs(dy) < h * DEADZONE:
                        continue
                    if abs(dy) < DIR_RATIO * abs(f["x"] - start_x):
                        mode = "ignore"             # диагональ/горизонталь — случайное касание
                        continue
                    active = True
                    start_y = f["y"]                # отсчёт от точки принятия жеста, без скачка
                    if mode == "bright":
                        base, cap = br_get()
                    else:
                        base = vol_get()
                    dy = start_y - f["y"]
                frac = dy / (h * FULL_SWIPE)
                if mode == "bright":
                    lo = cap * MIN_BRIGHT_PCT / 100
                    br_set(max(lo, min(cap, base + frac * cap)))
                else:
                    vol_set(max(0.0, min(VOL_MAX, base + frac)))

if __name__ == "__main__":
    main()
