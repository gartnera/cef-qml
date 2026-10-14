import QtQuick
import CefQml

// Back / forward / reload-stop, address field and a load progress line for
// one CefWebView.
Rectangle {
    id: bar
    property CefWebView view
    property alias addressField: address
    property alias searchUrl: address.searchUrl
    // Extra items placed after the address field (e.g. a menu button).
    default property alias trailing: trailingRow.data

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
            enabled: bar.view !== null && bar.view.canGoBack
            onClicked: bar.view.goBack()
        }
        IconButton {
            objectName: "forwardButton"
            text: "→"
            enabled: bar.view !== null && bar.view.canGoForward
            onClicked: bar.view.goForward()
        }
        IconButton {
            objectName: "reloadButton"
            text: bar.view && bar.view.loading ? "×" : "↻"
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
