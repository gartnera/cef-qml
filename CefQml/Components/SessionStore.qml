import QtQuick
import CefQml
import "SessionRegistry.js" as Registry

// Non-visual: persists the open tabs of a WebTabs (URL, title, icon, zoom,
// mute, current tab) and the recently closed tabs of a BrowserController to
// "<name>.json" under Cef.dataDir, and restores them.
//
//   WebTabs { id: tabs }
//   BrowserController { id: ctl; tabs: tabs }
//   SessionStore { id: session; tabs: tabs; controller: ctl }
//   Component.onCompleted: if (session.restore().length === 0) tabs.openTab("https://example.com")
//
// The file is written shortly after changes (at most `saveDelay` ms later,
// even while a page keeps changing its title) and at application quit and
// destruction. While the app runs the file is marked as running, so after a
// crash the next start sees `crashed`. Only each tab's current page is kept,
// not its back/forward history (Chromium offers no way to rebuild it).
//
// The session found at startup stays available as `saved` until restore()
// uses it, even though the file is overwritten with the new session as soon
// as the tabs change: restoring later (a "Restore previous session" action)
// still works.
QtObject {
    id: session

    property WebTabs tabs: null
    property BrowserController controller: null
    // File name without ".json", under Cef.dataDir. Give each SessionStore of
    // a process its own name. Read once at startup.
    property string name: "session"
    // Write the file. Off by default when another process holds the profile
    // (Cef.temporaryProfile): that process owns the session file. The saved
    // session is still read.
    property bool enabled: !Cef.temporaryProfile
    property int saveDelay: 1000
    // restore() default: background tabs start discarded (no browser until
    // selected), so restoring many tabs only loads the current one.
    property bool lazy: true
    // Tabs whose URL satisfies this are saved without their URL (e.g. a large
    // data: new-tab page) and restored as `internalTabUrl`.
    property var isInternalUrl: controller ? controller.isInternalUrl : (u => false)
    property url internalTabUrl: tabs ? tabs.homeUrl : "about:blank"
    // Favicons (often data: URLs) longer than this are not saved.
    property int maxIconLength: 4096

    // The session read at startup ({ tabs: [{ url, title, icon, zoom, muted,
    // internal }], current, closed, savedAt }) until restore() uses it, or null.
    readonly property var saved: _saved
    readonly property bool hasSavedSession: _saved !== null && _saved.tabs.length > 0
    // The previous run did not end cleanly (the file is still marked running).
    readonly property bool crashed: _crashed
    readonly property bool loaded: _file.loaded
    readonly property string filePath: _file.filePath

    // The current state, as it is saved.
    // DevTools tabs are left out: what they inspect is gone after a restart.
    function snapshot() {
        const views = tabs ? tabs.views.filter(v => !!v && v.devToolsFor === null) : []
        let current = tabs ? tabs.currentView : null
        if (current && current.devToolsFor !== null) current = current.devToolsFor
        let index = current ? views.indexOf(current) : -1
        if (index < 0) index = tabs ? Math.min(tabs.currentIndex, views.length - 1) : 0
        return {
            version: 1,
            tabs: views.map(_tabEntry),
            current: Math.max(0, index),
            closed: controller ? controller.closedTabs.map(_closedEntry) : [],
            savedAt: Date.now()
        }
    }

    // Writes the current state now. Returns false if disabled or on error.
    function save() {
        _last = snapshot()
        return _write(true)
    }

    // Opens the tabs of `saved` (or of options.session, e.g. a snapshot())
    // and returns their views; [] if there is nothing to restore. The saved
    // current tab is selected. Options:
    //   replace: close the existing tabs first (default: add after them)
    //   lazy: background tabs start discarded (default: the `lazy` property)
    function restore(options) {
        options = options || {}
        const s = options.session || _saved
        if (!tabs || !s || !Array.isArray(s.tabs) || s.tabs.length === 0) return []
        const entries = s.tabs.filter(t => t && typeof t === "object").map(t => {
            const e = Object.assign({}, t)
            if (t.internal || !t.url) e.url = internalTabUrl
            return e
        })
        if (!options.session) _saved = null
        return tabs.restore(entries, s.current || 0, {
            lazy: options.lazy !== undefined ? !!options.lazy : lazy,
            append: !options.replace
        })
    }

    // Forgets `saved` and the controller's closed tabs, and writes the
    // current state.
    function clear() {
        _saved = null
        if (controller) controller.closedTabs = []
        save()
    }

    // ---- internals ---------------------------------------------------------

    property var _saved: null
    property bool _crashed: false
    property bool _started: false
    property bool _closedMerged: false
    property var _savedClosed: []
    property bool _ended: false
    property var _last: null
    property string _claimed: ""

    function _iconString(icon) {
        const s = icon ? icon.toString() : ""
        return s.length <= maxIconLength ? s : ""
    }
    function _tabEntry(v) {
        const u = v.url.toString()
        const internal = u !== "" && isInternalUrl(u)
        const e = internal ? { url: "", internal: true } : { url: u }
        if (v.title) e.title = v.title
        if (internal) return e
        const icon = _iconString(v.icon)
        if (icon) e.icon = icon
        if (v.zoomFactor !== 1) e.zoom = v.zoomFactor
        if (v.audioMuted) e.muted = true
        return e
    }
    function _closedEntry(c) {
        const e = Object.assign({}, c)
        e.url = String(c.url)
        e.icon = _iconString(c.icon)
        return e
    }

    function _canWrite() {
        if (!enabled || !_started || _file.filePath === "") return false
        if (_claimed === _file.filePath) return true
        if (!Registry.claim(_file.filePath, session)) {
            console.warn("SessionStore: another SessionStore already writes", _file.filePath,
                         "- give each one its own name")
            return false
        }
        _claimed = _file.filePath
        return true
    }
    function _write(running) {
        if (!_canWrite() || !_last) return false
        _timer.stop()
        _file.data = Object.assign({}, _last, { running: running })
        return _file.save()
    }
    function _changed() {
        if (_ended) return
        _last = snapshot()
        if (_started && enabled && !_timer.running) _timer.start()
    }
    function _mergeClosed() {
        if (_closedMerged || !controller || !_started) return
        _closedMerged = true
        const old = _savedClosed.filter(c => c && typeof c === "object" && c.url)
        _savedClosed = []
        if (old.length) controller.closedTabs = old.concat(controller.closedTabs)
    }
    function _start() {
        if (_started || !_file.loaded) return
        const d = _file.data
        if (d && typeof d === "object" && Array.isArray(d.tabs)) {
            _saved = { tabs: d.tabs, current: d.current || 0,
                       closed: Array.isArray(d.closed) ? d.closed : [], savedAt: d.savedAt || 0 }
            _savedClosed = _saved.closed
            // A running mark is ours only if we own the file (otherwise the
            // process that does is simply still running).
            _crashed = d.running === true && enabled
        }
        _started = true
        _mergeClosed()
        // Mark the file as running right away, keeping the saved tabs until
        // the first change: a crash during startup must not lose them.
        _last = _saved ? Object.assign({ version: 1 }, _saved) : snapshot()
        _write(true)
        _last = snapshot()
    }
    function _end() {
        if (_ended) return
        if (_started) _write(false)
        _ended = true
        _timer.stop()
    }

    onTabsChanged: _changed()
    onControllerChanged: { _mergeClosed(); _changed() }
    onEnabledChanged: _changed()

    property JsonStore _file: JsonStore {
        path: session.name === "" ? "" : session.name + ".json"
        autoSave: false
        onLoadedChanged: if (loaded) session._start()
    }
    property Timer _timer: Timer {
        interval: session.saveDelay
        onTriggered: session._write(true)
    }
    property Connections _tabsConnection: Connections {
        target: session.tabs
        function onSessionChanged() { session._changed() }
    }
    property Connections _controllerConnection: Connections {
        target: session.controller
        function onClosedTabsChanged() { session._changed() }
    }
    property Connections _appConnection: Connections {
        target: Qt.application
        function onAboutToQuit() {
            session._last = session.snapshot()
            session._end()
        }
    }

    Component.onCompleted: _start()
    Component.onDestruction: {
        _end()
        if (_claimed) Registry.release(_claimed, session)
    }
}
