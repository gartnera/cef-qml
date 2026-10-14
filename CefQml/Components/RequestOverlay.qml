import QtQuick
import CefQml

// Shows JavaScript dialogs (alert/confirm/prompt/beforeunload) and
// permission prompts of a WebTabs as an in-page card. Requests from
// background tabs wait until their tab is shown.
//
//   RequestOverlay { anchors.fill: tabs; tabs: tabs }
//
// Permission cards have a "Remember this decision" checkbox. A remembered
// decision is stored per permission for the requesting origin in
// tabs.siteSettings (which then answers later requests itself, also after a
// restart), or without one in `decisions` for this session.
Item {
    id: overlay
    required property WebTabs tabs
    // Offer the "Remember this decision" checkbox; false: never remember.
    property bool rememberPermissions: true
    // Initial state of the checkbox on every permission card.
    property bool rememberByDefault: true
    // The checkbox of the card shown now.
    property bool remember: rememberByDefault
    // Session memory used without tabs.siteSettings: "origin|permissions" ->
    // true (allowed) / false (blocked).
    property var decisions: ({})

    // [{ view, request, kind: "dialog" | "permission" }]
    property var queue: []
    readonly property var active: {
        for (const e of queue) if (e.view === tabs.currentView) return e
        return null
    }
    visible: active !== null

    Component.onCompleted: {
        tabs.interceptJavaScriptDialogs = true
        tabs.interceptPermissions = true
    }

    Connections {
        target: overlay.tabs
        function onJavaScriptDialogRequested(view, dialog) { overlay._push(view, dialog, "dialog") }
        function onPermissionRequested(view, request) {
            const key = overlay._key(request)
            if (overlay.rememberPermissions && key in overlay.decisions) {
                overlay.decisions[key] ? request.grant() : request.deny()
                return
            }
            overlay._push(view, request, "permission")
        }
        function onTabClosed(view) { overlay.queue = overlay.queue.filter(e => e.view !== view) }
    }

    function _key(request) { return request.origin + "|" + request.permissions.join(",") }

    function _push(view, request, kind) {
        const entry = { view: view, request: request, kind: kind }
        request.handledChanged.connect(() => overlay._remove(request))
        queue = queue.concat([entry])
        if (active === entry) Qt.callLater(card.focusDefault)
    }
    function _remove(request) {
        queue = queue.filter(e => e.request !== request)
    }

    // Stores a decision when the checkbox is on.
    function _remember(request, allowed) {
        if (!rememberPermissions || !remember) return
        const sites = tabs.siteSettings
        if (sites) {
            const origin = sites.originOf(request.origin)
            if (origin) {
                for (const p of request.permissions)
                    if (p !== "other") sites.set(origin, p, allowed ? "allow" : "block")
                return
            }
        }
        decisions[_key(request)] = allowed
    }

    function accept() {
        const e = active
        if (!e) return
        if (e.kind === "permission") {
            _remember(e.request, true)
            e.request.grant()
        } else {
            e.request.accept(promptInput.text)
        }
        e.view.forceActiveFocus()
    }
    function reject() {
        const e = active
        if (!e) return
        if (e.kind === "permission") {
            _remember(e.request, false)
            e.request.deny()
        } else {
            e.request.reject()
        }
        e.view.forceActiveFocus()
    }

    // Escape: closes a permission card without deciding (nothing is
    // remembered; the page may ask again), cancels a dialog.
    function dismiss() {
        const e = active
        if (!e) return
        if (e.kind !== "permission") { reject(); return }
        e.request.dismiss()
        e.view.forceActiveFocus()
    }

    onActiveChanged: if (active) {
        promptInput.text = active.kind === "dialog" ? active.request.defaultText : ""
        remember = rememberByDefault
        Qt.callLater(card.focusDefault)
    }

    Rectangle {
        anchors.fill: parent
        color: "#80000000"
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: {} }
    }

    Rectangle {
        id: card
        objectName: "requestCard"
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.min(parent.height * 0.18, 120)
        width: Math.min(440, parent.width - 32)
        height: content.implicitHeight + 32
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border

        readonly property var entry: overlay.active
        readonly property bool isPermission: entry !== null && entry.kind === "permission"
        readonly property int dialogType: entry !== null && !isPermission ? entry.request.type : -1

        function focusDefault() {
            if (dialogType === CefJavaScriptDialog.Prompt) {
                promptInput.forceActiveFocus()
                promptInput.selectAll()
            } else {
                card.forceActiveFocus()
            }
        }
        Keys.onReturnPressed: overlay.accept()
        Keys.onEnterPressed: overlay.accept()
        Keys.onEscapePressed: overlay.dismiss()

        Column {
            id: content
            x: 16; y: 16
            width: parent.width - 32
            spacing: 12

            Text {
                width: parent.width
                text: {
                    const e = card.entry
                    if (!e) return ""
                    const host = e.request.origin.toString().replace(/^[a-z]+:\/\//, "").replace(/\/.*$/, "")
                    if (card.isPermission) return (host || "This page") + " wants to"
                    if (card.dialogType === CefJavaScriptDialog.BeforeUnload)
                        return e.request.isReload ? "Reload site?" : "Leave site?"
                    return (host || "This page") + " says"
                }
                color: Style.text
                font.pixelSize: Style.fontSize + 2
                font.family: Style.fontFamily
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                objectName: "requestMessage"
                width: parent.width
                text: {
                    const e = card.entry
                    if (!e) return ""
                    if (card.isPermission) return "Use your " + e.request.permissions.join(", ").replace(/-/g, " ")
                    if (card.dialogType === CefJavaScriptDialog.BeforeUnload)
                        return "Changes you made may not be saved."
                    return e.request.message
                }
                wrapMode: Text.Wrap
                maximumLineCount: 12
                elide: Text.ElideRight
                color: Style.text
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
            }
            Rectangle {
                visible: card.dialogType === CefJavaScriptDialog.Prompt
                width: parent.width; height: 30
                radius: Style.radius
                color: Style.background
                border.color: promptInput.activeFocus ? Style.accent : Style.border
                TextInput {
                    id: promptInput
                    objectName: "promptInput"
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Style.text
                    selectionColor: Style.accent
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                    onAccepted: overlay.accept()
                    Keys.onEscapePressed: overlay.reject()
                }
            }
            Item {
                id: rememberBox
                objectName: "rememberCheckBox"
                visible: card.isPermission && overlay.rememberPermissions
                width: parent.width
                height: 22
                readonly property bool checked: overlay.remember
                function toggle() { overlay.remember = !overlay.remember }
                Rectangle {
                    id: box
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    radius: 3
                    color: rememberBox.checked ? Style.accent : "transparent"
                    border.color: rememberBox.checked ? Style.accent : Style.textDim
                    Text {
                        anchors.centerIn: parent
                        visible: rememberBox.checked
                        text: "\u2713"
                        color: "white"
                        font.pixelSize: 12
                        font.bold: true
                    }
                }
                Text {
                    anchors.left: box.right; anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Remember this decision"
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: rememberBox.toggle()
                }
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                DialogButton {
                    objectName: "rejectButton"
                    visible: card.dialogType !== CefJavaScriptDialog.Alert
                    text: card.isPermission ? "Block"
                        : card.dialogType === CefJavaScriptDialog.BeforeUnload ? "Stay" : "Cancel"
                    onClicked: overlay.reject()
                }
                DialogButton {
                    objectName: "acceptButton"
                    primary: true
                    text: card.isPermission ? "Allow"
                        : card.dialogType === CefJavaScriptDialog.BeforeUnload
                          ? (card.entry && card.entry.request.isReload ? "Reload" : "Leave") : "OK"
                    onClicked: overlay.accept()
                }
            }
        }
    }

    component DialogButton: Rectangle {
        id: btn
        property string text
        property bool primary: false
        signal clicked()
        width: Math.max(72, label.implicitWidth + 24)
        height: 30
        radius: Style.radius
        color: primary ? (m.containsMouse ? Qt.lighter(Style.accent, 1.1) : Style.accent)
                       : (m.containsMouse ? Style.surfaceActive : Style.surfaceHover)
        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            color: btn.primary ? "white" : Style.text
            font.pixelSize: Style.fontSize
            font.family: Style.fontFamily
        }
        MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; onClicked: btn.clicked() }
    }
}
