import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_showAddButton: showAddButton.checked
    property alias cfg_showWindowDots: showWindowDots.checked
    property alias cfg_wideActive: wideActive.checked
    property alias cfg_switchToNew: switchToNew.checked
    property alias cfg_wheelSwitch: wheelSwitch.checked
    property alias cfg_wrapAround: wrapAround.checked

    Kirigami.FormLayout {
        QQC2.CheckBox {
            id: wideActive
            Kirigami.FormData.label: i18n("Вид:")
            text: i18n("Растягивать активный рабочий стол")
        }
        QQC2.CheckBox {
            id: showWindowDots
            text: i18n("Показывать точки окон")
        }
        QQC2.CheckBox {
            id: showAddButton
            text: i18n("Показывать кнопку «+»")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: switchToNew
            Kirigami.FormData.label: i18n("Поведение:")
            text: i18n("Переходить на новый рабочий стол")
        }
        QQC2.CheckBox {
            id: wheelSwitch
            text: i18n("Переключать колесом мыши")
        }
        QQC2.CheckBox {
            id: wrapAround
            enabled: wheelSwitch.checked
            text: i18n("Зацикливать переключение")
        }
    }
}
