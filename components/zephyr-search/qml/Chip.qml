import QtQuick
import org.kde.kirigami as Kirigami

// Toggle pill in the footer, e.g. "Весь компьютер  Ctrl+G".
Rectangle {
    id: chip

    property string text
    property string hint
    property string iconName
    property bool checked: false
    signal toggled()

    implicitWidth: row.implicitWidth + 20
    implicitHeight: 26
    radius: height / 2
    color: checked ? Qt.alpha(Kirigami.Theme.highlightColor, 0.35)
                   : hover.hovered ? Qt.alpha(Kirigami.Theme.textColor, 0.10) : Qt.alpha(Kirigami.Theme.textColor, 0.05)
    border.width: 1
    border.color: checked ? Qt.alpha(Kirigami.Theme.highlightColor, 0.8) : Qt.alpha(Kirigami.Theme.textColor, 0.10)

    Behavior on color { ColorAnimation { duration: 120 } }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Kirigami.Icon {
            source: chip.iconName
            width: 14; height: 14
            anchors.verticalCenter: parent.verticalCenter
            color: Kirigami.Theme.textColor
            isMask: true
        }
        Text {
            text: chip.text
            color: Kirigami.Theme.textColor
            font.pixelSize: 12
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: chip.hint
            color: Qt.alpha(Kirigami.Theme.textColor, 0.45)
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.toggled() }
}
