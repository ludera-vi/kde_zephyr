import QtQuick
import QtQuick.Effects
import QtQuick.Window
import org.kde.kirigami as Kirigami

Window {
    id: root

    readonly property int panelWidth: 740
    readonly property int maxListHeight: 440
    readonly property real radius: 18

    flags: Qt.FramelessWindowHint
    color: "transparent"
    visible: false
    title: "Zephyr Search"

    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.inherit: false

    Connections {
        target: zephyr
        function onShown() {
            input.text = zephyr.query
            input.forceActiveFocus()
            input.selectAll()
            list.currentIndex = 0
            list.hoverArmed = false
            hoverArm.restart()
            appear.restart()
        }
    }

    // Click outside the panel closes the launcher.
    MouseArea {
        anchors.fill: parent
        onClicked: zephyr.hide()
    }

    RectangularShadow {
        anchors.fill: panel
        radius: root.radius
        blur: 48
        spread: 0
        offset.y: 14
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: panel.opacity
        scale: panel.scale
    }

    Rectangle {
        id: panel

        x: Math.round((root.width - width) / 2)
        y: Math.round(root.height * 0.2)
        width: Math.min(root.panelWidth, root.width - 32)
        height: content.implicitHeight
        radius: root.radius
        clip: true

        // Translucent tint over KWin blur: the "dark glass" look, tinted by the colour scheme.
        color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.72)
        border.width: 1
        border.color: Qt.alpha(Kirigami.Theme.textColor, 0.12)

        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        onXChanged: updateBlur()
        onYChanged: updateBlur()
        onWidthChanged: updateBlur()
        onHeightChanged: updateBlur()
        function updateBlur() { zephyr.setBlurRect(x, y, width, height, radius) }

        // Soft highlight along the top edge, like light on glass.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 90
            radius: root.radius
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha("white", 0.07) }
                GradientStop { position: 1; color: "transparent" }
            }
        }

        MouseArea { anchors.fill: parent } // swallow clicks so they don't close the panel

        ParallelAnimation {
            id: appear
            NumberAnimation { target: panel; property: "opacity"; from: 0; to: 1; duration: 130; easing.type: Easing.OutCubic }
            NumberAnimation { target: panel; property: "scale"; from: 0.97; to: 1; duration: 160; easing.type: Easing.OutCubic }
        }

        Column {
            id: content
            width: parent.width

            // ── Search field ───────────────────────────────────────────
            Item {
                width: parent.width
                height: 64

                Kirigami.Icon {
                    id: searchIcon
                    source: "search"
                    width: 22; height: 22
                    anchors { left: parent.left; leftMargin: 22; verticalCenter: parent.verticalCenter }
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.7)
                    isMask: true
                }

                TextInput {
                    id: input
                    anchors { left: searchIcon.right; leftMargin: 14; right: spinner.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    font.pixelSize: 21
                    color: Kirigami.Theme.textColor
                    selectionColor: Kirigami.Theme.highlightColor
                    selectedTextColor: Kirigami.Theme.highlightedTextColor
                    clip: true
                    focus: true
                    onTextEdited: zephyr.query = text

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !input.text
                        text: zephyr.content ? "Искать текст внутри файлов…" : "Приложения, настройки, файлы и папки…"
                        color: Qt.alpha(Kirigami.Theme.textColor, 0.38)
                        font: input.font
                    }

                    Keys.onPressed: (event) => {
                        const ctrl = event.modifiers & Qt.ControlModifier
                        if (event.key === Qt.Key_Escape) {
                            if (input.text) { input.text = ""; zephyr.query = "" } else zephyr.hide()
                        } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) {
                            list.move(1)
                        } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) {
                            list.move(-1)
                        } else if (event.key === Qt.Key_PageDown) {
                            list.move(8)
                        } else if (event.key === Qt.Key_PageUp) {
                            list.move(-8)
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            zephyr.activate(list.currentIndex, ctrl)
                        } else if (ctrl && event.key === Qt.Key_G) {
                            zephyr.wholeSystem = !zephyr.wholeSystem
                        } else if (ctrl && event.key === Qt.Key_H) {
                            zephyr.hidden = !zephyr.hidden
                        } else if (ctrl && event.key === Qt.Key_F) {
                            zephyr.content = !zephyr.content
                        } else {
                            return
                        }
                        event.accepted = true
                    }
                }

                // Small pulsing dot while files are still being searched.
                Rectangle {
                    id: spinner
                    width: 8; height: 8; radius: 4
                    anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
                    color: Kirigami.Theme.highlightColor
                    opacity: zephyr.busy ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    SequentialAnimation on scale {
                        running: zephyr.busy
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.6; to: 1.2; duration: 450; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.2; to: 0.6; duration: 450; easing.type: Easing.InOutSine }
                    }
                }
            }

            Rectangle {
                width: parent.width; height: 1
                color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
                visible: list.count > 0
            }

            // ── Results ────────────────────────────────────────────────
            ListView {
                id: list
                width: parent.width
                height: count > 0 ? Math.min(contentHeight + 16, root.maxListHeight) : 0
                topMargin: 8; bottomMargin: 8
                clip: true
                model: zephyr.results
                currentIndex: 0
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: false

                function move(step) {
                    if (count === 0) return
                    currentIndex = Math.max(0, Math.min(count - 1, currentIndex + step))
                }

                onCountChanged: if (currentIndex < 0 || currentIndex >= count) currentIndex = 0

                section.property: "section"
                section.delegate: Text {
                    required property string section
                    width: ListView.view.width
                    leftPadding: 22
                    topPadding: 8; bottomPadding: 4
                    text: section.toUpperCase()
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.45)
                }

                property bool hoverArmed: false
                Timer { id: hoverArm; interval: 350; onTriggered: list.hoverArmed = true }

                delegate: Item {
                    id: row
                    required property int index
                    required property string title
                    required property string subtitle
                    required property string iconName
                    required property string detail
                    required property int kind
                    width: ListView.view.width
                    height: 50

                    // Subtitle with the searched text emphasised (only for text matches).
                    readonly property string richSubtitle: {
                        const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                        if (kind !== 4) return esc(subtitle)
                        const q = zephyr.query.trim()
                        const i = q ? subtitle.toLowerCase().indexOf(q.toLowerCase()) : -1
                        if (i < 0) return esc(subtitle)
                        return esc(subtitle.slice(0, i)) + "<font color=\"" + Kirigami.Theme.highlightColor + "\"><b>"
                            + esc(subtitle.slice(i, i + q.length)) + "</b></font>" + esc(subtitle.slice(i + q.length))
                    }

                    Rectangle {
                        anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                        radius: 10
                        visible: list.currentIndex === row.index
                        color: Qt.alpha(Kirigami.Theme.highlightColor, 0.28)
                        border.width: 1
                        border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.5)
                    }

                    Kirigami.Icon {
                        id: icon
                        source: row.iconName || "unknown"
                        width: 30; height: 30
                        anchors { left: parent.left; leftMargin: 22; verticalCenter: parent.verticalCenter }
                    }

                    Column {
                        anchors { left: icon.right; leftMargin: 14; right: parent.right; rightMargin: 22; verticalCenter: parent.verticalCenter }
                        spacing: 2

                        Item {
                            width: parent.width
                            height: titleText.height

                            Text {
                                id: titleText
                                width: Math.min(implicitWidth, parent.width - (detailText.visible ? detailText.width + 16 : 0))
                                text: row.title
                                textFormat: Text.PlainText
                                maximumLineCount: 1
                                color: Kirigami.Theme.textColor
                                font.pixelSize: 14
                                elide: Text.ElideRight
                            }
                            // Location of a text match, right-aligned on the title line.
                            Text {
                                id: detailText
                                anchors { right: parent.right; baseline: titleText.baseline }
                                width: Math.min(implicitWidth, parent.width * 0.5)
                                visible: text.length > 0
                                text: row.detail
                                textFormat: Text.PlainText
                                maximumLineCount: 1
                                color: Qt.alpha(Kirigami.Theme.textColor, 0.4)
                                font.pixelSize: 11
                                elide: Text.ElideLeft
                            }
                        }
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: row.richSubtitle
                            textFormat: Text.StyledText
                            maximumLineCount: 1
                            wrapMode: Text.NoWrap
                            color: Qt.alpha(Kirigami.Theme.textColor, 0.5)
                            font.pixelSize: 12
                            // Paths keep both ends visible; text snippets read from the start.
                            elide: row.kind === 4 ? Text.ElideRight : Text.ElideMiddle
                        }
                    }

                    HoverHandler {
                        onPointChanged: if (hovered && list.hoverArmed) list.currentIndex = row.index
                    }
                    TapHandler {
                        onTapped: (point) => zephyr.activate(row.index, point.modifiers & Qt.ControlModifier)
                    }
                }
            }

            Rectangle {
                width: parent.width; height: 1
                color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
            }

            // ── Footer: search scope toggles and key hints ─────────────
            Item {
                width: parent.width
                height: 44

                Row {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    spacing: 8
                    Chip {
                        text: zephyr.wholeSystem ? "Весь компьютер" : "Дом и диски"
                        iconName: zephyr.wholeSystem ? "computer" : "user-home"
                        hint: "Ctrl+G"
                        checked: zephyr.wholeSystem
                        onToggled: zephyr.wholeSystem = !zephyr.wholeSystem
                    }
                    Chip {
                        text: "Скрытые"
                        iconName: "view-hidden"
                        hint: "Ctrl+H"
                        checked: zephyr.hidden
                        onToggled: zephyr.hidden = !zephyr.hidden
                    }
                    Chip {
                        text: "По тексту"
                        iconName: "edit-find"
                        hint: "Ctrl+F"
                        checked: zephyr.content
                        onToggled: zephyr.content = !zephyr.content
                    }
                }

                Text {
                    anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter }
                    text: "↵ открыть   Ctrl+↵ в папке"
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.4)
                    font.pixelSize: 12
                }
            }
        }
    }
}
