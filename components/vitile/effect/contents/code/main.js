// vitile_motion — анимации в духе Hyprland для KWin 6.
// Появление: окно «выпрыгивает» из уменьшенного размера с проявлением (popin).
// Закрытие и сворачивание: обратно — уменьшается и тает.
// Перестройка плитки: окно плавно перетекает со старого места и размера на новое.
// Настройки — в kwinrc, группа [Effect-vitile_motion] (их пишет vitile.py apply).

"use strict";

var config = {};

function loadConfig() {
    config.duration = animationTime(Number(effect.readConfig("Duration", 220)));
    config.scale = Number(effect.readConfig("PopinScale", 0.85));
    config.move = String(effect.readConfig("AnimateMove", true)) !== "false";
}

// Те же окна, что анимирует встроенный эффект «Масштаб»: обычные окна и диалоги,
// без меню, подсказок, экрана блокировки и окон самой Plasma.
function animated(w) {
    if (!w || effects.hasActiveFullScreenEffect) return false;
    var cls = String(w.windowClass);
    if (cls.indexOf("plasmashell") === 0) return w.hasDecoration;
    if (cls.indexOf("ksmserver") === 0 || cls.indexOf("ksplashqml") === 0) return false;
    if (w.popupWindow || w.lockScreen || w.outline || !w.managed) return false;
    // Окна, которые нельзя двигать (layer-shell: панели, окошки у трея, карточки
    // вроде Whisper), анимирует сама программа — не вмешиваемся
    if (!w.moveable) return false;
    return w.normalWindow || w.dialog;
}

function forceBlur(w, on) {
    w.setData(Effect.WindowForceBackgroundContrastRole, on ? true : null);
    w.setData(Effect.WindowForceBlurRole, on ? true : null);
}

function stop(w, name) {
    if (w[name]) {
        cancel(w[name]);
        delete w[name];
    }
}

// --- появление и закрытие ---

function opened(w) {
    if (!animated(w) || !w.visible || effect.isGrabbed(w, Effect.WindowAddedGrabRole)) return;
    w.vtAddedAt = Date.now();
    forceBlur(w, true);
    w.vtOpen = animate({
        window: w, duration: config.duration, curve: QEasingCurve.OutBack,
        animations: [{ type: Effect.Scale, from: config.scale },
                     { type: Effect.Opacity, from: 0, curve: QEasingCurve.OutCubic }]
    });
}

function closed(w) {
    if (!animated(w) || !w.visible || w.skipsCloseAnimation) return;
    if (effect.isGrabbed(w, Effect.WindowClosedGrabRole)) return;
    stop(w, "vtOpen");
    stop(w, "vtMove");
    forceBlur(w, true);
    animate({
        window: w, duration: config.duration * 0.8, curve: QEasingCurve.InCubic,
        animations: [{ type: Effect.Scale, to: config.scale },
                     { type: Effect.Opacity, to: 0 }]
    });
}

// --- сворачивание ---

function minimized(w) {
    if (!animated(w)) return;
    if (w.vtUnmin && redirect(w.vtUnmin, Effect.Backward)) return;
    stop(w, "vtUnmin");
    stop(w, "vtMove");
    w.vtMin = animate({
        window: w, duration: config.duration, curve: QEasingCurve.InCubic, keepAlive: false,
        animations: [{ type: Effect.Scale, from: 1, to: config.scale },
                     { type: Effect.Translation, from: { value1: 0, value2: 0 },
                       to: { value1: 0, value2: w.height * 0.08 } },
                     { type: Effect.Opacity, from: 1, to: 0 }]
    });
}

function unminimized(w) {
    if (!animated(w)) return;
    if (w.vtMin && redirect(w.vtMin, Effect.Backward)) return;
    stop(w, "vtMin");
    w.vtUnmin = animate({
        window: w, duration: config.duration, curve: QEasingCurve.OutBack, keepAlive: false,
        animations: [{ type: Effect.Scale, from: config.scale, to: 1 },
                     { type: Effect.Translation, from: { value1: 0, value2: w.height * 0.08 },
                       to: { value1: 0, value2: 0 } },
                     { type: Effect.Opacity, from: 0, to: 1, curve: QEasingCurve.OutCubic }]
    });
}

// --- перестройка плитки ---

// Клиент на Wayland меняет размер не мгновенно: сначала окно переезжает,
// потом приходит новый размер. Поэтому пока анимация идёт, новые изменения
// продолжают её от той же исходной точки, а не начинают заново с полпути.
function geometryChanged(w, old) {
    if (!config.move || !animated(w) || !w.visible || w.minimized || w.fullScreen) return;
    if (w.move || w.resize) return;                     // тянут мышью — не мешаем
    if (!old || old.width < 2 || old.height < 2) return;
    // Только что открылось: программа ещё устраивается (плееры подгоняют окно под видео,
    // vitile возвращает его в ячейку) — эти шаги не анимируем
    if (w.vtAddedAt && Date.now() - w.vtAddedAt < Math.max(config.duration, 700)) return;
    var now = w.geometry;
    if (Math.abs(now.x - old.x) < 2 && Math.abs(now.y - old.y) < 2 &&
        Math.abs(now.width - old.width) < 2 && Math.abs(now.height - old.height) < 2) return;

    var from = old;
    if (w.vtMove && Date.now() - w.vtMoveAt < config.duration) from = w.vtFrom;
    stop(w, "vtMove");
    w.vtFrom = { x: from.x, y: from.y, width: from.width, height: from.height };
    w.vtMoveAt = Date.now();
    w.vtMove = animate({
        window: w, duration: config.duration, curve: QEasingCurve.OutCubic,
        animations: [{
            type: Effect.Size,
            from: { value1: from.width, value2: from.height },
            to: { value1: now.width, value2: now.height }
        }, {
            type: Effect.Translation,
            from: { value1: from.x - now.x - (now.width - from.width) / 2,
                    value2: from.y - now.y - (now.height - from.height) / 2 },
            to: { value1: 0, value2: 0 }
        }]
    });
}

// vitile прячет окна (прозрачность 0), пока меняется рамка при смене стола,
// и потом возвращает — делаем возвращение плавным проявлением
function opacityChanged(w, oldOpacity, newOpacity) {
    if (oldOpacity > 0.01 || newOpacity < 0.5 || !w.visible) return;
    stop(w, "vtReveal");
    w.vtReveal = animate({
        window: w, duration: config.duration * 0.7, curve: QEasingCurve.OutCubic,
        animations: [{ type: Effect.Opacity, from: 0 }]
    });
}

function manage(w) {
    w.windowFrameGeometryChanged.connect(geometryChanged);
    if (w.windowOpacityChanged) w.windowOpacityChanged.connect(opacityChanged);
    w.minimizedChanged.connect(function () {
        if (w.minimized) minimized(w);
        else unminimized(w);
    });
}

loadConfig();
effect.configChanged.connect(loadConfig);
effect.animationEnded.connect(function (w) { forceBlur(w, false); });
effects.windowAdded.connect(function (w) { manage(w); opened(w); });
effects.windowClosed.connect(closed);
effects.stackingOrder.forEach(manage);
