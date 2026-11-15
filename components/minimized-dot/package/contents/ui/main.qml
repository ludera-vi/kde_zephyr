import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.taskmanager as TaskManager
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Список окон от KWin — обновляется по событиям, без опроса.
    // Все открытые окна (и свёрнутые, и нет), самые недавние — в начале ряда.
    TaskManager.TasksModel {
        id: tasks
        filterNotMinimized: false
        filterByVirtualDesktop: false
        filterByActivity: false
        filterByScreen: false
        groupMode: TaskManager.TasksModel.GroupDisabled
        sortMode: TaskManager.TasksModel.SortLastActivated
    }

    // Панель слева или справа: ряд раскрывается вниз, а не вбок
    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property int count: tasks.count
    readonly property bool editMode: Plasmoid.containment && Plasmoid.containment.corona
                                     && Plasmoid.containment.corona.editMode
    readonly property bool shown: count > 0 || editMode

    // Раскрыт ли ряд иконок. Закрывается с задержкой, чтобы не мигал,
    // когда курсор на мгновение выходит за край.
    property bool open: false
    // Курсор над виджетом. Нужно таймеру: после закрытия меню ряд не должен схлопнуться под курсором
    property bool hovering: false
    // Пока открыто меню окна, курсор уходит с панели, а ряд должен оставаться на месте
    readonly property bool menuOpen: windowMenu.status !== PlasmaExtras.Menu.Closed

    Plasmoid.status: shown ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.HiddenStatus
    Plasmoid.icon: "window-minimize"
    preferredRepresentation: compactRepresentation
    // Своя подсказка у каждой иконки, общая не нужна
    toolTipMainText: ""
    toolTipSubText: ""

    onCountChanged: if (count === 0) open = false

    function activate(i) { tasks.requestActivate(tasks.makeModelIndex(i)) }
    function close(i) { tasks.requestClose(tasks.makeModelIndex(i)) }
    function textTint(a) {
        const c = Kirigami.Theme.textColor
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    Timer {
        id: closeTimer
        interval: 350
        onTriggered: if (!root.menuOpen && !root.hovering) root.open = false
    }

    onMenuOpenChanged: if (!menuOpen) closeTimer.restart()

    // Меню по правой кнопке. Одно на все плитки: номер окна в ряду берём у плитки в момент
    // выбора пункта, потому что ряд сортируется по активности и может сдвинуться
    PlasmaExtras.Menu {
        id: windowMenu
        property Item target: null

        PlasmaExtras.MenuItem {
            text: "Открыть"
            icon: "window"
            onClicked: if (windowMenu.target) root.activate(windowMenu.target.index)
        }
        PlasmaExtras.MenuItem {
            text: "Закрыть"
            icon: "window-close"
            onClicked: if (windowMenu.target) root.close(windowMenu.target.index)
        }
    }

    compactRepresentation: MouseArea {
        id: area
        visible: root.shown
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton

        onContainsMouseChanged: {
            root.hovering = containsMouse
            if (containsMouse) { closeTimer.stop(); if (root.count > 0) root.open = true }
            else closeTimer.restart()
        }
        // На тачпаде/тачскрине без наведения — раскрыть кликом
        onClicked: if (root.count > 0) root.open = !root.open

        // pillH — толщина плашки поперёк панели, animLength — её длина вдоль панели
        readonly property real thickness: root.vertical ? width : height
        readonly property real pillH: Math.round(Math.min(thickness * (root.vertical ? 0.92 : 0.8), Kirigami.Units.iconSizes.medium + 6))
        readonly property real iconSize: Math.round(pillH * 0.66)
        readonly property real tileRadius: Math.round(pillH * 0.27)
        readonly property real pad: Math.round(pillH * 0.3)
        readonly property real gap: Math.round(pillH * 0.18)

        readonly property real closedLength: Math.max(pillH, pad * 2 + dot.height + gap * 0.6
                                             + (root.vertical ? countLabel.implicitHeight : countLabel.implicitWidth))
        // В раскрытом виде общей плашки нет: у каждого окна своя плитка
        readonly property real openLength: Math.max(1, root.count) * pillH + (Math.max(1, root.count) - 1) * gap
        readonly property real targetLength: !root.shown ? 0 : root.open ? openLength : closedLength

        // Плавное раскрытие: панель раздвигает соседей вместе с анимацией
        property real animLength: targetLength
        Behavior on animLength { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic } }

        // Вдоль панели размер ровно по плашке, поперёк (-1) его задаёт сама панель
        readonly property real panelLength: animLength + Kirigami.Units.smallSpacing * 2
        readonly property real panelWidth: root.vertical ? -1 : panelLength
        readonly property real panelHeight: root.vertical ? panelLength : -1

        Layout.minimumWidth: panelWidth
        Layout.preferredWidth: panelWidth
        Layout.maximumWidth: panelWidth
        Layout.minimumHeight: panelHeight
        Layout.preferredHeight: panelHeight
        Layout.maximumHeight: panelHeight

        Item {
            id: pill
            anchors.centerIn: parent
            width: root.vertical ? area.pillH : area.animLength
            height: root.vertical ? area.animLength : area.pillH
            clip: true

            // Рамка свёрнутого состояния, при раскрытии растворяется в плитках окон
            Rectangle {
                anchors.fill: parent
                radius: area.tileRadius
                color: "transparent"
                border.width: 1
                border.color: root.textTint(area.containsMouse ? 0.42 : 0.22)
                opacity: root.open ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
            }

            // Свёрнутое состояние: точка + число (на боковой панели — друг над другом)
            Grid {
                anchors.centerIn: parent
                columns: root.vertical ? 1 : 2
                spacing: area.gap * 0.6
                horizontalItemAlignment: Grid.AlignHCenter
                verticalItemAlignment: Grid.AlignVCenter
                opacity: root.open ? 0 : 1
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

                Rectangle {
                    id: dot
                    width: Math.round(area.pillH * 0.32)
                    height: width
                    radius: width / 2
                    color: Kirigami.Theme.highlightColor
                }
                PlasmaComponents.Label {
                    id: countLabel
                    // Векторная отрисовка без субпиксельного сглаживания: иначе на мелком тексте цветная кайма
                    renderType: Text.CurveRendering
                    text: root.count
                    font.weight: Font.Medium
                    font.pixelSize: Math.round(area.pillH * 0.5)
                    font.features: { "tnum": 1 }
                }
            }

            // Раскрытое состояние: иконки всех окон
            Grid {
                columns: root.vertical ? 1 : Math.max(1, root.count)
                spacing: area.gap
                opacity: root.open ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: Kirigami.Units.longDuration } }

                Repeater {
                    model: tasks
                    delegate: MouseArea {
                        id: iconArea
                        required property int index
                        required property var model
                        width: area.pillH
                        height: area.pillH
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        // Левый — развернуть, средний — закрыть окно, правый — меню
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                windowMenu.target = iconArea
                                windowMenu.visualParent = iconArea
                                windowMenu.open(mouse.x, mouse.y)
                            } else if (mouse.button === Qt.MiddleButton) root.close(index)
                            else root.activate(index)
                        }
                        // Наведение на иконку держит ряд открытым
                        onContainsMouseChanged: if (containsMouse) closeTimer.stop()

                        // Плитка окна. Активное отмечено цветом рамки
                        Rectangle {
                            anchors.fill: parent
                            radius: area.tileRadius
                            color: "transparent"
                            border.width: 1
                            border.color: iconArea.model.IsActive === true ? Kirigami.Theme.highlightColor
                                        : root.textTint(iconArea.containsMouse ? 0.42 : 0.22)
                            Behavior on border.color { ColorAnimation { duration: Kirigami.Units.shortDuration } }
                        }

                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: area.iconSize
                            height: area.iconSize
                            source: iconArea.model.decoration
                            // Свёрнутые — приглушённые, чтобы отличались от окон на экране
                            opacity: iconArea.model.IsMinimized && !iconArea.containsMouse ? 0.45 : 1
                            Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                            scale: iconArea.containsMouse ? 1.08 : 1
                            Behavior on scale { NumberAnimation { duration: Kirigami.Units.shortDuration; easing.type: Easing.OutBack } }
                        }

                        PlasmaCore.ToolTipArea {
                            anchors.fill: parent
                            mainText: iconArea.model.AppName || iconArea.model.display
                            subText: iconArea.model.AppName ? iconArea.model.display : ""
                            icon: iconArea.model.decoration
                        }
                    }
                }
            }
        }
    }

    fullRepresentation: Item {}
}
