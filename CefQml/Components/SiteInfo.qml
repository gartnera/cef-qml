import QtQuick
import CefQml

// Site information card for the page of a CefWebView, drawn above the rest
// of the window below an anchor item (the "site info" button of
// NavigationBar opens one): the origin, connection security, the page's
// permissions and content settings (allow / block / ask), zoom, "Reset all
// for this site" and "Clear cookies and site data". In your own layout:
//
//   SiteSettings { id: sites }
//   SiteInfo { id: siteInfo; store: sites; view: tabs.currentView }
//   ... siteInfo.toggle(myButton)
//
// Without a store only the connection and site-data parts are shown.
// Choosing a value stores it for the page's origin (or removes the
// origin's own value when the site would get that value anyway, from its
// host, pattern or default scope). Content settings (JavaScript, images,
// pop-ups) apply from the next page load: the card then offers "Reload".
//
// objectNames: siteInfo (the card), siteInfoOrigin, siteInfoSecurity,
// siteInfoCertificate, siteInfoRow (one per setting; property settingKey),
// siteInfoOption_<key>_<value> (e.g. siteInfoOption_camera_block),
// siteInfoZoom, siteInfoZoomOut, siteInfoZoomIn, siteInfoZoomReset,
// siteInfoReload, siteInfoResetAll, siteInfoClearData, siteInfoStatus,
// siteInfoManage.
FocusScope {
    id: info

    property CefWebView view: null
    property SiteSettings store: null
    // The settings listed (more are listed when the origin stores them):
    // [{ key, label }]. Permissions offer Ask / Allow / Block, the other
    // keys Allow / Block.
    property var settingKeys: [
        { key: "camera", label: "Camera" },
        { key: "microphone", label: "Microphone" },
        { key: "geolocation", label: "Location" },
        { key: "notifications", label: "Notifications" },
        { key: "clipboard", label: "Clipboard" },
        { key: "javascript", label: "JavaScript" },
        { key: "images", label: "Images" },
        { key: "popups", label: "Pop-ups" },
    ]
    // Zoom changes are stored for the site (WebTabs zoomPolicy "origin");
    // false: they only change the view's zoomFactor.
    property bool storeZoom: true
    property real zoomStep: 0.1
    property bool showClearData: true
    // Shows a "Site settings…" link emitting manageRequested().
    property bool showManageLink: false
    // Item the card is shown under by open() / toggle() without an argument.
    property Item anchorItem: null

    readonly property bool opened: visible
    readonly property url url: view ? view.url : ""
    // "scheme://host[:port]", "" for pages without an origin of their own.
    readonly property string origin: store ? store.originOf(url) : _originOf(url)
    // http(s) pages, whose settings can be stored.
    readonly property bool hasSettings: store !== null && /^https?:\/\//.test(origin)
    // "secure", "insecure", "certificate-error", "file" or "internal".
    readonly property string security: {
        const u = url.toString()
        if (/^https:/i.test(u) || /^wss:/i.test(u)) {
            if (!view) return "insecure"
            if (view.secure) return "secure"
            const c = view.certificate
            return c && c.errors && c.errors.length > 0 ? "certificate-error" : "insecure"
        }
        if (/^http:/i.test(u)) return "insecure"
        if (/^file:/i.test(u)) return "file"
        return "internal"
    }
    // The rows shown: [{ key, label, options }].
    readonly property var rows: store ? (store.revision, _rows()) : []
    readonly property Item card: cardItem
    // Content settings changed since the page loaded.
    readonly property bool needsReload: _needsReload
    readonly property string status: _status

    // After "Clear cookies and site data" (ok: the DevTools call succeeded).
    signal siteDataCleared(string origin, bool ok)
    signal manageRequested()

    function open(anchor) {
        const w = Window.window
        if (!w || !view) return false
        if (parent !== w.contentItem) parent = w.contentItem
        if (!visible) _restoreFocus = w.activeFocusItem
        _status = ""
        _needsReload = false
        visible = true
        _place(anchor || anchorItem)
        cardItem.forceActiveFocus(Qt.PopupFocusReason)
        return true
    }
    function close() {
        if (!visible) return
        visible = false
        const f = _restoreFocus
        _restoreFocus = null
        try { if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason) } catch (e) {}
    }
    function toggle(anchor) { return visible ? (close(), false) : open(anchor) }

    // The value that applies to the page ("allow", "block", "ask").
    function value(key) { return store ? String(store.effective(url, key)) : "" }
    // Whether the origin itself stores `key` (rather than a wider scope or
    // the built-in default deciding).
    function isCustom(key) { return store ? store.scopeFor(url, key) === origin : false }
    // Sets `key` for the page's origin.
    function setValue(key, value) {
        if (!hasSettings) return false
        store.reset(origin, key)
        if (String(store.effective(url, key)) !== String(value)) store.set(origin, key, value)
        if (!store.isPermission(key)) _needsReload = true
        return true
    }
    function zoomIn() { return _zoom(view ? view.zoomFactor + zoomStep : 1) }
    function zoomOut() { return _zoom(view ? view.zoomFactor - zoomStep : 1) }
    // Back to the site's default zoom (1 without a store).
    function resetZoom() {
        if (!view) return false
        if (store && storeZoom && origin !== "") {
            store.reset(origin, "zoom")
            view.zoomFactor = Number(store.effective(url, "zoom"))
        } else {
            view.zoomFactor = 1
        }
        return true
    }
    // Removes everything stored for the page's origin (its host and
    // pattern scopes stay).
    function resetAll() {
        if (!store || origin === "") return false
        const had = store.settings(origin)
        store.reset(origin)
        if (storeZoom && view) view.zoomFactor = Number(store.effective(url, "zoom"))
        if (Object.keys(had).some(k => k !== "zoom" && !store.isPermission(k))) _needsReload = true
        _status = "Settings reset for this site"
        return true
    }
    // Deletes the origin's cookies and storage (DevTools
    // Storage.clearDataForOrigin); callback(ok, error).
    function clearSiteData(callback) {
        if (!view || origin === "" || origin === "file://") return false
        const o = origin
        view.devToolsMethod("Storage.clearDataForOrigin", { origin: o, storageTypes: "all" }, (r, err) => {
            _status = err ? "Could not clear site data: " + err : "Cookies and site data cleared"
            info.siteDataCleared(o, !err)
            if (callback) callback(!err, err)
        })
        return true
    }
    function reload() {
        if (view) view.reload()
        _needsReload = false
    }

    function label(key) {
        for (const s of settingKeys) if (s.key === key) return s.label
        const t = key.replace(/-/g, " ")
        return t.charAt(0).toUpperCase() + t.slice(1)
    }

    // --- Internals ------------------------------------------------------

    property bool _needsReload: false
    property string _status: ""
    property var _restoreFocus: null

    function _originOf(u) {
        const m = /^([a-z][a-z0-9+.-]*):\/\/([^\/?#]*)/i.exec(String(u))
        return m && m[1].toLowerCase() !== "data" ? m[1].toLowerCase() + "://" + m[2].toLowerCase() : ""
    }
    function _rows() {
        if (!hasSettings) return []
        const keys = settingKeys.map(s => s.key)
        for (const k of Object.keys(store.settings(origin)).sort())
            if (k !== "zoom" && keys.indexOf(k) < 0 && (store.isPermission(k) || Cef.contentSettingTypes.indexOf(k) >= 0))
                keys.push(k)
        return keys.map(k => ({
            key: k,
            label: label(k),
            options: store.isPermission(k) ? ["ask", "allow", "block"] : ["allow", "block"]
        }))
    }
    function _zoom(z) {
        if (!view) return false
        view.zoomFactor = Math.round(Math.max(0.25, Math.min(5, z)) * 100) / 100
        // WebTabs (zoomPolicy "origin") stores it too; this covers layouts
        // without one. Same value, so no further change.
        if (store && storeZoom && origin !== "") {
            const zoom = view.zoomFactor
            store.reset(origin, "zoom")
            if (Math.abs(Number(store.effective(url, "zoom")) - zoom) > 1e-6) store.set(origin, "zoom", zoom)
        }
        return true
    }
    function _place(anchor) {
        if (anchor) {
            const p = anchor.mapToItem(null, 0, anchor.height + 4)
            cardItem.x = Math.max(8, Math.min(p.x, width - cardItem.width - 8))
            cardItem.y = Math.max(8, Math.min(p.y, height - cardItem.height - 8))
        } else {
            cardItem.x = Math.round((width - cardItem.width) / 2)
            cardItem.y = Math.max(8, Math.round((height - cardItem.height) / 4))
        }
    }

    // The view went away (tab closed) or switched: close.
    onViewChanged: close()

    visible: false
    z: 10002
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    Keys.onEscapePressed: close()

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: info.close()
        onWheel: {}
    }

    component Button: Rectangle {
        id: button
        property string text
        property bool danger: false
        property bool selected: false
        property bool enabled: true
        signal clicked()
        implicitWidth: label.implicitWidth + 16
        implicitHeight: 24
        radius: Style.radius
        opacity: enabled ? 1 : 0.4
        color: selected ? Style.accent
             : mouse.pressed ? Style.surfaceActive
             : mouse.containsMouse ? Style.surfaceHover : Style.background
        border.color: selected ? "transparent" : danger && mouse.containsMouse ? Style.danger : Style.border
        Text {
            id: label
            anchors.centerIn: parent
            text: button.text
            color: button.selected ? "white" : button.danger ? Style.danger : Style.text
            font.pixelSize: Style.fontSize - 1
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

    component Caption: Text {
        color: Style.textDim
        font.pixelSize: Style.fontSize - 1
        font.family: Style.fontFamily
    }

    Rectangle {
        id: cardItem
        objectName: "siteInfo"
        width: 340
        height: column.implicitHeight + 28
        radius: Style.radius * 2
        color: Style.surface
        border.color: Style.border
        Keys.onEscapePressed: info.close()

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: {} }

        Column {
            id: column
            x: 14; y: 14
            width: parent.width - 28
            spacing: 8

            Text {
                objectName: "siteInfoOrigin"
                width: parent.width
                text: info.origin.replace(/^https:\/\//, "") || (info.view ? info.view.title || "This page" : "")
                color: Style.text
                font.pixelSize: Style.fontSize + 2
                font.bold: true
                font.family: Style.fontFamily
                elide: Text.ElideMiddle
            }
            Text {
                objectName: "siteInfoSecurity"
                width: parent.width
                wrapMode: Text.Wrap
                text: ({
                    "secure": "Connection is secure",
                    "certificate-error": "Connection is not secure: the certificate is not valid",
                    "insecure": "Connection is not secure",
                    "file": "Local or shared file",
                    "internal": "Internal page",
                })[info.security]
                color: info.security === "secure" ? Style.accent
                     : info.security === "certificate-error" ? Style.danger : Style.textDim
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
            }
            Caption {
                objectName: "siteInfoCertificate"
                width: parent.width
                wrapMode: Text.Wrap
                readonly property var cert: info.view ? info.view.certificate : ({})
                visible: text !== ""
                text: {
                    const c = cert
                    if (!c || !c.subject) return ""
                    const lines = ["Issued to: " + c.subject]
                    if (c.organization) lines.push("Organization: " + c.organization)
                    if (c.issuer) lines.push("Issued by: " + c.issuer)
                    if (c.validTo) lines.push("Valid until: " + Qt.formatDate(c.validTo, "d MMMM yyyy"))
                    if (c.protocol) lines.push("Protocol: " + c.protocol)
                    if (c.errors && c.errors.length) lines.push("Errors: " + c.errors.join(", "))
                    return lines.join("\n")
                }
            }

            Rectangle { width: parent.width; height: 1; color: Style.border; visible: info.hasSettings }

            Repeater {
                model: info.rows
                delegate: Item {
                    id: row
                    required property var modelData
                    objectName: "siteInfoRow"
                    readonly property string settingKey: modelData.key
                    readonly property string current: info.store ? (info.store.revision, info.value(settingKey)) : ""
                    width: parent.width
                    height: 26
                    Text {
                        anchors.left: parent.left
                        anchors.right: options.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.label
                        elide: Text.ElideRight
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                        font.italic: !(info.store.revision, info.isCustom(row.settingKey))
                    }
                    Row {
                        id: options
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Repeater {
                            model: row.modelData.options
                            delegate: Button {
                                required property string modelData
                                objectName: "siteInfoOption_" + row.settingKey + "_" + modelData
                                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                                selected: row.current === modelData
                                onClicked: info.setValue(row.settingKey, modelData)
                            }
                        }
                    }
                }
            }

            Item {
                objectName: "siteInfoZoom"
                visible: info.view !== null
                width: parent.width
                height: 26
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Zoom"
                    color: Style.text
                    font.pixelSize: Style.fontSize
                    font.family: Style.fontFamily
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Button { objectName: "siteInfoZoomOut"; text: "−"; onClicked: info.zoomOut() }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 48
                        horizontalAlignment: Text.AlignHCenter
                        text: info.view ? Math.round(info.view.zoomFactor * 100) + "%" : ""
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Button { objectName: "siteInfoZoomIn"; text: "+"; onClicked: info.zoomIn() }
                    Button { objectName: "siteInfoZoomReset"; text: "Reset"; onClicked: info.resetZoom() }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Style.border }

            Flow {
                width: parent.width
                spacing: 6
                Button {
                    objectName: "siteInfoReload"
                    visible: info.needsReload
                    text: "Reload to apply"
                    selected: true
                    onClicked: info.reload()
                }
                Button {
                    objectName: "siteInfoResetAll"
                    visible: info.hasSettings
                    text: "Reset all for this site"
                    enabled: info.store !== null && (info.store.revision, info.store.contains(info.origin))
                    onClicked: info.resetAll()
                }
                Button {
                    objectName: "siteInfoClearData"
                    visible: info.showClearData && info.origin !== "" && info.origin !== "file://"
                    text: "Clear cookies and site data"
                    danger: true
                    onClicked: info.clearSiteData()
                }
                Button {
                    objectName: "siteInfoManage"
                    visible: info.showManageLink
                    text: "Site settings…"
                    onClicked: { info.close(); info.manageRequested() }
                }
            }
            Caption {
                objectName: "siteInfoStatus"
                width: parent.width
                visible: text !== ""
                text: info._status
                wrapMode: Text.Wrap
            }
        }
    }
}
