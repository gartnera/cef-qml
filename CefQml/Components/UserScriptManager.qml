import QtQuick
import CefQml

// Manager UI for a UserScriptStore: the installed scripts with enable
// switches, what they run on, which of them run on the current page, and
// a source editor to write, paste, review and install scripts.
//
//   UserScriptManager {
//       anchors.fill: parent
//       store: myUserScriptStore
//       view: tabs.currentView        // "running on this page", templates
//       onCloseRequested: visible = false
//   }
//
// `Browser` shows one as an overlay (action "userscripts.manage",
// Ctrl+Shift+U). Items carry objectNames for tests and automation:
// userScriptList, userScriptUrlInput, userScriptReviewUrl,
// userScriptNew, userScriptPaste, userScriptStatus, userScriptEditor,
// userScriptSave, userScriptCancel, userScriptClose, and per script
// userScriptRow_<id>, userScriptToggle_<id>, userScriptRunning_<id>,
// userScriptEdit_<id>, userScriptRemove_<id>, userScriptClearValues_<id>.
FocusScope {
    id: manager

    property var store: null
    property CefWebView view: null

    // Ids of the store's scripts running in `view`'s current top document.
    readonly property var runningIds: _running
    // "" while showing the list, "new" for a script that is not installed
    // yet, otherwise the id of the script being edited.
    readonly property string editing: _editing
    // Where the script in the editor came from (review(url)); passed to
    // install() as its url (base of relative @require).
    readonly property string editorUrl: _editorUrl
    readonly property string editorText: editor.text
    readonly property bool editorModified: _editing !== "" && editor.text !== _editorOriginal
    // Last message shown in the status line.
    readonly property string status: _status
    readonly property bool statusIsError: _statusIsError

    signal closeRequested()

    implicitWidth: 720
    implicitHeight: 520

    // --- API ------------------------------------------------------------

    // Opens script `id` in the editor.
    function edit(id) {
        const s = store ? store.script(id) : null
        if (!s) return false
        _openEditor(id, s.source, s.url)
        return true
    }
    // Opens the editor on a new script: `source`, or a template matching
    // the current page.
    function newScript(source) {
        _openEditor("new", source === undefined || source === "" ? template() : String(source), "")
    }
    // Opens the editor on the clipboard's text (installing from a paste).
    function pasteScript() {
        _openEditor("new", "", "")
        editor.paste()
        if (editor.text === "") {
            editor.text = template()
            _setStatus("The clipboard is empty", true)
        }
        _editorOriginal = ""   // a paste is unsaved
    }
    // Fetches `url` and opens it in the editor for review; Save installs it.
    function review(url) {
        url = String(url || "").trim()
        if (!store || url === "") return
        _setStatus("Fetching " + url + "…", false)
        const generation = ++_fetchGeneration
        store.fetchSource(url, (text, error) => {
            if (generation !== _fetchGeneration) return
            if (error) { _setStatus("Could not fetch " + url + ": " + error, true); return }
            const meta = store.parseMetadata(text)
            if (!meta) { _setStatus(url + " is not a userscript (no ==UserScript== block)", true); return }
            _openEditor("new", text, url)
            const existing = store.scripts.find(s => s.name === meta.name && (s.namespace || "") === meta.namespace)
            _setStatus((existing ? "Update " : "Install ") + (meta.name || url)
                       + (meta.version ? " " + meta.version : "")
                       + (existing ? " (installed: " + (existing.version || "?") + ")" : "")
                       + "? Review the source, then Save.", false)
        })
    }
    // Installs or updates the editor's text; returns the store's result.
    function save() {
        if (!store || _editing === "") return { ok: false, error: "Nothing to save" }
        const text = editor.text
        const r = _editing === "new" ? store.install(text, { url: _editorUrl })
                                     : store.update(_editing, text)
        if (!r.ok) {
            _setStatus(r.error, true)
            return r
        }
        const what = (r.script.name || "Script") + (r.script.version ? " " + r.script.version : "")
        _setStatus((r.updated ? "Updated " : "Installed ") + what
                   + (r.warnings && r.warnings.length ? " (" + r.warnings.join("; ") + ")" : "")
                   + ". It applies to pages loaded from now on.", false)
        _closeEditor()
        return r
    }
    function cancelEdit() {
        _closeEditor()
        _setStatus("", false)
    }
    function setEnabled(id, enabled) {
        if (store) store.setEnabled(id, enabled)
    }
    function toggle(id) {
        const s = store ? store.script(id) : null
        if (s) store.setEnabled(id, !s.enabled)
    }
    // Removes script `id` (and its values).
    function remove(id) {
        const s = store ? store.script(id) : null
        if (!s) return false
        store.remove(id)
        _setStatus("Removed " + s.name, false)
        return true
    }
    function clearValues(id) {
        const s = store ? store.script(id) : null
        if (!s) return
        store.clearValues(id)
        _setStatus("Cleared the stored values of " + s.name, false)
    }
    // A new script matching the current page's site.
    function template() {
        const u = view ? String(view.url) : ""
        const m = /^(https?):\/\/([^/?#]+)/i.exec(u)
        const match = m ? m[1].toLowerCase() + "://" + m[2] + "/*" : "*://*/*"
        return "// ==UserScript==\n"
             + "// @name        New script\n"
             + "// @namespace   cefqml\n"
             + "// @version     1.0\n"
             + "// @description \n"
             + "// @match       " + match + "\n"
             + "// @grant       none\n"
             + "// ==/UserScript==\n\n"
    }
    function focusDefault() {
        if (_editing !== "") editor.forceActiveFocus()
        else manager.forceActiveFocus()
    }

    // --- Internals ------------------------------------------------------

    property var _running: []
    property string _editing: ""
    property string _editorUrl: ""
    property string _editorOriginal: ""
    property string _status: ""
    property bool _statusIsError: false
    property int _fetchGeneration: 0
    property int _valuesTick: 0
    // Two-step removal: the id whose Remove button asks for confirmation.
    property string _confirmRemove: ""

    function _setStatus(text, error) {
        _status = text
        _statusIsError = !!error
    }
    function _openEditor(id, source, url) {
        _editing = id
        _editorUrl = url || ""
        editor.text = source
        _editorOriginal = source
        editor.cursorPosition = 0
        editorFlick.contentX = 0
        editorFlick.contentY = 0
        Qt.callLater(() => editor.forceActiveFocus())
    }
    function _closeEditor() {
        _editing = ""
        _editorUrl = ""
        editor.text = ""
        _editorOriginal = ""
        manager.forceActiveFocus()
    }
    function _refreshRunning() {
        _running = store && view ? store.runningScripts(view) : []
    }
    function _valueCount(id) {
        _valuesTick   // dependency
        return store ? Object.keys(store.values(id)).length : 0
    }

    onViewChanged: _refreshRunning()
    onStoreChanged: { _refreshRunning(); if (_editing !== "") _closeEditor() }
    Component.onCompleted: _refreshRunning()

    Connections {
        target: manager.store
        ignoreUnknownSignals: true
        function onRunningChanged(v) { if (v === manager.view) manager._refreshRunning() }
        function onValuesChanged() { manager._valuesTick++ }
        function onRemoved(id) {
            if (manager._editing === id) manager._closeEditor()
            manager._valuesTick++
        }
    }

    Keys.onEscapePressed: event => {
        if (_editing === "") { closeRequested(); return }
        if (editorModified) _setStatus("Unsaved changes: Save (Ctrl+S) or Cancel", true)
        else cancelEdit()
    }

    // --- Pieces ---------------------------------------------------------

    component Button: Rectangle {
        id: button
        property string text
        property bool primary: false
        property bool danger: false
        property bool enabled: true
        signal clicked()
        implicitWidth: label.implicitWidth + 20
        implicitHeight: 26
        radius: Style.radius
        opacity: enabled ? 1 : 0.4
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
            enabled: button.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component Switch: Rectangle {
        id: sw
        property bool checked: false
        signal toggled()
        implicitWidth: 34
        implicitHeight: 18
        radius: height / 2
        color: checked ? Style.accent : Style.surfaceActive
        Rectangle {
            width: parent.height - 4; height: width
            radius: width / 2
            y: 2
            x: sw.checked ? sw.width - width - 2 : 2
            color: "white"
            Behavior on x { NumberAnimation { duration: 90 } }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled()
        }
    }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border
        // Keeps clicks and wheel events from reaching what is underneath.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: manager.focusDefault()
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
                text: manager._editing === "" ? "Userscripts"
                    : manager._editing === "new" ? "New userscript"
                    : "Edit " + ((manager.store && manager.store.script(manager._editing) || {}).name || "")
                color: Style.text
                font.pixelSize: Style.fontSize + 3
                font.bold: true
                font.family: Style.fontFamily
                elide: Text.ElideRight
                width: parent.width - closeButton.width - 8
            }
            IconButton {
                id: closeButton
                objectName: "userScriptClose"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                onClicked: manager.closeRequested()
            }
        }

        // Install row (list mode).
        Row {
            visible: manager._editing === ""
            width: parent.width
            spacing: 6
            Rectangle {
                width: parent.width - reviewButton.width - newButton.width - pasteButton.width - 3 * parent.spacing
                height: 26
                radius: Style.radius
                color: Style.background
                border.color: urlInput.activeFocus ? Style.accent : Style.border
                TextInput {
                    id: urlInput
                    objectName: "userScriptUrlInput"
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Style.text
                    selectionColor: Style.accent
                    selectByMouse: true
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                    Keys.onReturnPressed: manager.review(text)
                    Keys.onEnterPressed: manager.review(text)
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: urlInput.text === "" && !urlInput.activeFocus
                        text: "Install from URL (https://…/script.user.js)"
                        color: Style.textDim
                        font: urlInput.font
                        elide: Text.ElideRight
                    }
                }
            }
            Button {
                id: reviewButton
                objectName: "userScriptReviewUrl"
                text: "Install…"
                enabled: urlInput.text.trim() !== ""
                onClicked: manager.review(urlInput.text)
            }
            Button {
                id: newButton
                objectName: "userScriptNew"
                text: "New"
                onClicked: manager.newScript()
            }
            Button {
                id: pasteButton
                objectName: "userScriptPaste"
                text: "Paste"
                onClicked: manager.pasteScript()
            }
        }

        Text {
            id: statusText
            objectName: "userScriptStatus"
            width: parent.width
            visible: text !== ""
            text: manager._status
            color: manager._statusIsError ? Style.danger : Style.textDim
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
    }

    // --- List -----------------------------------------------------------

    ListView {
        id: list
        objectName: "userScriptList"
        visible: manager._editing === ""
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        clip: true
        spacing: 4
        boundsBehavior: Flickable.StopAtBounds
        model: manager.store ? manager.store.scripts : []

        Text {
            anchors.centerIn: parent
            visible: list.count === 0
            width: parent.width - 32
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "No userscripts installed.\nOpen a .user.js URL, enter one above, or write a New script."
            color: Style.textDim
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }

        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property var script: modelData
            readonly property bool running: manager._running.indexOf(script.id) >= 0
            readonly property int valueCount: manager._valueCount(script.id)
            objectName: "userScriptRow_" + script.id
            width: ListView.view.width
            height: rowContent.implicitHeight + 16
            radius: Style.radius
            color: rowMouse.containsMouse ? Style.surfaceHover : Style.background
            opacity: script.enabled ? 1 : 0.65

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onDoubleClicked: manager.edit(row.script.id)
            }

            Switch {
                id: toggle
                objectName: "userScriptToggle_" + row.script.id
                x: 10
                y: 10
                checked: row.script.enabled
                onToggled: manager.setEnabled(row.script.id, !row.script.enabled)
            }

            Column {
                id: rowContent
                x: toggle.x + toggle.width + 12
                y: 8
                width: actions.x - x - 8
                spacing: 3

                Row {
                    spacing: 8
                    width: parent.width
                    Text {
                        id: nameText
                        text: row.script.name
                        color: Style.text
                        font.pixelSize: Style.fontSize + 1
                        font.bold: true
                        font.family: Style.fontFamily
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.width - versionText.width - badge.width - 16)
                    }
                    Text {
                        id: versionText
                        text: row.script.version || ""
                        visible: text !== ""
                        color: Style.textDim
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                        anchors.baseline: nameText.baseline
                    }
                    Rectangle {
                        id: badge
                        objectName: "userScriptRunning_" + row.script.id
                        visible: row.running
                        width: badgeText.implicitWidth + 12
                        height: badgeText.implicitHeight + 2
                        radius: height / 2
                        color: Qt.rgba(0.27, 0.72, 0.39, 0.2)
                        border.color: "#46b864"
                        anchors.verticalCenter: nameText.verticalCenter
                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: "running on this page"
                            color: "#5fd07d"
                            font.pixelSize: Style.fontSize - 2
                            font.family: Style.fontFamily
                        }
                    }
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    text: row.script.description || ""
                    color: Style.text
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    text: "Runs on " + row.script.matchSummary
                          + " · " + (row.script.world === "page" ? "page world" : "isolated world")
                          + " · " + row.script.runAt
                          + (row.script.noframes ? " · top frame only" : "")
                          + (row.valueCount ? " · " + row.valueCount + (row.valueCount === 1 ? " value" : " values") : "")
                    color: Style.textDim
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize - 1
                    font.family: Style.fontFamily
                }
                Text {
                    width: parent.width
                    readonly property string problem: row.script.error
                        || (row.script.pending ? "Fetching @require files…" : "")
                        || (row.script.warnings || []).join("; ")
                    visible: problem !== ""
                    text: problem
                    color: row.script.error ? Style.danger : Style.textDim
                    font.italic: !row.script.error
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.pixelSize: Style.fontSize - 1
                    font.family: Style.fontFamily
                }
            }

            Row {
                id: actions
                anchors.right: parent.right
                anchors.rightMargin: 8
                y: 8
                spacing: 4
                Button {
                    objectName: "userScriptClearValues_" + row.script.id
                    visible: row.valueCount > 0
                    text: "Clear values"
                    onClicked: manager.clearValues(row.script.id)
                }
                Button {
                    objectName: "userScriptEdit_" + row.script.id
                    text: "Edit"
                    onClicked: manager.edit(row.script.id)
                }
                Button {
                    objectName: "userScriptRemove_" + row.script.id
                    readonly property bool confirming: manager._confirmRemove === row.script.id
                    text: confirming ? "Remove?" : "Remove"
                    danger: true
                    onClicked: {
                        if (confirming) {
                            manager._confirmRemove = ""
                            manager.remove(row.script.id)
                        } else {
                            manager._confirmRemove = row.script.id
                            confirmTimer.restart()
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: confirmTimer
        interval: 3000
        onTriggered: manager._confirmRemove = ""
    }

    // --- Editor ---------------------------------------------------------

    Rectangle {
        id: editorFrame
        visible: manager._editing !== ""
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: editorButtons.top
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.bottomMargin: 10
        radius: Style.radius
        color: Style.background
        border.color: editor.activeFocus ? Style.accent : Style.border

        Flickable {
            id: editorFlick
            anchors.fill: parent
            anchors.margins: 8
            clip: true
            contentWidth: Math.max(width, editor.contentWidth)
            contentHeight: Math.max(height, editor.contentHeight)
            boundsBehavior: Flickable.StopAtBounds
            interactive: false   // the wheel still scrolls; drags select text

            function ensureVisible(r) {
                if (contentX >= r.x) contentX = r.x
                else if (contentX + width <= r.x + r.width) contentX = r.x + r.width - width
                if (contentY >= r.y) contentY = r.y
                else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }

            TextEdit {
                id: editor
                objectName: "userScriptEditor"
                width: editorFlick.contentWidth
                height: editorFlick.contentHeight
                color: Style.text
                selectionColor: Style.accent
                selectByMouse: true
                persistentSelection: true
                tabStopDistance: fontMetrics.averageCharacterWidth * 4
                font.family: "monospace"
                font.pixelSize: Style.fontSize
                onCursorRectangleChanged: editorFlick.ensureVisible(cursorRectangle)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
                        manager.save()
                        event.accepted = true
                    }
                }
            }
            FontMetrics { id: fontMetrics; font: editor.font }
        }
        MouseArea {
            // Wheel scrolling for the non-interactive Flickable.
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: wheel => {
                const f = editorFlick
                const dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 2
                const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 2
                f.contentY = Math.max(0, Math.min(f.contentHeight - f.height, f.contentY - dy))
                f.contentX = Math.max(0, Math.min(f.contentWidth - f.width, f.contentX - dx))
            }
        }
    }

    Row {
        id: editorButtons
        visible: manager._editing !== ""
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        spacing: 6
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: manager._editorUrl !== "" ? "From " + manager._editorUrl : ""
            color: Style.textDim
            elide: Text.ElideMiddle
            width: Math.min(implicitWidth, manager.width - 260)
            font.pixelSize: Style.fontSize - 1
            font.family: Style.fontFamily
        }
        Button {
            objectName: "userScriptCancel"
            text: "Cancel"
            onClicked: manager.cancelEdit()
        }
        Button {
            objectName: "userScriptSave"
            primary: true
            text: manager._editing === "new" ? "Install" : "Save"
            onClicked: manager.save()
        }
    }
}
