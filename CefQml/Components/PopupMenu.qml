import QtQuick

// A small menu drawn above the rest of the window (internal; used by the
// bookmark components). `entries` are { label, hint, enabled, action } or
// null for a separator. popup(item, x, y) shows it at a point of `item`;
// a press outside it or Escape closes it.
FocusScope {
    id: menu

    property var entries: []
    property real menuWidth: 220
    property int rowHeight: 28
    readonly property bool opened: visible
    readonly property Item panel: panel

    signal closed()

    visible: false
    z: 10001

    function popup(item, px, py) {
        const w = Window.window
        if (!w) return false
        if (parent !== w.contentItem) parent = w.contentItem
        _restoreFocus = w.activeFocusItem
        visible = true
        const p = item ? item.mapToItem(null, px || 0, py || 0) : Qt.point(px || 0, py || 0)
        panel.x = Math.max(4, Math.min(p.x, width - panel.width - 4))
        panel.y = p.y + panel.height + 4 > height ? Math.max(4, p.y - panel.height) : p.y
        forceActiveFocus(Qt.PopupFocusReason)
        return true
    }
    function close() {
        if (!visible) return
        visible = false
        const f = _restoreFocus
        _restoreFocus = null
        try { if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason) } catch (e) {}
        closed()
    }
    // Runs entry `i` (as a click on it does).
    function trigger(i) {
        const e = entries[i]
        if (!e || e.enabled === false) return false
        close()
        if (typeof e.action === "function") e.action()
        return true
    }
    // The row of entry `i` (null for separators).
    function rowAt(i) {
        const r = repeater.itemAt(i)
        return r && r.isEntry ? r : null
    }
    function indexOfLabel(label) { return entries.findIndex(e => e && e.label === label) }

    property var _restoreFocus: null
    readonly property var _ys: {
        const ys = []
        let y = 0
        for (const e of entries) {
            ys.push(y)
            y += e ? rowHeight : 9
        }
        ys.push(y)
        return ys
    }

    x: 0
    y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    Keys.onEscapePressed: close()

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
        onWheel: menu.close()
    }

    Rectangle {
        id: panel
        objectName: "popupMenuPanel"
        width: menu.menuWidth
        height: menu._ys[menu._ys.length - 1] + 8
        radius: Style.radius
        color: Style.surface
        border.color: Style.border

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        Repeater {
            id: repeater
            model: menu.entries
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool isEntry: modelData !== null
                readonly property bool itemEnabled: isEntry && modelData.enabled !== false
                x: 4
                y: 4 + menu._ys[index]
                width: panel.width - 8
                height: isEntry ? menu.rowHeight : 9
                radius: Style.radius - 2
                color: m.containsMouse && itemEnabled ? Style.surfaceHover : "transparent"
                Rectangle {
                    visible: !row.isEntry
                    anchors.centerIn: parent
                    width: parent.width - 8
                    height: 1
                    color: Style.border
                }
                Text {
                    visible: row.isEntry
                    x: 10
                    width: parent.width - 20 - hint.implicitWidth
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.isEntry ? row.modelData.label : ""
                    elide: Text.ElideRight
                    color: row.itemEnabled ? Style.text : Style.textDim
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    id: hint
                    visible: row.isEntry
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.isEntry ? row.modelData.hint || "" : ""
                    color: Style.textDim
                    font.pixelSize: Style.fontSize - 1
                    font.family: Style.fontFamily
                }
                MouseArea {
                    id: m
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: row.itemEnabled
                    onClicked: menu.trigger(row.index)
                }
            }
        }
    }
}
