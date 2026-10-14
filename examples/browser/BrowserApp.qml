// The reference browser application. Loaded by main.qml (normal run) or
// dev.qml (live reloading).
import QtQuick
import CefQml
import CefQml.Components

Item {
    id: app
    property alias browser: browser
    // Opened next to the restored session (command line URLs).
    property var initialUrls: []

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        // Reopen the last session's tabs (Cef.dataDir/session.json); under
        // HotReload (dev.qml) this also keeps the tabs across reloads: the
        // old UI saves the session when it is destroyed, before the new one
        // is created. Command line URLs only open on the first load.
        restoreSession: "always"
        initialUrls: app.hot && app.hot.generation > 0 ? [] : app.initialUrls

        // Key bindings: { actionName: [keys] } replaces an action's default
        // keys; [] unbinds it (see "Actions, key bindings and scripting" in
        // the README; browser.actions.names() lists the actions).
        // bindings: ({
        //     "tab.new": ["Ctrl+T", "Ctrl+N"],
        //     "zoom.reset": [],
        //     "app.copyTitle": ["Ctrl+Shift+C"],
        // })

        // Userscripts: Ctrl+Shift+U opens the manager; opening a *.user.js
        // URL offers to install it. browser.userScriptStore holds them
        // (Cef.dataDir/userscripts); userScriptStore: null turns them off.

        // History: recorded in Cef.dataDir/history.json, searched by the
        // address bar, Ctrl+H shows it. historyStore: null turns it off;
        // browser.historyStore.recording = false is private browsing.

        // Site settings: remembered permission decisions, per-site zoom,
        // JavaScript / images / pop-ups in Cef.dataDir/site-settings.json.
        // The (i) button left of the address field shows the site info card;
        // "site.info" / "site.settings" have no keys by default.
        // siteSettings: null turns per-site settings off;
        // tabs.zoomPolicy: "tab" keeps a zoom per tab instead of per site.
        // Component.onCompleted: browser.siteSettings.set("*", "javascript", "block")

        // An action of your own; give it keys here or in `bindings`.
        // BrowserAction {
        //     registry: browser.actions
        //     name: "app.copyTitle"; text: "Copy page title"
        //     defaultShortcuts: ["Ctrl+Shift+C"]
        //     onTriggered: Cef.copyToClipboard(browser.title)
        // }
    }

    readonly property var hot: typeof hotReload !== "undefined" ? hotReload : null
    // Without a session file of our own (another process holds the profile,
    // see Cef.temporaryProfile), carry the tabs across reloads in memory.
    Connections {
        target: app.hot
        function onAboutToReload() { app.hot.state = { session: browser.sessionStore.snapshot() } }
    }

    Component.onCompleted: {
        const s = browser.sessionStore
        if (hot && hot.state.session && !s.enabled)
            s.restore({ session: hot.state.session, replace: true })
        browser.forceActiveFocus()
    }
}
