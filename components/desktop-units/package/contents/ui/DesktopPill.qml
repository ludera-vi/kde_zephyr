import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// One virtual desktop: a thin-outlined tile with its number and window dots.
Item {
    id: pill

    property int number: 1
    property string name: ""
    property bool active: false
    property int windows: 0
    property real size: 24
    property real stretch: 1.6
    property bool vertical: false
    property bool showDots: true

    signal activated()
    signal removeRequested()

    readonly property real major: Math.round(active ? size * stretch : size)
    readonly property bool hovered: area.containsMouse
    readonly property color fg: Kirigami.Theme.textColor

    width: vertical ? size : major
    height: vertical ? major : size

    Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic } }

    // Idle tile. The active look is the shared sliding highlight in main.qml.
    Rectangle {
        anchors.fill: parent
        radius: Math.round(pill.size * 0.27)
        color: "transparent"
        border.width: 1
        border.color: pill.tint(pill.hovered ? 0.42 : 0.22)
        opacity: pill.active ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
        Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
    }

    Item {
        id: content
        anchors.fill: parent
        scale: area.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutQuad } }

        PlasmaComponents.Label {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: dots.visible && !pill.active ? -Math.round(pill.size * 0.06) : 0
            text: pill.number
            renderType: Text.CurveRendering
            color: pill.fg
            opacity: pill.active || pill.hovered ? 1 : pill.windows > 0 ? 0.85 : 0.45
            font.pixelSize: Math.round(pill.size * 0.52)
            font.weight: pill.active ? Font.DemiBold : Font.Medium
            font.features: { "tnum": 1 }
            Behavior on color { ColorAnimation { duration: Kirigami.Units.longDuration } }
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.longDuration } }
            Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic } }
        }

        Row {
            id: dots
            readonly property real dot: Math.max(2, Math.round(pill.size * 0.09))
            visible: pill.showDots && pill.windows > 0
            opacity: pill.active ? 0 : 0.8
            spacing: Math.max(1, Math.round(dot * 0.7))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Math.round(pill.size * 0.1)
            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.longDuration } }

            Repeater {
                model: Math.min(pill.windows, 3)
                Rectangle {
                    width: dots.dot
                    height: dots.dot
                    radius: dots.dot / 2
                    color: Kirigami.Theme.highlightColor
                }
            }
        }
    }

    PlasmaCore.ToolTipArea {
        anchors.fill: parent
        mainText: pill.name || i18n("Рабочий стол %1", pill.number)
        subText: pill.windowsText(pill.windows) + "\n" + i18n("Средняя кнопка — удалить")

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: event => event.button === Qt.MiddleButton ? pill.removeRequested() : pill.activated()
        }
    }

    function tint(a) {
        const c = Kirigami.Theme.textColor
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    function windowsText(n) {
        if (n === 0)
            return i18n("Нет окон")
        const m10 = n % 10, m100 = n % 100
        if (m10 === 1 && m100 !== 11)
            return i18n("%1 окно", n)
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
            return i18n("%1 окна", n)
        return i18n("%1 окон", n)
    }
}
