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
    // Tabs opened on start-up; empty opens one home tab.
    property var initialUrls: []
    property bool openInitialTabs: true
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
    }

    NavigationBar {
        id: navBar
        anchors.top: tabStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        view: webTabs.currentView
        searchUrl: browser.searchUrl
        keyBindings: keys
        addressField.isInternalUrl: u => browser.isNewTabUrl(u)
    }

    FindBar {
        id: findBar
        anchors.top: navBar.bottom
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

        Item {
            id: userScriptOverlay
            objectName: "userScriptOverlay"
            anchors.fill: parent
            visible: false
            function open() {
                if (!browser.userScriptStore) return
                visible = true
                usManager.focusDefault()
            }
            function close() {
                if (!visible) return
                visible = false
                if (webTabs.currentView) webTabs.currentView.forceActiveFocus()
            }
            function toggle() { visible ? close() : open() }

            Rectangle {
                anchors.fill: parent
                color: "#80000000"
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onClicked: userScriptOverlay.close()
                    onWheel: {}
                }
            }
            UserScriptManager {
                id: usManager
                objectName: "userScriptManager"
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(8, Math.min(48, (parent.height - 600) / 2))
                width: Math.min(820, parent.width - 32)
                height: Math.min(600, parent.height - 2 * y)
                store: browser.userScriptStore
                view: webTabs.currentView
                onCloseRequested: userScriptOverlay.close()
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

    Loader {
        id: fileDialogs
        // Optional: needs the QtQuick.Dialogs module.
        source: Qt.resolvedUrl("FileDialogHandler.qml")
    }

    Component.onCompleted: {
        if (!openInitialTabs) return
        if (initialUrls.length > 0) webTabs.restore(initialUrls, 0)
        else webTabs.openTab(homeUrl)
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
