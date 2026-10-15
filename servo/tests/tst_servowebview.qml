import QtQuick
import QtTest
import ServoQml

// ServoWebView (ServoQml module, -Dservo=enabled). Run by the "servo" meson
// test: tests/run.sh with TEST_INPUT pointing here.
Item {
    id: root
    width: 800; height: 600

    ServoWebView {
        id: view
        anchors.fill: parent
        focus: true
    }

    SignalSpy { id: newWindowSpy; target: view; signalName: "newWindowRequested" }
    SignalSpy { id: consoleSpy; target: view; signalName: "consoleMessage" }
    SignalSpy { id: loadSpy; target: view; signalName: "loadFinished" }

    TestCase {
        name: "ServoWebView"
        when: windowShown

        // Loads `html` and waits until the page has loaded and painted.
        function load(html) {
            const frames = view.frameCount
            loadSpy.clear()
            view.loadHtml(html)
            tryVerify(() => loadSpy.count > 0, 30000, "load finished")
            tryVerify(() => view.frameCount > frames, 10000, "painted")
        }

        // Synchronous evaluateJavaScript.
        function js(script) {
            let done = false, result, error
            view.evaluateJavaScript(script, (r, e) => { result = r; error = e; done = true })
            tryVerify(() => done, 10000, "evaluated: " + script)
            if (error !== undefined)
                fail("JavaScript error: " + error)
            return result
        }

        function test_01_load() {
            tryCompare(view, "ready", true, 20000)
            load("<title>First</title><body style='margin:0;background:#00ff00'>"
                 + "<script>console.log('hello', 6 * 7)</script>")
            compare(view.title, "First")
            verify(view.url.toString().startsWith("data:text/html"))
            compare(view.loadProgress, 1)
            compare(view.engine, "servo")
            verify(consoleSpy.signalArguments.some(a => a[1] === "hello 42"))
            tryVerify(() => Qt.colorEqual(grabImage(view).pixel(400, 300), "#00ff00"), 10000,
                      "page painted")
        }

        function test_02_javascript() {
            compare(js("1 + 2"), 3)
            compare(js("'a' + 'b'"), "ab")
            compare(js("null"), null)
            compare(js("[1, 'x', false]"), [1, "x", false])
            compare(js("({n: 1, nested: {s: 'v'}})"), {n: 1, nested: {s: "v"}})
            compare(js("document.title"), "First")
            compare(js("document.body"), "[object Element]")

            let done = false, result, error
            view.evaluateJavaScript("throw new Error('boom')", (r, e) => { result = r; error = e; done = true })
            tryVerify(() => done, 10000)
            compare(result, undefined)
            verify(String(error).length > 0, "error reported")
        }

        function test_03_click() {
            load("<title>click</title><body style='margin:0'>"
                 + "<button id=b style='position:absolute;left:100px;top:100px;width:200px;height:100px'"
                 + " onclick=\"document.title = 'clicked ' + event.button\">Click</button>")
            view.sendMouseClick(200, 150)
            tryCompare(view, "title", "clicked 0", 10000)
        }

        function test_04_typing() {
            load("<title>typing</title><body style='margin:0'>"
                 + "<input id=i style='position:absolute;left:0;top:0;width:400px;height:50px'"
                 + " onkeydown=\"if (event.key === 'Enter') document.title = 'enter:' + this.value\">")
            view.sendMouseClick(100, 25)
            tryVerify(() => js("document.activeElement.id") === "i", 10000, "input focused")
            view.sendKey(Qt.Key_H, Qt.ShiftModifier, "H")
            view.sendKey(Qt.Key_I, 0, "i")
            view.sendKey(Qt.Key_Space, 0, " ")
            view.sendKey(Qt.Key_1, 0, "1")
            view.sendKey(Qt.Key_Backspace)
            view.sendKey(Qt.Key_Exclam, Qt.ShiftModifier, "!")
            view.sendKey(Qt.Key_Return)
            tryCompare(view, "title", "enter:Hi !", 10000)
        }

        function test_05_wheel() {
            load("<title>scroll</title><body style='margin:0'><div style='height:5000px'></div>")
            compare(js("window.scrollY"), 0)
            // Qt convention: a negative angle delta scrolls down.
            view.sendMouseWheel(400, 300, 0, -360)
            tryVerify(() => js("window.scrollY") > 0, 10000, "scrolled down")
            const down = js("window.scrollY")
            view.sendMouseWheel(400, 300, 0, 120)
            tryVerify(() => js("window.scrollY") < down, 10000, "scrolled back up")
        }

        function test_06_hover() {
            load("<title>hover</title><body style='margin:0'>"
                 + "<a href='https://example.org/hovered' style='display:block;width:300px;height:100px'>link</a>")
            view.sendMouseMove(50, 50)
            tryVerify(() => view.hoveredUrl.indexOf("example.org/hovered") >= 0, 10000,
                      "hoveredUrl: " + view.hoveredUrl)
            view.sendMouseMove(600, 500)
            tryCompare(view, "hoveredUrl", "", 10000)
        }

        function test_07_new_window() {
            load("<title>popup</title><body style='margin:0'>"
                 + "<a target=_blank href='https://example.org/popup' style='display:block;width:300px;height:100px'>open</a>")
            newWindowSpy.clear()
            view.sendMouseClick(50, 50)
            tryCompare(newWindowSpy, "count", 1, 10000)
            compare(newWindowSpy.signalArguments[0][0], "https://example.org/popup")
            // The page did not navigate.
            compare(view.title, "popup")
        }

        function test_08_history() {
            load("<title>A</title>")
            load("<title>B</title>")
            tryCompare(view, "canGoBack", true, 10000)
            compare(view.canGoForward, false)
            view.goBack()
            tryCompare(view, "title", "A", 10000)
            tryCompare(view, "canGoForward", true, 10000)
            view.goForward()
            tryCompare(view, "title", "B", 10000)
        }

        function test_09_zoom() {
            load("<title>zoom</title>")
            compare(js("window.innerWidth"), 800)
            view.zoomFactor = 2
            tryVerify(() => js("window.innerWidth") === 400, 10000, "zoomed")
            view.zoomFactor = 1
            tryVerify(() => js("window.innerWidth") === 800, 10000, "unzoomed")
        }

        function test_10_resize() {
            view.anchors.fill = undefined
            view.width = 500
            view.height = 400
            tryVerify(() => js("window.innerWidth") === 500, 10000, "resized")
            compare(js("window.innerHeight"), 400)
            view.anchors.fill = root
            tryVerify(() => js("window.innerWidth") === 800, 10000, "restored")
        }
    }
}
