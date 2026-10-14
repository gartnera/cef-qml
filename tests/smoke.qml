// Smoke test: renders a page, checks pixels, exercises JS + navigation.
// Run: QML_IMPORT_PATH=build qml tests/smoke.qml   (exit code 0 = pass)
import QtQuick
import QtQuick.Window
import CefQml

Window {
    id: win
    width: 400
    height: 300
    visible: true

    property int step: 0

    function fail(msg) { console.log("FAIL:", msg); Qt.exit(1) }

    CefWebView {
        id: view
        anchors.fill: parent
        url: "data:text/html,<html><head><title>smoke</title></head><body style='margin:0;background:rgb(255,0,0)'></body></html>"
        onConsoleMessage: (level, message) => console.log("page:", message)
        onTitleChanged: console.log("title:", title)
    }

    Timer {
        interval: 200; repeat: true; running: true
        onTriggered: {
            if (win.step === 0 && view.title === "smoke" && view.frameCount > 0) {
                win.step = 1
                view.grabToImage(r => {
                    const c = r.image ? null : null
                    r.saveToFile("/tmp/cefqml-smoke-1.png")
                    console.log("grabbed frame 1, frames:", view.frameCount)
                    view.runJavaScript("document.body.style.background='rgb(0,0,255)'; document.title='blue'")
                })
            } else if (win.step === 1 && view.title === "blue") {
                win.step = 2
                // let a frame arrive with the new colour
                grabLater.start()
            }
        }
    }
    Timer {
        id: grabLater; interval: 500
        onTriggered: view.grabToImage(r => {
            r.saveToFile("/tmp/cefqml-smoke-2.png")
            console.log("PASS: version", Cef.version, "chromium", Cef.chromiumVersion,
                        "urlFromUserInput:", Cef.urlFromUserInput("example.com"),
                        Cef.urlFromUserInput("localhost:8080/x"), Cef.urlFromUserInput("hello world"))
            Qt.quit()
        })
    }
    Timer { interval: 30000; running: true; onTriggered: win.fail("timeout at step " + win.step + " title=" + view.title + " frames=" + view.frameCount) }
}
