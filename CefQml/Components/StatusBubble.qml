import QtQuick
import CefQml

// Bottom-left bubble showing the hovered link of a CefWebView.
Rectangle {
    id: bubble
    property CefWebView view
    readonly property string text: view ? view.hoveredUrl : ""

    anchors.left: parent ? parent.left : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    width: Math.min(label.implicitWidth + 16, parent ? parent.width * 0.6 : 400)
    height: 24
    radius: Style.radius
    color: Style.surface
    border.color: Style.border
    opacity: text !== "" ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    Text {
        id: label
        anchors.fill: parent
        anchors.leftMargin: 8; anchors.rightMargin: 8
        verticalAlignment: Text.AlignVCenter
        text: bubble.text
        elide: Text.ElideMiddle
        color: Style.textDim
        font.pixelSize: Style.fontSize - 1
        font.family: Style.fontFamily
    }
}
