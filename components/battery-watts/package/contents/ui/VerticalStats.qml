import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Столбик значений для боковой панели. Каждый блок устроен одинаково: мелкая приглушённая
// подпись и значение под ней. Значения не длиннее трёх знаков, поэтому шрифт не зависит
// от данных и размеры не прыгают. Блоки разделены тонкой линией.
ColumnLayout {
    id: stats

    property real tile: 24              // ширина плашки, от неё считаются все размеры
    property string cpu: "—"
    property color cpuColor: Kirigami.Theme.textColor
    property bool gpuShown: false
    property string gpu: "—"
    property color gpuColor: Kirigami.Theme.textColor
    property string gpuMem: ""
    property bool wattsShown: false
    property string watts: "—"
    property int percent: -1

    readonly property int valueSize: Math.max(9, Math.round(tile * 0.46))
    readonly property int labelSize: Math.max(7, Math.round(tile * 0.33))
    readonly property int groupGap: Math.max(3, Math.round(tile * 0.17))
    readonly property color ink: Kirigami.Theme.textColor
    readonly property color muted: Qt.rgba(ink.r, ink.g, ink.b, 0.6)

    spacing: 0

    component Line: PlasmaComponents.Label {
        property int size: stats.valueSize
        Layout.alignment: Qt.AlignHCenter
        horizontalAlignment: Text.AlignHCenter
        // Векторная отрисовка без субпиксельного сглаживания: иначе на мелком тексте цветная кайма
        renderType: Text.CurveRendering
        font.pixelSize: size
        font.features: { "tnum": 1 }
        lineHeightMode: Text.FixedHeight
        lineHeight: Math.round(size * 1.2)
    }
    component Caption: Line {
        size: stats.labelSize
        color: stats.muted
    }
    component Value: Line {
        font.weight: Font.Medium
    }
    // Блок с линией сверху. Первому блоку линия не нужна
    component Group: ColumnLayout {
        property bool divided: true
        spacing: 0
        Layout.alignment: Qt.AlignHCenter
        Rectangle {
            visible: parent.divided
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.round(stats.tile * 0.5)
            Layout.preferredHeight: 1
            Layout.topMargin: stats.groupGap
            Layout.bottomMargin: stats.groupGap
            color: Qt.rgba(stats.ink.r, stats.ink.g, stats.ink.b, 0.18)
        }
    }

    Group {
        divided: false
        Caption { text: "CPU" }
        Value { text: stats.cpu; color: stats.cpuColor }
    }
    Group {
        visible: stats.gpuShown
        Caption { text: "GPU" }
        Value { text: stats.gpu; color: stats.gpuColor }
        Caption { visible: text !== ""; text: stats.gpuMem }
    }
    Group {
        visible: stats.wattsShown
        Caption { text: "W" }
        Value { text: stats.watts }
    }
    Group {
        visible: stats.percent >= 0 && stats.percent <= 20
        LowBattery {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 1
            Layout.bottomMargin: 2
            level: stats.percent
            font: Qt.font({ family: Kirigami.Theme.defaultFont.family, pixelSize: stats.labelSize })
        }
        Value { text: stats.percent }
    }
}
