import QtQuick
import CefQml

// Non-visual tab manager: owns one CefWebView per tab, stacked in this item,
// with only the current one visible (hidden tabs stop rendering). Background
// tabs can be discarded (discard(), or restore() with `lazy`): they keep
// their URL, title and icon but have no browser until they are selected.
//
//   WebTabs { id: tabs; anchors.fill: parent; Component.onCompleted: openTab("https://example.com") }
//   tabs.currentView.goBack()
Item {
    id: tabs

    // CefWebView objects in tab order. Reassigned on every change.
    property var views: []
    readonly property int count: views.length
    property int currentIndex: -1
    readonly property CefWebView currentView:
        currentIndex >= 0 && currentIndex < views.length ? views[currentIndex] : null

    property url homeUrl: "about:blank"
    // Instantiated for each tab; must be (or derive from) CefWebView.
    property Component viewDelegate: Component { CefWebView {} }
    // target=_blank / window.open / middle click open a tab next to the opener.
    property bool openPopupsInNewTabs: true
    // Close the tab when the page calls window.close().
    property bool closeOnRequest: true
    // Userscripts injected into every tab (a UserScriptStore), or null.
    // Tabs opened afterwards get them before their first page; tabs that
    // are already open from their next document on.
    property var userScriptStore: null
    property var _attachedStore: null
    onUserScriptStoreChanged: {
        if (_attachedStore) for (const v of views) _attachedStore.detach(v)
        _attachedStore = userScriptStore
        if (userScriptStore) for (const v of views) userScriptStore.attach(v)
    }
    // A HistoryStore that records every tab's visits (null: none).
    property var historyStore: null
    property var _attachedHistory: null
    onHistoryStoreChanged: {
        if (_attachedHistory) for (const v of views) _attachedHistory.detach(v)
        _attachedHistory = historyStore
        if (historyStore) for (const v of views) historyStore.attach(v)
    }
    Component.onCompleted: {
        _attachedStore = userScriptStore
        _attachedHistory = historyStore
    }

    // When enabled, the matching request of every tab is forwarded through
    // the signals below instead of CEF's default handling.
    property bool interceptJavaScriptDialogs: false
    property bool interceptPermissions: false
    property bool interceptFileDialogs: false
    property bool interceptDownloads: false

    signal tabOpened(CefWebView view, int index)
    signal tabClosed(CefWebView view, int index)
    signal lastTabClosed()
    // Tabs, order or current tab changed, or a tab's url, title, icon,
    // zoomFactor, audioMuted or discarded state (persist with urls(), or
    // let a SessionStore do it).
    signal sessionChanged()

    signal javaScriptDialogRequested(CefWebView view, CefJavaScriptDialog dialog)
    signal permissionRequested(CefWebView view, CefPermissionRequest request)
    signal fileDialogRequested(CefWebView view, CefFileDialogRequest request)
    signal downloadRequested(CefWebView view, CefDownload download)
    signal contextMenuRequested(CefWebView view, real x, real y, url linkUrl, string selectedText, bool editable)

    onCurrentIndexChanged: {
        _updateVisibility()
        sessionChanged()
    }

    function indexOf(view) { return views.indexOf(view) }

    // Opens `url` in a new tab at `index` (default: end) and returns its view.
    // `properties` are set on the new view, e.g. { discarded: true, title:
    // "Placeholder" } for a tab that only loads once selected.
    function openTab(url, background, index, properties) {
        const view = _create(url, properties)
        if (!view) return null
        const list = views.slice()
        const at = index === undefined || index < 0 || index > list.length ? list.length : index
        list.splice(at, 0, view)
        views = list
        if (!background || currentIndex < 0)
            currentIndex = at
        else if (at <= currentIndex)
            currentIndex++
        _updateVisibility()
        tabOpened(view, at)
        sessionChanged()
        return view
    }

    function closeTab(index) {
        if (index === undefined) index = currentIndex
        if (index < 0 || index >= views.length) return
        const list = views.slice()
        const view = list.splice(index, 1)[0]
        let next = currentIndex
        if (index < currentIndex || (index === currentIndex && index === list.length))
            next = currentIndex - 1
        views = list
        currentIndex = list.length === 0 ? -1 : Math.max(0, next)
        _updateVisibility()
        tabClosed(view, index)
        view.destroy()
        sessionChanged()
        if (list.length === 0) lastTabClosed()
    }

    function moveTab(from, to) {
        if (from === to || from < 0 || to < 0 || from >= views.length || to >= views.length) return
        const current = currentView
        const list = views.slice()
        list.splice(to, 0, list.splice(from, 1)[0])
        views = list
        currentIndex = list.indexOf(current)
        sessionChanged()
    }

    function closeAll() {
        while (views.length > 0) closeTab(views.length - 1)
    }

    // Frees the browser of background tab `index` (see CefWebView.discarded):
    // it keeps its URL, title and icon and loads again when selected (or
    // navigated, or reloaded). Back/forward history and page state are lost.
    // Returns false for the current tab or one already discarded.
    function discard(index) {
        const view = index >= 0 && index < views.length ? views[index] : null
        if (!view || index === currentIndex || view.discarded) return false
        view.discarded = true
        return true
    }

    // URLs of all tabs, for session persistence.
    function urls() { return views.map(v => v.url.toString()) }

    // Replaces all tabs with `entries`, selecting `current`, and returns the
    // new views. Entries are URLs or { url, title, icon, zoom, muted }
    // objects (title and icon are shown until the page provides its own).
    // `options`:
    //   lazy: background tabs start discarded, so only the current tab loads
    //   append: keep the existing tabs and add these after them
    function restore(entries, current, options) {
        options = options || {}
        if (!options.append) {
            const old = views.slice()
            views = []
            currentIndex = -1
            old.forEach(v => v.destroy())
        }
        const n = entries ? entries.length : 0
        if (n === 0) return []
        const selected = Math.max(0, Math.min(current || 0, n - 1))
        const created = []
        for (let i = 0; i < n; ++i) {
            const e = entries[i]
            const isEntry = e !== null && typeof e === "object" && ("url" in e)
            const props = {}
            if (isEntry) {
                if (e.title) props.title = e.title
                if (e.icon) props.icon = e.icon
                if (e.zoom > 0 && e.zoom !== 1) props.zoomFactor = e.zoom
                if (e.muted) props.audioMuted = true
            }
            if (options.lazy && i !== selected) props.discarded = true
            const view = _create(isEntry ? e.url : e, props)
            if (view) created.push(view)
        }
        const base = views.length
        views = views.concat(created)
        const at = base + Math.min(selected, created.length - 1)
        if (currentIndex === at) _updateVisibility()
        else currentIndex = at
        created.forEach((v, i) => tabOpened(v, base + i))
        sessionChanged()
        return created
    }

    function _create(url, properties) {
        const target = url === undefined || url === null || url === "" ? homeUrl : url
        const props = Object.assign({}, properties || {}, { url: target, visible: false })
        const view = viewDelegate.createObject(tabs, props)
        if (!view) {
            console.warn("WebTabs: could not create view:", viewDelegate.errorString())
            return null
        }
        view.anchors.fill = tabs
        _wire(view)
        return view
    }

    function _updateVisibility() {
        for (let i = 0; i < views.length; ++i) {
            const v = views[i]
            v.visible = i === currentIndex
            if (v.visible && v.discarded) v.discarded = false
        }
    }

    function _wire(view) {
        _attachedStore = userScriptStore
        if (userScriptStore) userScriptStore.attach(view)
        _attachedHistory = historyStore
        if (historyStore) historyStore.attach(view)
        view.urlChanged.connect(tabs.sessionChanged)
        view.titleChanged.connect(tabs.sessionChanged)
        view.iconChanged.connect(tabs.sessionChanged)
        view.zoomFactorChanged.connect(tabs.sessionChanged)
        view.audioMutedChanged.connect(tabs.sessionChanged)
        view.discardedChanged.connect(tabs.sessionChanged)
        view.newWindowRequested.connect((url, userGesture, background) => {
            if (tabs.openPopupsInNewTabs)
                tabs.openTab(url, background, tabs.indexOf(view) + 1)
            else
                view.url = url
        })
        view.closeRequested.connect(() => { if (tabs.closeOnRequest) tabs.closeTab(tabs.indexOf(view)) })
        view.contextMenuRequested.connect((x, y, link, sel, editable) =>
            tabs.contextMenuRequested(view, x, y, link, sel, editable))
        // Request signals are only connected while intercepted, so that CEF's
        // defaults apply otherwise (the view checks for connected handlers).
        const forward = (enabled, signal, handler) => {
            const update = () => {
                if (tabs[enabled] && !handler.connected) { signal.connect(handler.fn); handler.connected = true }
                else if (!tabs[enabled] && handler.connected) { signal.disconnect(handler.fn); handler.connected = false }
            }
            tabs[enabled + "Changed"].connect(update)
            update()
        }
        forward("interceptJavaScriptDialogs", view.javaScriptDialogRequested,
                { fn: d => tabs.javaScriptDialogRequested(view, d) })
        forward("interceptPermissions", view.permissionRequested,
                { fn: r => tabs.permissionRequested(view, r) })
        forward("interceptFileDialogs", view.fileDialogRequested,
                { fn: r => tabs.fileDialogRequested(view, r) })
        forward("interceptDownloads", view.downloadRequested,
                { fn: d => tabs.downloadRequested(view, d) })
    }
}
