// The reference browser application. Loaded by main.qml (normal run) or
// dev.qml (live reloading).
import QtQuick
import CefQml
import CefQml.Components

Item {
    id: app
    property alias browser: browser
    property var initialUrls: []

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        openInitialTabs: false

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

        // An action of your own; give it keys here or in `bindings`.
        // BrowserAction {
        //     registry: browser.actions
        //     name: "app.copyTitle"; text: "Copy page title"
        //     defaultShortcuts: ["Ctrl+Shift+C"]
        //     onTriggered: Cef.copyToClipboard(browser.title)
        // }
    }

    // Under HotReload (dev.qml), keep the open tabs across reloads.
    readonly property var hot: typeof hotReload !== "undefined" ? hotReload : null
    Connections {
        target: app.hot
        function onAboutToReload() {
            app.hot.state = { urls: browser.tabs.urls(), current: browser.tabs.currentIndex }
        }
    }

    Component.onCompleted: {
        const saved = hot && hot.state.urls ? hot.state : null
        if (saved && saved.urls.length > 0) browser.tabs.restore(saved.urls, saved.current)
        else if (initialUrls.length > 0) browser.tabs.restore(initialUrls, 0)
        else browser.tabs.openTab(browser.homeUrl)
        browser.forceActiveFocus()
    }
}
