import QtQuick
import CefQml

// A small card for editing one bookmark or folder of a BookmarkStore (name,
// URL, folder) or creating a folder, drawn above the rest of the window
// below an anchor item (or centred). BookmarkButton, BookmarksBar and
// BookmarkManager each have one; in your own layout:
//
//   BookmarkEditor { id: editor; store: bookmarks }
//   ... editor.edit(id, starButton)          // or editor.newFolder("bar")
//
// Enter or "Done" saves, Escape or "Cancel" closes without changes, a click
// outside saves (like Enter), "Remove" deletes the bookmark. The folder
// button opens a list of folders to move it to.
//
// objectNames: bookmarkEditor (the card), bookmarkEditorName,
// bookmarkEditorUrl, bookmarkEditorFolder, bookmarkEditorFolderList,
// bookmarkEditorRemove, bookmarkEditorCancel, bookmarkEditorSave,
// bookmarkEditorError.
FocusScope {
    id: editor

    property BookmarkStore store: null
    // Edit URLs of bookmarks (otherwise only the name and folder).
    property bool showUrl: true
    readonly property bool opened: visible
    // The edited node ("" while creating a folder).
    readonly property string nodeId: _id
    // "bookmark", "folder" or "newFolder".
    readonly property string mode: _mode
    readonly property bool isNew: _isNew
    property alias name: nameField.text
    property alias url: urlField.text
    // The folder the node is (to be) in.
    property string folder: ""
    readonly property string error: _error
    readonly property Item card: card

    // After saving (removed: the bookmark was removed) or cancelling.
    signal finished(string id, bool removed)

    // Edits node `id`, below `anchorItem` (optional). opts: { added: true }
    // titles it "Bookmark added" (for a bookmark that was just created).
    function edit(id, anchorItem, opts) {
        if (!store || !store.contains(id) || id === store.rootFolder) return false
        const n = store.get(id)
        opts = opts || {}
        _id = id
        _mode = n.isFolder ? "folder" : "bookmark"
        _isNew = !!opts.added
        _index = -1
        _heading = opts.added ? "Bookmark added" : n.isFolder ? "Edit folder" : "Edit bookmark"
        nameInput.text = n.title
        urlInput.text = n.url ? _display(n.url) : ""
        _shownUrl = urlInput.text
        folder = n.parent
        return _open(anchorItem)
    }
    // Asks for the name of a new folder in `parentFolder` (at `index`).
    function newFolder(parentFolder, index, anchorItem) {
        if (!store) return false
        if (!parentFolder || !store.isFolder(parentFolder) || parentFolder === store.rootFolder)
            parentFolder = store.defaultFolder
        _id = ""
        _mode = "newFolder"
        _isNew = true
        _index = index === undefined ? -1 : index
        _heading = "New folder"
        nameInput.text = "New folder"
        urlInput.text = ""
        folder = parentFolder
        return _open(anchorItem)
    }
    // Saves and closes; false (staying open) if the URL is invalid.
    function accept() {
        if (!visible) return false
        if (!store) { _close(); return false }
        let id = _id
        if (_mode === "newFolder") {
            id = store.addFolder(nameInput.text, { folder: folder, index: _index })
        } else if (store.contains(id)) {
            const changes = { title: nameInput.text }
            // Only a URL the user changed is parsed again.
            if (_mode === "bookmark" && showUrl && urlInput.text !== _shownUrl) {
                const typed = urlInput.text.trim()
                const u = Cef.urlFromUserInput(typed).toString()
                if (u === "") {
                    _error = "Enter a valid URL"
                    urlInput.forceActiveFocus()
                    return false
                }
                if (store.normalizeUrl(u) !== store.get(id).url) changes.url = u
            }
            if (_mode === "folder" && nameInput.text.trim() === "") changes.title = store.get(id).title
            store.update(id, changes)
            if (folder !== store.get(id).parent && store.isFolder(folder)) store.move(id, folder, -1)
        }
        _close()
        finished(id, false)
        return true
    }
    function cancel() {
        if (!visible) return
        const id = _id
        _close()
        finished(id, false)
    }
    // Removes the edited bookmark or folder and closes.
    function remove() {
        if (!visible) return false
        const id = _id
        if (store && id !== "") store.remove(id)
        _close()
        finished(id, true)
        return true
    }
    // The folders it can be moved to: [{ id, title, depth }].
    readonly property var folderChoices: _folders

    // --- Internals ------------------------------------------------------

    property string _id: ""
    property string _mode: "bookmark"
    property bool _isNew: false
    property int _index: -1
    property string _heading: ""
    property string _error: ""
    property string _shownUrl: ""
    property var _folders: []
    property bool _picking: false
    property var _restoreFocus: null

    function _display(u) {
        u = String(u)
        try { return decodeURI(u) } catch (e) { return u }
    }
    function _open(anchorItem) {
        const w = Window.window
        if (!w) return false
        if (parent !== w.contentItem) parent = w.contentItem
        if (!visible) _restoreFocus = w.activeFocusItem
        _error = ""
        _picking = false
        _folders = store.folders().filter(f => _mode === "bookmark" || _mode === "newFolder"
                                             || !store.isAncestor(_id, f.id))
        visible = true
        if (anchorItem) {
            const p = anchorItem.mapToItem(null, anchorItem.width, anchorItem.height + 4)
            card.x = Math.max(8, Math.min(p.x - card.width, width - card.width - 8))
            card.y = Math.max(8, Math.min(p.y, height - card.height - 8))
        } else {
            card.x = Math.round((width - card.width) / 2)
            card.y = Math.max(8, Math.round((height - card.height) / 3))
        }
        nameInput.forceActiveFocus(Qt.PopupFocusReason)
        nameInput.selectAll()
        return true
    }
    function _close() {
        visible = false
        _picking = false
        const f = _restoreFocus
        _restoreFocus = null
        try { if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason) } catch (e) {}
    }
    function _folderTitle(id) {
        const f = store ? store.get(id) : undefined
        return f ? f.title : ""
    }
    function _keys(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            accept()
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            if (_picking) _picking = false
            else cancel()
            event.accepted = true
        }
    }

    visible: false
    z: 10002
    x: 0
    y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    Keys.onPressed: event => _keys(event)

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: editor.accept()
        onWheel: {}
    }

    component Field: Rectangle {
        property alias input: field
        property alias text: field.text
        property string label
        width: parent.width
        height: 30
        radius: Style.radius
        color: Style.background
        border.color: field.activeFocus ? Style.accent : Style.border
        TextInput {
            id: field
            anchors.fill: parent
            anchors.leftMargin: 8; anchors.rightMargin: 8
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Style.text
            selectionColor: Style.accent
            selectByMouse: true
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
            Keys.onPressed: event => editor._keys(event)
            KeyNavigation.tab: null
        }
    }

    component Button: Rectangle {
        id: button
        property string text
        property bool primary: false
        property bool danger: false
        signal clicked()
        implicitWidth: label.implicitWidth + 20
        implicitHeight: 28
        radius: Style.radius
        color: primary ? (mouse.pressed ? Qt.darker(Style.accent, 1.2) : Style.accent)
             : mouse.pressed ? Style.surfaceActive
             : mouse.containsMouse ? Style.surfaceHover : Style.background
        border.color: primary ? "transparent" : danger && mouse.containsMouse ? Style.danger : Style.border
        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: button.primary ? "white" : button.danger ? Style.danger : Style.text
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component Caption: Text {
        color: Style.textDim
        font.pixelSize: Style.fontSize - 1
        font.family: Style.fontFamily
    }

    Rectangle {
        id: card
        objectName: "bookmarkEditor"
        width: 320
        height: column.implicitHeight + 28
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: editor._picking = false }

        Column {
            id: column
            x: 14; y: 14
            width: parent.width - 28
            spacing: 6

            Text {
                text: editor._heading
                color: Style.text
                font.pixelSize: Style.fontSize + 2
                font.bold: true
                font.family: Style.fontFamily
                bottomPadding: 4
            }
            Caption { text: "Name" }
            Field {
                id: nameField
                Component.onCompleted: input.objectName = "bookmarkEditorName"
            }
            Caption { text: "URL"; visible: urlField.visible }
            Field {
                id: urlField
                visible: editor._mode === "bookmark" && editor.showUrl
                Component.onCompleted: input.objectName = "bookmarkEditorUrl"
            }
            Caption { text: "Folder" }
            Rectangle {
                objectName: "bookmarkEditorFolder"
                width: parent.width
                height: 30
                radius: Style.radius
                color: folderMouse.containsMouse ? Style.surfaceHover : Style.background
                border.color: editor._picking ? Style.accent : Style.border
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    text: editor._folderTitle(editor.folder)
                    elide: Text.ElideRight
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: "▾"
                    color: Style.textDim
                    font.pixelSize: Style.fontSize
                }
                MouseArea {
                    id: folderMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: editor._picking = !editor._picking
                }
            }
            Rectangle {
                visible: editor._picking
                width: parent.width
                height: visible ? Math.min(folderList.contentHeight, 26 * 6) + 4 : 0
                radius: Style.radius
                color: Style.background
                border.color: Style.border
                ListView {
                    id: folderList
                    objectName: "bookmarkEditorFolderList"
                    anchors.fill: parent
                    anchors.margins: 2
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: editor._folders
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        objectName: "bookmarkEditorFolderRow"
                        readonly property string folderId: modelData.id
                        width: ListView.view.width
                        height: 26
                        radius: Style.radius - 2
                        color: modelData.id === editor.folder ? Style.surfaceActive
                             : rowMouse.containsMouse ? Style.surfaceHover : "transparent"
                        Text {
                            x: 8 + 14 * parent.modelData.depth
                            width: parent.width - x - 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: parent.modelData.title
                            elide: Text.ElideRight
                            color: Style.text
                            font.pixelSize: Style.fontSize
                            font.family: Style.fontFamily
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                editor.folder = parent.modelData.id
                                editor._picking = false
                            }
                        }
                    }
                }
            }
            Text {
                objectName: "bookmarkEditorError"
                visible: text !== ""
                text: editor._error
                color: Style.danger
                font.pixelSize: Style.fontSize - 1
                font.family: Style.fontFamily
            }
            Item {
                width: parent.width
                height: 36
                Button {
                    objectName: "bookmarkEditorRemove"
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    visible: editor._mode !== "newFolder"
                    text: "Remove"
                    danger: true
                    onClicked: editor.remove()
                }
                Row {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 6
                    Button {
                        objectName: "bookmarkEditorCancel"
                        text: "Cancel"
                        onClicked: editor.cancel()
                    }
                    Button {
                        objectName: "bookmarkEditorSave"
                        text: editor._mode === "newFolder" ? "Create" : "Done"
                        primary: true
                        onClicked: editor.accept()
                    }
                }
            }
        }
    }

    // Aliases into the fields.
    readonly property TextInput nameInput: nameField.input
    readonly property TextInput urlInput: urlField.input
}
