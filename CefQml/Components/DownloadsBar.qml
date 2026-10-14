import QtQuick
import CefQml

// Strip listing downloads (Cef.downloads). Hidden when there are none.
Rectangle {
    id: bar
    implicitHeight: Style.barHeight + 12
    color: Style.surface
    visible: Cef.downloads.length > 0

    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Style.border }

    ListView {
        anchors.fill: parent
        anchors.margins: 6
        anchors.rightMargin: clearAll.width + 12
        orientation: ListView.Horizontal
        spacing: 6
        clip: true
        model: Cef.downloads
        delegate: Rectangle {
            id: item
            required property var modelData
            readonly property CefDownload download: modelData
            readonly property bool finished: download.state === CefDownload.Complete
                || download.state === CefDownload.Canceled || download.state === CefDownload.Interrupted
            width: 240
            height: ListView.view.height
            radius: Style.radius
            color: m.containsMouse ? Style.surfaceHover : Style.background

            Column {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 44
                spacing: 3
                Text {
                    width: parent.width
                    text: item.download.path ? item.download.path.split("/").pop() : item.download.suggestedFileName
                    elide: Text.ElideMiddle
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    function size(b) {
                        if (b < 1024) return b + " B"
                        if (b < 1048576) return (b / 1024).toFixed(1) + " KB"
                        return (b / 1048576).toFixed(1) + " MB"
                    }
                    text: {
                        const d = item.download
                        switch (d.state) {
                        case CefDownload.Complete: return "Done · " + size(d.receivedBytes)
                        case CefDownload.Canceled: return "Canceled"
                        case CefDownload.Interrupted: return "Failed"
                        case CefDownload.Paused: return "Paused · " + size(d.receivedBytes)
                        default: return size(d.receivedBytes) + (d.totalBytes > 0 ? " of " + size(d.totalBytes) : "")
                        }
                    }
                    elide: Text.ElideRight
                    color: item.download.state === CefDownload.Interrupted ? Style.danger : Style.textDim
                    font.pixelSize: Style.fontSize - 2
                    font.family: Style.fontFamily
                }
            }
            Rectangle {
                anchors.bottom: parent.bottom
                height: 2
                radius: 1
                visible: !item.finished
                width: parent.width * Math.max(0, item.download.progress)
                color: Style.accent
            }
            MouseArea {
                id: m
                anchors.fill: parent
                hoverEnabled: true
                onClicked: if (item.download.state === CefDownload.Complete)
                               Qt.openUrlExternally("file://" + item.download.path)
            }
            IconButton {
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: item.finished ? "×" : "■"
                onClicked: item.finished ? item.download.remove() : item.download.cancel()
            }
        }
    }

    IconButton {
        id: clearAll
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        text: "Clear"
        textColor: Style.textDim
        onClicked: {
            for (const d of Cef.downloads)
                if (d.state !== CefDownload.InProgress && d.state !== CefDownload.Paused) d.remove()
        }
    }
}
