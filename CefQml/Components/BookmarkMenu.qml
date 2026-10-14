import QtQuick
import CefQml

// Drop-down menu of a bookmark folder, with sub-menus for the folders in
// it, drawn above the rest of the window. BookmarksBar uses it for its
// folders and its overflow "»" button; use it for a bookmarks menu button
// in your own layout:
//
//   BookmarkMenu {
//       id: bmMenu
//       store: bookmarks
//       onOpenRequested: (url, newTab) => newTab ? tabs.openTab(url, true) : tabs.currentView.url = url
//   }
//   IconButton { text: "★"; onClicked: bmMenu.popup("other", this, 0, height) }
//
// Click a bookmark to open it (Ctrl+click or middle click: newTab), hover
// or click a folder for its sub-menu; middle click on a folder or "Open
// all in tabs" opens all its bookmarks (openRequested(url, true) for each).
// Right click emits contextMenuRequested(id, x, y) (window coordinates).
// A press outside the menu or Escape closes it.
//
// Rows of the open menus (rowAt(level, row)) have objectName
// "bookmarkMenuRow"; panels (panelAt(level)) "bookmarkMenuPanel".
FocusScope {
    id: menu

    property BookmarkStore store: null
    property bool showOpenAll: true
    property real menuWidth: 260
    property int rowHeight: 28
    // Opened menus: [{ folder, startIndex, x, y }], the first is the root.
    readonly property var levels: _levels
    readonly property bool opened: visible
    readonly property string folder: _levels.length > 0 ? _levels[0].folder : ""

    signal openRequested(string url, bool newTab)
    signal contextMenuRequested(string id, real x, real y)
    signal closed()

    // Shows folder `folder` below point (px, py) of `item`, starting at
    // child `startIndex` (e.g. the first one that did not fit in a bar).
    function popup(folder, item, px, py, startIndex) {
        const w = Window.window
        if (!w || !store || !store.isFolder(folder)) return false
        if (parent !== w.contentItem) parent = w.contentItem
        if (!visible) _restoreFocus = w.activeFocusItem
        const p = item ? item.mapToItem(null, px || 0, py || 0) : Qt.point(px || 0, py || 0)
        _levels = [{ folder: folder, startIndex: startIndex || 0, x: Math.max(4, Math.min(p.x, width - menuWidth - 4)), y: p.y }]
        visible = true
        forceActiveFocus(Qt.PopupFocusReason)
        return true
    }
    function close() {
        if (!visible) return
        visible = false
        _levels = []
        const f = _restoreFocus
        _restoreFocus = null
        try { if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason) } catch (e) {}
        closed()
    }
    // Opens the sub-menu of the folder at `row` of menu `level`.
    function openSubmenu(level, row) {
        const panel = panelAt(level)
        const r = rowAt(level, row)
        if (!panel || !r || !r.isFolder) return false
        const p = r.mapToItem(null, 0, 0)
        let x = panel.x + panel.width - 4
        if (x + menuWidth > width - 4) x = Math.max(4, panel.x - menuWidth + 4)
        const lv = _levels.slice(0, level + 1)
        lv.push({ folder: r.nodeId, startIndex: 0, x: x, y: p.y - 4 })
        _levels = lv
        return true
    }
    // Closes the menus deeper than `level`.
    function closeSubmenus(level) {
        if (_levels.length > level + 1) _levels = _levels.slice(0, level + 1)
    }
    function panelAt(level) { return levelRepeater.itemAt(level) }
    // The row item (id, url, title, isFolder via nodeId/nodeUrl/...) of a menu.
    function rowAt(level, row) {
        const p = panelAt(level)
        return p ? p.rowAt(row) : null
    }
    // Opens every bookmark directly in `folder` in new tabs.
    function openAll(folder) {
        if (!store) return 0
        const urls = store.children(folder).filter(n => !n.isFolder).map(n => n.url)
        close()
        for (const u of urls) openRequested(u, true)
        return urls.length
    }
    function activate(level, row, newTab) {
        const r = rowAt(level, row)
        if (!r) return false
        if (r.isFolder) {
            if (newTab) openAll(r.nodeId)
            else openSubmenu(level, row)
            return true
        }
        const url = r.nodeUrl
        close()
        openRequested(url, !!newTab)
        return true
    }

    property var _levels: []
    property var _restoreFocus: null

    visible: false
    z: 10000
    x: 0
    y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    Keys.onEscapePressed: {
        if (_levels.length > 1) closeSubmenus(_levels.length - 2)
        else close()
    }
    Keys.onLeftPressed: if (_levels.length > 1) closeSubmenus(_levels.length - 2)

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
        onWheel: {}
    }

    Repeater {
        id: levelRepeater
        model: menu._levels.length
        delegate: Rectangle {
            id: panel
            objectName: "bookmarkMenuPanel"
            required property int index
            readonly property var level: menu._levels[index] || ({ folder: "", startIndex: 0, x: 0, y: 0 })
            readonly property int level_: index
            readonly property int shownRows: Math.max(0, model.count - level.startIndex)
            readonly property int bookmarkRows: {
                void (menu.store ? menu.store.revision : 0)
                let n = 0
                for (let i = level.startIndex; i < model.count; ++i) if (!model.get(i).isFolder) ++n
                return n
            }
            readonly property bool hasOpenAll: menu.showOpenAll && bookmarkRows > 1
            function rowAt(i) {
                list.forceLayout()
                return list.itemAtIndex(i)
            }

            x: level.x
            y: Math.max(4, Math.min(level.y, menu.height - height - 4))
            width: menu.menuWidth
            height: Math.min(menu.height - 8, Math.max(list.contentHeight, shownRows === 0 ? menu.rowHeight : 0) + footer.height + 8)
            radius: Style.radius
            color: Style.surface
            border.color: Style.border

            BookmarkModel {
                id: model
                store: menu.store
                folder: panel.level.folder
            }

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: wheel => wheel.accepted = false }

            ListView {
                id: list
                x: 4; y: 4
                width: parent.width - 8
                height: parent.height - 8 - footer.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: model
                delegate: Rectangle {
                    id: row
                    objectName: "bookmarkMenuRow"
                    required property int index
                    required property string nodeId
                    required property bool isFolder
                    required property string title
                    required property string url
                    required property string icon
                                        readonly property string nodeUrl: url
                    readonly property bool shown: index >= panel.level.startIndex
                    readonly property bool expanded: menu._levels.length > panel.level_ + 1
                                                     && menu._levels[panel.level_ + 1].folder === nodeId
                    visible: shown
                    width: ListView.view.width
                    height: shown ? menu.rowHeight : 0
                    radius: Style.radius - 2
                    color: rowMouse.containsMouse || expanded ? Style.surfaceHover : "transparent"

                    Item {
                        id: iconBox
                        x: 8
                        width: 16
                        height: parent.height
                        Image {
                            id: favicon
                            anchors.centerIn: parent
                            width: 16; height: 16
                            sourceSize: Qt.size(32, 32)
                            asynchronous: true
                            source: row.isFolder ? "" : row.icon
                            visible: status === Image.Ready
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !favicon.visible
                            text: row.isFolder ? "▤" : "☆"
                            color: Style.textDim
                            font.pixelSize: Style.fontSize
                            font.family: Style.fontFamily
                        }
                    }
                    Text {
                        anchors.left: iconBox.right
                        anchors.leftMargin: 8
                        anchors.right: arrow.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.title || row.url
                        elide: Text.ElideRight
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Text {
                        id: arrow
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.isFolder ? "›" : ""
                        color: Style.textDim
                        font.pixelSize: Style.fontSize + 2
                        font.family: Style.fontFamily
                    }
                    Timer {
                        id: hoverTimer
                        interval: 250
                        onTriggered: if (rowMouse.containsMouse) {
                            if (row.isFolder) menu.openSubmenu(panel.level_, row.index)
                            else menu.closeSubmenus(panel.level_)
                        }
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        onEntered: hoverTimer.restart()
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                menu.contextMenuRequested(row.nodeId, p.x, p.y)
                                return
                            }
                            menu.activate(panel.level_, row.index, mouse.button === Qt.MiddleButton
                                          || (mouse.modifiers & Qt.ControlModifier) !== 0)
                        }
                    }
                }

                Text {
                    visible: panel.shownRows === 0
                    x: 12
                    height: menu.rowHeight
                    verticalAlignment: Text.AlignVCenter
                    text: "(empty)"
                    color: Style.textDim
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
            }

            Item {
                id: footer
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4
                x: 4
                width: parent.width - 8
                height: panel.hasOpenAll ? menu.rowHeight + 9 : 0
                visible: panel.hasOpenAll
                Rectangle { y: 4; width: parent.width; height: 1; color: Style.border }
                Rectangle {
                    objectName: "bookmarkMenuOpenAll"
                    y: 9
                    width: parent.width
                    height: menu.rowHeight
                    radius: Style.radius - 2
                    color: allMouse.containsMouse ? Style.surfaceHover : "transparent"
                    Text {
                        x: 32
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Open all (" + panel.bookmarkRows + ") in tabs"
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    MouseArea {
                        id: allMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: menu.closeSubmenus(panel.level_)
                        onClicked: menu.openAll(panel.level.folder)
                    }
                }
            }
        }
    }
}
