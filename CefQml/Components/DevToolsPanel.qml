import QtQuick
import CefQml

// Chromium's DevTools for the views of a layout, rendered off-screen like
// any CefWebView: docked at the bottom or right of the page area (with a
// draggable splitter), as a tab next to the inspected one, or in a window
// of their own. Every inspected view gets its own frontend (a CefWebView
// with devToolsFor set); the docked area shows the one of `view`, usually
// the current tab, so switching tabs switches DevTools too. `Browser` has
// one as `devToolsPanel`; in a custom layout, the page area goes inside:
//
//   DevToolsPanel {
//       id: devTools
//       anchors.fill: parent
//       view: tabs.currentView
//       tabs: tabs                       // for dock: "tab"
//       WebTabs { id: tabs; anchors.fill: parent }
//   }
//   ... devTools.toggle()                // F12
//   ... devTools.inspect(x, y, view)     // reveal the element at (x, y)
//
// Functions that take a `view` default to `view`. For a frontend view they
// act on what it inspects: toggle() on a DevTools tab closes it.
Item {
    id: panel

    // The page area: items declared inside fill what docked DevTools leave.
    default property alias content: pageArea.data
    readonly property Item pageItem: pageArea
    // The docked area (header and frontend).
    readonly property Item dockItem: dockArea

    // The view whose docked DevTools are shown.
    property CefWebView view: null
    // Where DevTools open: "bottom" or "right" (docked here), "tab" (a tab
    // of `tabs` next to the inspected view; "bottom" without `tabs`) or
    // "window". Changing it moves the DevTools that are open.
    property string dock: "bottom"
    property WebTabs tabs: null
    // Docked height ("bottom") or width ("right"); dragging the splitter
    // changes it. It is clamped so both sides keep their minimum.
    property real size: 320
    property real minimumSize: 120
    property real minimumPageSize: 120
    // Size of a new DevTools window.
    property size windowSize: Qt.size(1000, 700)
    // Show the docked header (dock buttons and close).
    property bool showHeader: true
    // Instantiated for each frontend; must be (or derive from) CefWebView.
    property Component frontendDelegate: Component { CefWebView { } }

    // The docked frontend of `view`, or null.
    readonly property CefWebView frontend: {
        const e = _entries.find(x => x.kind === "docked" && x.view === panel.view)
        return e ? e.frontend : null
    }
    readonly property bool docked: frontend !== null
    // Docked extent actually used (0 when nothing is docked).
    readonly property real dockSize: docked ? _clampSize(size) : 0
    // DevTools opened by this panel: [{ view, frontend, kind ("docked",
    // "tab" or "window"), window }]. Reassigned on every change.
    readonly property var entries: _entries

    signal opened(CefWebView view, CefWebView frontend)
    signal closed(CefWebView view)
    // A DevTools link asks for a new tab or window (e.g. "Open in new tab").
    signal openUrlRequested(url url)

    // True if DevTools of `v` are open (here or elsewhere), or `v` is a
    // DevTools frontend.
    function isOpen(v) {
        v = _arg(v)
        return !!v && (v.hasDevTools || v.devToolsFor !== null)
    }
    // The frontend showing the DevTools of `v`, or null.
    function frontendFor(v) {
        v = _arg(v)
        return !v ? null : v.devToolsFor !== null ? v : v.devToolsView
    }
    // Opens (or reveals and focuses) the DevTools of `v` where `dock` says
    // and returns the frontend view.
    function show(v) {
        v = _arg(v)
        if (!v) return null
        if (v.devToolsFor !== null) { _reveal(_entryOf(v) || { frontend: v, kind: "" }); return v }
        const kind = _kind()
        const old = _entries.find(x => x.view === v)
        if (old && old.kind === kind && v.devToolsView === old.frontend) {
            _reveal(old)
            return old.frontend
        }
        // A new frontend takes over from any other one (see devToolsFor).
        const e = _create(v, kind)
        if (!e) return null
        _entries = _entries.concat([e])
        _reveal(e)
        opened(v, e.frontend)
        return e.frontend
    }
    // Closes the DevTools of `v` (or the DevTools `v` is); false if none.
    function close(v) {
        v = _arg(v)
        if (!v) return false
        const target = v.devToolsFor !== null ? v.devToolsFor : v
        if (!target.hasDevTools) return false
        target.closeDevTools()
        return true
    }
    // Closes the DevTools of `v` if open, else opens them; returns whether
    // they are open now.
    function toggle(v) {
        if (isOpen(v)) { close(v); return false }
        return show(v) !== null
    }
    // Opens the DevTools of `v` and reveals the element at (x, y) (view
    // coordinates) in the Elements panel.
    function inspect(x, y, v) {
        v = _arg(v)
        if (!v || v.devToolsFor !== null || !show(v)) return false
        v.inspectElementAt(x, y)
        return true
    }
    // Closes every DevTools opened by this panel.
    function closeAll() {
        for (const e of _entries.slice()) if (e.view) e.view.closeDevTools()
    }

    // ---- layout -------------------------------------------------------------

    readonly property bool _right: dock === "right"

    Item {
        id: pageArea
        objectName: "devToolsPageArea"
        x: 0; y: 0
        width: panel._right ? panel.width - panel.dockSize : panel.width
        height: panel._right ? panel.height : panel.height - panel.dockSize
    }

    Rectangle {
        id: dockArea
        objectName: "devToolsDock"
        visible: panel.docked
        color: Style.background
        x: panel._right ? panel.width - panel.dockSize : 0
        y: panel._right ? 0 : panel.height - panel.dockSize
        width: panel._right ? panel.dockSize : panel.width
        height: panel._right ? panel.height : panel.dockSize

        Rectangle {
            id: header
            objectName: "devToolsHeader"
            visible: panel.showHeader
            width: parent.width
            height: visible ? 28 : 0
            color: Style.surface
            Text {
                x: 10
                width: buttons.x - x - 8
                anchors.verticalCenter: parent.verticalCenter
                text: panel.view ? "DevTools — " + (panel.view.title || panel.view.url) : "DevTools"
                elide: Text.ElideRight
                color: Style.textDim
                font.pixelSize: Style.fontSize - 1
                font.family: Style.fontFamily
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.rightMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                IconButton {
                    objectName: "devToolsDockBottom"
                    text: "▁"; toolTip: "Dock to bottom"; implicitHeight: 24
                    checked: panel.dock === "bottom"
                    onClicked: panel.dock = "bottom"
                }
                IconButton {
                    objectName: "devToolsDockRight"
                    text: "▕"; toolTip: "Dock to right"; implicitHeight: 24
                    checked: panel.dock === "right"
                    onClicked: panel.dock = "right"
                }
                IconButton {
                    objectName: "devToolsUndock"
                    text: "⧉"; toolTip: "Open in a window"; implicitHeight: 24
                    onClicked: panel.dock = "window"
                }
                IconButton {
                    objectName: "devToolsClose"
                    text: "×"; toolTip: "Close DevTools"; implicitHeight: 24
                    onClicked: panel.close(panel.view)
                }
            }
        }
        // Frontends are parented here; only the one of `view` is visible.
        Item {
            id: frontendArea
            objectName: "devToolsFrontendArea"
            y: header.height
            width: parent.width
            height: parent.height - header.height
        }
    }

    // Splitter between the page area and docked DevTools: wider than the
    // drawn line, above both views so it gets the mouse first.
    Item {
        id: splitter
        objectName: "devToolsSplitter"
        visible: panel.docked
        z: 1
        x: panel._right ? dockArea.x - 3 : 0
        y: panel._right ? 0 : dockArea.y - 3
        width: panel._right ? 6 : panel.width
        height: panel._right ? panel.height : 6
        Rectangle {
            x: panel._right ? 3 : 0
            y: panel._right ? 0 : 3
            width: panel._right ? 1 : parent.width
            height: panel._right ? parent.height : 1
            color: drag.pressed || drag.containsMouse ? Style.accent : Style.border
        }
        MouseArea {
            id: drag
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: panel._right ? Qt.SplitHCursor : Qt.SplitVCursor
            property real startPos: 0
            property real startSize: 0
            function pos(mouse) {
                const p = mapToItem(panel, mouse.x, mouse.y)
                return panel._right ? p.x : p.y
            }
            onPressed: mouse => { startPos = pos(mouse); startSize = panel.dockSize }
            onPositionChanged: mouse => {
                if (pressed) panel.size = panel._clampSize(startSize - (pos(mouse) - startPos))
            }
        }
    }

    Component {
        id: windowComponent
        Window {
            property CefWebView frontend: null
            title: frontend && frontend.title ? frontend.title : "DevTools"
            color: Style.background
        }
    }

    // ---- internals ----------------------------------------------------------

    property var _entries: []
    property bool _dying: false

    onDockChanged: {
        // Move open DevTools to the new place ("bottom" <-> "right" only
        // changes the layout).
        const kind = _kind()
        for (const e of _entries.slice())
            if (e.kind !== kind && e.view && e.view.devToolsView === e.frontend) show(e.view)
    }
    onFrontendChanged: _updateVisibility()

    function _arg(v) { return v === undefined || v === null ? view : v }
    function _kind() {
        if (dock === "window") return "window"
        if (dock === "tab" && tabs) return "tab"
        return "docked"
    }
    function _clampSize(s) {
        const extent = _right ? width : height
        return Math.max(0, Math.min(Math.max(s, minimumSize), extent - minimumPageSize))
    }
    function _entryOf(fe) { return _entries.find(x => x.frontend === fe) || null }
    function _updateVisibility() {
        for (const e of _entries)
            if (e.kind === "docked" && e.frontend) e.frontend.visible = e.frontend === frontend
    }

    function _create(v, kind) {
        let fe = null, win = null
        if (kind === "tab") {
            const i = tabs.indexOf(v)
            // WebTabs' url is ignored: a frontend's URL follows devToolsFor.
            fe = tabs.openTab("", false, i >= 0 ? i + 1 : undefined, { devToolsFor: v })
        } else if (kind === "window") {
            win = windowComponent.createObject(panel, {
                width: windowSize.width, height: windowSize.height })
            if (win) {
                fe = frontendDelegate.createObject(win.contentItem, { devToolsFor: v })
                if (fe) {
                    fe.anchors.fill = win.contentItem
                    win.frontend = fe
                    win.closing.connect(() => { if (fe && fe.devToolsFor) fe.devToolsFor.closeDevTools() })
                } else {
                    win.destroy()
                }
            }
        } else {
            fe = frontendDelegate.createObject(frontendArea, { devToolsFor: v, visible: false })
            if (fe) fe.anchors.fill = frontendArea
        }
        if (!fe) {
            console.warn("DevToolsPanel: could not create the DevTools view:",
                         kind === "tab" ? "WebTabs.openTab failed" : frontendDelegate.errorString())
            return null
        }
        const e = { view: v, frontend: fe, kind: kind, window: win }
        // The entry ends when the frontend stops inspecting `v` (closed,
        // replaced, `v` gone) or is destroyed (e.g. its tab was closed).
        // While a tree is torn down (hot reload, exit), the views can outlive
        // this item and its context.
        const alive = () => !e.dead && typeof panel !== "undefined" && panel !== null && !panel._dying
        e.onFrontend = () => { if (alive() && (!e.frontend || e.frontend.devToolsFor !== e.view)) panel._remove(e) }
        e.onView = () => { if (alive() && (!e.view || e.view.devToolsView !== e.frontend)) panel._remove(e) }
        e.onNewWindow = url => { if (alive()) panel.openUrlRequested(url) }
        fe.devToolsForChanged.connect(e.onFrontend)
        v.devToolsChanged.connect(e.onView)
        if (kind !== "tab") fe.newWindowRequested.connect(e.onNewWindow)
        return e
    }

    function _disconnect(e) {
        e.dead = true
        try { e.frontend.devToolsForChanged.disconnect(e.onFrontend) } catch (err) {}
        try { e.frontend.newWindowRequested.disconnect(e.onNewWindow) } catch (err) {}
        try { e.view.devToolsChanged.disconnect(e.onView) } catch (err) {}
    }
    function _remove(e) {
        if (_entries.indexOf(e) < 0) return
        _entries = _entries.filter(x => x !== e)
        _disconnect(e)
        if (_dying) return
        const fe = e.frontend
        if (e.kind === "docked") {
            if (fe && fe.activeFocus && e.view) e.view.forceActiveFocus(Qt.OtherFocusReason)
            if (fe) fe.destroy()
        } else if (e.kind === "window") {
            if (e.window) { e.window.visible = false; e.window.destroy() }
        } else if (fe && tabs) {
            // Usually closed already (WebTabs.closeOnRequest, or the user).
            const i = tabs.indexOf(fe)
            if (i >= 0) tabs.closeTab(i)
        }
        closed(e.view)
    }

    function _reveal(e) {
        const fe = e.frontend
        if (e.kind === "tab" || (!e.kind && tabs && tabs.indexOf(fe) >= 0)) {
            tabs.currentIndex = tabs.indexOf(fe)
        } else if (e.kind === "window") {
            if (e.window.visible) e.window.raise()
            e.window.visible = true
            e.window.requestActivate()
        }
        if (e.kind === "docked") _updateVisibility()
        fe.forceActiveFocus(Qt.OtherFocusReason)
    }

    Component.onDestruction: {
        _dying = true
        for (const e of _entries) _disconnect(e)
    }
}
