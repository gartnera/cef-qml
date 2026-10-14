import QtQuick
import QtQml
import CefQml

// A complete tabbed browser assembled from the other components. Use it as
// is, or copy it as a starting point for your own layout.
//
//   Browser { anchors.fill: parent; initialUrls: ["https://example.com"] }
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

    signal lastTabClosed()

    // Opens `url` (typed text is turned into a URL or a search).
    function open(url, newTab) {
        const target = typeof url === "string" ? navBar.addressField.urlFor(url) : url
        if (newTab || !currentView) webTabs.openTab(target)
        else currentView.url = target
    }
    // True for the built-in new-tab page (Chromium re-encodes data: URLs, so
    // match on a marker instead of the exact string).
    function isNewTabUrl(u) {
        u = u.toString()
        if (!u.startsWith("data:")) return false
        try { return decodeURIComponent(u).indexOf("cefqml-newtab") >= 0 } catch (e) { return u.indexOf("cefqml-newtab") >= 0 }
    }
    function newTab() {
        webTabs.openTab(homeUrl)
        navBar.addressField.focusAndSelect()
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
  <a href="https://quickshell.org"><span>Q</span>Quickshell</a>
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
        onOpenLinkInNewTab: url => webTabs.openTab(url, true, webTabs.currentIndex + 1)
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

    // Keyboard shortcuts (window-wide, so they work while a page has focus).
    // Note: listing the same keys twice (e.g. StandardKey.AddTab and "Ctrl+T")
    // makes a Shortcut ambiguous and it never fires.
    component Key: Shortcut { context: Qt.WindowShortcut; enabled: browser.enabled && browser.visible }
    Key { sequences: ["Ctrl+T"]; onActivated: browser.newTab() }
    Key { sequences: ["Ctrl+W", "Ctrl+F4"]; onActivated: webTabs.closeTab() }
    Key { sequences: ["Ctrl+L", "F6", "Alt+D"]; onActivated: navBar.addressField.focusAndSelect() }
    Key { sequences: ["Ctrl+Tab", "Ctrl+PgDown"]; onActivated: webTabs.currentIndex = (webTabs.currentIndex + 1) % webTabs.count }
    Key { sequences: ["Ctrl+Shift+Tab", "Ctrl+PgUp"]; onActivated: webTabs.currentIndex = (webTabs.currentIndex + webTabs.count - 1) % webTabs.count }
    Key { sequences: ["Ctrl+R", "F5"]; onActivated: if (browser.currentView) browser.currentView.reload() }
    Key { sequences: ["Ctrl+Shift+R", "Shift+F5"]; onActivated: if (browser.currentView) browser.currentView.reloadIgnoringCache() }
    Key { sequences: ["Alt+Left"]; onActivated: if (browser.currentView) browser.currentView.goBack() }
    Key { sequences: ["Alt+Right"]; onActivated: if (browser.currentView) browser.currentView.goForward() }
    Key { sequences: ["Ctrl+F", "F3"]; onActivated: findBar.open() }
    Key { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: if (browser.currentView) browser.currentView.zoomFactor += 0.1 }
    Key { sequences: ["Ctrl+-"]; onActivated: if (browser.currentView) browser.currentView.zoomFactor -= 0.1 }
    Key { sequences: ["Ctrl+0"]; onActivated: if (browser.currentView) browser.currentView.zoomFactor = 1 }
    Instantiator {
        model: 9
        delegate: Key {
            required property int index
            sequences: ["Ctrl+" + (index + 1)]
            onActivated: webTabs.currentIndex = index === 8 ? webTabs.count - 1 : Math.min(index, webTabs.count - 1)
        }
    }
}
