import QtQuick
import CefQml

// Bookmark manager page for a BookmarkStore: the folder tree on the left,
// the selected folder's bookmarks and sub-folders on the right, a search
// over all bookmarks, editing (✎), removal (×), new folders, reordering,
// and import / export of Netscape bookmark HTML (what every browser
// exports) or JSON.
//
//   BookmarkManager {
//       anchors.fill: parent
//       store: bookmarks
//       onOpenRequested: (url, newTab) => newTab ? tabs.openTab(url) : tabs.currentView.url = url
//       onCloseRequested: visible = false
//   }
//
// Click selects; double click or Enter opens (a folder: shows it); middle
// click or Ctrl+click / Ctrl+Enter opens in a new tab. Keys (in the search
// field): Up/Down select, Ctrl+Up/Down move the selected item, F2 edits,
// Shift+Delete (or Delete with an empty search) removes, Backspace with an
// empty search goes to the parent folder, Escape clears the search, then
// emits closeRequested(). `Browser` shows one as an overlay (action
// "bookmarks.manage", Ctrl+Shift+O).
//
// objectNames: bookmarkManagerSearch, bookmarkFolderList (rows
// folderRowAt(i): bookmarkFolderRow), bookmarkList (rows rowAt(i):
// bookmarkRow, containing bookmarkEdit and bookmarkRemove), bookmarkEmpty,
// bookmarkStatus, bookmarkNewFolder, bookmarkUp, bookmarkImportExport,
// bookmarkFilePath, bookmarkImport, bookmarkExportHtml, bookmarkExportJson,
// bookmarkManagerClose.
FocusScope {
    id: bm

    property BookmarkStore store: null
    // The folder shown on the right.
    property string currentFolder: store ? store.barFolder : "bar"
    property alias filterText: search.text
    // Selected row of the list (-1: none).
    property alias currentIndex: list.currentIndex
    readonly property int count: items.count
    readonly property BookmarkModel model: items
    readonly property BookmarkModel folderModel: folderTree
    property string title: "Bookmarks"
    property bool closable: true
    // File used by Import / Export ("~" is the home directory).
    property alias filePath: fileInput.text
    readonly property bool showingFileRow: _fileRow
    readonly property string status: _status
    readonly property BookmarkEditor editor: editorItem

    signal openRequested(string url, bool newTab)
    signal closeRequested()

    implicitWidth: 760
    implicitHeight: 560

    // --- API ------------------------------------------------------------

    function focusDefault() { search.forceActiveFocus(Qt.OtherFocusReason) }
    // The node at row `i` of the list ({ id, title, url, isFolder, ... }).
    function entryAt(i) { return items.get(i) }
    // Shows folder `id` on the right (clears the search).
    function selectFolder(id) {
        if (!store || !store.isFolder(id) || id === store.rootFolder) return false
        search.text = ""
        currentFolder = id
        currentIndex = -1
        return true
    }
    // Opens row `i` (default: the selected one): a bookmark through
    // openRequested(), a folder by showing it (newTab: all its bookmarks).
    function open(i, newTab) {
        const e = entryAt(i === undefined ? currentIndex : i)
        if (!e) return false
        if (e.isFolder) {
            if (newTab) {
                for (const c of store.children(e.id)) if (!c.isFolder) openRequested(c.url, true)
            } else {
                selectFolder(e.id)
            }
            return true
        }
        openRequested(e.url, !!newTab)
        return true
    }
    // Removes row `i` (default: the selected one).
    function remove(i) {
        const row = i === undefined ? currentIndex : i
        const e = entryAt(row)
        if (!e || !store) return false
        store.remove(e.id)
        _setStatus("Removed " + (e.title || _display(e.url)))
        currentIndex = count > 0 && row >= 0 ? Math.min(row, count - 1) : -1
        return true
    }
    // Opens the editor of row `i` (default: the selected one).
    function edit(i) {
        const row = i === undefined ? currentIndex : i
        const e = entryAt(row)
        return !!e && editorItem.edit(e.id, rowAt(row))
    }
    // Asks for the name of a new folder in the current folder.
    function newFolder() {
        if (!store) return false
        const at = currentIndex >= 0 && filterText === "" ? currentIndex + 1 : -1
        return editorItem.newFolder(currentFolder, at, null)
    }
    // Moves row `i` by `delta` places in its folder (Ctrl+Up/Down).
    function moveBy(i, delta) {
        const e = entryAt(i)
        if (!e || !store || filterText !== "") return false
        const to = e.position + delta
        if (to < 0 || to >= store.children(e.parent).length) return false
        store.move(e.id, e.parent, to)
        currentIndex = items.indexOf(e.id)
        return true
    }
    // Imports a bookmarks HTML or JSON file (default: filePath) into the
    // store (its bar and other folders merge with ours).
    function importFile(file) {
        if (!store) return false
        const r = store.importFile(file || filePath)
        _setStatus(r.ok ? "Imported " + r.bookmarks + (r.bookmarks === 1 ? " bookmark" : " bookmarks")
                          + (r.folders ? " and " + r.folders + (r.folders === 1 ? " folder" : " folders") : "")
                        : "Import failed: " + r.error)
        return r.ok
    }
    // Exports all bookmarks as "html" (Netscape format) or "json".
    function exportFile(format, file) {
        if (!store) return false
        let f = file || filePath
        if (!file && format === "json" && /\.html?$/i.test(f)) f = f.replace(/\.html?$/i, ".json")
        else if (!file && format === "html" && /\.json$/i.test(f)) f = f.replace(/\.json$/i, ".html")
        const ok = store.exportFile(f, format)
        _setStatus(ok ? "Exported " + store.count + (store.count === 1 ? " bookmark" : " bookmarks") + " to " + f
                      : "Export failed: " + store.errorString)
        return ok
    }
    function showFileRow(show) { _fileRow = show === undefined ? true : !!show }
    // The list delegate of row `i` (null when not instantiated).
    function rowAt(i) {
        list.forceLayout()
        return list.itemAtIndex(i)
    }
    // The folder tree delegate of row `i`.
    function folderRowAt(i) {
        tree.forceLayout()
        return tree.itemAtIndex(i)
    }
    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        switch (event.key) {
        case Qt.Key_Down:
            if (ctrl) moveBy(currentIndex, 1)
            else _move(1)
            break
        case Qt.Key_Up:
            if (ctrl) moveBy(currentIndex, -1)
            else _move(-1)
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (currentIndex < 0 && count > 0 && filterText !== "") currentIndex = 0
            if (!open(currentIndex, (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) !== 0)) return
            break
        case Qt.Key_F2:
            if (!edit()) return
            break
        case Qt.Key_Delete:
            if (currentIndex < 0 || (!(event.modifiers & Qt.ShiftModifier) && filterText !== "")) return
            remove(currentIndex)
            break
        case Qt.Key_Backspace: {
            if (filterText !== "" || !store) return
            const p = store.get(currentFolder)
            if (!p || p.parent === store.rootFolder) return
            const from = currentFolder
            selectFolder(p.parent)
            currentIndex = items.indexOf(from)
            break
        }
        case Qt.Key_Escape:
            if (filterText !== "") filterText = ""
            else closeRequested()
            break
        default:
            return
        }
        event.accepted = true
    }

    // --- Internals ------------------------------------------------------

    property string _status: ""
    property bool _fileRow: false

    function _display(u) {
        u = String(u)
        try { u = decodeURI(u) } catch (e) {}
        return u.length > 300 ? u.substring(0, 300) + "…" : u
    }
    function _setStatus(text) { _status = text }
    function _move(delta) {
        if (count === 0) return
        const i = currentIndex < 0 ? (delta > 0 ? 0 : count - 1) : currentIndex + delta
        currentIndex = Math.max(0, Math.min(count - 1, i))
        list.positionViewAtIndex(currentIndex, ListView.Contain)
    }
    function _homeFile() {
        return "~/bookmarks.html"
    }

    onFilterTextChanged: currentIndex = filterText !== "" && count > 0 ? 0 : -1
    onCountChanged: if (currentIndex >= count) currentIndex = count - 1
    Keys.onPressed: event => handleKey(event)

    // The current folder went away (removed, or a folder above it was).
    Connections {
        target: bm.store
        function onChanged() {
            if (bm.store && !bm.store.isFolder(bm.currentFolder)) bm.currentFolder = bm.store.barFolder
        }
    }

    BookmarkModel {
        id: folderTree
        store: bm.store
        folder: bm.store ? bm.store.rootFolder : ""
        recursive: true
        foldersOnly: true
    }
    BookmarkModel {
        id: items
        store: bm.store
        // A search covers every folder.
        folder: bm.filterText !== "" && bm.store ? bm.store.rootFolder : bm.currentFolder
        filterText: bm.filterText
    }

    component Button: Rectangle {
        id: button
        property string text
        property bool enabled: true
        property bool checked: false
        signal clicked()
        implicitWidth: label.implicitWidth + 20
        implicitHeight: 26
        radius: Style.radius
        opacity: enabled ? 1 : 0.4
        color: mouse.pressed || checked ? Style.surfaceActive
             : mouse.containsMouse ? Style.surfaceHover : Style.background
        border.color: Style.border
        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: Style.text
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: bm.focusDefault()
            onWheel: {}
        }
    }

    Column {
        id: header
        x: 16; y: 14
        width: parent.width - 32
        spacing: 10

        Item {
            width: parent.width
            height: 28
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - buttons.width - 16
                text: bm.title
                color: Style.text
                font.pixelSize: Style.fontSize + 3
                font.bold: true
                font.family: Style.fontFamily
                elide: Text.ElideRight
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Button {
                    objectName: "bookmarkNewFolder"
                    text: "New folder"
                    enabled: bm.store !== null
                    onClicked: bm.newFolder()
                }
                Button {
                    objectName: "bookmarkImportExport"
                    text: "Import / export…"
                    enabled: bm.store !== null
                    checked: bm._fileRow
                    onClicked: bm.showFileRow(!bm._fileRow)
                }
                IconButton {
                    objectName: "bookmarkManagerClose"
                    visible: bm.closable
                    text: "×"
                    onClicked: bm.closeRequested()
                }
            }
        }

        // Import / export.
        Rectangle {
            visible: bm._fileRow
            width: parent.width
            height: visible ? 42 : 0
            radius: Style.radius
            color: Style.background
            border.color: Style.border
            Rectangle {
                id: fileBox
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 16 - fileButtons.width - 8
                height: 28
                radius: Style.radius
                color: Style.surface
                border.color: fileInput.activeFocus ? Style.accent : Style.border
                TextInput {
                    id: fileInput
                    objectName: "bookmarkFilePath"
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    text: bm._homeFile()
                    color: Style.text
                    selectionColor: Style.accent
                    selectByMouse: true
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                    Keys.onEscapePressed: bm.showFileRow(false)
                }
            }
            Row {
                id: fileButtons
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Button { objectName: "bookmarkImport"; text: "Import"; onClicked: bm.importFile() }
                Button { objectName: "bookmarkExportHtml"; text: "Export HTML"; onClicked: bm.exportFile("html") }
                Button { objectName: "bookmarkExportJson"; text: "Export JSON"; onClicked: bm.exportFile("json") }
            }
        }

        Rectangle {
            width: parent.width
            height: 30
            radius: Style.radius
            color: Style.background
            border.color: search.activeFocus ? Style.accent : Style.border
            TextInput {
                id: search
                objectName: "bookmarkManagerSearch"
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                focus: true
                color: Style.text
                selectionColor: Style.accent
                selectByMouse: true
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
                Keys.onPressed: event => bm.handleKey(event)
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: search.text === ""
                    text: "Search bookmarks"
                    color: Style.textDim
                    font: search.font
                    elide: Text.ElideRight
                }
            }
        }

        Text {
            objectName: "bookmarkStatus"
            width: parent.width
            visible: text !== ""
            text: bm._status
            color: Style.textDim
            elide: Text.ElideRight
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
    }

    // Folder tree.
    ListView {
        id: tree
        objectName: "bookmarkFolderList"
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        width: Math.min(220, parent.width / 3)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: folderTree
        delegate: Rectangle {
            id: folderRow
            objectName: "bookmarkFolderRow"
            required property int index
            required property string nodeId
            required property string title
            required property int depth
            readonly property bool selected: bm.filterText === "" && nodeId === bm.currentFolder
            width: ListView.view.width
            height: 28
            radius: Style.radius
            color: selected ? Style.surfaceActive : folderMouse.containsMouse ? Style.surfaceHover : "transparent"
            Text {
                x: 8 + 14 * folderRow.depth
                width: parent.width - x - 8
                anchors.verticalCenter: parent.verticalCenter
                text: "▤  " + folderRow.title
                elide: Text.ElideRight
                color: Style.text
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
            }
            MouseArea {
                id: folderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    bm.selectFolder(folderRow.nodeId)
                    bm.focusDefault()
                }
            }
        }
    }

    Rectangle {
        id: divider
        anchors.top: tree.top
        anchors.bottom: tree.bottom
        anchors.left: tree.right
        anchors.leftMargin: 6
        width: 1
        color: Style.border
    }

    Item {
        id: crumbs
        anchors.top: tree.top
        anchors.left: divider.right
        anchors.leftMargin: 8
        anchors.right: parent.right
        anchors.rightMargin: 8
        height: 28
        readonly property var node: bm.store ? (bm.store.revision, bm.store.get(bm.currentFolder)) : undefined
        IconButton {
            id: upButton
            objectName: "bookmarkUp"
            anchors.verticalCenter: parent.verticalCenter
            text: "↑"
            enabled: bm.filterText === "" && !!crumbs.node && crumbs.node.parent !== bm.store.rootFolder
            onClicked: bm.selectFolder(crumbs.node.parent)
        }
        Text {
            anchors.left: upButton.right
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: bm.filterText !== "" ? bm.count + (bm.count === 1 ? " result" : " results")
                : crumbs.node ? crumbs.node.path.concat([crumbs.node.title]).join("  ›  ") : ""
            elide: Text.ElideLeft
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
    }

    ListView {
        id: list
        objectName: "bookmarkList"
        anchors.top: crumbs.bottom
        anchors.topMargin: 4
        anchors.left: crumbs.left
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        clip: true
        currentIndex: -1
        boundsBehavior: Flickable.StopAtBounds
        highlightFollowsCurrentItem: false
        model: items

        Text {
            objectName: "bookmarkEmpty"
            anchors.centerIn: parent
            visible: list.count === 0
            width: parent.width - 32
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: !bm.store ? "No bookmark store."
                : bm.filterText !== "" ? "No bookmarks match “" + bm.filterText + "”."
                : "This folder is empty."
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }

        delegate: Rectangle {
            id: row
            objectName: "bookmarkRow"
            required property int index
            required property string nodeId
            required property bool isFolder
            required property string title
            required property string url
            required property string icon
            required property int childCount
            required property var path

            width: ListView.view.width
            height: 40
            radius: Style.radius
            color: ListView.isCurrentItem ? Style.surfaceActive
                 : rowMouse.containsMouse ? Style.surfaceHover : "transparent"

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    bm.currentIndex = row.index
                    bm.focusDefault()
                    if (mouse.button === Qt.MiddleButton || (mouse.modifiers & Qt.ControlModifier) !== 0)
                        bm.open(row.index, true)
                }
                onDoubleClicked: mouse => {
                    if (mouse.button === Qt.LeftButton) bm.open(row.index, false)
                }
            }

            Item {
                id: iconBox
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 16; height: 16
                Image {
                    id: favicon
                    anchors.fill: parent
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
                }
            }
            Column {
                anchors.left: iconBox.right
                anchors.leftMargin: 10
                anchors.right: rowButtons.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    width: parent.width
                    text: row.title || bm._display(row.url)
                    color: Style.text
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    text: (row.isFolder ? row.childCount + (row.childCount === 1 ? " item" : " items")
                                        : bm._display(row.url))
                          + (bm.filterText !== "" && row.path.length > 0 ? "  ·  " + row.path.join(" › ") : "")
                    color: Style.textDim
                    elide: Text.ElideMiddle
                    font.pixelSize: Style.fontSize - 2
                    font.family: Style.fontFamily
                }
            }
            Row {
                id: rowButtons
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                IconButton {
                    objectName: "bookmarkEdit"
                    text: "✎"
                    textColor: rowMouse.containsMouse || row.ListView.isCurrentItem ? Style.text : Style.textDim
                    onClicked: { bm.currentIndex = row.index; bm.edit(row.index) }
                }
                IconButton {
                    objectName: "bookmarkRemove"
                    text: "×"
                    textColor: rowMouse.containsMouse || row.ListView.isCurrentItem ? Style.text : Style.textDim
                    onClicked: bm.remove(row.index)
                }
            }
        }
    }

    BookmarkEditor {
        id: editorItem
        store: bm.store
    }
}
