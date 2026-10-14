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
    SignalSpy { id: findSpy; target: view; signalName: "findResult" }
    TextInput { id: clipProbe; visible: false }
    SignalSpy { id: devToolsEventSpy; target: view; signalName: "devToolsEvent" }

    // A second view created with user scripts, to check they apply to the
    // very first navigation.
    Component {
        id: scriptedView
        CefWebView {
            width: 100; height: 100
            userScripts: ["window.injected = 'yes'; document.addEventListener('DOMContentLoaded', () => document.title = 'injected:' + window.injected)"]
            url: "data:text/html,<title>original</title>"
        }
    }

    // Answers JavaScript dialogs according to `dialogAnswer` while enabled.
    property bool handleDialogs: false
    property var dialogAnswer: null
    property var lastDialog: null
    Connections {
        target: root.handleDialogs ? view : null
        function onJavaScriptDialogRequested(dialog) {
            root.lastDialog = { type: dialog.type, message: dialog.message, defaultText: dialog.defaultText }
            if (root.dialogAnswer === null) dialog.reject()
            else dialog.accept(root.dialogAnswer)
        }
        function onFileDialogRequested(request) {
            root.lastDialog = { mode: request.mode, filters: Array.from(request.acceptFilters) }
            request.accept(["/etc/hostname"])
        }
        function onDownloadRequested(download) {
            download.accept(root.downloadDir)
        }
    }
    property string downloadDir: ""

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

        function test_13_dialogs_unhandled() {
            root.handleDialogs = false
            view.loadHtml("<title>d</title><script>setTimeout(() => document.title = 'c:' + confirm('q'), 100)</script>")
            tryCompare(view, "title", "c:false", 10000)
        }

        function test_14_dialogs_handled() {
            root.handleDialogs = true
            root.dialogAnswer = "hello"
            view.loadHtml("<title>d</title><script>setTimeout(() => document.title = 'p:' + prompt('name?', 'def'), 100)</script>")
            tryCompare(view, "title", "p:hello", 10000)
            compare(root.lastDialog.type, CefJavaScriptDialog.Prompt)
            compare(root.lastDialog.message, "name?")
            compare(root.lastDialog.defaultText, "def")

            root.dialogAnswer = null
            view.loadHtml("<title>d</title><script>setTimeout(() => document.title = 'c:' + confirm('sure?'), 100)</script>")
            tryCompare(view, "title", "c:false", 10000)
            compare(root.lastDialog.type, CefJavaScriptDialog.Confirm)

            root.dialogAnswer = ""
            view.loadHtml("<title>d</title><script>setTimeout(() => { alert('hi'); document.title = 'alerted' }, 100)</script>")
            tryCompare(view, "title", "alerted", 10000)
            compare(root.lastDialog.type, CefJavaScriptDialog.Alert)
        }

        function test_15_find() {
            view.loadHtml("<title>f</title><p>apple banana apple cherry apple</p>")
            tryCompare(view, "title", "f", 10000)
            // The title arrives before the load finishes; a find started
            // while the navigation is still settling can end with 0 matches.
            tryCompare(view, "loading", false, 10000)
            findSpy.clear()
            const lastFinal = () => {
                for (let i = findSpy.count - 1; i >= 0; --i)
                    if (findSpy.signalArguments[i][2]) return findSpy.signalArguments[i]
                return null
            }
            view.find("apple")
            tryVerify(() => lastFinal() !== null, 5000)
            compare(lastFinal()[0], 3)
            // Repeating the same text moves to the next match.
            findSpy.clear()
            view.find("apple")
            view.find("apple")
            tryVerify(() => lastFinal() !== null && lastFinal()[1] === 2, 5000)
            findSpy.clear()
            view.find("apple", false)
            tryVerify(() => lastFinal() !== null && lastFinal()[1] === 1, 5000)
            view.stopFinding()
        }

        function test_16_file_dialog() {
            root.handleDialogs = true
            view.loadHtml(`<title>file</title><body style="margin:0">
              <input type=file accept=".txt" style="position:absolute;left:0;top:0;width:200px;height:40px"
                     onchange="document.title = 'file:' + this.files[0].name">`)
            tryCompare(view, "title", "file", 10000)
            wait(200)
            mouseClick(view, 50, 20)
            tryCompare(view, "title", "file:hostname", 10000)
            compare(root.lastDialog.mode, CefFileDialogRequest.Open)
            compare(root.lastDialog.filters.length, 1)
            compare(root.lastDialog.filters[0], ".txt")
        }

        function test_17_download() {
            root.handleDialogs = true
            root.downloadDir = Cef.environment("CEF_QML_TEST_DIR") + "/test-downloads/"
            const before = Cef.downloads.length
            view.loadHtml(`<title>dl</title><body style="margin:0">
              <a download="hello.txt" href="data:text/plain,hello%20world"
                 style="position:absolute;left:0;top:0;width:200px;height:40px;display:block">dl</a>`)
            tryCompare(view, "title", "dl", 10000)
            wait(200)
            mouseClick(view, 50, 20)
            tryVerify(() => Cef.downloads.length === before + 1, 10000)
            const d = Cef.downloads[Cef.downloads.length - 1]
            tryCompare(d, "state", CefDownload.Complete, 10000)
            compare(d.suggestedFileName, "hello.txt")
            compare(d.receivedBytes, 11)
            verify(d.path.endsWith("/hello.txt") || d.path.indexOf("hello (") >= 0, d.path)
            compare(d.progress, 1)
            d.remove()
            tryVerify(() => Cef.downloads.length === before, 5000)
            root.handleDialogs = false
        }

        // evaluateJavaScript() wrapper returning [result, error] once done.
        function evaluate(target, script) {
            let out = null
            target.evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, "evaluate: " + script)
            return out
        }

        function test_18_evaluateJavaScript() {
            view.loadHtml("<title>eval</title><div id=x data-n=41>hi</div>")
            tryCompare(view, "title", "eval", 10000)
            compare(evaluate(view, "1 + 2")[0], 3)
            compare(evaluate(view, "document.getElementById('x').textContent")[0], "hi")
            const obj = evaluate(view, "({a: [1, 2], b: {c: 'd'}, n: null})")[0]
            compare(obj.a.length, 2)
            compare(obj.b.c, "d")
            compare(obj.n, null)
            compare(evaluate(view, "new Promise(r => setTimeout(() => r('later'), 50))")[0], "later")
            const err = evaluate(view, "throw new Error('boom')")
            compare(err[0], undefined)
            verify(err[1].indexOf("boom") >= 0, err[1])
            compare(evaluate(view, "undefined")[0], undefined)
            // Mutations are visible to the page.
            evaluate(view, "document.title = 'changed'")
            tryCompare(view, "title", "changed", 5000)
        }

        function test_19_devToolsMethod() {
            let shot = null
            view.devToolsMethod("Page.captureScreenshot", { format: "png" }, (r, e) => shot = [r, e])
            tryVerify(() => shot !== null, 10000)
            compare(shot[1], undefined)
            verify(shot[0].data.length > 100, "base64 png expected")

            let bad = null
            view.devToolsMethod("No.suchMethod", {}, (r, e) => bad = [r, e])
            tryVerify(() => bad !== null, 10000)
            verify(bad[1].length > 0)

            devToolsEventSpy.clear()
            let enabled = false
            view.devToolsMethod("Runtime.enable", {}, () => enabled = true)
            tryVerify(() => enabled, 5000)
            view.runJavaScript("console.log('via-cdp')")
            tryVerify(() => {
                for (let i = 0; i < devToolsEventSpy.count; ++i) {
                    const [method, params] = devToolsEventSpy.signalArguments[i]
                    if (method === "Runtime.consoleAPICalled" && params.args[0].value === "via-cdp")
                        return true
                }
                return false
            }, 5000)
            view.devToolsMethod("Runtime.disable")
        }

        function test_20_userScripts() {
            const v = createTemporaryObject(scriptedView, root)
            tryCompare(v, "title", "injected:yes", 15000)
            // Changing the scripts applies to the next document.
            v.userScripts = ["document.addEventListener('DOMContentLoaded', () => document.title = 'second')"]
            v.reload()
            tryCompare(v, "title", "second", 10000)
        }

        function test_22_destroyed_before_browser_exists() {
            // Browser creation is asynchronous; a view destroyed in the same
            // event-loop turn (e.g. a HotReload reload) must close the
            // browser once CEF has created it, without crashing.
            for (let i = 0; i < 3; ++i)
                scriptedView.createObject(root).destroy()
            wait(1500)  // let CEF create and close them
            const v = createTemporaryObject(scriptedView, root)
            tryCompare(v, "title", "injected:yes", 15000)
        }

        function test_21_clipboard_bridge() {
            if (Qt.platform.pluginName !== "offscreen")
                skip("needs a usable system clipboard (headless compositors have no seat focus)")
            view.loadHtml("<title>clip</title><input id=a value='from-page'><textarea id=b></textarea>")
            tryCompare(view, "title", "clip", 10000)
            view.forceActiveFocus()
            evaluate(view, "a.focus(); a.select(); 1")
            keyClick(Qt.Key_C, Qt.ControlModifier)
            tryVerify(() => { clipProbe.text = ""; clipProbe.paste(); return clipProbe.text === "from-page" }, 5000)
            // A page writing via the async clipboard API is mirrored too.
            Cef.copyToClipboard("")
            evaluate(view, "document.execCommand('copy'); 1")  // keeps the user-activation path warm
            Cef.copyToClipboard("from-qt")
            evaluate(view, "b.focus(); 1")
            view.forceActiveFocus()
            keyClick(Qt.Key_V, Qt.ControlModifier)
            tryCompare(evaluate(view, "new Promise(r => setTimeout(() => r(b.value), 100))"), 0, "from-qt")
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
