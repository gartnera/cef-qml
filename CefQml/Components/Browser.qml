import QtQuick
import QtQml
import CefQml

// A complete tabbed browser assembled from the other components. Use it as
// is, or copy it as a starting point for your own layout.
//
//   Browser { anchors.fill: parent; initialUrls: ["https://example.com"] }
//
// Keyboard shortcuts come from `actions` (BrowserActions) through
// `keyBindings` (KeyBindings); `bindings` overrides them:
//
//   Browser { bindings: ({ "tab.new": ["Ctrl+T", "Ctrl+N"], "nav.back": [] }) }
//
// Scripting: navigate(), openTab(), selectTab(), trigger("tab.next"), ...
// forward to `controller` (BrowserController).
FocusScope {
    id: browser

    property alias tabs: webTabs
    readonly property CefWebView currentView: webTabs.currentView
    readonly property string title: currentView ? (currentView.title || "New Tab") : ""
    property string searchUrl: "https://duckduckgo.com/?q=%s"
    property url homeUrl: newTabUrl
    // Tabs opened on start-up, after the restored session if any (the first
    // one is selected). With neither, one home tab opens.
    property var initialUrls: []
    // Open the start-up tabs (session, initialUrls or home) when complete.
    property bool openInitialTabs: true
    // Open tabs and recently closed tabs, saved to Cef.dataDir/<sessionName>.json
    // (SessionStore). Give each Browser of a process its own sessionName.
    // Set sessionStore to null to keep no session.
    property string sessionName: "session"
    property SessionStore sessionStore: SessionStore {
        id: defaultSession
        // Inert once replaced (e.g. createObject(..., { sessionStore: null })).
        readonly property bool active: browser.sessionStore === defaultSession
        name: active ? browser.sessionName : ""
        tabs: active ? webTabs : null
        controller: active ? ctl : null
        internalTabUrl: browser.newTabUrl
    }
    // When to reopen the saved session on start-up: "always", "never" or
    // "ifCrashed" (the previous run did not exit cleanly). Background tabs
    // restore discarded (sessionStore.lazy). The "session.restore" action
    // reopens the previous session later.
    property string restoreSession: "ifCrashed"
    // True if the start-up tabs came from the saved session.
    readonly property bool sessionRestored: _sessionRestored
    property bool _sessionRestored: false
    // Open a fresh tab when the last one is closed (otherwise emit lastTabClosed).
    property bool keepOneTab: true
    property alias tabStrip: tabStrip
    property alias navigationBar: navBar
    property alias findBar: findBar

    // Programmatic API, actions and key bindings.
    property alias controller: ctl
    property alias actions: acts
    property alias keyBindings: keys
    // User key bindings, { actionName: [sequences] } (see KeyBindings).
    property alias bindings: keys.bindings
    // Userscripts injected into every tab (UserScriptStore, persisted under
    // Cef.dataDir/userscripts). Set to null to disable them.
    property QtObject userScriptStore: UserScriptStore { }
    // The userscript manager overlay (UserScriptManager; action
    // "userscripts.manage", Ctrl+Shift+U) and whether it is shown.
    property alias userScriptManager: usManager
    readonly property bool userScriptManagerVisible: userScriptOverlay.visible
    // Offer to install pages whose URL ends in .user.js (http(s) and file:).
    property bool offerUserScriptInstall: true
    // Browsing history of every tab (HistoryStore, Cef.dataDir/history.json;
    // the new-tab page is not recorded). Set to null to disable history; set
    // `historyStore.recording` to false for private browsing. Share one store
    // between several Browser windows.
    property QtObject historyStore: HistoryStore {
        path: "history.json"
        ignoreUrl: u => !!browser && browser.isNewTabUrl(u)
    }
    // The address bar's drop-down (AddressSuggestions): add your own
    // sources with addressSuggestions.addProvider(...).
    property alias addressSuggestions: suggestions
    // The history overlay (HistoryView; action "history.show", Ctrl+H) and
    // whether it is shown.
    property alias historyView: historyPanel
    readonly property bool historyVisible: historyOverlay.visible
    // Bookmarks (BookmarkStore, Cef.dataDir/bookmarks.json): the star in
    // the navigation bar, the bookmarks bar, the bookmark manager and
    // address-bar suggestions use it. Set to null to disable bookmarks;
    // share one store between several Browser windows.
    property QtObject bookmarkStore: BookmarkStore { path: "bookmarks.json" }
    // Show the bookmarks bar under the navigation bar ("bookmarks.showBar",
    // Ctrl+Shift+B).
    property bool showBookmarksBar: true
    property alias bookmarksBar: bmBar
    // The bookmark manager overlay (BookmarkManager; action
    // "bookmarks.manage", Ctrl+Shift+O) and whether it is shown.
    property alias bookmarkManager: bmManager
    readonly property bool bookmarkManagerVisible: bookmarkOverlay.visible
    // The tab strip's right-click menu and the recently closed tabs menu
    // (RecentlyClosedMenu; action "tab.recentlyClosed").
    property alias tabMenu: tabMenu
    property alias recentlyClosedMenu: closedMenu

    signal lastTabClosed()

    // ---- scripting (see BrowserController for the details) ----------------

    // Loads `target` (url or typed text); returns a Promise of the load
    // result. opts: { newTab, background, index, tab, timeout }.
    function navigate(target, opts, callback) { return ctl.navigate(target, opts, callback) }
    // Opens a tab and returns its view. opts: { background, index }.
    function openTab(url, opts, callback) { return ctl.openTab(url, opts, callback) }
    function closeTab(tab) { return ctl.closeTab(tab) }
    function selectTab(tab) { return ctl.selectTab(tab) }
    function back(tab) { return ctl.back(tab) }
    function forward(tab) { return ctl.forward(tab) }
    function reload(tab, ignoreCache) { return ctl.reload(tab, ignoreCache) }
    function stop(tab) { return ctl.stop(tab) }
    function findTab(predicate) { return ctl.findTab(predicate) }
    function tabForUrl(url) { return ctl.tabForUrl(url) }
    function whenLoaded(view, callback, opts) { return ctl.whenLoaded(view, callback, opts) }
    function showUserScripts() { userScriptOverlay.open() }
    function hideUserScripts() { userScriptOverlay.close() }
    // Opens the manager reviewing the userscript at `url` for installation.
    function reviewUserScript(url) {
        userScriptOverlay.open()
        usManager.review(url)
    }
    function showHistory() { historyOverlay.open() }
    function hideHistory() { historyOverlay.close() }
    function showBookmarks() { bookmarkOverlay.open() }
    function hideBookmarks() { bookmarkOverlay.close() }
    // Opens a bookmark (or any URL) as the bookmark components do: here, or
    // in a background tab next to the current one.
    function openBookmark(url, newTab) {
        if (newTab) return ctl.openTab(url, { background: true, index: webTabs.currentIndex + 1 })
        const r = ctl.navigate(url)
        if (webTabs.currentView) webTabs.currentView.forceActiveFocus(Qt.OtherFocusReason)
        return r
    }
    function isUserScriptUrl(url) {
        return /^(https?|file):[^?#]*\.user\.js([?#].*)?$/i.test(String(url))
    }
    // Runs the action `name` (e.g. "tab.next", "tab.select" with { index: 2 }).
    function trigger(name, args) { return acts.trigger(name, args) }

    // Opens `url` (typed text is turned into a URL or a search).
    function open(url, newTab) { return ctl.navigate(url, { newTab: !!newTab }) }
    // True for the built-in new-tab page (Chromium re-encodes data: URLs, so
    // match on a marker instead of the exact string).
    function isNewTabUrl(u) {
        u = u.toString()
        if (!u.startsWith("data:")) return false
        try { return decodeURIComponent(u).indexOf("cefqml-newtab") >= 0 } catch (e) { return u.indexOf("cefqml-newtab") >= 0 }
    }
    // A home-page tab with the address field focused (the "tab.new" action).
    function newTab() { acts.trigger("tab.new") }
    // Shows the menu for tab `index` at point (x, y) of `item` (the tab
    // strip's right click).
    function showTabMenu(index, item, x, y) {
        const v = webTabs.views[index]
        if (!v) return false
        const hint = name => keys.hint(name)
        const closed = ctl.closedTabs.length
        tabMenu.entries = [
            { label: "New tab", hint: hint("tab.new"), action: () => browser.newTab() },
            null,
            { label: "Reload", action: () => ctl.reload(v) },
            { label: "Duplicate", action: () => ctl.duplicateTab(v) },
            { label: v.audioMuted ? "Unmute tab" : "Mute tab", action: () => v.audioMuted = !v.audioMuted },
            { label: "Discard tab", enabled: index !== webTabs.currentIndex && !v.discarded,
              action: () => ctl.discardTab(v) },
            null,
            { label: "Close tab", hint: index === webTabs.currentIndex ? hint("tab.close") : "",
              action: () => ctl.closeTab(v) },
            { label: "Close other tabs", enabled: webTabs.count > 1,
              action: () => webTabs.views.filter(t => t !== v).forEach(t => ctl.closeTab(t)) },
            { label: "Close tabs to the right", enabled: index < webTabs.count - 1,
              action: () => webTabs.views.slice(index + 1).reverse().forEach(t => ctl.closeTab(t)) },
            null,
            { label: "Reopen closed tab", hint: hint("tab.reopenClosed"), enabled: closed > 0,
              action: () => ctl.reopenClosedTab() },
            { label: "Recently closed tabs…", enabled: closed > 0,
              action: () => closedMenu.popup(item, x, y) },
        ]
        return tabMenu.popup(item, x, y)
    }

    readonly property string newTabUrl: "data:text/html;charset=utf-8," + encodeURIComponent(newTabHtml)
    property string newTabHtml: `<!doctype html><html><head><title>New Tab</title><meta charset="utf-8"><meta name="cefqml-newtab">
<style>
  :root { color-scheme: dark }
  html, body { height: 100%; margin: 0 }
  body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 28px;
         background: radial-gradient(1200px 600px at 50% -10%, ${Qt.lighter(Style.accent, 1.0)}33, transparent 60%), ${Style.background};
         font: 15px system-ui, sans-serif; color: ${Style.text} }
  h1 { font-weight: 300; font-size: 44px; margin: 0; letter-spacing: -1px }
  #clock { color: ${Style.textDim}; font-size: 14px; margin-top: -18px }
  form { width: min(560px, 86vw) }
  input { width: 100%; box-sizing: border-box; padding: 14px 20px; border-radius: 999px; outline: none;
          border: 1px solid ${Style.border}; background: ${Style.surface}; color: ${Style.text}; font-size: 16px }
  input:focus { border-color: ${Style.accent}; box-shadow: 0 0 0 4px ${Style.accent}33 }
  .links { display: flex; gap: 14px; flex-wrap: wrap; justify-content: center }
  .links a { display: flex; flex-direction: column; align-items: center; gap: 8px; width: 88px; padding: 14px 0;
             border-radius: 12px; color: ${Style.text}; text-decoration: none; font-size: 12px }
  .links a:hover { background: ${Style.surface} }
  .links span { width: 40px; height: 40px; border-radius: 50%; display: grid; place-items: center;
                background: ${Style.surfaceHover}; font-size: 18px; font-weight: 600 }
</style></head><body>
<h1 id="greet">Hello</h1><div id="clock"></div>
<form action="${searchUrl.split("?")[0]}" method="get">
  <input name="${(searchUrl.split("?")[1] || "q=").split("=")[0]}" placeholder="Search the web" autocomplete="off">
</form>
<div class="links">
  <a href="https://github.com"><span>G</span>GitHub</a>
  <a href="https://en.wikipedia.org"><span>W</span>Wikipedia</a>
  <a href="https://news.ycombinator.com"><span>Y</span>Hacker News</a>
  <a href="https://www.youtube.com"><span>▶</span>YouTube</a>
  <a href="https://doc.qt.io"><span>Q</span>Qt Docs</a>
</div>
<script>
  const tick = () => { const d = new Date(); const h = d.getHours();
    greet.textContent = h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
    clock.textContent = d.toLocaleString(undefined, { weekday: "long", hour: "2-digit", minute: "2-digit" }) };
  tick(); setInterval(tick, 10000);
</script></body></html>`

    Rectangle { anchors.fill: parent; color: Style.background }

    TabStrip {
        id: tabStrip
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        tabs: webTabs
        onNewTabRequested: browser.newTab()
        onContextMenuRequested: (index, x, y) => browser.showTabMenu(index, tabStrip, x, y)
    }

    NavigationBar {
        id: navBar
        anchors.top: tabStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        view: webTabs.currentView
        searchUrl: browser.searchUrl
        keyBindings: keys
        bookmarkStore: browser.bookmarkStore
        addressField.isInternalUrl: u => browser.isNewTabUrl(u)
    }

    BookmarksBar {
        id: bmBar
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        store: browser.bookmarkStore
        visible: browser.showBookmarksBar && store !== null
        height: visible ? implicitHeight : 0
        onOpenRequested: (url, newTab) => browser.openBookmark(url, newTab)
        onManageRequested: bookmarkOverlay.open()
        onHideRequested: browser.showBookmarksBar = false
    }

    FindBar {
        id: findBar
        anchors.top: bmBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        view: webTabs.currentView
        visible: false
        height: visible ? implicitHeight : 0
    }

    Item {
        id: content
        anchors.top: findBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: downloads.top

        WebTabs {
            id: webTabs
            anchors.fill: parent
            homeUrl: browser.homeUrl
            userScriptStore: browser.userScriptStore
            historyStore: browser.historyStore
            onLastTabClosed: browser.keepOneTab ? browser.newTab() : browser.lastTabClosed()
            onCurrentViewChanged: if (currentView && browser.activeFocus && !navBar.addressField.input.activeFocus)
                                      currentView.forceActiveFocus()
            onFileDialogRequested: (view, request) => fileDialogs.item ? fileDialogs.item.open(request) : request.reject()
            interceptFileDialogs: fileDialogs.status === Loader.Ready
        }

        StatusBubble {
            view: webTabs.currentView
            anchors.margins: 4
        }

        RequestOverlay {
            anchors.fill: parent
            tabs: webTabs
        }

        // Manager panels; opening one closes the other.
        PanelOverlay {
            id: userScriptOverlay
            objectName: "userScriptOverlay"
            anchors.fill: parent
            available: browser.userScriptStore !== null
            returnFocusTo: webTabs.currentView
            onOpened: { historyOverlay.close(); bookmarkOverlay.close() }
            UserScriptManager {
                id: usManager
                objectName: "userScriptManager"
                anchors.fill: parent
                store: browser.userScriptStore
                view: webTabs.currentView
                onCloseRequested: userScriptOverlay.close()
            }
        }

        PanelOverlay {
            id: historyOverlay
            objectName: "historyOverlay"
            anchors.fill: parent
            panelWidth: 760
            available: browser.historyStore !== null
            returnFocusTo: webTabs.currentView
            onOpened: { userScriptOverlay.close(); bookmarkOverlay.close() }
            HistoryView {
                id: historyPanel
                objectName: "historyView"
                anchors.fill: parent
                store: browser.historyStore
                // Click: open here and close; Ctrl/middle click: background tab.
                onOpenRequested: (url, newTab) => {
                    if (newTab) {
                        ctl.openTab(url, { background: true, index: webTabs.currentIndex + 1 })
                        return
                    }
                    historyOverlay.close()
                    ctl.navigate(url)
                }
                onCloseRequested: historyOverlay.close()
            }
        }

        PanelOverlay {
            id: bookmarkOverlay
            objectName: "bookmarkOverlay"
            anchors.fill: parent
            panelWidth: 860
            available: browser.bookmarkStore !== null
            returnFocusTo: webTabs.currentView
            onOpened: { userScriptOverlay.close(); historyOverlay.close() }
            BookmarkManager {
                id: bmManager
                objectName: "bookmarkManager"
                anchors.fill: parent
                store: browser.bookmarkStore
                // Open here and close; Ctrl/middle click: background tab.
                onOpenRequested: (url, newTab) => {
                    if (!newTab) bookmarkOverlay.close()
                    browser.openBookmark(url, newTab)
                }
                onCloseRequested: bookmarkOverlay.close()
            }
        }
    }

    DownloadsBar {
        id: downloads
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? implicitHeight : 0
    }

    ContextMenu {
        anchors.fill: parent
        tabs: webTabs
        keyBindings: keys
        onOpenLinkInNewTab: url => ctl.openTab(url, { background: true, index: webTabs.currentIndex + 1 })
    }

    AddressSuggestions {
        id: suggestions
        objectName: "addressSuggestions"
        addressField: navBar.addressField
        historyStore: browser.historyStore
        bookmarkStore: browser.bookmarkStore
        tabs: webTabs
        navigate: (url, newTab) => {
            if (!newTab) return navBar.addressField.go(url)
            const v = ctl.openTab(url)
            if (v) v.forceActiveFocus(Qt.OtherFocusReason)
        }
        selectTab: view => {
            ctl.selectTab(view)
            view.forceActiveFocus(Qt.OtherFocusReason)
        }
    }

    Loader {
        id: fileDialogs
        // Optional: needs the QtQuick.Dialogs module.
        source: Qt.resolvedUrl("FileDialogHandler.qml")
    }

    PopupMenu {
        id: tabMenu
        objectName: "tabMenu"
    }
    RecentlyClosedMenu {
        id: closedMenu
        objectName: "recentlyClosedMenu"
        controller: ctl
    }

    Component.onCompleted: {
        if (!openInitialTabs) return
        const s = sessionStore
        if (s && s.enabled && (restoreSession === "always" || (restoreSession === "ifCrashed" && s.crashed)))
            _sessionRestored = s.restore({ replace: true }).length > 0
        if (initialUrls.length > 0) webTabs.restore(initialUrls, 0, { append: webTabs.count > 0 })
        else if (webTabs.count === 0) webTabs.openTab(homeUrl)
    }

    BrowserController {
        id: ctl
        tabs: webTabs
        searchUrl: browser.searchUrl
        isInternalUrl: u => browser.isNewTabUrl(u)
    }

    BrowserActions {
        id: acts
        controller: ctl
        addressField: navBar.addressField
        findBar: findBar
        window: browser.Window.window
        userScriptManager: browser.userScriptStore ? userScriptOverlay : null
        historyView: browser.historyStore ? historyOverlay : null
        bookmarkStore: browser.bookmarkStore
        bookmarkButton: browser.bookmarkStore ? navBar.bookmarkButton : null
        bookmarkManager: browser.bookmarkStore ? bookmarkOverlay : null
        bookmarksBarTarget: browser.bookmarkStore ? browser : null
        bookmarksBarProperty: "showBookmarksBar"
        recentlyClosedMenu: closedMenu
        sessionStore: browser.sessionStore
    }

    // Install prompt for *.user.js pages loaded in the current tab.
    Connections {
        target: webTabs.currentView
        function onLoadingChanged() {
            const v = webTabs.currentView
            if (browser.offerUserScriptInstall && browser.userScriptStore && v && !v.loading
                    && browser.isUserScriptUrl(v.url))
                browser.reviewUserScript(v.url.toString())
        }
    }

    // Window-wide, so they work while a page has focus.
    KeyBindings {
        id: keys
        actions: acts
    }
}
