import QtQuick
import org.kde.kirigami as Kirigami

// Значок низкого заряда для панели: батарейка высотой с цифры текста на панели.
// Рамка — жёлтая (20–11%) или красная (10–0%), чуть приглушённая; внутри — тот же
// цвет, но темнее. Число процентов стоит рядом обычным текстом (в main.qml).
Item {
    id: bat

    property int level: 20
    readonly property bool critical: level <= 10

    property color paper: Kirigami.Theme.backgroundColor
    property font font: Kirigami.Theme.defaultFont
    // Свои жёлтый и красный: «внимание» в теме бывает оранжевым
    readonly property color yellow: "#f7d038"
    readonly property color red: "#ff4d4d"
    readonly property color accent: critical ? red : yellow
    // Смешиваем с фоном, а не прозрачностью — цвета получаются ровными
    function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }
    readonly property color rim: mix(accent, paper, 0.3)
    readonly property color inside: mix(accent, paper, 0.7)

    // Высота — ровно с цифры текста на панели. Базовая линия — такая, чтобы при
    // выравнивании по ней значок встал вровень с цифрами.
    FontMetrics { id: panelFont; font: bat.font }
    readonly property rect digit: panelFont.tightBoundingRect("0")
    readonly property real h: Math.round(digit.height)
    baselineOffset: h / 2 - digit.y - digit.height / 2

    implicitHeight: h
    implicitWidth: Math.round(h * 1.8) + nub.width

    Rectangle {
        id: shell
        width: parent.width - nub.width
        height: parent.height
        radius: Math.max(1.5, height * 0.2)
        color: bat.inside
        border.width: 1.5
        border.color: bat.rim
    }
    Rectangle {
        id: nub
        anchors { left: shell.right; verticalCenter: shell.verticalCenter }
        width: Math.max(1.5, bat.h * 0.18); height: shell.height * 0.45
        radius: 0.8
        color: bat.rim
    }
}
