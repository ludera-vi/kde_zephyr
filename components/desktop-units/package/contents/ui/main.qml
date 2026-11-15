import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager
import org.kde.plasma.workspace.dbus as DBus
import org.kde.kcmutils as KCM

PlasmoidItem {
    id: root

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool inPanel: vertical || Plasmoid.formFactor === PlasmaCore.Types.Horizontal

    readonly property int currentIndex: indexOfDesktop(vdi.currentDesktop)
    property var windowCounts: ({})
    property bool switchToNewPending: false
    property int lastDesktopCount: 0

    preferredRepresentation: fullRepresentation
    Plasmoid.backgroundHints: inPanel ? PlasmaCore.Types.NoBackground
                                      : PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground

    toolTipMainText: ""
    toolTipSubText: ""

    // ---------------------------------------------------------------- state

    TaskManager.VirtualDesktopInfo {
        id: vdi
        onDesktopIdsChanged: root.syncModel()
        onNumberOfDesktopsChanged: {
            if (root.switchToNewPending && numberOfDesktops > root.lastDesktopCount) {
                root.switchToNewPending = false
                root.activate(numberOfDesktops - 1)
            }
            root.lastDesktopCount = numberOfDesktops
        }
    }

    TaskManager.ActivityInfo { id: activityInfo }

    TaskManager.TasksModel {
        id: tasksModel
        groupMode: TaskManager.TasksModel.GroupDisabled
        filterByVirtualDesktop: false
        filterByScreen: false
        filterByActivity: true
        activity: activityInfo.currentActivity

        onRowsInserted: countTimer.restart()
        onRowsRemoved: countTimer.restart()
        onModelReset: countTimer.restart()
        onDataChanged: countTimer.restart()
    }

    Timer {
        id: countTimer
        interval: 120
        onTriggered: root.countWindows()
    }

    // Desktops mirrored into a ListModel so add/remove get animated transitions.
    ListModel { id: desktopModel }

    function idString(id) {
        return id === undefined || id === null ? "" : String(id)
    }

    function indexOfDesktop(id) {
        const wanted = idString(id)
        const ids = vdi.desktopIds
        for (let i = 0; i < ids.length; ++i)
            if (idString(ids[i]) === wanted)
                return i
        return -1
    }

    function syncModel() {
        const ids = vdi.desktopIds.map(idString)
        for (let i = desktopModel.count - 1; i >= 0; --i)
            if (ids.indexOf(desktopModel.get(i).desktopId) < 0)
                desktopModel.remove(i)
        for (let i = 0; i < ids.length; ++i) {
            let found = -1
            for (let j = i; j < desktopModel.count; ++j) {
                if (desktopModel.get(j).desktopId === ids[i]) {
                    found = j
                    break
                }
            }
            if (found < 0)
                desktopModel.insert(i, { desktopId: ids[i] })
            else if (found !== i)
                desktopModel.move(found, i, 1)
        }
    }

    function countWindows() {
        const counts = {}
        const roles = TaskManager.AbstractTasksModel
        for (let row = 0; row < tasksModel.rowCount(); ++row) {
            const idx = tasksModel.index(row, 0)
            if (!tasksModel.data(idx, roles.IsWindow) || tasksModel.data(idx, roles.IsOnAllVirtualDesktops))
                continue
            const desktops = tasksModel.data(idx, roles.VirtualDesktops) || []
            for (let i = 0; i < desktops.length; ++i) {
                const key = idString(desktops[i])
                counts[key] = (counts[key] || 0) + 1
            }
        }
        windowCounts = counts
    }

    // -------------------------------------------------------------- actions

    function kwin(path, iface, member, args) {
        DBus.SessionBus.asyncCall({
            service: "org.kde.KWin",
            path: path,
            iface: iface,
            member: member,
            arguments: args
        })
    }

    function activate(index) {
        if (index < 0 || index >= vdi.numberOfDesktops || index === currentIndex)
            return
        kwin("/KWin", "org.kde.KWin", "setCurrentDesktop", [new DBus.int32(index + 1)])
    }

    function addDesktop() {
        switchToNewPending = Plasmoid.configuration.switchToNew
        lastDesktopCount = vdi.numberOfDesktops
        kwin("/VirtualDesktopManager", "org.kde.KWin.VirtualDesktopManager", "createDesktop",
             [new DBus.uint32(vdi.numberOfDesktops), new DBus.string("")])
    }

    function removeDesktop(index) {
        if (vdi.numberOfDesktops <= 1 || index < 0 || index >= vdi.numberOfDesktops)
            return
        kwin("/VirtualDesktopManager", "org.kde.KWin.VirtualDesktopManager", "removeDesktop",
             [new DBus.string(idString(vdi.desktopIds[index]))])
    }

    function step(delta) {
        const n = vdi.numberOfDesktops
        let next = currentIndex + delta
        if (Plasmoid.configuration.wrapAround)
            next = (next + n) % n
        activate(Math.max(0, Math.min(n - 1, next)))
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Добавить рабочий стол")
            icon.name: "list-add"
            onTriggered: root.addDesktop()
        },
        PlasmaCore.Action {
            text: i18n("Удалить текущий рабочий стол")
            icon.name: "list-remove"
            enabled: vdi.numberOfDesktops > 1
            onTriggered: root.removeDesktop(root.currentIndex)
        },
        PlasmaCore.Action {
            text: i18n("Настроить рабочие столы…")
            icon.name: "preferences-desktop-virtual"
            onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_kwin_virtualdesktops")
        }
    ]

    Component.onCompleted: {
        syncModel()
        lastDesktopCount = vdi.numberOfDesktops
        countWindows()
    }

    // ------------------------------------------------------------------- ui

    fullRepresentation: Item {
        id: strip

        readonly property real thickness: root.vertical ? width : height
        readonly property real pillSize: root.inPanel
            ? Math.round(Math.max(Kirigami.Units.iconSizes.small, Math.min(thickness * (root.vertical ? 0.92 : 0.8), Kirigami.Units.iconSizes.large)))
            : Math.round(Kirigami.Units.gridUnit * 1.6)
        readonly property real gap: Math.max(2, Math.round(pillSize * 0.2))
        readonly property real stretch: Plasmoid.configuration.wideActive ? 1.75 : 1

        readonly property real length: list.contentLength
            + (Plasmoid.configuration.showAddButton ? gap + pillSize : 0)
            + (root.inPanel ? gap * 2 : Kirigami.Units.largeSpacing * 2)

        Layout.minimumWidth: root.vertical ? -1 : length
        Layout.preferredWidth: root.vertical ? -1 : length
        Layout.maximumWidth: root.vertical ? -1 : length
        readonly property real panelHeight: root.vertical ? length : (root.inPanel ? -1 : pillSize + Kirigami.Units.largeSpacing * 2)
        Layout.minimumHeight: panelHeight
        Layout.preferredHeight: panelHeight
        Layout.maximumHeight: root.vertical ? length : -1

        WheelHandler {
            enabled: Plasmoid.configuration.wheelSwitch
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            property real accumulated: 0
            onWheel: event => {
                const delta = event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x
                accumulated += delta
                while (Math.abs(accumulated) >= 120) {
                    root.step(accumulated > 0 ? -1 : 1)
                    accumulated -= accumulated > 0 ? 120 : -120
                }
            }
        }

        Grid {
            anchors.centerIn: parent
            flow: root.vertical ? Grid.TopToBottom : Grid.LeftToRight
            columns: root.vertical ? 1 : 2
            spacing: strip.gap
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter

            ListView {
                id: list

                readonly property real contentLength: root.vertical ? contentHeight : contentWidth

                width: root.vertical ? strip.pillSize : contentWidth
                height: root.vertical ? contentHeight : strip.pillSize
                orientation: root.vertical ? ListView.Vertical : ListView.Horizontal
                spacing: strip.gap
                interactive: false
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 10000
                model: desktopModel
                currentIndex: root.currentIndex

                highlightFollowsCurrentItem: true
                highlightMoveDuration: Kirigami.Units.longDuration
                highlightMoveVelocity: -1
                highlightResizeDuration: Kirigami.Units.longDuration
                highlightResizeVelocity: -1
                // Active desktop: the same empty tile, outlined in the accent colour.
                highlight: Rectangle {
                    radius: Math.round(strip.pillSize * 0.27)
                    color: "transparent"
                    border.width: 1
                    border.color: Kirigami.Theme.highlightColor
                }

                delegate: DesktopPill {
                    required property int index
                    required property string desktopId

                    number: index + 1
                    name: vdi.desktopNames[index] || ""
                    active: index === root.currentIndex
                    windows: root.windowCounts[desktopId] || 0
                    size: strip.pillSize
                    stretch: strip.stretch
                    vertical: root.vertical
                    showDots: Plasmoid.configuration.showWindowDots
                    onActivated: root.activate(index)
                    onRemoveRequested: root.removeDesktop(index)
                }

                add: Transition {
                    NumberAnimation { property: "scale"; from: 0; to: 1; duration: Kirigami.Units.longDuration; easing.type: Easing.OutBack }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Kirigami.Units.longDuration }
                }
                remove: Transition {
                    NumberAnimation { property: "scale"; to: 0; duration: Kirigami.Units.longDuration; easing.type: Easing.InBack }
                    NumberAnimation { property: "opacity"; to: 0; duration: Kirigami.Units.longDuration }
                }
                displaced: Transition {
                    NumberAnimation { properties: "x,y"; duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                }
            }

            AddButton {
                visible: Plasmoid.configuration.showAddButton
                size: strip.pillSize
                onClicked: root.addDesktop()
            }
        }
    }
}
