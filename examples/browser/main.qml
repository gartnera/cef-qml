// Standalone reference browser:
//   QML_IMPORT_PATH=<builddir or install qml dir> qml examples/browser/main.qml [urls...]
import QtQuick
import QtQuick.Window
import CefQml.Components

Window {
    width: 1280
    height: 820
    visible: true
    color: Style.background
    title: (app.browser.title ? app.browser.title + " — " : "") + "CefQml Browser"

    // Off by default; QT_LOGGING_RULES="cefqml.browser.info=true" lets external
    // tooling (tests/cdp_remote.py) observe the window without a compositor.
    LoggingCategory {
        id: log
        name: "cefqml.browser"
        defaultLogLevel: LoggingCategory.Warning
    }
    // Deferred: the category is not usable before the component completes.
    onTitleChanged: Qt.callLater(logTitle)
    function logTitle() { console.info(log, "window title:", title) }

    BrowserApp {
        id: app
        anchors.fill: parent
        // Any command line argument that looks like an address opens a tab.
        initialUrls: Qt.application.arguments.slice(1).filter(a => !a.endsWith(".qml") && !a.startsWith("-"))
    }
}
