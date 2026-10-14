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
