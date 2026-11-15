import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Панель слева или справа: на ней значения идут столбиком, в ширину панели
    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical

    // Как часто читать батарею, пока работаем от неё. На сети не читаем вообще.
    readonly property int interval: 2000
    // Окно усреднения для «Среднее за минуту»
    readonly property int avgWindow: 60000
    // Сколько истории держать для графика
    readonly property int historyWindow: 3600000

    // Одно чтение uevent батареи — только sysfs (ACPI-запрос к EC, как у upower),
    // никакие устройства вроде дискретки при этом не трогаются.
    readonly property string readCmd: "sh -c 'cat /sys/class/power_supply/BAT*/uevent 2>/dev/null'"
    // Температуры — тоже только sysfs; NVIDIA спрашиваем, лишь когда она и так не спит
    readonly property string tempsScript: "sh '" + Qt.resolvedUrl("../code/temps.sh").toString().replace("file://", "") + "'"
    readonly property string cpuTempCmd: tempsScript + " cpu"
    readonly property string gpuTempCmd: tempsScript + " gpu"
    readonly property string gpuAppsCmd: tempsScript + " gpuapps"
    readonly property string onTimeScript: "sh '" + Qt.resolvedUrl("../code/ontime.sh").toString().replace("file://", "") + "'"
    // Топ программ по CPU — запускается только пока открыто окошко
    readonly property string topCmd: "sh '" + Qt.resolvedUrl("../code/topcpu.sh").toString().replace("file://", "") + "'"

    // Событие от PowerDevil/UPower, без опроса
    readonly property bool pluggedIn: {
        const ac = pm.data["AC Adapter"]
        return ac ? !!ac["Plugged in"] : false
    }

    property real watts: NaN
    property int percent: -1
    property real hoursLeft: NaN
    property real energyNow: NaN    // Вт·ч сейчас
    property real energyFull: NaN   // Вт·ч при полном заряде (текущая ёмкость)
    property real energyDesign: NaN // Вт·ч паспортная ёмкость
    property var samples: []        // [{t, w}] за последний час
    property real avgWatts: NaN
    property var topApps: []        // [{cpu, name}]
    property real nowMs: Date.now() // обновляется с каждым чтением батареи
    // С последнего отключения зарядки (из ontime.sh): когда отключили и сколько
    // секунд реально проработал без сна и выключений — на момент onTimeAt
    property real unpluggedAt: NaN
    property real onBatterySec: NaN
    property real onTimeAt: 0
    property bool onBatteryApprox: false  // данных не хватило — это оценка снизу
    property int unpluggedPercent: -1     // заряд в момент отключения
    // Когда виджет сам видел, как выдернули шнур (unix-секунды, 0 — не видел).
    // Точнее истории UPower: при лимите заряда батарея иногда ненадолго пишет
    // «разряжается» со шнуром.
    // Засчитываем, только если шнур перед этим был воткнут хотя бы минуту: мгновенные
    // «подключили-отключили» бывают ложными — например, когда asusd при запуске заново
    // пишет лимит заряда, и питание на долю секунды «мигает».
    readonly property int minPluggedSec: 60
    property real pluggedSince: 0   // unix-секунды, 0 — не видели подключения
    property real liveUnplug: 0

    property real cpuTemp: NaN
    property string gpuTemp: ""     // градусы, "off" — выключена, "sleep" — спит, "?" — не ответила
    property real gpuMemUsed: NaN   // МиБ, только когда NVIDIA работает
    property real gpuMemTotal: NaN
    property var gpuApps: []        // [{mib, name}] — кто занимает память NVIDIA
    property bool gpuAppsKnown: false  // список хоть раз получен (иначе «считаю…»)
    readonly property bool gpuOn: /^[0-9]+$/.test(gpuTemp)

    readonly property bool wantTop: expanded

    function fmt(w) { return isNaN(w) ? "— W" : w.toFixed(1) + " W" }
    // Для узкого столбика: не больше трёх знаков. Точное значение есть в окошке по клику
    function fmtShort(w) { return isNaN(w) ? "—" : w < 10 ? w.toFixed(1) : String(Math.round(w)) }

    function tempColor(t) {
        if (t >= 90) return Kirigami.Theme.negativeTextColor
        if (t >= 75) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.textColor
    }
    function gpuText(full) {
        if (gpuTemp === "sleep") return full ? "спит" : "сон"
        if (gpuTemp === "" || gpuTemp === "?") return "—"
        return gpuTemp
    }

    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.icon: "battery-discharging"
    preferredRepresentation: compactRepresentation

    // Подсказки при наведении нет — всё в окошке по клику
    toolTipMainText: ""
    toolTipSubText: ""

    onPluggedInChanged: {
        if (pluggedIn) {
            watts = NaN; avgWatts = NaN; topApps = []; unpluggedAt = NaN; onBatterySec = NaN
            pluggedSince = Math.floor(Date.now() / 1000)
        } else if (pluggedSince > 0) {
            const now = Math.floor(Date.now() / 1000)
            if (now - pluggedSince >= minPluggedSec) liveUnplug = now
            pluggedSince = 0
        }
    }

    P5Support.DataSource {
        id: pm
        engine: "powermanagement"
        connectedSources: ["AC Adapter"]
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source === root.readCmd) root.parse(data["stdout"])
            else if (source === root.topCmd) root.parseTop(data["stdout"])
            else if (source === root.cpuTempCmd) root.cpuTemp = parseInt(data["stdout"])
            else if (source === root.gpuTempCmd) root.parseGpu(data["stdout"])
            else if (source === root.gpuAppsCmd) root.parseGpuApps(data["stdout"])
            else if (source.startsWith(root.onTimeScript)) root.parseOnTime(data["stdout"])
        }
    }

    function parse(text) {
        const v = {}
        for (const line of text.split("\n")) {
            const i = line.indexOf("=")
            if (i > 0) v[line.slice(0, i).replace("POWER_SUPPLY_", "")] = line.slice(i + 1)
        }
        const num = k => v[k] !== undefined ? Math.abs(Number(v[k])) : NaN

        // Энергия в Вт·ч: energy_* (мкВт·ч), иначе charge_* (мкА·ч) × номинальное напряжение
        const volts = (num("VOLTAGE_MIN_DESIGN") || num("VOLTAGE_NOW")) / 1e6
        const wh = k => !isNaN(num("ENERGY_" + k)) ? num("ENERGY_" + k) / 1e6 : num("CHARGE_" + k) / 1e6 * volts
        energyNow = wh("NOW")
        energyFull = wh("FULL")
        energyDesign = wh("FULL_DESIGN")
        percent = v.CAPACITY !== undefined ? Number(v.CAPACITY) : -1

        if (v.STATUS !== "Discharging") { watts = NaN; hoursLeft = NaN; return }

        // power_now в мкВт; иначе ток (мкА) × напряжение (мкВ)
        let w = num("POWER_NOW") / 1e6
        if (isNaN(w)) w = num("CURRENT_NOW") * num("VOLTAGE_NOW") / 1e12
        watts = w
        nowMs = Date.now()

        // Оставшееся время: energy_now (мкВт·ч) / мощность, или charge_now (мкА·ч) / ток
        if (!isNaN(num("ENERGY_NOW")) && w > 0) hoursLeft = num("ENERGY_NOW") / 1e6 / w
        else if (!isNaN(num("CHARGE_NOW")) && num("CURRENT_NOW") > 0) hoursLeft = num("CHARGE_NOW") / num("CURRENT_NOW")
        else hoursLeft = NaN

        if (!isNaN(w)) {
            const now = Date.now()
            const s = samples.filter(x => now - x.t < historyWindow)
            s.push({ t: now, w: w })
            samples = s
            const recent = s.filter(x => now - x.t < avgWindow)
            avgWatts = recent.reduce((a, x) => a + x.w, 0) / recent.length
        }
    }

    function parseOnTime(text) {
        const f = text.trim().split(" ")
        const ok = f.length === 4
        unpluggedAt = ok ? Number(f[0]) * 1000 : NaN
        onBatterySec = ok ? Number(f[1]) : NaN
        onBatteryApprox = ok && f[2] === "1"
        unpluggedPercent = ok ? Number(f[3]) : -1
        onTimeAt = Date.now()
        // Только что выдернули — UPower мог ещё не записать, спросим чуть позже
        if (!ok && !pluggedIn) onTimeRetry.restart()
    }
    function queryOnTime() {
        executable.connectSource(onTimeScript + " " + liveUnplug)
    }

    function parseGpu(text) {
        const f = text.trim().split(" ")
        // Драйвер может отдать температуру с сотыми ("38.43") — округляем до целых
        gpuTemp = /^[0-9]+(\.[0-9]+)?$/.test(f[0]) ? String(Math.round(Number(f[0]))) : (f[0] || "")
        gpuMemUsed = f.length === 3 ? Number(f[1]) : NaN
        gpuMemTotal = f.length === 3 ? Number(f[2]) : NaN
        if (!gpuOn) { gpuApps = []; gpuAppsKnown = false }
    }

    function parseGpuApps(text) {
        gpuAppsKnown = true
        gpuApps = text.split("\n").filter(s => s).map(line => {
            const i = line.indexOf(" ")
            return { mib: Number(line.slice(0, i)), name: line.slice(i + 1) }
        })
    }

    // Память: до гигабайта — в МБ, дальше — в ГБ с десятыми
    function fmtMem(mib, short) {
        if (isNaN(mib)) return ""
        if (mib < (short ? 1000 : 1024)) return Math.round(mib) + (short ? "M" : " МБ")
        return (mib / 1024).toFixed(1) + (short ? "G" : " ГБ")
    }

    function parseTop(text) {
        topApps = text.split("\n").filter(s => s).map(line => {
            const i = line.indexOf(" ")
            return { cpu: Number(line.slice(0, i)), name: line.slice(i + 1) }
        }).filter(a => a.cpu > 0)
    }

    Timer {
        // На сети батарею читаем раз в 30 с — ради процента для батарейки на панели,
        // а пока открыто окошко — как обычно
        interval: root.pluggedIn && !root.expanded ? 30000 : root.interval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.readCmd)
    }

    // Температуры на панели — всегда. GPU реже: nvidia-smi тяжелее, чем чтение sysfs.
    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.cpuTempCmd)
    }
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.gpuTempCmd)
    }
    // Кто занимает память GPU — только пока открыто окошко и карта не спит
    Timer {
        interval: 3000
        running: root.expanded && root.gpuOn
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.gpuAppsCmd)
    }

    // Сам скрипт меряет 1 секунду, плюс пауза — итого замер раз в ~3 с, только пока открыто окошко
    Timer {
        interval: 2000
        running: root.wantTop
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.topCmd)
    }

    // Время от батареи: журнал и история UPower — только пока открыто окошко, раз в минуту.
    // Между замерами досчитываем по часам: с открытым окошком ноутбук точно не спит.
    Timer {
        interval: 60000
        running: root.expanded && !root.pluggedIn
        repeat: true
        triggeredOnStart: true
        onTriggered: root.queryOnTime()
    }
    Timer {
        id: onTimeRetry
        interval: 5000
        running: false
        onTriggered: if (root.expanded && !root.pluggedIn) root.queryOnTime()
    }

    // На панели: температуры всегда, ватты — только от батареи
    // Всё в строке панели — по одной базовой линии цифр
    component PanelLabel: PlasmaComponents.Label {
        Layout.alignment: Qt.AlignBaseline
        font.features: { "tnum": 1 }   // цифры одинаковой ширины — текст не дёргается
    }

    component PanelValue: RowLayout {
        property string name
        property string value
        property string extra           // ещё одно значение рядом, обычным цветом
        property color color: Kirigami.Theme.textColor
        spacing: Kirigami.Units.smallSpacing
        Layout.alignment: Qt.AlignBaseline
        baselineOffset: valueLabel.y + valueLabel.baselineOffset
        // Подпись тем же шрифтом, что и число, только приглушённая — стоят на одной линии
        PanelLabel { text: parent.name; opacity: 0.6 }
        PanelLabel { id: valueLabel; text: parent.value; color: parent.color }
        PanelLabel { visible: text !== ""; text: parent.extra }
    }

    compactRepresentation: MouseArea {
        id: compact
        readonly property real padding: Kirigami.Units.smallSpacing * 3
        // Зазор до соседей вдоль панели, чтобы рамки не слипались
        readonly property real tileMargin: Kirigami.Units.smallSpacing / 2
        readonly property real thickness: root.vertical ? width : height
        readonly property real tileSize: Math.round(thickness * (root.vertical ? 0.92 : 0.8))
        hoverEnabled: true

        // Вдоль панели размер ровно по содержимому, поперёк (-1) его задаёт сама панель
        readonly property real panelWidth: root.vertical ? -1 : panelRow.implicitWidth + padding + tileMargin * 2
        readonly property real panelHeight: root.vertical ? panelColumn.implicitHeight + padding + tileMargin * 2 : -1

        Layout.minimumWidth: panelWidth
        Layout.preferredWidth: panelWidth
        Layout.maximumWidth: panelWidth
        Layout.minimumHeight: panelHeight
        Layout.preferredHeight: panelHeight
        Layout.maximumHeight: panelHeight
        onClicked: root.expanded = !root.expanded

        // Плашка под значениями: только тонкая рамка, как у соседних виджетов
        Rectangle {
            readonly property bool lit: root.expanded || compact.containsMouse
            readonly property real crossMargin: Math.round((compact.thickness - compact.tileSize) / 2)
            anchors.fill: parent
            // Поперёк панели — тот же размер, что у соседей, вдоль — небольшой зазор до них
            anchors.topMargin: root.vertical ? compact.tileMargin : crossMargin
            anchors.bottomMargin: anchors.topMargin
            anchors.leftMargin: root.vertical ? crossMargin : compact.tileMargin
            anchors.rightMargin: anchors.leftMargin
            radius: Math.round(compact.tileSize * 0.27)
            color: "transparent"
            border.width: 1
            border.color: root.tint(Kirigami.Theme.textColor, lit ? 0.42 : 0.22)
            Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
        }

        VerticalStats {
            id: panelColumn
            visible: root.vertical
            anchors.centerIn: parent
            tile: compact.tileSize
            cpu: isNaN(root.cpuTemp) ? "—" : String(root.cpuTemp)
            cpuColor: root.tempColor(root.cpuTemp)
            gpuShown: root.gpuTemp !== "off"
            gpu: root.gpuText(false)
            // Спящая GPU — состояние, а не измерение, поэтому приглушена
            gpuColor: root.gpuOn ? root.tempColor(Number(root.gpuTemp))
                                 : root.tint(Kirigami.Theme.textColor, 0.6)
            gpuMem: root.gpuOn ? root.fmtMem(root.gpuMemUsed, true) : ""
            wattsShown: !root.pluggedIn
            watts: root.fmtShort(root.watts)
            percent: root.percent
        }

        RowLayout {
            id: panelRow
            visible: !root.vertical
            anchors.centerIn: parent
            spacing: Kirigami.Units.largeSpacing

            PanelValue {
                name: "CPU"
                value: isNaN(root.cpuTemp) ? "—" : String(root.cpuTemp)
                color: root.tempColor(root.cpuTemp)
            }
            PanelValue {
                visible: root.gpuTemp !== "off"   // выключенную NVIDIA не показываем вовсе
                name: "GPU"
                value: root.gpuText(false)
                color: root.tempColor(Number(root.gpuTemp))
                extra: root.gpuOn ? root.fmtMem(root.gpuMemUsed, true) : ""
            }
            PanelLabel {
                visible: !root.pluggedIn
                text: root.fmt(root.watts)
            }
            // 20% и меньше — значок батарейки и число процентов рядом. Только по проценту:
            // и на батарее, и на зарядке, пока не наберётся больше 20%
            RowLayout {
                id: lowBattery
                visible: root.percent >= 0 && root.percent <= 20
                spacing: Kirigami.Units.smallSpacing
                Layout.alignment: Qt.AlignBaseline
                baselineOffset: lowPercent.y + lowPercent.baselineOffset

                LowBattery {
                    level: root.percent
                    Layout.alignment: Qt.AlignBaseline
                }
                PanelLabel { id: lowPercent; text: root.percent }
            }
        }
    }

    fullRepresentation: Details {}

    FontMetrics { id: metrics; font: Kirigami.Theme.defaultFont }
    FontMetrics { id: smallMetrics; font: Kirigami.Theme.smallFont }

    // Прозрачность фона окошка (1 — непрозрачный)
    readonly property real popupOpacity: 0.8

    // Фон окна Plasma рисует сама (svg «dialogs/background» прямо в окне),
    // своего API для прозрачности нет — находим этот элемент.
    function backgrounds(win) {
        const out = []
        if (!win || !win.contentItem) return out
        const walk = (item, depth) => {
            for (const c of item.children) {
                if (c.imagePath !== undefined && String(c.imagePath).indexOf("background") >= 0) out.push(c)
                else if (depth < 2) walk(c, depth + 1)
            }
        }
        walk(win.contentItem, 0)
        return out
    }

    // Те же пороги и цвета, что у батарейки на панели: 20–11% жёлтый, 10–0% красный
    function levelColor(p) {
        if (p < 0) return Kirigami.Theme.disabledTextColor
        if (p <= 10) return "#ff4d4d"
        if (p <= 20) return "#f7d038"
        return Kirigami.Theme.positiveTextColor
    }
    function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // Мелкая приглушённая подпись
    component Caption: PlasmaComponents.Label {
        Layout.preferredHeight: smallMetrics.height
        font: Kirigami.Theme.smallFont
        opacity: 0.65
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    // Полупрозрачная плашка-подложка
    component Card: Rectangle {
        radius: Kirigami.Units.cornerRadius
        color: root.tint(Kirigami.Theme.textColor, 0.06)
        border.width: 1
        border.color: root.tint(Kirigami.Theme.textColor, 0.08)
    }

    // Плитка: подпись сверху, значение крупно
    component Stat: Card {
        id: stat
        property string label
        property string value
        property color accent: Kirigami.Theme.textColor
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        implicitHeight: statCol.implicitHeight + Kirigami.Units.smallSpacing * 3

        ColumnLayout {
            id: statCol
            anchors {
                left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                leftMargin: Kirigami.Units.largeSpacing; rightMargin: Kirigami.Units.smallSpacing
            }
            spacing: 0
            Caption { Layout.fillWidth: true; text: stat.label }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                Layout.preferredHeight: metrics.height
                text: stat.value || "—"
                color: stat.accent
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    // Строка списка «кто грузит»: имя, значение справа и полоска-подложка по доле
    component UsageRow: Item {
        id: usage
        property string name
        property string value
        property real fraction: 0
        Layout.fillWidth: true
        Layout.preferredHeight: metrics.height + Kirigami.Units.smallSpacing

        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: usage.name ? Math.max(radius * 2, parent.width * Math.min(1, usage.fraction)) : 0
            radius: Kirigami.Units.cornerRadius / 2
            color: root.tint(Kirigami.Theme.highlightColor, 0.25)
            Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
        }
        RowLayout {
            anchors {
                fill: parent
                leftMargin: Kirigami.Units.smallSpacing; rightMargin: Kirigami.Units.smallSpacing
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: usage.name
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            PlasmaComponents.Label {
                text: usage.value
                opacity: 0.75
                font.features: { "tnum": 1 }
            }
        }
    }

    // Содержимое окошка по клику. Размер фиксированный: у каждой строки
    // своя высота, длинный текст обрезается, график на месте даже без данных.
    component Details: Item {
        id: details
        readonly property real fixedWidth: Kirigami.Units.gridUnit * 20

        implicitWidth: fixedWidth
        implicitHeight: col.implicitHeight + Kirigami.Units.smallSpacing * 2
        Layout.minimumWidth: fixedWidth
        Layout.maximumWidth: fixedWidth
        Layout.preferredWidth: fixedWidth
        Layout.minimumHeight: implicitHeight
        Layout.maximumHeight: implicitHeight
        Layout.preferredHeight: implicitHeight

        function applyOpacity() {
            for (const bg of root.backgrounds(Window.window)) bg.opacity = root.popupOpacity
        }
        Window.onWindowChanged: applyOpacity()
        onVisibleChanged: if (visible) applyOpacity()
        Component.onCompleted: applyOpacity()

        ColumnLayout {
            id: col
            x: 0; y: Kirigami.Units.smallSpacing
            width: details.fixedWidth
            spacing: Kirigami.Units.largeSpacing

            // ── Шапка: крупные ватты слева, процент справа
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Layout.alignment: Qt.AlignVCenter
                    source: root.pluggedIn ? "battery-ac-adapter" : "battery-discharging"
                }

                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true
                    Caption {
                        Layout.fillWidth: true
                        text: root.pluggedIn ? "Работает от сети" : "Расход от батареи"
                    }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing / 2
                        PlasmaComponents.Label {
                            text: isNaN(root.watts) ? "—" : root.watts.toFixed(1)
                            font.pixelSize: Kirigami.Units.gridUnit * 1.6
                            font.weight: Font.Bold
                            font.features: { "tnum": 1 }
                        }
                        PlasmaComponents.Label {
                            Layout.alignment: Qt.AlignBaseline
                            text: "W"
                            opacity: 0.7
                        }
                    }
                }

                ColumnLayout {
                    spacing: 0
                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                    Caption { Layout.alignment: Qt.AlignRight; text: "Заряд" }
                    PlasmaComponents.Label {
                        Layout.alignment: Qt.AlignRight
                        text: root.percent >= 0 ? root.percent + "%" : "—"
                        color: root.levelColor(root.percent)
                        font.pixelSize: Kirigami.Units.gridUnit * 1.6
                        font.weight: Font.Bold
                        font.features: { "tnum": 1 }
                    }
                }
            }

            // ── Полоска заряда
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: -Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.smallSpacing * 2
                    radius: height / 2
                    color: root.tint(Kirigami.Theme.textColor, 0.12)

                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        width: Math.max(height, parent.width * Math.max(0, root.percent) / 100)
                        visible: root.percent >= 0
                        color: root.levelColor(root.percent)
                        Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Caption {
                        Layout.fillWidth: true
                        text: isNaN(root.energyNow) ? "" : root.energyNow.toFixed(1) + " Wh в батарее"
                    }
                    Caption {
                        text: {
                            if (isNaN(root.hoursLeft) || root.hoursLeft <= 0) return ""
                            const h = Math.floor(root.hoursLeft), m = Math.round((root.hoursLeft - h) * 60)
                            return "≈ " + h + " ч " + m + " мин до разряда"
                        }
                    }
                }
            }

            // ── Плитки 2×2
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                Stat {
                    Layout.columnSpan: root.gpuTemp === "off" ? 2 : 1
                    label: "Температура CPU"
                    value: isNaN(root.cpuTemp) ? "" : root.cpuTemp + " °C"
                    accent: root.tempColor(root.cpuTemp)
                }
                Stat {
                    visible: root.gpuTemp !== "off"
                    label: root.gpuOn ? "GPU (NVIDIA) · память" : "Температура GPU (NVIDIA)"
                    value: root.gpuOn ? root.gpuTemp + " °C · " + root.fmtMem(root.gpuMemUsed)
                                        + (isNaN(root.gpuMemTotal) ? "" : " / " + (root.gpuMemTotal / 1024).toFixed(0) + " ГБ")
                                      : root.gpuText(true)
                    accent: root.tempColor(Number(root.gpuTemp))
                }
                Stat {
                    label: "Среднее за минуту"
                    value: isNaN(root.avgWatts) ? "" : root.fmt(root.avgWatts)
                }
                Stat {
                    label: "Осталось времени"
                    value: {
                        if (isNaN(root.hoursLeft) || root.hoursLeft <= 0) return ""
                        const h = Math.floor(root.hoursLeft), m = Math.round((root.hoursLeft - h) * 60)
                        return h + " ч " + m + " мин"
                    }
                }
                Stat {
                    label: "Энергия сейчас"
                    value: isNaN(root.energyNow) ? "" : root.energyNow.toFixed(1) + " Wh"
                }
                Stat {
                    readonly property real health: root.energyDesign > 0 ? root.energyFull / root.energyDesign * 100 : NaN
                    label: isNaN(health) ? "Ёмкость" : "Ёмкость · " + Math.round(health) + "% от новой"
                    value: {
                        if (isNaN(root.energyFull)) return ""
                        return root.energyFull.toFixed(1) + (root.energyDesign > 0 ? " из " + root.energyDesign.toFixed(1) : "") + " Wh"
                    }
                    accent: isNaN(health) || health >= 70 ? Kirigami.Theme.textColor
                                                          : health >= 50 ? Kirigami.Theme.neutralTextColor
                                                                         : Kirigami.Theme.negativeTextColor
                }
                Stat {
                    readonly property real since: root.unpluggedAt
                    Layout.columnSpan: 2
                    label: {
                        if (isNaN(since)) return "Работает от батареи, без сна"
                        const d = new Date(since), today = new Date(root.nowMs).toDateString() === d.toDateString()
                        return "Работает от батареи, без сна · отключили " + Qt.formatDateTime(d, today ? "в hh:mm" : "d MMM в hh:mm")
                               + (root.unpluggedPercent >= 0 ? " при " + root.unpluggedPercent + "%" : "")
                    }
                    value: {
                        if (root.pluggedIn) return "на зарядке"
                        if (isNaN(root.onBatterySec)) return ""
                        const sec = root.onBatterySec + Math.max(0, root.nowMs - root.onTimeAt) / 1000
                        const min = Math.floor(sec / 60)
                        if (min < 1) return "меньше минуты"
                        const h = Math.floor(min / 60), m = min % 60
                        return (root.onBatteryApprox ? "не меньше " : "") + (h ? h + " ч " + m + " мин" : m + " мин")
                    }
                }
            }

            // ── График за последний час
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 7.5

                Caption {
                    id: chartTitle
                    anchors { left: parent.left; top: parent.top; margins: Kirigami.Units.smallSpacing * 2 }
                    text: "Последний час"
                }
                Caption {
                    anchors { right: parent.right; top: parent.top; margins: Kirigami.Units.smallSpacing * 2 }
                    text: "до " + plot.maxW + " W"
                }

                Item {
                    id: plot
                    anchors {
                        left: parent.left; right: parent.right
                        top: chartTitle.bottom; bottom: axis.top
                        leftMargin: Kirigami.Units.smallSpacing * 2; rightMargin: Kirigami.Units.smallSpacing * 2
                        topMargin: Kirigami.Units.smallSpacing; bottomMargin: Kirigami.Units.smallSpacing / 2
                    }

                    readonly property real maxW: {
                        let m = 0
                        for (const s of root.samples) m = Math.max(m, s.w)
                        return Math.max(5, Math.ceil(m / 5) * 5)
                    }

                    Canvas {
                        id: chart
                        anchors.fill: parent
                        property real maxW: parent.maxW
                        onMaxWChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        Connections {
                            target: root
                            function onSamplesChanged() { if (chart.visible) chart.requestPaint() }
                        }
                        onVisibleChanged: if (visible) requestPaint()

                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            const pad = 3   // место под точку на конце
                            const W = width - pad, H = height - pad
                            const now = Date.now(), from = now - root.historyWindow
                            const x = t => (t - from) / root.historyWindow * W
                            const y = w => pad + H - w / maxW * H
                            const c = Kirigami.Theme.highlightColor
                            const grid = Kirigami.Theme.textColor

                            // Сетка: пунктир по четвертям
                            ctx.strokeStyle = Qt.rgba(grid.r, grid.g, grid.b, 0.12)
                            ctx.lineWidth = 1
                            if (ctx.setLineDash) ctx.setLineDash([2, 4])
                            ctx.beginPath()
                            for (let i = 1; i < 4; i++) {
                                const gy = Math.round(pad + H * i / 4) + 0.5
                                ctx.moveTo(0, gy); ctx.lineTo(width, gy)
                            }
                            ctx.stroke()
                            if (ctx.setLineDash) ctx.setLineDash([])
                            ctx.strokeStyle = Qt.rgba(grid.r, grid.g, grid.b, 0.2)
                            ctx.beginPath()
                            ctx.moveTo(0, height - 0.5); ctx.lineTo(width, height - 0.5)
                            ctx.stroke()

                            // Разбиваем на куски там, где был перерыв (зарядка, сон)
                            const gap = root.interval * 5
                            const runs = []
                            let cur = []
                            for (const s of root.samples) {
                                if (cur.length && s.t - cur[cur.length - 1].t > gap) { runs.push(cur); cur = [] }
                                cur.push(s)
                            }
                            if (cur.length) runs.push(cur)

                            const grad = ctx.createLinearGradient(0, 0, 0, height)
                            grad.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.45))
                            grad.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0.02))

                            for (const run of runs) {
                                ctx.beginPath()
                                ctx.moveTo(x(run[0].t), height)
                                for (const s of run) ctx.lineTo(x(s.t), y(s.w))
                                ctx.lineTo(x(run[run.length - 1].t), height)
                                ctx.closePath()
                                ctx.fillStyle = grad
                                ctx.fill()

                                ctx.beginPath()
                                run.forEach((s, i) => i ? ctx.lineTo(x(s.t), y(s.w)) : ctx.moveTo(x(s.t), y(s.w)))
                                ctx.strokeStyle = c
                                ctx.lineWidth = 1.5
                                ctx.lineJoin = "round"
                                ctx.stroke()
                            }

                            // Точка на последнем значении
                            const last = root.samples[root.samples.length - 1]
                            if (last && now - last.t < gap) {
                                ctx.beginPath()
                                ctx.arc(x(last.t), y(last.w), 3, 0, Math.PI * 2)
                                ctx.fillStyle = c
                                ctx.fill()
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        anchors.centerIn: parent
                        visible: root.samples.length < 2
                        text: "Пока нет данных"
                        opacity: 0.5
                    }
                }

                RowLayout {
                    id: axis
                    anchors {
                        left: parent.left; right: parent.right; bottom: parent.bottom
                        leftMargin: Kirigami.Units.smallSpacing * 2; rightMargin: Kirigami.Units.smallSpacing * 2
                        bottomMargin: Kirigami.Units.smallSpacing
                    }
                    Caption { text: "−60 мин" }
                    Item { Layout.fillWidth: true }
                    Caption { text: "−30" }
                    Item { Layout.fillWidth: true }
                    Caption { text: "сейчас" }
                }
            }

            // ── Кто грузит CPU
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                Caption {
                    Layout.fillWidth: true
                    text: root.topApps.length ? "Больше всего грузят CPU" : "Больше всего грузят CPU: считаю…"
                }
                Repeater {
                    model: 3
                    UsageRow {
                        required property int index
                        readonly property var app: root.topApps[index]
                        name: app ? app.name : ""
                        value: app ? app.cpu + "%" : ""
                        fraction: app ? app.cpu / 100 : 0
                    }
                }
            }

            // ── Кто занимает память GPU — только когда NVIDIA работает
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.gpuOn
                spacing: Kirigami.Units.smallSpacing / 2

                Caption {
                    Layout.fillWidth: true
                    text: root.gpuApps.length ? "Память GPU занимают"
                        : root.gpuAppsKnown ? "Память GPU занимают: никто" : "Память GPU занимают: считаю…"
                }
                Repeater {
                    model: 3
                    UsageRow {
                        required property int index
                        readonly property var app: root.gpuApps[index]
                        name: app ? app.name : ""
                        value: app ? root.fmtMem(app.mib) : ""
                        fraction: app && root.gpuMemTotal > 0 ? app.mib / root.gpuMemTotal : 0
                    }
                }
            }
        }
    }
}
