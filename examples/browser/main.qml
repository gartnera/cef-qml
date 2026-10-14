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
    title: (browser.title ? browser.title + " — " : "") + "CefQml Browser"

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        // Any command line argument that looks like an address opens a tab.
        initialUrls: Qt.application.arguments.slice(1).filter(a => !a.endsWith(".qml") && !a.startsWith("-"))
    }
}
