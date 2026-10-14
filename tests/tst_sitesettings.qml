// Per-site settings: the SiteSettings store and SiteSettingsModel, their
// enforcement by WebTabs (remembered permissions, per-site zoom,
// JavaScript and pop-ups), RequestOverlay's "Remember this decision", the
// SiteInfo card, SiteSettingsManager and the Browser wiring.
//
// Pages come from the local HTTP server of tests/run.sh (TEST_HTTP_ORIGIN,
// http://127.0.0.1:<port>; http://localhost:<port> is a second origin):
// data: URLs have opaque origins. Without it the browser suites skip.
// getUserMedia() needs --use-fake-device-for-media-stream (run.sh sets it in
// CEF_QML_FLAGS); --use-fake-ui-for-media-stream must not be set, since it
// would grant media requests before CefQml sees them.
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 1100
    height: 750

    readonly property string origin: Cef.environment("TEST_HTTP_ORIGIN")
    readonly property string alt: origin.replace("127.0.0.1", "localhost")
    property int serial: 0

    // A page of the test server titled `title` (made unique) with `body`.
    function page(o, title, body) {
        ++serial
        return o + "/p" + serial + "?html=" + encodeURIComponent("<title>" + title + "</title>" + (body || ""))
    }

    // --- Store ---------------------------------------------------------------

    // Lookups only: nothing is pushed into Chromium.
    SiteSettings {
        id: store
        path: "test-sitesettings/store.json"
        saveDelay: 20
        contentSettings: false
    }
    SiteSettingsModel { id: filtered; store: store }
    SignalSpy { id: changedSpy; target: store; signalName: "changed" }

    TestCase {
        name: "SiteSettingsStore"

        function init() {
            store.clear()
            compare(store.count, 0)
            changedSpy.clear()
        }

        function test_01_scopes() {
            compare(store.originOf("https://Example.com:443/a?b#c"), "https://example.com")
            compare(store.originOf("http://a.test:8080/x"), "http://a.test:8080")
            compare(store.originOf("http://a.test:80/"), "http://a.test")
            compare(store.originOf("data:text/html,x"), "")
            compare(store.originOf("about:blank"), "")
            compare(store.originOf("file:///tmp/x.html"), "file://")
            compare(store.originOf(""), "")

            compare(store.normalizeScope("https://x.test/path?q"), "https://x.test")
            compare(store.normalizeScope("Example.COM."), "example.com")
            compare(store.normalizeScope("[*.]Example.COM"), "[*.]example.com")
            compare(store.normalizeScope("*"), "*")
            compare(store.normalizeScope("bücher.test"), "xn--bcher-kva.test")
            compare(store.normalizeScope("[*.]"), "")
            compare(store.normalizeScope("a b"), "")
            compare(store.normalizeScope("*.example.com"), "")
            compare(store.normalizeScope(""), "")
        }

        function test_02_crud() {
            const rev = store.revision
            verify(store.set("https://a.test/page", "camera", "allow"))
            compare(changedSpy.count, 1)
            compare(changedSpy.signalArguments[0][0], "https://a.test")
            compare(changedSpy.signalArguments[0][1], "camera")
            verify(store.revision > rev)
            compare(store.get("https://a.test", "camera"), "allow")
            compare(store.get("https://a.test:443/other", "camera"), "allow", "any URL of the origin")
            compare(store.get("http://a.test", "camera"), undefined, "another origin")
            verify(store.contains("https://a.test"))
            compare(store.count, 1)

            // The same value again: no change.
            verify(store.set("https://a.test", "camera", "allow"))
            compare(changedSpy.count, 1)

            verify(store.set("https://a.test", "zoom", 1.5))
            verify(store.set("https://a.test", "custom", { any: ["json"] }))
            compare(store.settings("https://a.test").zoom, 1.5)
            compare(store.settings("https://a.test").custom.any[0], "json")
            compare(store.origins(), ["https://a.test"])

            // Invalid values and scopes.
            ignoreWarning(/invalid value/)
            verify(!store.set("https://a.test", "camera", "maybe"))
            ignoreWarning(/invalid value/)
            verify(!store.set("https://a.test", "javascript", "ask"))
            ignoreWarning(/invalid zoom/)
            verify(!store.set("https://a.test", "zoom", 0))
            ignoreWarning(/invalid scope/)
            verify(!store.set("data:text/html,x", "camera", "allow"))
            compare(store.get("https://a.test", "camera"), "allow")
            // Zoom is clamped to 0.25 .. 5.
            verify(store.set("https://a.test", "zoom", 9))
            compare(store.get("https://a.test", "zoom"), 5)

            // Reset one key, undefined removes too, the last key removes the scope.
            verify(store.reset("https://a.test", "custom"))
            compare(store.get("https://a.test", "custom"), undefined)
            verify(store.set("https://a.test", "zoom", undefined))
            compare(Object.keys(store.settings("https://a.test")), ["camera"])
            changedSpy.clear()
            verify(store.reset("https://a.test", "camera"))
            verify(!store.contains("https://a.test"))
            compare(store.count, 0)
            compare(changedSpy.count, 1)

            // Reset a whole scope.
            store.set("b.test", "images", "block")
            store.set("b.test", "popups", "allow")
            changedSpy.clear()
            verify(store.reset("b.test"))
            compare(changedSpy.count, 1)
            compare(changedSpy.signalArguments[0][1], "", "key is empty for a whole scope")
            compare(store.count, 0)
        }

        function test_03_patterns_and_effective() {
            store.set("*", "zoom", 1.25)
            store.set("[*.]example.org", "javascript", "block")
            store.set("[*.]a.example.org", "javascript", "allow")
            store.set("example.org", "images", "block")
            store.set("https://example.org", "camera", "allow")
            store.set("https://example.org", "zoom", 0.8)

            compare(store.effective("https://x.example.org/", "javascript"), "block")
            compare(store.scopeFor("https://x.example.org/", "javascript"), "[*.]example.org")
            compare(store.effective("https://example.org/", "javascript"), "block", "the domain itself")
            compare(store.effective("https://y.a.example.org/", "javascript"), "allow", "the longest domain wins")
            compare(store.scopeFor("https://y.a.example.org/", "javascript"), "[*.]a.example.org")
            compare(store.effective("https://notexample.org/", "javascript"), "allow", "no partial label match")
            compare(store.scopeFor("https://notexample.org/", "javascript"), "")
            // Host scope: any scheme and port.
            compare(store.effective("http://example.org:8443/", "images"), "block")
            compare(store.effective("https://sub.example.org/", "images"), "allow")
            // Origin scope: only that scheme.
            compare(store.effective("https://example.org/x", "camera"), "allow")
            compare(store.effective("http://example.org/x", "camera"), "ask")
            // Per key: the origin stores zoom, the pattern still decides javascript.
            compare(store.effective("https://example.org/", "zoom"), 0.8)
            compare(store.effective("https://other.test/", "zoom"), 1.25, "the * default")
            compare(store.scopeFor("https://other.test/", "zoom"), "*")
            compare(store.effective("data:text/html,x", "zoom"), 1.25)

            // Built-in defaults.
            compare(store.effective("https://other.test/", "popups"), "block")
            compare(store.effective("https://other.test/", "images"), "allow")
            compare(store.effective("https://other.test/", "geolocation"), "ask")
            compare(store.effective("https://other.test/", "unknown"), undefined)
            compare(store.defaultValue("zoom"), 1)
            verify(store.isPermission("camera"))
            verify(store.isPermission("notifications"))
            verify(!store.isPermission("javascript"))
            verify(!store.isPermission("zoom"))

            // decide(): block wins, all allowed -> allow, else ask.
            compare(store.decide("https://example.org", ["camera"]), "allow")
            compare(store.decide("https://example.org", ["camera", "microphone"]), "ask")
            store.set("example.org", "microphone", "block")
            compare(store.decide("https://example.org", ["camera", "microphone"]), "block")
            compare(store.decide("https://example.org", []), "ask")
        }

        function test_04_model() {
            store.set("https://b.test", "zoom", 1.1)
            store.set("[*.]a.test", "javascript", "block")
            store.set("*", "popups", "allow")
            store.set("http://c.test:81", "camera", "block")
            compare(store.count, 4)
            compare(store.get(0).scope, "*", "the default first")
            compare(store.get(0).kind, "default")
            const scopes = [1, 2, 3].map(i => store.get(i).scope)
            compare(scopes, ["[*.]a.test", "https://b.test", "http://c.test:81"], "then by host")
            const b = store.get(2)
            compare(b.name, "b.test")
            compare(b.kind, "origin")
            compare(b.keys, ["zoom"])
            compare(b.settings.zoom, 1.1)
            compare(store.get(1).kind, "pattern")
            compare(store.get(1).name, "a.test")

            compare(filtered.count, 4)
            filtered.filterText = "c.test"
            compare(filtered.count, 1)
            compare(filtered.get(0).scope, "http://c.test:81")
            filtered.filterText = "JAVASCRIPT"
            compare(filtered.count, 1, "keys match too, case-insensitively")
            compare(filtered.get(0).scope, "[*.]a.test")
            filtered.filterText = "test zoom"
            compare(filtered.count, 1, "every word must match")
            filtered.filterText = "nothing"
            compare(filtered.count, 0)
            compare(filtered.get(0), undefined)
            filtered.filterText = ""
            compare(filtered.count, 4)
            store.reset("https://b.test")
            compare(filtered.count, 3)
        }

        function read(path) {
            const xhr = new XMLHttpRequest()
            xhr.open("GET", "file://" + path, false)
            xhr.send()
            return xhr.responseText
        }

        function test_05_persistence() {
            verify(store.filePath.endsWith("/test-sitesettings/store.json"), store.filePath)
            store.set("https://saved.test", "zoom", 1.5)
            store.set("[*.]saved.test", "geolocation", "block")
            // Saved after saveDelay.
            tryVerify(() => read(store.filePath).indexOf("saved.test") >= 0, 5000)
            const json = JSON.parse(read(store.filePath))
            compare(json.version, 1)
            compare(json.sites["https://saved.test"].zoom, 1.5)
            compare(json.sites["[*.]saved.test"].geolocation, "block")

            // A second store on the same file loads it.
            const other = Qt.createQmlObject(
                'import CefQml; SiteSettings { path: "test-sitesettings/store.json"; contentSettings: false }', root)
            verify(other.loaded)
            compare(other.count, 2)
            compare(other.effective("https://www.saved.test/", "geolocation"), "block")
            // ... changes it; reload() picks the change up.
            other.set("https://saved.test", "camera", "allow")
            verify(other.save())
            other.destroy()
            verify(store.reload())
            compare(store.get("https://saved.test", "camera"), "allow")
            compare(store.count, 2)

            // An in-memory store.
            const mem = Qt.createQmlObject('import CefQml; SiteSettings { path: ""; contentSettings: false }', root)
            compare(mem.filePath, "")
            verify(mem.set("https://m.test", "zoom", 2))
            verify(mem.save())
            mem.destroy()
        }

        function cleanupTestCase() {
            store.clear()
            store.save()
        }
    }

    // --- Enforcement in a custom layout -----------------------------------------

    // Pushes its content settings into Chromium.
    SiteSettings {
        id: live
        path: "test-sitesettings/live.json"
        saveDelay: 20
    }

    Item {
        id: custom
        anchors.fill: parent

        NavigationBar {
            id: nav
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            view: tabs.currentView
            siteSettings: live
        }
        WebTabs {
            id: tabs
            anchors.top: nav.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            siteSettings: live
        }
        RequestOverlay {
            id: overlay
            anchors.fill: tabs
            tabs: tabs
        }
    }
    SignalSpy { id: requestSpy; target: tabs; signalName: "permissionRequested" }
    SignalSpy { id: clearedSpy; target: nav.siteInfo; signalName: "siteDataCleared" }

    TestCase {
        id: enforce
        name: "SiteSettingsEnforcement"
        when: windowShown

        function initTestCase() {
            if (!root.origin) return
            tabs.openTab(root.page(root.origin, "start"))
            tryCompare(tabs.currentView, "title", "start", 10000)
        }
        function init() {
            if (!root.origin) skip("TEST_HTTP_ORIGIN is not set (run through tests/run.sh)")
            live.clear()
            tabs.zoomPolicy = "origin"
            while (tabs.count > 1) tabs.closeTab(tabs.count - 1)
            tabs.currentIndex = 0
            view().zoomFactor = 1
            nav.siteInfo.close()
            requestSpy.clear()
        }

        function view() { return tabs.currentView }
        function load(v, url, title) {
            v.url = url
            tryCompare(v, "title", title, 10000)
            tryVerify(() => !v.loading, 10000)
        }
        function evaluate(v, script) {
            let out = null
            v.evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, script)
            verify(!out[1], out[1])
            return out[0]
        }
        // Starts getUserMedia() for a camera; result() polls it.
        function startCamera(v) {
            evaluate(v, "window.gum = 'pending'; navigator.mediaDevices.getUserMedia({ video: true })"
                     + ".then(s => { s.getTracks().forEach(t => t.stop()); window.gum = 'ok' }, e => window.gum = e.name); 1")
        }
        function cameraResult(v) {
            let r = "pending"
            tryVerify(() => (r = evaluate(v, "window.gum")) !== "pending", 10000, "getUserMedia answered")
            return r
        }
        function permissionState(v, name) {
            return evaluate(v, "navigator.permissions.query({ name: '" + name + "' }).then(r => r.state)")
        }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item) {
            verify(item && item.visible, "clickable")
            const p = center(item)
            mouseClick(root, p.x, p.y)
        }
        function find(parent, name) {
            const item = findChild(parent, name)
            verify(item, "no child " + name)
            return item
        }

        function test_01_remembered_media_permission() {
            const o = live.originOf(root.origin)
            live.set(o, "camera", "allow")
            load(view(), root.page(root.origin, "cam allow"), "cam allow")
            startCamera(view())
            compare(cameraResult(view()), "ok")
            compare(requestSpy.count, 0, "answered without asking")
            verify(!overlay.visible)

            live.set(o, "camera", "block")
            load(view(), root.page(root.origin, "cam block"), "cam block")
            startCamera(view())
            compare(cameraResult(view()), "NotAllowedError")
            compare(requestSpy.count, 0)
            verify(!overlay.visible)

            // Another origin is not affected: it asks.
            load(view(), root.page(root.alt, "cam other"), "cam other")
            startCamera(view())
            tryVerify(() => overlay.visible, 10000, "the other origin asks")
            compare(requestSpy.count, 1)
            overlay.dismiss()
            compare(cameraResult(view()), "NotAllowedError")
            compare(live.get(root.alt, "camera"), undefined, "a dismissed card stores nothing")
        }

        function test_02_remember_checkbox() {
            const o = live.originOf(root.origin)
            load(view(), root.page(root.origin, "cam ask"), "cam ask")
            startCamera(view())
            tryVerify(() => overlay.visible, 10000)
            const box = find(overlay, "rememberCheckBox")
            verify(box.visible)
            verify(box.checked, "on by default")
            waitForRendering(overlay)
            click(find(overlay, "rejectButton"))
            compare(cameraResult(view()), "NotAllowedError")
            compare(live.get(o, "camera"), "block", "remembered for the origin")

            // Answered from the store from now on, also after a reload.
            requestSpy.clear()
            load(view(), root.page(root.origin, "cam again"), "cam again")
            startCamera(view())
            compare(cameraResult(view()), "NotAllowedError")
            compare(requestSpy.count, 0)

            // Unchecked: allowed once, nothing stored.
            live.reset(o)
            load(view(), root.page(root.origin, "cam once"), "cam once")
            startCamera(view())
            tryVerify(() => overlay.visible, 10000)
            verify(box.checked, "reset for every card")
            waitForRendering(overlay)
            click(box)
            verify(!box.checked)
            click(find(overlay, "acceptButton"))
            compare(cameraResult(view()), "ok")
            compare(live.get(o, "camera"), undefined)
            compare(live.count, 0)

            // rememberPermissions: false hides the checkbox.
            overlay.rememberPermissions = false
            load(view(), root.page(root.origin, "cam nobox"), "cam nobox")
            startCamera(view())
            tryVerify(() => overlay.visible, 10000)
            verify(!box.visible)
            overlay.accept()
            compare(cameraResult(view()), "ok")
            compare(live.count, 0)
            overlay.rememberPermissions = true
        }

        function test_03_prompt_permissions() {
            const o = live.originOf(root.origin)
            load(view(), root.page(root.origin, "perm default"), "perm default")
            compare(permissionState(view(), "notifications"), "prompt")
            live.set(o, "notifications", "allow")
            live.set("127.0.0.1", "geolocation", "block")   // host scope
            load(view(), root.page(root.origin, "perm set"), "perm set")
            compare(permissionState(view(), "notifications"), "granted")
            compare(permissionState(view(), "geolocation"), "denied")
            compare(evaluate(view(), "Notification.requestPermission()"), "granted")
            // The other origin keeps the defaults.
            load(view(), root.page(root.alt, "perm other"), "perm other")
            compare(permissionState(view(), "notifications"), "prompt")
            compare(permissionState(view(), "geolocation"), "prompt")
            // Reset: back to asking.
            live.reset(o)
            live.reset("127.0.0.1")
            load(view(), root.page(root.origin, "perm reset"), "perm reset")
            compare(permissionState(view(), "notifications"), "prompt")
            compare(permissionState(view(), "geolocation"), "prompt")
        }

        function test_04_javascript() {
            live.set("localhost", "javascript", "block")
            const script = n => "<script>document.title = 'js" + n + "'</script>"
            load(view(), root.page(root.alt, "nojs1", script(1)), "nojs1")
            compare(view().title, "nojs1", "scripts blocked on localhost")
            load(view(), root.page(root.origin, "nojs2", script(2)), "js2")
            live.set("[*.]0.0.1", "javascript", "block")
            load(view(), root.page(root.origin, "nojs3", script(3)), "nojs3")
            compare(view().title, "nojs3", "a pattern scope")
            live.clear()
            load(view(), root.page(root.alt, "nojs4", script(4)), "js4")
        }

        function test_05_popups() {
            const o = live.originOf(root.origin)
            const opener = n => root.page(root.origin, "opener" + n,
                "<script>window.open('/popup" + n + "?html=" + encodeURIComponent("<title>popup" + n + "</title>") + "')</script>")
            load(view(), opener(1), "opener1")
            wait(500)
            compare(tabs.count, 1, "blocked by default")
            live.set(o, "popups", "allow")
            load(view(), opener(2), "opener2")
            tryCompare(tabs, "count", 2, 10000)
            tryCompare(tabs.views[1], "title", "popup2", 10000)
        }

        function test_06_zoom_per_origin() {
            const o = live.originOf(root.origin)
            const v = view()
            load(v, root.page(root.origin, "z1"), "z1")
            v.zoomFactor = 1.5
            compare(live.get(o, "zoom"), 1.5, "stored for the origin")
            load(v, root.page(root.alt, "z2"), "z2")
            tryCompare(v, "zoomFactor", 1, 5000, "another origin: its own zoom")
            load(v, root.page(root.origin, "z3"), "z3")
            tryCompare(v, "zoomFactor", 1.5, 5000, "restored on navigation")
            // The page is zoomed.
            tryVerify(() => Math.abs(evaluate(v, "window.devicePixelRatio") - 1.5) < 0.05, 5000,
                      "devicePixelRatio follows the zoom")

            // A new tab on the origin starts zoomed; zooming it zooms the
            // origin's other tabs.
            const t = tabs.openTab(root.page(root.origin, "z4"))
            tryCompare(t, "title", "z4", 10000)
            compare(t.zoomFactor, 1.5)
            t.zoomFactor = 1.2
            compare(live.get(o, "zoom"), 1.2)
            compare(v.zoomFactor, 1.2, "the other tab of the origin follows")
            // Back to the default: nothing stored.
            t.zoomFactor = 1
            compare(live.get(o, "zoom"), undefined)
            compare(live.count, 0)
            compare(v.zoomFactor, 1)

            // A "*" default zoom applies to every origin without its own.
            live.set("*", "zoom", 0.9)
            compare(t.zoomFactor, 0.9)
            load(t, root.page(root.alt, "z5"), "z5")
            compare(t.zoomFactor, 0.9)
            // Zooming to the default stores nothing; another value does.
            t.zoomFactor = 1.1
            compare(live.get(root.alt, "zoom"), 1.1)
            t.zoomFactor = 0.9
            compare(live.get(root.alt, "zoom"), undefined)
            live.reset("*")
            compare(t.zoomFactor, 1)
            // data: pages keep the tab's zoom.
            t.zoomFactor = 1.3
            load(t, "data:text/html,<title>z6</title>", "z6")
            compare(t.zoomFactor, 1.3)
            compare(live.get(root.alt, "zoom"), 1.3)
            live.clear()
        }

        function test_07_zoom_per_tab() {
            tabs.zoomPolicy = "tab"
            const v = view()
            load(v, root.page(root.origin, "t1"), "t1")
            v.zoomFactor = 1.4
            compare(live.count, 0, "nothing stored")
            load(v, root.page(root.alt, "t2"), "t2")
            compare(v.zoomFactor, 1.4, "the tab keeps its zoom")
            const t = tabs.openTab(root.page(root.alt, "t3"))
            tryCompare(t, "title", "t3", 10000)
            compare(t.zoomFactor, 1)
            compare(v.zoomFactor, 1.4)
            tabs.closeTab(tabs.indexOf(t))
            v.zoomFactor = 1
            // Back to "origin": stored zooms apply again.
            live.set(root.origin, "zoom", 1.25)
            compare(v.zoomFactor, 1)
            load(v, root.page(root.origin, "t4"), "t4")
            compare(v.zoomFactor, 1)
            tabs.zoomPolicy = "origin"
            compare(v.zoomFactor, 1.25)
        }

        function test_08_site_info() {
            const o = live.originOf(root.origin)
            const info = nav.siteInfo
            load(view(), root.page(root.origin, "info"), "info")
            waitForRendering(nav)
            const button = find(nav, "siteInfoButton")
            click(button)
            verify(info.opened)
            compare(info.origin, o)
            compare(info.security, "insecure")
            verify(info.hasSettings)
            const card = info.card
            verify(find(card, "siteInfoOrigin").text.indexOf("127.0.0.1") >= 0)
            compare(find(card, "siteInfoSecurity").text, "Connection is not secure")
            waitForRendering(card)

            // Permission rows: Ask / Allow / Block.
            verify(find(card, "siteInfoOption_camera_ask").selected)
            click(find(card, "siteInfoOption_camera_block"))
            compare(live.get(o, "camera"), "block")
            verify(find(card, "siteInfoOption_camera_block").selected)
            verify(!info.needsReload, "permissions apply at once")
            // Choosing what the site gets anyway removes the origin's value.
            click(find(card, "siteInfoOption_camera_ask"))
            compare(live.get(o, "camera"), undefined)
            compare(live.count, 0)

            // Content settings: reload to apply.
            click(find(card, "siteInfoOption_javascript_block"))
            compare(live.get(o, "javascript"), "block")
            verify(info.needsReload)
            const reloadButton = find(card, "siteInfoReload")
            tryVerify(() => reloadButton.visible, 2000)
            waitForItemPolished(reloadButton.parent)
            click(reloadButton)
            verify(!info.needsReload)
            tryVerify(() => !view().loading, 10000)

            // Zoom.
            click(find(card, "siteInfoZoomIn"))
            compare(view().zoomFactor, 1.1)
            compare(live.get(o, "zoom"), 1.1)
            click(find(card, "siteInfoZoomOut"))
            click(find(card, "siteInfoZoomOut"))
            compare(view().zoomFactor, 0.9)
            click(find(card, "siteInfoZoomReset"))
            compare(view().zoomFactor, 1)
            compare(live.get(o, "zoom"), undefined)

            // Reset all for this site.
            live.set(o, "geolocation", "allow")
            view().zoomFactor = 1.5
            compare(live.get(o, "zoom"), 1.5)
            const resetAll = find(card, "siteInfoResetAll")
            tryVerify(() => resetAll.enabled, 2000)
            click(resetAll)
            verify(!live.contains(o))
            compare(view().zoomFactor, 1)
            compare(find(card, "siteInfoStatus").text, "Settings reset for this site")

            // Escape closes and focus returns.
            keyClick(Qt.Key_Escape)
            verify(!info.opened)
            // A click outside the card closes it too.
            verify(info.toggle())
            mouseClick(root, root.width - 10, root.height - 10)
            verify(!info.opened)
            // Switching tabs closes it.
            verify(info.open())
            tabs.openTab(root.page(root.origin, "info2"))
            verify(!info.opened)
        }

        // Not "..._data": TestCase takes that for a data function.
        function test_09_clear_cookies_and_storage() {
            const info = nav.siteInfo
            load(view(), root.page(root.origin, "data"), "data")
            evaluate(view(), "document.cookie = 'k=v; max-age=3600'; localStorage.setItem('k', 'v'); 1")
            compare(evaluate(view(), "document.cookie + '|' + localStorage.getItem('k')"), "k=v|v")
            // The other origin's data stays.
            load(view(), root.page(root.alt, "data other"), "data other")
            evaluate(view(), "localStorage.setItem('k', 'other'); 1")
            load(view(), root.page(root.origin, "data2"), "data2")
            compare(evaluate(view(), "localStorage.getItem('k')"), "v")

            verify(info.open(find(nav, "siteInfoButton")))
            waitForRendering(info.card)
            clearedSpy.clear()
            click(find(info.card, "siteInfoClearData"))
            tryCompare(clearedSpy, "count", 1, 10000)
            compare(clearedSpy.signalArguments[0][0], live.originOf(root.origin))
            verify(clearedSpy.signalArguments[0][1])
            compare(info.status, "Cookies and site data cleared")
            info.close()
            load(view(), root.page(root.origin, "data3"), "data3")
            compare(evaluate(view(), "document.cookie + '|' + localStorage.getItem('k')"), "|null")
            load(view(), root.page(root.alt, "data other2"), "data other2")
            compare(evaluate(view(), "localStorage.getItem('k')"), "other")
            evaluate(view(), "localStorage.clear(); 1")
        }

        function test_10_no_store() {
            // WebTabs without a store: permission requests go to the overlay;
            // the card still shows security and clears data.
            tabs.siteSettings = null
            nav.siteSettings = null
            load(view(), root.page(root.origin, "nostore"), "nostore")
            startCamera(view())
            tryVerify(() => overlay.visible, 10000)
            overlay.reject()
            compare(cameraResult(view()), "NotAllowedError")
            const info = nav.siteInfo
            verify(info.open())
            verify(!info.hasSettings)
            compare(info.rows.length, 0)
            verify(find(info.card, "siteInfoClearData").visible)
            verify(!find(info.card, "siteInfoResetAll").visible)
            info.close()
            // Session memory of RequestOverlay: answered without the card now.
            startCamera(view())
            compare(cameraResult(view()), "NotAllowedError")
            verify(!overlay.visible)
            overlay.decisions = ({})
            tabs.siteSettings = live
            nav.siteSettings = live
        }

        function cleanupTestCase() {
            if (!root.origin) return
            tabs.closeAll()
            live.clear()
            live.save()
        }
    }

    // --- Browser -----------------------------------------------------------------

    Loader {
        id: browserLoader
        anchors.fill: parent
        z: 1
        active: false
        sourceComponent: Browser {
            focus: true
            siteSettings: live
            sessionStore: null
            openInitialTabs: false
        }
    }

    TestCase {
        name: "SiteSettingsBrowser"
        when: windowShown

        property var browser: browserLoader.item

        function initTestCase() {
            if (!root.origin) return
            custom.visible = false
            browserLoader.active = true
            browserLoader.item.forceActiveFocus()
            browser.openTab(root.page(root.origin, "browser"))
            tryCompare(browser, "title", "browser", 10000)
        }
        function init() {
            if (!root.origin) skip("TEST_HTTP_ORIGIN is not set (run through tests/run.sh)")
            live.clear()
        }
        function find(parent, name) {
            const item = findChild(parent, name)
            verify(item, "no child " + name)
            return item
        }
        function findChildren(parent, name) {
            const out = []
            const walk = item => {
                for (let i = 0; i < item.children.length; ++i) {
                    const c = item.children[i]
                    if (c.objectName === name) out.push(c)
                    walk(c)
                }
            }
            walk(parent)
            return out
        }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item) {
            verify(item && item.visible, "clickable")
            const p = center(item)
            mouseClick(root, p.x, p.y)
        }

        function test_01_wiring() {
            compare(browser.tabs.siteSettings, live)
            compare(browser.navigationBar.siteSettings, live)
            compare(browser.siteSettingsManager.store, live)
            verify(browser.actions.has("site.info"))
            verify(browser.actions.has("site.settings"))
            compare(browser.keyBindings.hint("site.info"), "", "no default key")
            compare(browser.keyBindings.hint("site.settings"), "")

            // site.info toggles the card under the button.
            verify(browser.trigger("site.info"))
            const info = browser.navigationBar.siteInfo
            verify(info.opened)
            verify(browser.actions.action("site.info").checked)
            compare(info.origin, live.originOf(root.origin))
            const button = browser.navigationBar.siteInfoButton
            verify(Math.abs(info.card.y - button.mapToItem(null, 0, button.height + 4).y) < 1, "below the button")
            browser.trigger("site.info")
            verify(!info.opened)

            // Zooming the page stores the zoom (Browser's WebTabs default policy).
            browser.currentView.zoomFactor = 1.2
            compare(live.get(root.origin, "zoom"), 1.2)
            browser.currentView.zoomFactor = 1
        }

        function test_02_manager() {
            live.set(root.origin, "camera", "block")
            live.set(root.origin, "zoom", 1.25)
            live.set("[*.]example.test", "javascript", "block")
            live.set("*", "popups", "block")

            // "Site settings…" in the card opens the manager.
            const info = browser.navigationBar.siteInfo
            verify(info.open())
            waitForRendering(info.card)
            click(find(info.card, "siteInfoManage"))
            verify(!info.opened)
            tryVerify(() => browser.siteSettingsVisible, 2000)
            const mgr = browser.siteSettingsManager
            const search = find(mgr, "siteSettingsSearch")
            tryVerify(() => search.activeFocus, 2000)
            compare(mgr.count, 3)
            compare(mgr.entryAt(0).kind, "default")

            // Search.
            for (const ch of "example") keyClick(ch)
            compare(mgr.count, 1)
            compare(mgr.entryAt(0).scope, "[*.]example.test")
            keyClick(Qt.Key_Escape)
            compare(mgr.filterText, "", "Escape clears the search first")
            verify(browser.siteSettingsVisible)

            // Chips: × resets one value.
            // Sorted by host: *, 127.0.0.1, example.test.
            const row = mgr.rowAt(1)
            verify(row)
            compare(row.scope, live.originOf(root.origin))
            waitForRendering(mgr)
            let chips = findChildren(row, "siteSettingsChip")
            compare(chips.map(c => c.settingKey).sort(), ["camera", "zoom"])
            const zoomChip = chips.filter(c => c.settingKey === "zoom")[0]
            click(find(zoomChip, "siteSettingsChipReset"))
            compare(live.get(root.origin, "zoom"), undefined)
            compare(live.get(root.origin, "camera"), "block")
            verify(mgr.status.indexOf("Zoom") >= 0, mgr.status)

            // Reset removes the site.
            click(find(mgr.rowAt(1), "siteSettingsReset"))
            verify(!live.contains(root.origin))
            compare(mgr.count, 2)

            // Reset all… asks first.
            click(find(mgr, "siteSettingsResetAll"))
            verify(mgr.confirming)
            keyClick(Qt.Key_Escape)
            verify(!mgr.confirming, "Escape cancels")
            compare(live.count, 2)
            click(find(mgr, "siteSettingsResetAll"))
            click(find(mgr, "siteSettingsResetAllConfirm"))
            compare(live.count, 0)
            verify(find(mgr, "siteSettingsEmpty").visible)

            // site.settings toggles; Escape closes.
            keyClick(Qt.Key_Escape)
            verify(!browser.siteSettingsVisible)
            verify(browser.trigger("site.settings"))
            verify(browser.siteSettingsVisible)
            verify(browser.actions.action("site.settings").checked)
            // Another panel closes it.
            browser.showHistory()
            verify(!browser.siteSettingsVisible)
            browser.hideHistory()
        }

        function test_03_disabled() {
            const b = Qt.createQmlObject(
                'import CefQml.Components; Browser { siteSettings: null; sessionStore: null; openInitialTabs: false; visible: false }',
                root)
            compare(b.tabs.siteSettings, null)
            compare(b.navigationBar.siteSettings, null)
            verify(!b.actions.action("site.settings").enabled)
            b.showSiteSettings()
            verify(!b.siteSettingsVisible)
            b.destroy()
        }

        function cleanupTestCase() {
            if (!root.origin) return
            // Not tabs.closeAll(): Browser opens a new tab for the last one closed.
            browserLoader.active = false
            custom.visible = true
            live.clear()
            live.save()
        }
    }
}
