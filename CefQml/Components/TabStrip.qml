import QtQuick
import CefQml

// Horizontal tab bar for a WebTabs. Click selects, middle click or × closes,
// + opens a new tab.
Rectangle {
    id: strip
    required property WebTabs tabs
    property real maxTabWidth: 220
    property real minTabWidth: 48
    signal newTabRequested()

    implicitHeight: Style.barHeight
    color: Style.background

    readonly property real tabWidth: tabs.count === 0 ? maxTabWidth
        : Math.max(minTabWidth, Math.min(maxTabWidth, (width - newButton.width - 12) / tabs.count))

    Row {
        id: row
        x: 6
        anchors.bottom: parent.bottom
        spacing: 2

        Repeater {
            model: strip.tabs.views
            delegate: Rectangle {
                id: tab
                required property var modelData
                required property int index
                readonly property CefWebView view: modelData
                readonly property bool current: index === strip.tabs.currentIndex

                width: strip.tabWidth
                height: strip.height - 6
                radius: Style.radius + 2
                color: current ? Style.surface : tabMouse.containsMouse ? Style.surfaceHover : "transparent"
                objectName: "tab" + index

                // The current tab flows into the toolbar below: square bottom corners.
                Rectangle {
                    visible: tab.current
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: parent.radius
                    color: parent.color
                }
                // Separator between inactive tabs.
                Rectangle {
                    visible: !tab.current && tab.index + 1 !== strip.tabs.currentIndex && !tabMouse.containsMouse
                    anchors.right: parent.right
                    anchors.rightMargin: -1
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1; height: parent.height * 0.5
                    color: Style.border
                }

                Image {
                    id: favicon
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    sourceSize: Qt.size(32, 32)
                    source: tab.view && tab.view.icon.toString().startsWith("http") ? tab.view.icon : ""
                    visible: status === Image.Ready && !(tab.view && tab.view.loading)
                }
                Rectangle {
                    // loading indicator / placeholder dot
                    anchors.centerIn: favicon
                    width: 8; height: 8; radius: 4
                    visible: !favicon.visible
                    color: tab.view && tab.view.loading ? Style.accent : Style.textDim
                    SequentialAnimation on opacity {
                        running: tab.view !== null && tab.view.loading
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 400 }
                        NumberAnimation { to: 1; duration: 400 }
                        onRunningChanged: if (!running) parent.opacity = 1
                    }
                }
                Text {
                    anchors.left: favicon.right
                    anchors.leftMargin: 8
                    anchors.right: close.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: !tab.view ? "" : tab.view.title || tab.view.url.toString() || "New Tab"
                    elide: Text.ElideRight
                    color: tab.current ? Style.text : Style.textDim
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton) strip.tabs.closeTab(tab.index)
                        else strip.tabs.currentIndex = tab.index
                    }
                }
                IconButton {
                    id: close
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 20; implicitHeight: 20
                    text: "×"
                    visible: tab.width > 90 || tab.current
                    onClicked: strip.tabs.closeTab(tab.index)
                }
            }
        }

        IconButton {
            id: newButton
            objectName: "newTabButton"
            y: (strip.height - 6 - height) / 2
            text: "+"
            onClicked: strip.newTabRequested()
        }
    }
}
