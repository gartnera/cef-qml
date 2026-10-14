// HotReload: edits files on disk and checks the content reloads, state
// survives, errors recover, and CefWebView keeps working across reloads.
// Needs QML_XHR_ALLOW_FILE_WRITE=1 (set by tests/run.sh).
import QtQuick
import QtTest
import CefQml

Item {
    id: root
    width: 400
    height: 300

    readonly property string dir: Cef.runtimeDir + "/../test-hotreload"

    // Writes a file and returns once the write completed (file XHR is
    // asynchronous even when asked to be synchronous).
    function write(name, text) {
        const xhr = new XMLHttpRequest()
        xhr.open("PUT", "file://" + dir + "/" + name)
        xhr.send(text)
        test.tryVerify(() => xhr.readyState === XMLHttpRequest.DONE, 5000, "writing " + name)
    }
    function app(tag, title) {
        return `import QtQuick
import CefQml
Item {
    objectName: "${tag}"
    property alias view: v
    property alias child: c
    Child { id: c }
    CefWebView { id: v; anchors.fill: parent; url: "data:text/html,<title>${title}</title>" }
    function reloadFromInside() { hotReload.reload() }
}
`
    }
    function child(tag) { return `import QtQuick\nItem { objectName: "${tag}" }\n` }

    Loader { id: loader; anchors.fill: parent; active: false
        sourceComponent: HotReload { delay: 50; source: "file://" + root.dir + "/App.qml" } }
    SignalSpy { id: failedSpy; target: loader.item; signalName: "failed" }

    TestCase {
        id: test
        name: "HotReload"
        when: windowShown
        property var hot: loader.item

        function initTestCase() {
            root.write("Child.qml", root.child("child-a"))
            root.write("App.qml", root.app("v1", "one"))
            loader.active = true
            tryVerify(() => hot && hot.generation === 1, 5000)
        }

        function test_1_initial_load() {
            compare(hot.item.objectName, "v1")
            compare(hot.item.width, root.width)
            compare(hot.item.child.objectName, "child-a")
            tryCompare(hot.item.view, "title", "one", 15000)
        }

        function test_2_edit_reloads_and_keeps_state() {
            hot.state = { tabs: ["a", "b"] }
            wait(100)
            root.write("App.qml", root.app("v2", "two"))
            tryCompare(hot, "generation", 2, 5000)
            compare(hot.item.objectName, "v2")
            compare(hot.state.tabs.length, 2)
            tryCompare(hot.item.view, "title", "two", 15000)  // a new browser works
        }

        function test_3_sibling_type_edit() {
            wait(100)
            root.write("Child.qml", root.child("child-b"))
            tryCompare(hot, "generation", 3, 5000)
            compare(hot.item.child.objectName, "child-b")
        }

        function test_4_error_then_recover() {
            failedSpy.clear()
            wait(100)
            root.write("App.qml", "import QtQuick\nItem { this is not qml")
            tryVerify(() => failedSpy.count > 0, 5000)
            verify(hot.errorString.length > 0)
            compare(hot.generation, 3)
            wait(100)
            root.write("App.qml", root.app("v3", "three"))
            tryCompare(hot, "generation", 4, 5000)
            compare(hot.errorString, "")
            tryCompare(hot.item.view, "title", "three", 15000)
        }

        function test_5_reload_from_inside() {
            hot.item.reloadFromInside()
            tryCompare(hot, "generation", 5, 5000)
            compare(hot.item.objectName, "v3")
        }
    }
}
