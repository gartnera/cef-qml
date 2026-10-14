import QtQuick
import CefQml

// Non-visual tab manager: owns one CefWebView per tab, stacked in this item,
// with only the current one visible (hidden tabs stop rendering).
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

    // When enabled, the matching request of every tab is forwarded through
    // the signals below instead of CEF's default handling.
    property bool interceptJavaScriptDialogs: false
    property bool interceptPermissions: false
    property bool interceptFileDialogs: false
    property bool interceptDownloads: false

    signal tabOpened(CefWebView view, int index)
    signal tabClosed(CefWebView view, int index)
    signal lastTabClosed()
    // Tabs, order, current tab or any tab URL changed (persist with urls()).
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
    function openTab(url, background, index) {
        const target = url === undefined || url === "" ? homeUrl : url
        const view = viewDelegate.createObject(tabs, { url: target, visible: false })
        if (!view) {
            console.warn("WebTabs: could not create view:", viewDelegate.errorString())
            return null
        }
        view.anchors.fill = tabs
        _wire(view)
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

    // URLs of all tabs, for session persistence.
    function urls() { return views.map(v => v.url.toString()) }

    // Replaces all tabs with `urlList`, selecting `current`.
    function restore(urlList, current) {
        const list = views.slice()
        views = []
        currentIndex = -1
        list.forEach(v => v.destroy())
        for (const u of urlList) openTab(u, true)
        if (views.length > 0)
            currentIndex = Math.max(0, Math.min(current || 0, views.length - 1))
    }

    function _updateVisibility() {
        for (let i = 0; i < views.length; ++i)
            views[i].visible = i === currentIndex
    }

    function _wire(view) {
        view.urlChanged.connect(tabs.sessionChanged)
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
