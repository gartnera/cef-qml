import QtQuick

// Small flat button showing a text glyph.
Rectangle {
    id: button
    property string text
    property string toolTip
    property bool enabled: true
    property bool checked: false
    property color textColor: Style.text
    signal clicked()

    implicitWidth: Math.max(28, label.implicitWidth + 12)
    implicitHeight: 28
    radius: Style.radius
    opacity: enabled ? 1 : 0.35
    color: !enabled ? "transparent"
         : mouse.pressed || checked ? Style.surfaceActive
         : mouse.containsMouse ? Style.surfaceHover : "transparent"

    Text {
        id: label
        anchors.centerIn: parent
        text: button.text
        color: button.textColor
        font.pixelSize: Style.fontSize + 3
        font.family: Style.fontFamily
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: button.enabled
        onClicked: button.clicked()
    }
}
