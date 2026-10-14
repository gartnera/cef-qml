// Renders the reference browser and saves screenshots (used for docs/).
//   SHOT_DIR=out SHOT_URLS="https://a,https://b" qml scripts/screenshot.qml
// Each step: open/select a tab, wait for it to load, save <n>-<name>.png.
import QtQuick
import QtQuick.Window
import CefQml
import CefQml.Components

Window {
    id: win
    width: 1280
    height: 800
    visible: true
    color: Style.background
    title: browser.title

    readonly property string outDir: Qt.application.arguments.length > 0 && typeof SHOT_DIR !== "undefined" ? SHOT_DIR : ""
    property var urls: []
    property int step: 0

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        openInitialTabs: false
    }

    function env(name, fallback) {
        const v = Qt.application.arguments.find(a => a.startsWith("--" + name + "="))
        return v ? v.substring(name.length + 3) : fallback
    }

    function shot(name, then) {
        win.contentItem.grabToImage(r => {
            const path = env("out", "/tmp") + "/" + name + ".png"
            r.saveToFile(path)
            console.log("saved", path)
            then()
        })
    }

    function waitLoaded(view, minMs, then) {
        let elapsed = 0
        const t = Qt.createQmlObject("import QtQuick; Timer { interval: 250; repeat: true }", win)
        t.triggered.connect(() => {
            elapsed += 250
            if ((!view.loading && elapsed >= minMs) || elapsed > 20000) { t.destroy(); then() }
        })
        t.start()
    }

    Component.onCompleted: {
        const sites = env("urls", "https://en.wikipedia.org/wiki/Chromium_Embedded_Framework,https://github.com/chromiumembedded/cef,https://www.qt.io").split(",")
        const steps = []
        // 1: new tab page
        steps.push(next => { browser.tabs.openTab(browser.homeUrl); waitLoaded(browser.currentView, 1500, () => shot("1-new-tab", next)) })
        // 2..: sites, each in its own tab
        sites.forEach((u, i) => steps.push(next => {
            browser.tabs.openTab(u)
            waitLoaded(browser.currentView, 2500, () => shot((i + 2) + "-site", next))
        }))
        // find bar on the first site
        steps.push(next => {
            browser.tabs.currentIndex = 1
            browser.findBar.open()
            browser.findBar.text = "Chromium"
            waitLoaded(browser.currentView, 1500, () => shot((sites.length + 2) + "-find", next))
        })
        // a JavaScript dialog
        steps.push(next => {
            browser.findBar.close()
            browser.currentView.runJavaScript("setTimeout(() => confirm('Leave a star on the CefQml repository?'), 10)")
            waitLoaded(browser.currentView, 1200, () => shot((sites.length + 3) + "-dialog", next))
        })
        steps.push(() => Qt.quit())
        const run = i => steps[i](() => run(i + 1))
        run(0)
    }
}
