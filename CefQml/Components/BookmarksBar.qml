import QtQuick
import CefQml

// A strip of the bookmarks in one folder of a BookmarkStore (by default the
// built-in "Bookmarks bar"), usually placed under the navigation bar:
//
//   BookmarksBar {
//       store: bookmarks
//       onOpenRequested: (url, newTab) => newTab ? tabs.openTab(url, true) : tabs.currentView.url = url
//       onManageRequested: managerOverlay.open()
//   }
//
// Click a bookmark to open it (openRequested(url, false)); middle click or
// Ctrl+click opens it in a new tab (newTab true). Folders open a drop-down
// BookmarkMenu (middle click: all their bookmarks in new tabs). Items that
// do not fit go into the "»" menu at the end. Drag an item to reorder it,
// or onto a folder to move it there. Right click: Open / Open in new tab /
// Edit… / Delete / New folder… / Bookmark manager (and Hide on empty
// space). With showOtherFolder an "Other bookmarks" button sits at the
// right while that folder has items.
//
// objectNames: bookmarksBar, bookmarkBarItem (the items, itemAt(i)),
// bookmarkBarOverflow (»), bookmarkBarOther, bookmarkBarEmpty.
Rectangle {
    id: bar

    property BookmarkStore store: null
    // The folder shown (default: the store's "Bookmarks bar").
    property string folder: store ? store.barFolder : ""
    property bool showOtherFolder: true
    property bool dragEnabled: true
    property real maxItemWidth: 180
    readonly property int count: model.count
    // Number of items shown in the bar (the rest are in the "»" menu).
    readonly property int visibleCount: {
        void strip.width
        void row.implicitWidth
        void repeater.count
        let n = 0
        for (let i = 0; i < repeater.count; ++i) {
            const it = repeater.itemAt(i)
            if (!it || it.x + it.width > strip.width) break
            ++n
        }
        return n
    }
    readonly property bool overflowing: visibleCount < count
    readonly property BookmarkMenu menu: bmMenu
    readonly property BookmarkEditor editor: editorItem
    readonly property Item contextMenu: ctxMenu
    // While dragging: the index the dragged item would land at, or -1.
    readonly property int dropIndex: _dropIndex
    readonly property string dropFolder: _dropFolder

    signal openRequested(string url, bool newTab)
    signal manageRequested()
    signal hideRequested()

    function itemAt(i) { return repeater.itemAt(i) }
    function indexOf(id) { return model.indexOf(id) }
    // Opens item `i` as a click does (a folder: its drop-down menu).
    function activate(i, newTab) {
        const it = itemAt(i)
        if (!it) return false
        if (it.isFolder) {
            if (newTab) bmMenu.openAll(it.nodeId)
            else openFolder(i)
        } else {
            openRequested(it.url, !!newTab)
        }
        return true
    }
    function openFolder(i) {
        const it = itemAt(i)
        return !!it && it.isFolder && bmMenu.popup(it.nodeId, it, 0, it.height + 2)
    }
    // Shows the items that do not fit.
    function openOverflow() {
        return overflowButton.visible && bmMenu.popup(folder, overflowButton, overflowButton.width - bmMenu.menuWidth,
                                                    overflowButton.height + 2, visibleCount)
    }
    // The right-click menu of node `id` ("" for the bar itself) at window
    // point (x, y).
    function showContextMenu(id, x, y) {
        if (!store) return false
        const n = id !== "" ? store.get(id) : undefined
        const e = []
        if (n && !n.isFolder) {
            e.push({ label: "Open", action: () => bar.openRequested(n.url, false) })
            e.push({ label: "Open in new tab", action: () => bar.openRequested(n.url, true) })
            e.push(null)
            e.push({ label: "Edit…", action: () => editorItem.edit(n.id, null) })
            e.push({ label: "Delete", action: () => store.remove(n.id) })
        } else if (n) {
            const urls = store.children(n.id).filter(c => !c.isFolder).length
            e.push({ label: "Open all (" + urls + ") in tabs", enabled: urls > 0,
                     action: () => bmMenu.openAll(n.id) })
            e.push(null)
            e.push({ label: "Rename…", action: () => editorItem.edit(n.id, null) })
            e.push({ label: "Delete", action: () => store.remove(n.id) })
        }
        if (e.length > 0) e.push(null)
        e.push({ label: "New folder…", action: () => n ? editorItem.newFolder(n.parent, n.position + 1, null)
                                                      : editorItem.newFolder(bar.folder, -1, null) })
        e.push({ label: "Bookmark manager", action: () => bar.manageRequested() })
        if (!n) {
            e.push(null)
            e.push({ label: "Hide bookmarks bar", action: () => bar.hideRequested() })
        }
        bmMenu.close()
        ctxMenu.entries = e
        return ctxMenu.popup(null, x, y)
    }

    // --- Internals ------------------------------------------------------

    property int _dropIndex: -1
    property string _dropFolder: ""

    // Where an item dragged to x (in row coordinates) lands: sets
    // _dropIndex (insertion slot) or _dropFolder (onto a folder's middle).
    function _dragTo(from, x) {
        _dropIndex = -1
        _dropFolder = ""
        const n = Math.max(visibleCount, 1)
        for (let i = 0; i < n; ++i) {
            const it = itemAt(i)
            if (!it) break
            if (x < it.x + it.width / 2 && !(it.isFolder && i !== from && x > it.x + it.width / 4)) {
                _dropIndex = i
                return
            }
            if (it.isFolder && i !== from && x < it.x + it.width * 3 / 4) {
                _dropFolder = it.nodeId
                return
            }
        }
        _dropIndex = visibleCount
    }
    function _drop(from) {
        const it = itemAt(from)
        if (it && store) {
            if (_dropFolder !== "") {
                store.move(it.nodeId, _dropFolder, -1)
            } else if (_dropIndex >= 0) {
                const to = _dropIndex > from ? _dropIndex - 1 : _dropIndex
                if (to !== from) store.move(it.nodeId, folder, to)
            }
        }
        _dropIndex = -1
        _dropFolder = ""
    }

    objectName: "bookmarksBar"
    implicitHeight: 30
    color: Style.surface

    BookmarkModel {
        id: model
        store: bar.store
        folder: bar.folder
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => {
            const p = mapToItem(null, mouse.x, mouse.y)
            bar.showContextMenu("", p.x, p.y)
        }
    }

    Item {
        id: strip
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.right: overflowButton.visible ? overflowButton.left : otherButton.left
        anchors.rightMargin: 4
        height: parent.height
        clip: true

        Row {
            id: row
            height: parent.height
            spacing: 2

            Repeater {
                id: repeater
                model: model
                delegate: Rectangle {
                    id: item
                    objectName: "bookmarkBarItem"
                    required property int index
                    required property string nodeId
                    required property bool isFolder
                    required property string title
                    required property string url
                    required property string icon
                    readonly property bool fits: index < bar.visibleCount
                    readonly property bool dragging: itemMouse.drag.active
                    readonly property bool dropTarget: bar._dropFolder === nodeId

                    y: (row.height - height) / 2
                    width: Math.min(bar.maxItemWidth, label.implicitWidth + 16 + (glyph.visible || favicon.visible ? 22 : 0))
                    height: 24
                    radius: Style.radius - 2
                    // Items that do not fit keep their place in the Row
                    // (hiding them would move the next ones back in).
                    opacity: fits ? (dragging ? 0.5 : 1) : 0
                    enabled: fits
                    color: dropTarget || itemMouse.pressed || menuOpen ? Style.surfaceActive
                         : itemMouse.containsMouse ? Style.surfaceHover : "transparent"
                    readonly property bool menuOpen: bmMenu.opened && bmMenu.folder === nodeId

                    Image {
                        id: favicon
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        sourceSize: Qt.size(32, 32)
                        asynchronous: true
                        source: item.isFolder ? "" : item.icon
                        visible: status === Image.Ready
                    }
                    Text {
                        id: glyph
                        anchors.centerIn: favicon
                        visible: !favicon.visible && (item.isFolder || item.title !== "")
                        text: item.isFolder ? "▤" : "☆"
                        color: Style.textDim
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Text {
                        id: label
                        x: glyph.visible || favicon.visible ? 30 : 8
                        width: parent.width - x - 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: item.title !== "" ? item.title : item.isFolder ? "" : item.url
                        elide: Text.ElideRight
                        color: Style.text
                        font.pixelSize: Style.fontSize - 1
                        font.family: Style.fontFamily
                    }
                    MouseArea {
                        id: itemMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        drag.target: bar.dragEnabled ? dragProxy : null
                        drag.axis: Drag.XAxis
                        drag.threshold: 6
                        property bool _dragged: false
                        onPressed: mouse => {
                            _dragged = false
                            if (mouse.button === Qt.LeftButton) {
                                dragProxy.x = item.x
                                dragProxy.width = item.width
                                dragProxy.text = label.text
                            }
                        }
                        onPositionChanged: if (drag.active) {
                            _dragged = true
                            bar._dragTo(item.index, dragProxy.x + item.width / 2)
                        }
                        onReleased: if (_dragged) bar._drop(item.index)
                        onCanceled: { bar._dropIndex = -1; bar._dropFolder = "" }
                        onClicked: mouse => {
                            if (_dragged) return
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                bar.showContextMenu(item.nodeId, p.x, p.y)
                                return
                            }
                            bar.activate(item.index, mouse.button === Qt.MiddleButton
                                         || (mouse.modifiers & Qt.ControlModifier) !== 0)
                        }
                    }
                }
            }
        }

        // What follows the pointer while dragging, and the drop marker.
        Rectangle {
            id: dragProxy
            property alias text: proxyLabel.text
            visible: bar._dropIndex >= 0 || bar._dropFolder !== ""
            y: (parent.height - height) / 2
            height: 24
            radius: Style.radius - 2
            color: Style.surfaceActive
            opacity: 0.85
            Text {
                id: proxyLabel
                anchors.centerIn: parent
                width: parent.width - 16
                elide: Text.ElideRight
                color: Style.text
                font.pixelSize: Style.fontSize - 1
                font.family: Style.fontFamily
            }
        }
        Rectangle {
            readonly property bool atEnd: bar._dropIndex >= bar.visibleCount
            readonly property Item at: bar._dropIndex < 0 ? null
                                     : bar.itemAt(atEnd ? bar.visibleCount - 1 : bar._dropIndex)
            visible: at !== null
            x: !at ? 0 : atEnd ? at.x + at.width : at.x - 2
            y: 4
            width: 2
            height: parent.height - 8
            color: Style.accent
        }

        Text {
            objectName: "bookmarkBarEmpty"
            visible: bar.count === 0
            anchors.verticalCenter: parent.verticalCenter
            x: 4
            text: bar.store ? "Bookmarks you add to the bookmarks bar appear here" : ""
            color: Style.textDim
            font.pixelSize: Style.fontSize - 1
            font.family: Style.fontFamily
        }
    }

    IconButton {
        id: overflowButton
        objectName: "bookmarkBarOverflow"
        anchors.right: otherButton.left
        anchors.rightMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        height: 24
        // Shown when the items do not fit in the space without it.
        visible: row.implicitWidth > bar.width - 10 - otherButton.width - otherButton.anchors.rightMargin
        text: "»"
        textColor: Style.textDim
        checked: bmMenu.opened && bmMenu.folder === bar.folder
        onClicked: bar.openOverflow()
    }

    Rectangle {
        id: otherButton
        objectName: "bookmarkBarOther"
        readonly property bool shown: bar.showOtherFolder && bar.store !== null && bar.folder === bar.store.barFolder
                                      && (bar.store.revision, bar.store.children(bar.store.otherFolder).length > 0)
        anchors.right: parent.right
        anchors.rightMargin: shown ? 6 : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: shown
        width: shown ? otherLabel.implicitWidth + 38 : 0
        height: 24
        radius: Style.radius - 2
        color: otherMouse.pressed || (bmMenu.opened && bmMenu.folder === bar.store.otherFolder) ? Style.surfaceActive
             : otherMouse.containsMouse ? Style.surfaceHover : "transparent"
        Text {
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "▤"
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        Text {
            id: otherLabel
            x: 30
            anchors.verticalCenter: parent.verticalCenter
            text: "Other bookmarks"
            color: Style.text
            font.pixelSize: Style.fontSize - 1
            font.family: Style.fontFamily
        }
        MouseArea {
            id: otherMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    bar.showContextMenu("", p.x, p.y)
                } else {
                    bmMenu.popup(bar.store.otherFolder, otherButton, otherButton.width - bmMenu.menuWidth, otherButton.height + 2)
                }
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Style.border
    }

    BookmarkMenu {
        id: bmMenu
        store: bar.store
        onOpenRequested: (url, newTab) => bar.openRequested(url, newTab)
        onContextMenuRequested: (id, x, y) => bar.showContextMenu(id, x, y)
    }

    BookmarkEditor {
        id: editorItem
        store: bar.store
    }

    PopupMenu {
        id: ctxMenu
        objectName: "bookmarkContextMenu"
    }
}
