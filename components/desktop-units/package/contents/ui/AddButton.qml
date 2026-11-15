import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

// Thin-outlined "+" tile that creates a new virtual desktop.
Item {
    id: button

    property real size: 24

    signal clicked()

    width: size
    height: size

    Rectangle {
        readonly property color ink: Kirigami.Theme.textColor
        anchors.fill: parent
        radius: Math.round(button.size * 0.27)
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(ink.r, ink.g, ink.b, area.containsMouse ? 0.42 : 0.22)
        Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
    }

    Item {
        id: plus
        readonly property real len: Math.round(button.size * 0.4)
        readonly property real thick: Math.max(1, Math.round(button.size * 0.05))
        anchors.centerIn: parent
        width: len
        height: len
        rotation: area.containsMouse ? 90 : 0
        scale: area.pressed ? 0.8 : 1
        opacity: area.containsMouse ? 1 : 0.55
        Behavior on rotation { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutBack } }
        Behavior on scale { NumberAnimation { duration: Kirigami.Units.shortDuration } }
        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

        Rectangle {
            anchors.centerIn: parent
            width: plus.len
            height: plus.thick
            radius: height / 2
            color: Kirigami.Theme.textColor
        }
        Rectangle {
            anchors.centerIn: parent
            width: plus.thick
            height: plus.len
            radius: width / 2
            color: Kirigami.Theme.textColor
        }
    }

    PlasmaCore.ToolTipArea {
        anchors.fill: parent
        mainText: i18n("Новый рабочий стол")

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
