// Integration tests for CefWebView. Run through tests/run.sh (meson test).
import QtQuick
import QtTest
import CefQml

Item {
    id: root
    width: 400
    height: 300

    readonly property string page: "data:text/html," + encodeURIComponent(`
<html><head><title>ready</title><style>
  body { margin: 0; background: rgb(255,0,0); height: 3000px }
  input { position: absolute; left: 0; top: 0; width: 200px; height: 40px; border: 0; padding: 0 }
  a { position: absolute; left: 0; top: 100px; width: 200px; height: 40px; display: block; background: rgb(0,255,0) }
</style></head><body>
<input id="i" oninput="document.title = 'typed:' + this.value"
       onkeydown="if (event.key === 'Enter') document.title = 'enter:' + this.value">
<a id="l" href="https://example.invalid/popup" target="_blank">link</a>
<script>
  addEventListener('scroll', () => document.title = 'scrolled:' + (scrollY > 0));
  addEventListener('mousedown', e => { if (e.button === 1) document.title = 'middle' });
</script>
</body></html>`)

    readonly property string page2: "data:text/html,<title>page2</title><body style='margin:0;background:rgb(0,0,255)'>"

    CefWebView {
        id: view
        anchors.fill: parent
        url: root.page
    }

    SignalSpy { id: newWindowSpy; target: view; signalName: "newWindowRequested" }
    SignalSpy { id: contextMenuSpy; target: view; signalName: "contextMenuRequested" }
    SignalSpy { id: loadFinishedSpy; target: view; signalName: "loadFinished" }

    TestCase {
        name: "CefWebView"
        when: windowShown

        function colorAt(x, y) {
            const img = grabImage(view)
            return img.pixel(x, y)
        }

        function initTestCase() {
            tryCompare(view, "ready", true, 20000)
            tryCompare(view, "title", "ready", 20000)
            tryVerify(() => view.frameCount > 0, 10000)
        }

        function test_01_renders() {
            tryVerify(() => Qt.colorEqual(colorAt(300, 250), "#ff0000"), 5000,
                      "page background should be red")
            tryVerify(() => Qt.colorEqual(colorAt(100, 120), "#00ff00"), 5000,
                      "link box should be green")
            verify(!view.loading)
            compare(view.loadProgress, 1)
        }

        function test_02_typing() {
            view.forceActiveFocus()
            mouseClick(view, 100, 20)
            keyClick(Qt.Key_A)
            keyClick("B")
            keyClick(Qt.Key_C)
            tryCompare(view, "title", "typed:aBc", 5000)
            keyClick(Qt.Key_Backspace)
            tryCompare(view, "title", "typed:aB", 5000)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_X)
            tryCompare(view, "title", "typed:axB", 5000)
            keyClick(Qt.Key_A, Qt.ControlModifier)   // select all
            keyClick(Qt.Key_Z)
            tryCompare(view, "title", "typed:z", 5000)
            keyClick(Qt.Key_Return)
            tryCompare(view, "title", "enter:z", 5000)
        }

        function test_03_newWindowRequested() {
            newWindowSpy.clear()
            mouseClick(view, 100, 120)
            tryCompare(newWindowSpy, "count", 1, 5000)
            compare(newWindowSpy.signalArguments[0][0].toString(), "https://example.invalid/popup")
            compare(newWindowSpy.signalArguments[0][1], true)  // user gesture
            compare(view.title, "enter:z", "view must not navigate")
        }

        function test_04_middleClick() {
            mouseClick(view, 300, 250, Qt.MiddleButton)
            tryCompare(view, "title", "middle", 5000)
        }

        function test_05_contextMenu() {
            contextMenuSpy.clear()
            mouseClick(view, 100, 120, Qt.RightButton)
            tryCompare(contextMenuSpy, "count", 1, 5000)
            compare(contextMenuSpy.signalArguments[0][2].toString(), "https://example.invalid/popup")
        }

        function test_06_wheel() {
            mouseWheel(view, 300, 250, 0, -120)
            tryCompare(view, "title", "scrolled:true", 5000)
        }

        function test_07_zoom() {
            view.zoomFactor = 2.0
            view.runJavaScript("setTimeout(() => document.title = 'dpr:' + devicePixelRatio, 300)")
            tryCompare(view, "title", "dpr:2", 5000)
            view.zoomFactor = 1.0
        }

        function test_08_navigation() {
            verify(!view.canGoBack)
            view.url = root.page2
            tryCompare(view, "title", "page2", 10000)
            tryCompare(view, "canGoBack", true, 5000)
            verify(!view.canGoForward)
            tryVerify(() => Qt.colorEqual(colorAt(200, 150), "#0000ff"), 5000)
            view.goBack()
            // Restored from the back-forward cache: the page keeps whatever
            // title earlier tests set, so check the content instead.
            tryVerify(() => view.title !== "page2", 10000)
            tryVerify(() => Qt.colorEqual(colorAt(300, 250), "#ff0000"), 5000)
            tryCompare(view, "canGoForward", true, 5000)
            verify(view.url.toString().startsWith("data:text/html"))
            view.goForward()
            tryCompare(view, "title", "page2", 10000)
        }

        function test_09_loadHtml() {
            loadFinishedSpy.clear()
            view.loadHtml("<title>html</title><body style='background:#00ff00'>")
            tryCompare(view, "title", "html", 10000)
            tryVerify(() => loadFinishedSpy.count > 0, 5000)
            tryVerify(() => Qt.colorEqual(colorAt(200, 150), "#00ff00"), 5000)
        }

        function test_10_select_popup() {
            view.loadHtml(`<title>sel</title><body style="margin:0">
              <select id=s style="position:absolute;left:0;top:0;width:150px;height:30px"
                      onchange="document.title='sel:'+this.value">
                <option>one</option><option>two</option><option>three</option></select>`)
            tryCompare(view, "title", "sel", 10000)
            wait(300)
            mouseClick(view, 50, 15)
            // The <select> dropdown is rendered as a separate CEF popup below
            // the control; pick the third option with the keyboard.
            wait(500)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(view, "title", "sel:three", 5000)
        }

        function test_11_resize() {
            const before = view.frameCount
            root.width = 300
            tryVerify(() => view.frameCount > before, 5000)
            tryVerify(() => grabImage(view).width === 300, 5000)
            root.width = 400
        }

        function test_12_urlFromUserInput() {
            compare(Cef.urlFromUserInput("example.com").toString(), "https://example.com")
            compare(Cef.urlFromUserInput("localhost:8080/x").toString(), "http://localhost:8080/x")
            compare(Cef.urlFromUserInput("about:blank").toString(), "about:blank")
            compare(Cef.urlFromUserInput("/tmp/a b.html").toString(), "file:///tmp/a b.html")
            verify(!Cef.urlFromUserInput("what is qml").toString())
            verify(Cef.version.length > 0)
        }
    }
}
