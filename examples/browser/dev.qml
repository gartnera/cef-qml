// Live-editing entry point: edit BrowserApp.qml (or any QML next to it) and
// save; the UI reloads in place and keeps its tabs.
//   QML_IMPORT_PATH=<builddir> qml examples/browser/dev.qml
// To also live-edit the shared components, watch their directory:
//   CEFQML_COMPONENTS=$PWD/CefQml/Components qml examples/browser/dev.qml
import QtQuick
import QtQuick.Window
import CefQml
import CefQml.Components

Window {
    width: 1280
    height: 820
    visible: true
    color: Style.background
    title: (hot.item && hot.item.browser ? hot.item.browser.title + " — " : "") + "CefQml Browser (live reload #" + hot.generation + ")"

    HotReload {
        id: hot
        anchors.fill: parent
        source: "BrowserApp.qml"
        watchPaths: Cef.environment("CEFQML_COMPONENTS") ? [Cef.environment("CEFQML_COMPONENTS")] : []
    }
}
