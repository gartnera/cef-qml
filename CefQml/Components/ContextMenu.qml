import QtQuick
import CefQml

// Right-click menu for a WebTabs, drawn inside the window.
Item {
    id: menu
    required property WebTabs tabs
    property CefWebView view
    property url linkUrl
    property string selectedText
    property bool editable: false
    // Optional KeyBindings: entries show the keys of their action.
    property var keyBindings: null
    signal openLinkInNewTab(url url)

    visible: false

    Connections {
        target: menu.tabs
        function onContextMenuRequested(view, x, y, linkUrl, selectedText, editable) {
            menu.show(view, x, y, linkUrl, selectedText, editable)
        }
    }

    function show(view, x, y, linkUrl, selectedText, editable) {
        menu.view = view
        menu.linkUrl = linkUrl
        menu.selectedText = selectedText
        menu.editable = editable
        visible = true
        // The entries were just rebuilt; Column only positions them (and
        // updates the panel height) at the next polish. Lay out now so the
        // placement below uses the new height and a click that arrives
        // before the next frame hits the entry under it, not a stale one.
        column.forceLayout()
        const p = view.mapToItem(menu, x, y)
        panel.x = Math.min(p.x, width - panel.width - 4)
        panel.y = Math.min(p.y, height - panel.height - 4)
    }
    function close() { visible = false }
    function _hint(action) { return keyBindings ? keyBindings.hint(action) : "" }

    readonly property var items: {
        const list = []
        const hasLink = linkUrl.toString() !== ""
        if (hasLink) {
            list.push({ label: "Open link in new tab", action: () => openLinkInNewTab(linkUrl) })
            list.push({ label: "Copy link address", action: () => Cef.copyToClipboard(linkUrl.toString()) })
            list.push(null)
        }
        if (editable) {
            list.push({ label: "Undo", action: () => view.undo() })
            list.push({ label: "Redo", action: () => view.redo() })
            list.push(null)
            list.push({ label: "Cut", action: () => view.cut() })
            list.push({ label: "Copy", action: () => view.copy() })
            list.push({ label: "Paste", action: () => view.paste() })
            list.push({ label: "Select all", action: () => view.selectAll() })
        } else if (selectedText !== "") {
            list.push({ label: "Copy", action: () => view.copy() })
        }
        if (!hasLink && !editable && selectedText === "") {
            list.push({ label: "Back", hint: _hint("nav.back"), enabled: view && view.canGoBack, action: () => view.goBack() })
            list.push({ label: "Forward", hint: _hint("nav.forward"), enabled: view && view.canGoForward, action: () => view.goForward() })
            list.push({ label: "Reload", hint: _hint("nav.reload"), action: () => view.reload() })
        }
        return list
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
        onWheel: menu.close()
    }

    Rectangle {
        id: panel
        objectName: "contextMenuPanel"
        width: 200
        height: column.implicitHeight + 8
        radius: Style.radius
        color: Style.surface
        border.color: Style.border

        Column {
            id: column
            x: 4; y: 4
            width: parent.width - 8
            Repeater {
                model: menu.items
                delegate: Loader {
                    required property var modelData
                    width: column.width
                    sourceComponent: modelData === null ? separator : entry
                    property var entryData: modelData
                }
            }
        }
    }

    Component {
        id: separator
        Item { height: 9; Rectangle { anchors.centerIn: parent; width: parent.width - 8; height: 1; color: Style.border } }
    }
    Component {
        id: entry
        Rectangle {
            readonly property bool itemEnabled: parent.entryData.enabled !== false
            height: 28
            radius: Style.radius - 2
            color: m.containsMouse && itemEnabled ? Style.surfaceHover : "transparent"
            Text {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                text: parent.parent.entryData.label
                color: parent.itemEnabled ? Style.text : Style.textDim
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: parent.parent.entryData.hint || ""
                color: Style.textDim
                font.pixelSize: Style.fontSize - 1
                font.family: Style.fontFamily
            }
            MouseArea {
                id: m
                anchors.fill: parent
                hoverEnabled: true
                enabled: parent.itemEnabled
                onClicked: { const a = parent.parent.entryData.action; menu.close(); a() }
            }
        }
    }
}
