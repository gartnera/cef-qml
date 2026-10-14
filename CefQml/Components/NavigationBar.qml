import QtQuick
import CefQml

// Back / forward / reload-stop, address field and a load progress line for
// one CefWebView.
Rectangle {
    id: bar
    property CefWebView view
    property alias addressField: address
    property alias searchUrl: address.searchUrl
    // Optional KeyBindings: adds the keys to the buttons' tool tips.
    property var keyBindings: null
    // Extra items placed after the address field (e.g. a menu button).
    default property alias trailing: trailingRow.data

    function _tip(text, action) {
        const k = keyBindings ? keyBindings.hint(action) : ""
        return k === "" ? text : text + " (" + k + ")"
    }

    implicitHeight: Style.barHeight + 4
    color: Style.surface

    Row {
        id: leading
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        IconButton {
            objectName: "backButton"
            text: "←"
            toolTip: bar._tip("Back", "nav.back")
            enabled: bar.view !== null && bar.view.canGoBack
            onClicked: bar.view.goBack()
        }
        IconButton {
            objectName: "forwardButton"
            text: "→"
            toolTip: bar._tip("Forward", "nav.forward")
            enabled: bar.view !== null && bar.view.canGoForward
            onClicked: bar.view.goForward()
        }
        IconButton {
            objectName: "reloadButton"
            text: bar.view && bar.view.loading ? "×" : "↻"
            toolTip: bar.view && bar.view.loading ? bar._tip("Stop", "nav.stop") : bar._tip("Reload", "nav.reload")
            enabled: bar.view !== null
            onClicked: bar.view.loading ? bar.view.stop() : bar.view.reload()
        }
    }

    AddressField {
        id: address
        view: bar.view
        anchors.left: leading.right
        anchors.leftMargin: 6
        anchors.right: zoom.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
    }

    IconButton {
        id: zoom
        anchors.right: trailingRow.left
        anchors.verticalCenter: parent.verticalCenter
        visible: bar.view !== null && Math.abs(bar.view.zoomFactor - 1) > 0.01
        width: visible ? implicitWidth : 0
        text: bar.view ? Math.round(bar.view.zoomFactor * 100) + "%" : ""
        textColor: Style.textDim
        toolTip: bar._tip("Reset zoom", "zoom.reset")
        onClicked: bar.view.zoomFactor = 1
    }

    Row {
        id: trailingRow
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
    }

    Rectangle {
        anchors.bottom: parent.bottom
        height: 2
        width: bar.view && bar.view.loading ? parent.width * Math.max(0.05, bar.view.loadProgress) : 0
        color: Style.accent
        visible: width > 0
        Behavior on width { NumberAnimation { duration: 150 } }
    }
}
