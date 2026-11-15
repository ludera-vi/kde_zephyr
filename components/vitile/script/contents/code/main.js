// vitile — плитка окон для KWin 6 в духе Hyprland (раскладка dwindle).
// Каждое следующее окно делит оставшееся место пополам по длинной стороне:
// 1 окно — весь экран, 2 — слева/справа, 3 — правая половина делится
// на верх/низ, 4 — нижняя правая часть делится на лево/право, и так далее.
// Если окно развёрнуто (Meta+F), стол переходит в ленту как в niri: окна стоят
// колонками в ряд, развёрнутое — на весь экран, остальные уезжают за край,
// а лента прокручивается к активному окну.

var outerGap = Number(readConfig("outerGap", 12));
var innerGap = Number(readConfig("innerGap", 10));
// Зазор от плавающей панели сверху или сбоку. Plasma прилепляет панель к краю, как только окно
// касается её области (окно панели вместе с «воздухом»), поэтому минимум — 1 пиксель.
var topGap = Math.max(1, Number(readConfig("topGap", 1)));
var exclude = String(readConfig("exclude", "")).split(",")
    .map(function (s) { return s.trim().toLowerCase(); })
    .filter(function (s) { return s.length > 0; });

var RATIO_STEP = 0.05;
var RATIO_MIN = 0.15, RATIO_MAX = 0.85;

// Какая рамка у окон:
//  native  — своя рамка vitile (модуль на C++): у каждого окна свой вид. Скрипт только
//            помечает окна в плитке (keepBelow), и смена стола ничего не переключает.
//  aurorae — запасной путь, если модуль не загрузился: одна тема на все окна, при смене
//            стола она переключается (окна на это время прячутся).
var decoMode = String(readConfig("decoMode", "aurorae"));
function native() { return decoMode === "native"; }

// Столы, где плитка выключена (Meta+Shift+T); запоминаются в kwinrc через vitile.py
var off = {};
String(readConfig("offDesktops", "")).split(",").forEach(function (d) { if (d) off[d] = true; });
var decoOn = null;   // какая рамка сейчас стоит: true — vitile, false — обычная
var veiled = {};     // id -> { окно, прежняя прозрачность }: спрятаны, пока меняется рамка
var veilTimer = null;
var decoTimer = null;
// Скольжение между столами длится ~0,5 с. Переключать рамку посреди него нельзя:
// KWin перечитывает настройки, и анимация спотыкается. Поэтому ждём её конца.
var SLIDE_WAIT = 550;
var decoAppliedAt = 0; // когда применилась новая рамка (0 — ещё нет)
var deskSeq = 0;     // номер перехода между столами: ответы для старых переходов игнорируем
var order = [];      // порядок окон в раскладке
var zoomed = {};     // id -> true: окно развёрнуто на всю область
var floating = {};   // id -> true: окно плавает поверх, раскладка его не трогает
var ratios = {};     // ключ группы -> доли разделов [0.5, 0.5, ...]
var placed = {};     // id -> куда окно поставлено и в каком разделе оно лежит
var minimizedStack = [];  // свёрнутые окна, последнее — в конце
var focused = [];    // два последних активных плиточных окна
var fits = {};       // ключ группы -> помещаются ли окна в свои минимальные размеры
var splitDirs = {};  // ключ группы -> { окна, направления разделов } — не меняются при ресайзе
var colWidth = {};   // id -> ширина колонки в ленте, доля экрана (по умолчанию 0.5)
var scroll = {};     // ключ группы -> прокрутка ленты, пиксели
var stripOn = {};    // ключ группы -> стол сейчас в режиме ленты

function id(w) { return String(w.internalId); }

function osd(text) {
    callDBus("org.kde.plasmashell", "/org/kde/osdService", "org.kde.osdService",
             "showText", "view-grid-symbolic", text);
}

function enabledHere() { return !off[workspace.currentDesktop.id]; }

function systemdStart(unit) {
    callDBus("org.freedesktop.systemd1", "/org/freedesktop/systemd1",
             "org.freedesktop.systemd1.Manager", "StartUnit", unit, "replace");
}

// Рамку переключает служба vitile-deco@on|off (её ставит vitile.py install).
// Рамка общая на все столы, поэтому меняем её при переходе на стол с другим режимом.
function setDeco(on) {
    if (decoOn === on) return;
    decoOn = on;
    callDBus("org.freedesktop.systemd1", "/org/freedesktop/systemd1",
             "org.freedesktop.systemd1.Manager", "StartUnit",
             "vitile-deco@" + (on ? "on" : "off") + ".service", "replace");
}

// «Картинка в картинке» из браузеров: в плитку не берём, держим поверх всех
function isPip(w) {
    return /picture[ -]?in[ -]?picture|картинка в картинке/i.test(String(w.caption));
}

function manageable(w) {
    if (!w || w.deleted) return false;
    if (!w.normalWindow || w.transient || w.specialWindow || w.popupWindow) return false;
    if (isPip(w)) return false;
    if (!w.resizeable || !w.moveable || w.skipTaskbar) return false;
    var cls = String(w.resourceClass).toLowerCase();
    return exclude.indexOf(cls) < 0;
}

function tileable(w) {
    return manageable(w) && !w.minimized && !w.fullScreen && !floating[id(w)];
}

function onCurrentDesktop(w) {
    if (!w.onAllDesktops) {
        var cur = workspace.currentDesktop.id;
        var found = w.desktops.some(function (d) { return d.id === cur; });
        if (!found) return false;
    }
    var acts = w.activities;
    return !acts || acts.length === 0 || acts.indexOf(workspace.currentActivity) >= 0;
}

// Область для окон: как у KWin, но панели учитываются вместе с их «воздухом»
// (плавающая панель занимает больше, чем резервирует). Если окно залезет
// в этот воздух, Plasma приклеит панель к краю экрана.
function workArea(output) {
    var a = workspace.clientArea(KWin.MaximizeArea, output, workspace.currentDesktop);
    var o = workspace.clientArea(KWin.FullScreenArea, output, workspace.currentDesktop);
    var top = a.y, bottom = a.y + a.height, left = a.x, right = a.x + a.width,
        topPanel = false, leftPanel = false, rightPanel = false;
    workspace.windowList().forEach(function (d) {
        if (!d.dock || d.output !== output) return;
        var g = d.frameGeometry;
        if (g.width >= g.height) {
            if (a.y > o.y && g.y <= o.y + 1) { top = Math.max(top, g.y + g.height); topPanel = true; }
            if (a.y + a.height < o.y + o.height && g.y + g.height >= o.y + o.height - 1)
                bottom = Math.min(bottom, g.y);
        } else {
            if (a.x > o.x && g.x <= o.x + 1) { left = Math.max(left, g.x + g.width); leftPanel = true; }
            if (a.x + a.width < o.x + o.width && g.x + g.width >= o.x + o.width - 1) {
                right = Math.min(right, g.x);
                rightPanel = true;
            }
        }
    });
    return { x: left, y: top, width: right - left, height: bottom - top,
             topPanel: topPanel, leftPanel: leftPanel, rightPanel: rightPanel };
}

function groupKey(output) { return output.name + "|" + workspace.currentDesktop.id; }

function visibleTiles(output) {
    return order.filter(function (w) {
        return tileable(w) && w.output === output && onCurrentDesktop(w);
    });
}

function place(w, r) {
    try { if (w.tile) w.tile = null; } catch (e) {}
    // setMaximize на неразвёрнутом окне возвращает его на старое место — только если нужно
    if (w.maximizeMode) w.setMaximize(false, false);
    // Только новый объект: правка копии w.frameGeometry KWin молча игнорирует
    w.frameGeometry = { x: Math.round(r.x), y: Math.round(r.y),
                        width: Math.round(r.width), height: Math.round(r.height) };
}

// Делит прямоугольник на две части с зазором. vertical — рядом (лево/право).
function split(r, vertical, ratio) {
    if (vertical) {
        var w1 = (r.width - innerGap) * ratio;
        return [{ x: r.x, y: r.y, width: w1, height: r.height },
                { x: r.x + w1 + innerGap, y: r.y, width: r.width - w1 - innerGap, height: r.height }];
    }
    var h1 = (r.height - innerGap) * ratio;
    return [{ x: r.x, y: r.y, width: r.width, height: h1 },
            { x: r.x, y: r.y + h1 + innerGap, width: r.width, height: r.height - h1 - innerGap }];
}

// Минимальный размер окна вместе с рамкой
function minFrame(w) {
    var m = w.minSize, f = w.frameGeometry, c = w.clientGeometry;
    var dw = c ? f.width - c.width : 0, dh = c ? f.height - c.height : 0;
    return { width: (m ? m.width : 0) + dw, height: (m ? m.height : 0) + dh };
}

// Раздел i отделяет окно i (первая часть) от всех следующих (вторая часть).
// Последнее окно — вторая часть последнего раздела.
// rs — доли разделов, need — минимумы веток (см. requirements), dirs — направления
// разделов (true — рядом); need и dirs можно не передавать.
function cells(wins, full, key, rs, mins, need, dirs) {
    var rest = full, prev = null;
    return wins.map(function (w, i) {
        var info;
        if (i === wins.length - 1) {
            info = { rect: rest, key: key, index: i - 1, first: false,
                     vertical: prev && prev.vertical, parent: prev && prev.parent };
        } else {
            var vertical = dirs ? dirs[i] : rest.width >= rest.height;
            var r = rs[i] || 0.5;
            if (need) r = fitRatio(r, rest, vertical, mins[i], need[i + 1]);
            var parts = split(rest, vertical, r);
            info = { rect: parts[0], key: key, index: i, first: true,
                     vertical: vertical, parent: rest };
            rest = parts[1];
        }
        return prev = info;
    });
}

// Сколько минимум места нужно ветке «окно i и все после него» при текущих направлениях.
function requirements(mins, dirs) {
    var n = mins.length, need = [];
    need[n - 1] = mins[n - 1];
    for (var i = n - 2; i >= 0; i--) {
        var a = mins[i], b = need[i + 1];
        need[i] = dirs[i]
            ? { width: a.width + innerGap + b.width, height: Math.max(a.height, b.height) }
            : { width: Math.max(a.width, b.width), height: a.height + innerGap + b.height };
    }
    return need;
}

// Доля раздела так, чтобы и окно, и остальная ветка влезли в свои минимумы.
// Если места на всех не хватает — делим пропорционально минимумам.
function fitRatio(r, rect, vertical, first, rest) {
    var total = (vertical ? rect.width : rect.height) - innerGap;
    var a = vertical ? first.width : first.height;
    var b = vertical ? rest.width : rest.height;
    if (total <= 0) return 0.5;
    if (a + b > total) return a / (a + b);
    return Math.max(a / total, Math.min(1 - b / total, r));
}

function layoutOutput(output) {
    var wins = visibleTiles(output);
    if (wins.length === 0) return;

    var a = workArea(output);
    // сверху или сбоку панель — свой зазор до неё
    var top = a.topPanel ? topGap : outerGap;
    var left = a.leftPanel ? topGap : outerGap;
    var right = a.rightPanel ? topGap : outerGap;
    var full = { x: a.x + left, y: a.y + top,
                 width: a.width - left - right, height: a.height - top - outerGap };
    var key = groupKey(output);
    if (wins.some(function (w) { return zoomed[id(w)]; })) return stripLayout(wins, full, key);
    stripOn[key] = false;
    var rs = ratios[key] || [];
    var mins = wins.map(minFrame);

    // Направления разделов — как в обычной спирали на момент, когда набор окон
    // поменялся. При изменении размеров они не переворачиваются (как preserve_split
    // в Hyprland), и окна с большим минимумом не превращают раскладку в столбики.
    // Под минимумы подгоняются только доли.
    var sig = wins.map(id).join();
    var cached = splitDirs[key];
    if (!cached || cached.sig !== sig) {
        var plain = cells(wins, full, key, rs, mins, null, null);
        cached = splitDirs[key] = { sig: sig, dirs: plain.map(function (x) { return x.vertical; }) };
    }
    var dirs = cached.dirs;
    var need = requirements(mins, dirs);
    var infos = cells(wins, full, key, rs, mins, need, dirs);
    var fit = need[0].width <= full.width + 1 && need[0].height <= full.height + 1;
    if (fits[key] !== fit) {
        fits[key] = fit;
        console.log("vitile: fit=" + (fit ? 1 : 0) + " windows=" + wins.length + " group=" + key);
    }

    wins.forEach(function (w, i) {
        placed[id(w)] = infos[i];
        place(w, infos[i].rect);
    });
}

// Лента как в niri: колонки во всю высоту в порядке раскладки. Развёрнутые — на всю
// ширину, остальные — по colWidth. Прокручиваем ровно настолько, чтобы активное
// окно было видно целиком; что не влезло — стоит за краем экрана.
function stripLayout(wins, full, key) {
    var span = full.width - innerGap, x = 0;
    var cols = wins.map(function (w) {
        var width = zoomed[id(w)] ? full.width
            : Math.min(full.width, Math.max(minFrame(w).width, span * (colWidth[id(w)] || 0.5)));
        var c = { w: w, x: x, width: width };
        x += width + innerGap;
        return c;
    });
    var total = x - innerGap;
    var act = workspace.activeWindow;
    var target = cols.filter(function (c) { return c.w === act; })[0] ||
                 cols.filter(function (c) { return zoomed[id(c.w)]; })[0];
    var s = stripOn[key] ? (scroll[key] || 0) : target.x;
    if (target.x < s) s = target.x;
    if (target.x + target.width > s + full.width) s = target.x + target.width - full.width;
    s = Math.max(0, Math.min(s, Math.max(0, total - full.width)));
    scroll[key] = s;
    stripOn[key] = true;

    cols.forEach(function (c) {
        var rect = { x: full.x + c.x - s, y: full.y, width: c.width, height: full.height };
        placed[id(c.w)] = { rect: rect, key: key, index: -1, strip: true, span: span };
        place(c.w, rect);
    });
}

// Окно «в плитке» (рамка рисует его без заголовка, с обводкой): управляемое окно
// на столе с плиткой, не плавающее и не на весь экран
function shouldMark(w) {
    if (!native() || !manageable(w) || w.fullScreen || floating[id(w)]) return false;
    if (w.onAllDesktops) return enabledHere();
    return w.desktops.length > 0 && w.desktops.every(function (d) { return !off[d.id]; });
}

// Пометки держим через keepBelow: плитки и так должны быть под плавающими окнами
// и диалогами. В режиме aurorae пометки снимаются (остались от native).
// Снимаем пометку только с тех окон, которым поставили её сами: свою «держать под
// остальными» пользователь может включить любому окну. И снимаем её всегда, даже
// если окно перестало быть «нашим»: у полноэкранного окна KWin запрещает двигать
// и менять размер, а с пометкой оно осталось бы под панелью.
var marked = {};     // id -> true: keepBelow поставил vitile

function markTiles() {
    workspace.windowList().forEach(function (w) {
        if (w.deleted) return;
        var k = id(w);
        if (shouldMark(w)) {
            if (!w.keepBelow) w.keepBelow = true;
            marked[k] = true;
        } else if (marked[k]) {
            if (w.keepBelow) w.keepBelow = false;
            delete marked[k];
        }
    });
}

function layout() {
    markTiles();
    if (!enabledHere()) return;
    workspace.screens.forEach(layoutOutput);
}

// --- всплывающие окна ---

var HELP_TITLE = "vitile — справка";

// Окна, которые нельзя двигать, — части системы и экранные подсказки программ:
// панели, громкость, окошки у трея (Asus Helper), карточка Whisper. Чаще всего это
// layer-shell поверхности: программа сама говорит, где им стоять. vitile их не трогает.
function systemSurface(w) { return !w.moveable; }

// Диалоги и прочие всплывающие окна программ (не меню, не подсказки, не панели)
function isPopup(w) {
    if (!w || w.deleted || systemSurface(w)) return false;
    if (w.popupWindow || w.dock || w.desktopWindow || w.splash) return false;
    if (w.notification || w.criticalNotification || w.onScreenDisplay) return false;
    if (w.dialog || w.utility) return true;
    return w.normalWindow && (w.transient || !w.resizeable);
}

function centerOn(w, width, height) {
    var a = workArea(w.output);
    var W = Math.min(width, a.width), H = Math.min(height, a.height);
    w.frameGeometry = { x: Math.round(a.x + (a.width - W) / 2), y: Math.round(a.y + (a.height - H) / 2),
                        width: Math.round(W), height: Math.round(H) };
}

// Поставить по центру поверх всех. На Wayland размер окна часто приходит
// чуть позже появления — тогда центрируем, как только он станет известен.
// Только центрируем. «Поверх всех» не ставим: окна в плитке и так под остальными,
// а постоянный keepAbove повис бы на играх в окне и заставках программ навсегда.
function popUp(w) {
    if (w.frameGeometry.width > 1) return centerOn(w, w.frameGeometry.width, w.frameGeometry.height);
    var once = function () {
        if (w.frameGeometry.width <= 1) return;
        w.frameGeometryChanged.disconnect(once);
        centerOn(w, w.frameGeometry.width, w.frameGeometry.height);
    };
    w.frameGeometryChanged.connect(once);
}

// Окно справки: Brave в режиме приложения задаёт класс окна с именем файла сразу,
// а заголовок «vitile — справка» приходит позже — проверяем и то, и другое
function isHelp(w) {
    return String(w.resourceClass).indexOf("help.html") >= 0 ||
           String(w.caption).indexOf(HELP_TITLE) >= 0;
}

// Окно справки (vitile.py help) плавает по центру поверх всех
function watchHelp(w) {
    var check = function () {
        if (!isHelp(w) || floating[id(w)]) return;
        floating[id(w)] = true;
        w.keepAbove = true;
        var a = workArea(w.output);
        centerOn(w, Math.min(980, a.width * 0.8), a.height * 0.85);
        workspace.activeWindow = w;
        layout();
    };
    on(w, "captionChanged", check);
    check();
}

// --- окна ---

function on(obj, signal, fn) {
    if (obj[signal] && obj[signal].connect) obj[signal].connect(fn);
}

function addWindow(w, nextTo) {
    if (!w.normalWindow || order.indexOf(w) >= 0) return;
    // Новое окно встаёт сразу за активным (как в Hyprland: делит его место)
    var i = nextTo ? order.indexOf(nextTo) : -1;
    if (i >= 0) order.splice(i + 1, 0, w);
    else order.push(w);

    ["fullScreenChanged", "desktopsChanged", "activitiesChanged", "outputChanged",
     "quickTileModeChanged"].forEach(function (s) { on(w, s, layout); });
    // Заголовок «картинки в картинке» приходит не сразу — проверяем при каждой смене
    var pip = function () {
        if (isPip(w) && !w.keepAbove) { w.keepAbove = true; layout(); }
    };
    on(w, "captionChanged", pip);
    pip();
    on(w, "minimizedChanged", function () {
        var k = minimizedStack.indexOf(w);
        if (k >= 0) minimizedStack.splice(k, 1);
        if (w.minimized) minimizedStack.push(w);
        layout();
    });
    on(w, "interactiveMoveResizeFinished", function () { dragFinished(w); });
    on(w, "frameGeometryChanged", function () { snapBack(w); });
}

// Программа сама поменяла размер окна в плитке (VLC и mpv подгоняют окно под видео,
// некоторые программы восстанавливают свой прошлый размер) — вернуть в ячейку.
// Не трогаем, пока окно тянут мышью. Против упрямых программ — не больше 6 возвратов
// за 3 секунды, дальше оставляем как есть.
var SNAP_LIMIT = 6, SNAP_WINDOW = 3000;
var snaps = {};      // id -> { таймер, время первого возврата, сколько раз }

function snapBack(w) {
    if (!enabledHere() || !tileable(w) || w.move || w.resize || !onCurrentDesktop(w)) return;
    var info = placed[id(w)];
    if (!info) return;
    var g = w.frameGeometry, r = info.rect;
    if (Math.abs(g.x - r.x) <= 2 && Math.abs(g.y - r.y) <= 2 &&
        Math.abs(g.width - r.width) <= 2 && Math.abs(g.height - r.height) <= 2) return;
    var st = snaps[id(w)] || (snaps[id(w)] = { timer: null, since: 0, count: 0 });
    if (st.timer) return;   // возврат уже запланирован
    var now = Date.now();
    if (now - st.since > SNAP_WINDOW) { st.since = now; st.count = 0; }
    if (++st.count > SNAP_LIMIT) return;
    // Чуть подождать: на Wayland окно меняет положение и размер не одним шагом
    st.timer = after(40, function () {
        st.timer = null;
        if (!w.deleted && tileable(w) && placed[id(w)]) place(w, placed[id(w)].rect);
    });
}

function removeWindow(w) {
    delete snaps[id(w)];
    focused = focused.filter(function (o) { return o !== w; });
    var i = order.indexOf(w);
    if (i >= 0) order.splice(i, 1);
    var k = minimizedStack.indexOf(w);
    if (k >= 0) minimizedStack.splice(k, 1);
    delete zoomed[id(w)];
    delete floating[id(w)];
    delete placed[id(w)];
    layout();
}

function swap(a, b) {
    var i = order.indexOf(a), j = order.indexOf(b);
    if (i < 0 || j < 0) return;
    order[i] = b;
    order[j] = a;
}

// Соседнее плиточное окно в направлении dir ("left", "right", "up", "down"):
// лежит с той стороны и перекрывается с текущим по другой оси, ближайшее из таких.
function neighbor(w, dir) {
    var cur = placed[id(w)];
    if (!cur) return null;
    var a = cur.rect, tol = innerGap + 2;
    var best = null, bestScore = Infinity;
    visibleTiles(w.output).forEach(function (o) {
        if (o === w || !placed[id(o)]) return;
        var b = placed[id(o)].rect;
        var gap, overlap;
        if (dir === "left" || dir === "right") {
            gap = dir === "left" ? a.x - (b.x + b.width) : b.x - (a.x + a.width);
            overlap = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
        } else {
            gap = dir === "up" ? a.y - (b.y + b.height) : b.y - (a.y + a.height);
            overlap = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
        }
        if (gap < -tol || overlap <= 0) return;
        var score = gap * 10000 - overlap;   // сначала ближайшее, потом с большим перекрытием
        if (score < bestScore) { bestScore = score; best = o; }
    });
    return best;
}

// Перетащили или потянули окно мышью
function dragFinished(w) {
    if (!enabledHere() || !tileable(w)) return;
    var info = placed[id(w)];
    if (!info) return layout();
    var g = w.frameGeometry, r = info.rect;
    if (info.strip && !zoomed[id(w)] && Math.abs(g.width - r.width) > 4) {
        colWidth[id(w)] = Math.max(0.2, Math.min(1, g.width / info.span));  // потянули колонку за край
        return layout();
    }
    var resized = Math.abs(g.width - r.width) > 4 || Math.abs(g.height - r.height) > 4;

    if (!resized) {
        // Бросили на другое окно — меняемся местами
        var p = workspace.cursorPos;
        var target = visibleTiles(w.output).filter(function (o) {
            var q = placed[id(o)];
            return o !== w && q && p.x >= q.rect.x && p.x <= q.rect.x + q.rect.width &&
                   p.y >= q.rect.y && p.y <= q.rect.y + q.rect.height;
        })[0];
        if (target) swap(w, target);
    } else if (info.parent && info.index >= 0) {
        // Потянули за край — меняем долю раздела
        var size = info.vertical ? g.width : g.height;
        var total = (info.vertical ? info.parent.width : info.parent.height) - innerGap;
        var share = size / total;
        setRatio(info, info.first ? share : 1 - share);
    }
    layout();
}

function setRatio(info, value) {
    var rs = ratios[info.key] || (ratios[info.key] = []);
    rs[info.index] = Math.max(RATIO_MIN, Math.min(RATIO_MAX, value));
}

// --- горячие клавиши ---

function active() {
    var w = workspace.activeWindow;
    return manageable(w) ? w : null;
}

function focusDir(dir) {
    var w = active();
    if (!enabledHere() || !w) return;
    var n = neighbor(w, dir);
    if (n) workspace.activeWindow = n;
}

function moveDir(dir) {
    var w = active();
    if (!enabledHere() || !w || !tileable(w)) return;
    var n = neighbor(w, dir);
    if (!n) return;
    swap(w, n);
    layout();
    workspace.activeWindow = w;
}

// Доля раздела, как она реально стоит на экране (с учётом минимальных размеров)
function shown(info) {
    var v = info.vertical;
    return (v ? info.rect.width : info.rect.height) /
           ((v ? info.parent.width : info.parent.height) - innerGap);
}

// Изменить размер активного окна: vertical=true — ширина, иначе высота.
// Двигаем ближайший раздел нужного направления, которому принадлежит окно.
function resizeActive(vertical, delta) {
    var w = active();
    if (!enabledHere() || !w || !tileable(w)) return;
    var wins = visibleTiles(w.output);
    var i = wins.indexOf(w), info = placed[id(w)];
    if (i < 0 || !info) return;
    if (info.strip) {
        // В ленте меняется ширина колонки; высота всегда на весь экран
        if (!vertical || zoomed[id(w)]) return;
        colWidth[id(w)] = Math.max(0.2, Math.min(1, (colWidth[id(w)] || 0.5) + delta));
        return layout();
    }
    var all = wins.map(function (o) { return placed[id(o)]; });
    // Своё деление: окно — первая часть, растёт вместе с долей
    if (i < wins.length - 1 && all[i] && all[i].vertical === vertical) {
        setRatio(all[i], shown(all[i]) + delta);
        return layout();
    }
    // Деление выше: окно во второй части, растёт, когда доля уменьшается
    for (var j = Math.min(i, wins.length - 1) - 1; j >= 0; j--) {
        if (!all[j] || all[j].vertical !== vertical) continue;
        setRatio(all[j], shown(all[j]) - delta);
        return layout();
    }
}

function toggleZoom() {
    var w = active();
    if (!enabledHere() || !w || !tileable(w)) return;
    if (zoomed[id(w)]) delete zoomed[id(w)];
    else zoomed[id(w)] = true;
    layout();
}

function toggleFloat() {
    var w = active();
    if (!enabledHere() || !w) return;
    var k = id(w);
    if (floating[k]) {
        delete floating[k];
        w.keepAbove = false;
    } else {
        floating[k] = true;
        delete zoomed[k];
        w.keepAbove = true;
        var a = workArea(w.output);
        place(w, { x: a.x + a.width * 0.2, y: a.y + a.height * 0.15,
                   width: a.width * 0.6, height: a.height * 0.7 });
    }
    layout();
}

function closeActive() {
    var w = workspace.activeWindow;
    if (w && w.normalWindow) w.closeWindow();
}

function minimizeActive() {
    var w = workspace.activeWindow;
    if (w && w.normalWindow && w.minimizable) w.minimized = true;
}

function restoreMinimized() {
    for (var i = minimizedStack.length - 1; i >= 0; i--) {
        var w = minimizedStack[i];
        if (w.minimized && onCurrentDesktop(w)) {
            w.minimized = false;
            workspace.activeWindow = w;
            return;
        }
    }
}

function showHelp() {
    callDBus("org.freedesktop.systemd1", "/org/freedesktop/systemd1",
             "org.freedesktop.systemd1.Manager", "StartUnit", "vitile-help.service", "replace");
}

// Включить или выключить плитку на текущем рабочем столе (запоминается)
function toggle() {
    var d = workspace.currentDesktop;
    if (off[d.id]) delete off[d.id];
    else off[d.id] = true;
    var on = enabledHere();
    osd("Плитка на «" + d.name + "»: " + (on ? "включена" : "выключена"));
    systemdStart("vitile-desk@" + (on ? "on" : "off") + "-" + d.id + ".service");
    if (!native()) switchDeco(on);
    layout();   // в native пометки окон этого стола обновятся здесь же
}

// Рамка одна на все окна, и переключается она не мгновенно (~0,3 с). Чтобы окна
// не мелькали заголовками и не дёргались, пока KWin перестраивает рамки,
// прячем их (прозрачность 0) и показываем, когда рамка применилась и всё встало
// на места. Эффект vitile_motion делает появление плавным.
function veil() {
    workspace.windowList().forEach(function (w) {
        if (w.deleted || w.minimized || w.onAllDesktops || !onCurrentDesktop(w)) return;
        if (!(w.normalWindow || w.dialog) || systemSurface(w) || w.opacity <= 0 || veiled[id(w)]) return;
        // Показываем, когда окно перестанет менять размер (медленные программы
        // перерисовываются позже): каждое изменение после новой рамки откладывает показ
        var settle = function () {
            if (decoAppliedAt && Date.now() - decoAppliedAt < 800) unveilAfter(150);
        };
        w.frameGeometryChanged.connect(settle);
        veiled[id(w)] = { w: w, opacity: w.opacity, settle: settle };
        w.opacity = 0;
    });
    unveilAfter(1500);   // на случай, если сигнал о новой рамке не придёт
}

function after(ms, fn) {
    var t = new QTimer();
    t.singleShot = true;
    t.interval = ms;
    t.timeout.connect(fn);
    t.start();
    return t;
}

function unveilAfter(ms) {
    if (veilTimer) veilTimer.stop();
    veilTimer = after(ms, unveil);
}

function unveil() {
    if (veilTimer) { veilTimer.stop(); veilTimer = null; }
    Object.keys(veiled).forEach(function (k) {
        var v = veiled[k];
        delete veiled[k];
        if (v.w.deleted) return;
        v.w.frameGeometryChanged.disconnect(v.settle);
        v.w.opacity = v.opacity;
    });
}

// Сменить рамку, спрятав окна на время перестройки. wait — подождать, пока доедет
// анимация смены стола; рамку берём для стола, который будет текущим к тому моменту.
function switchDeco(on, wait) {
    if (decoTimer) { decoTimer.stop(); decoTimer = null; }
    if (decoOn === on) return unveil();
    decoAppliedAt = 0;
    veil();
    if (!wait) return setDeco(on);
    unveilAfter(wait + 1500);
    decoTimer = after(wait, function () { decoTimer = null; setDeco(enabledHere()); });
}

function desktopChanged() {
    deskSeq++;
    unveil();   // окна прошлого стола, если ещё не показаны
    layout();
    if (native()) return;   // у каждого окна своя рамка — переключать нечего
    if (decoOn === enabledHere()) return switchDeco(enabledHere(), 0);
    // Включено ли скольжение — спрашиваем у KWin (ответ придёт сразу после этого кадра)
    var target = enabledHere(), seq = ++deskSeq;
    veil();
    callDBus("org.kde.KWin", "/Effects", "org.kde.kwin.Effects", "isEffectLoaded", "slide",
             function (sliding) { if (seq === deskSeq) switchDeco(target, sliding ? SLIDE_WAIT : 0); });
}

function key(name, text, keys, fn) {
    registerShortcut("vitile: " + name, "vitile: " + text, keys, fn);
}

var DIRS = { left: ["Left", "влево"], right: ["Right", "вправо"],
             up: ["Up", "вверх"], down: ["Down", "вниз"] };
Object.keys(DIRS).forEach(function (d) {
    var k = DIRS[d][0], ru = DIRS[d][1];
    key("фокус " + ru, "перейти на окно " + ru, "Meta+" + k, function () { focusDir(d); });
    key("сдвинуть " + ru, "передвинуть окно " + ru, "Meta+Shift+" + k, function () { moveDir(d); });
});
key("шире", "сделать окно шире", "Meta+Alt+Right", function () { resizeActive(true, RATIO_STEP); });
key("уже", "сделать окно уже", "Meta+Alt+Left", function () { resizeActive(true, -RATIO_STEP); });
key("выше", "сделать окно выше", "Meta+Alt+Up", function () { resizeActive(false, RATIO_STEP); });
key("ниже", "сделать окно ниже", "Meta+Alt+Down", function () { resizeActive(false, -RATIO_STEP); });
key("во весь экран", "развернуть окно, остальные — в ленту за край / вернуть", "Meta+F", toggleZoom);
key("плавающее", "открепить окно от плитки / вернуть", "Meta+Space", toggleFloat);
key("свернуть", "свернуть окно", "Meta+Q", minimizeActive);
key("вернуть свёрнутое", "вернуть последнее свёрнутое окно", "Meta+Shift+Q", restoreMinimized);
key("закрыть", "закрыть окно", "Meta+M", closeActive);
key("вкл/выкл", "включить или выключить плитку на этом рабочем столе", "Meta+Shift+T", toggle);
key("справка", "справка по клавишам и настройкам", "Meta+Shift+F1", showHelp);

// --- запуск ---

workspace.windowList().forEach(function (w) {
    // Прошлая копия скрипта могла спрятать окно на время смены рамки — вернуть.
    // Пометки «в плитке» от прошлой копии подхватываем, чтобы снять их, где не нужны.
    if ((w.normalWindow || w.dialog) && w.opacity === 0) w.opacity = 1;
    if (native() && w.normalWindow && w.keepBelow) marked[id(w)] = true;
    addWindow(w, null);
    if (w.normalWindow) watchHelp(w);
    if (w.minimized && manageable(w)) minimizedStack.push(w);
});
on(workspace, "windowActivated", function (w) {
    if (!w || !tileable(w)) return;
    // В ленте прокручиваемся к окну, на которое переключились (Alt+Tab, клик, клавиши)
    if (enabledHere() && stripOn[groupKey(w.output)]) layoutOutput(w.output);
    if (focused[focused.length - 1] === w) return;
    focused.push(w);
    if (focused.length > 2) focused.shift();
});
workspace.windowAdded.connect(function (w) {
    if (enabledHere() && isPopup(w) && !w.fullScreen) popUp(w);
    if (w.normalWindow) watchHelp(w);
    // На Wayland новое окно часто уже активно — берём то, что было до него
    var prev = focused.filter(function (o) { return o !== w && tileable(o); }).pop();
    addWindow(w, prev || null);
    layout();
});
workspace.windowRemoved.connect(function (w) { delete veiled[id(w)]; delete marked[id(w)]; removeWindow(w); });
// Рамка применилась — дать окнам пару кадров встать по местам и показать
// Рамку могли подменить со стороны KDE — например, применили глобальную тему, а она
// ставит свою рамку окон. Признак: у окна в плитке появился заголовок. Тогда вернуть
// свою (vitile.py deco on; та рамка запомнится как «прежняя» для удаления).
var decoGuardAt = 0;
function guardDeco() {
    if (!native() || Date.now() - decoGuardAt < 10000) return;
    var foreign = workspace.windowList().some(function (w) {
        // только окна на экране: невидимым окнам KWin меняет рамку, когда их покажут
        return marked[id(w)] && !w.deleted && !w.minimized && !w.fullScreen && onCurrentDesktop(w) &&
               w.clientGeometry.y - w.frameGeometry.y > 1;
    });
    if (!foreign) return;
    decoGuardAt = Date.now();
    console.log("vitile: рамку подменили — возвращаю свою");
    systemdStart("vitile-deco@on.service");
}

options.configChanged.connect(function () {
    after(800, guardDeco);   // новая рамка применяется чуть позже сигнала
    if (!Object.keys(veiled).length) return;
    decoAppliedAt = Date.now();
    layout();
    unveilAfter(150);
});
on(workspace, "currentDesktopChanged", desktopChanged);
on(workspace, "currentActivityChanged", layout);
on(workspace, "screensChanged", layout);
if (!native()) setDeco(enabledHere());
layout();
after(1500, guardDeco);   // при запуске: вдруг рамка уже не наша
