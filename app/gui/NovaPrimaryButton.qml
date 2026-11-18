import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

// Nova Play: boton principal de la marca (morado con texto blanco). Con busy muestra la rueda de carga en lugar del texto.
Button {
    id: b
    property bool busy: false
    Layout.fillWidth: true
    Layout.preferredHeight: 52
    background: Rectangle {
        radius: height / 2
        color: b.busy ? "#7F33E6" : !b.enabled ? "#3A2F5C" : b.down ? "#7F33E6" : b.hovered ? "#AE6BFF" : "#9B4DFF"
        border.width: b.visualFocus ? 2 : 0
        border.color: "#FFFFFF"
    }
    contentItem: Label {
        text: b.busy ? "" : b.text
        font.pointSize: 13
        font.weight: Font.DemiBold
        color: b.enabled ? "#FFFFFF" : "#9A93B5"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    BusyIndicator {
        anchors.centerIn: parent
        width: 30; height: 30
        running: b.busy
        visible: b.busy
        Material.accent: "#FFFFFF"
    }
}
