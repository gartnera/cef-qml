// DevTools rendered in the scene: CefWebView.devToolsFor (the in-process
// frontend bridge), DevToolsPanel's dock modes, the devtools.* actions and
// their keys, the context menu's "Inspect", and lifecycle (closing the
// inspected tab, closing DevTools, hot reload).
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 1000
    height: 700

    function page(title, body) {
        return "data:text/html," + encodeURIComponent("<title>" + title + "</title><body style='margin:0'>" + (body || ""))
    }
    readonly property string targetBody:
        "<div id=target style='width:200px;height:100px;background:#c33'>target</div><p id=other>other</p>"

    // ---- CefWebView.devToolsFor on its own --------------------------------

    CefWebView {
        id: inspected
        width: 500; height: 300
        url: root.page("inspected", root.targetBody)
    }
    Component { id: frontendComponent; CefWebView { x: 0; y: 300; width: 1000; height: 400 } }
    SignalSpy { id: closeSpy; signalName: "closeRequested" }

    // Runs `js` in `view` and returns its result (a Promise is awaited).
    function evalIn(test, view, js) {
        let out = null
        view.evaluateJavaScript(js, (r, e) => out = { r: r, e: e })
        test.tryVerify(() => out !== null, 15000, "evaluate " + js.slice(0, 60))
        if (out.e !== undefined && out.e !== null && out.e !== "") test.fail("script failed: " + out.e)
        return out.r
    }
    // What the frontend shows: { target (inspected URL), node (selected
    // element "TAG#id"), panel }, read through the frontend's own modules.
    function probe(test, frontend) {
        return JSON.parse(evalIn(test, frontend, `(async () => {
            const UI = await import('./ui/legacy/legacy.js');
            const SDK = await import('./core/sdk/sdk.js');
            const t = SDK.TargetManager.TargetManager.instance().primaryPageTarget();
            const n = UI.Context.Context.instance().flavor(SDK.DOMModel.DOMNode);
            const panel = UI.InspectorView.InspectorView.instance().currentPanelDeprecated();
            return JSON.stringify({ target: t ? t.inspectedURL() : null,
                                    node: n ? n.nodeName() + '#' + (n.getAttribute('id') || '') : null,
                                    panel: panel ? panel.name : null });
        })()`))
    }
    // Waits until `frontend` is connected and its DevTools show `view`'s page.
    function waitLoaded(test, frontend, view) {
        test.tryCompare(frontend, "devToolsConnected", true, 20000)
        test.tryVerify(() => frontend.title.startsWith("DevTools"), 20000, "frontend title")
        test.tryVerify(() => probe(test, frontend).target === view.url.toString(), 20000,
                       "the frontend shows the inspected page")
    }
    // Evaluates `expression` in the inspected page through the frontend
    // (its RuntimeModel), i.e. over the DevTools protocol connection.
    function evalThroughFrontend(test, frontend, expression) {
        return evalIn(test, frontend, `(async () => {
            const SDK = await import('./core/sdk/sdk.js');
            const rm = SDK.TargetManager.TargetManager.instance().primaryPageTarget().model(SDK.RuntimeModel.RuntimeModel);
            const res = await rm.defaultExecutionContext().evaluate({ expression: ${JSON.stringify(expression)} }, false, false);
            return res.object.value;
        })()`)
    }

    TestCase {
        id: apiTest
        name: "DevToolsView"
        when: windowShown

        function test_1_open_load_close() {
            tryCompare(inspected, "title", "inspected", 15000)
            verify(!inspected.hasDevTools)
            const fe = frontendComponent.createObject(root, { devToolsFor: inspected })
            closeSpy.target = fe
            closeSpy.clear()
            verify(inspected.hasDevTools)
            compare(inspected.devToolsView, fe)
            compare(fe.devToolsFor, inspected)
            compare(fe.url.toString().split(":")[0], "devtools")
            waitLoaded(apiTest, fe, inspected)
            tryVerify(() => fe.frameCount > 0, 10000, "the frontend paints")
            // The frontend talks to the page over the bridge.
            compare(evalThroughFrontend(apiTest, fe, "document.title + '!'"), "inspected!")
            // Its DOM is DevTools' own.
            verify(evalIn(apiTest, fe, "document.title.startsWith('DevTools') && document.body.childElementCount > 0"))
            // A frontend only ever shows DevTools.
            fe.url = root.page("elsewhere")
            compare(fe.url.toString().split(":")[0], "devtools")

            inspected.closeDevTools()
            verify(!inspected.hasDevTools)
            compare(inspected.devToolsView, null)
            compare(fe.devToolsFor, null)
            compare(fe.devToolsConnected, false)
            compare(closeSpy.count, 1)
            // The page is unaffected.
            compare(evalIn(apiTest, inspected, "document.getElementById('target').textContent"), "target")
            inspected.url = root.page("inspected again", root.targetBody)
            tryCompare(inspected, "title", "inspected again", 15000)
            fe.destroy()
        }

        function test_2_inspect_element() {
            const fe = frontendComponent.createObject(root, { devToolsFor: inspected })
            // Asked for before the frontend has connected: revealed once it has.
            inspected.inspectElementAt(50, 50)
            waitLoaded(apiTest, fe, inspected)
            tryVerify(() => probe(apiTest, fe).node === "DIV#target", 20000, "the element under the point is selected")
            compare(probe(apiTest, fe).panel, "elements")
            inspected.inspectElementAt(20, 125)
            tryVerify(() => probe(apiTest, fe).node === "P#other", 20000)
            inspected.closeDevTools()
            fe.destroy()
        }

        function test_3_newest_frontend_wins() {
            const a = frontendComponent.createObject(root, { devToolsFor: inspected })
            closeSpy.target = a
            closeSpy.clear()
            waitLoaded(apiTest, a, inspected)
            const b = frontendComponent.createObject(root, { devToolsFor: inspected })
            compare(inspected.devToolsView, b)
            compare(a.devToolsFor, null)
            compare(closeSpy.count, 1, "the replaced frontend asks to be closed")
            waitLoaded(apiTest, b, inspected)
            // Destroying the frontend detaches it.
            b.destroy()
            tryVerify(() => !inspected.hasDevTools, 5000)
            a.destroy()
            compare(evalIn(apiTest, inspected, "1 + 1"), 2)
        }

        function test_4_frontend_reload_reconnects() {
            const fe = frontendComponent.createObject(root, { devToolsFor: inspected })
            waitLoaded(apiTest, fe, inspected)
            let drops = 0
            const onChanged = () => { if (!fe.devToolsConnected) ++drops }
            fe.devToolsConnectedChanged.connect(onChanged)
            fe.reload()
            tryVerify(() => drops > 0, 10000, "the old document's connection is gone")
            fe.devToolsConnectedChanged.disconnect(onChanged)
            waitLoaded(apiTest, fe, inspected)
            compare(evalThroughFrontend(apiTest, fe, "6 * 7"), 42)
            inspected.closeDevTools()
            fe.destroy()
        }
    }

    // ---- the Browser: actions, keys, dock modes ------------------------------

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        sessionName: "devtools-session"
        visible: false
        enabled: visible
    }

    TestCase {
        id: browserTest
        name: "BrowserDevTools"
        when: windowShown && apiTest.completed

        readonly property var panel: browser.devToolsPanel
        function view() { return browser.currentView }
        function find(name) {
            const item = findChild(browser, name)
            verify(item, "no child " + name)
            return item
        }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item) { const p = center(item); mouseClick(root, p.x, p.y) }
        function resetTabs() {
            panel.closeAll()
            browser.devTools = "bottom"
            browser.tabs.restore([page("start", root.targetBody)], 0)
            tryCompare(browser, "title", "start", 15000)
            tryVerify(() => panel.entries.length === 0 && !view().hasDevTools, 5000)
            view().forceActiveFocus()
            // Painted, so mouse input hits the laid out page.
            compare(evalIn(browserTest, view(), "new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))"), 1)
        }

        function initTestCase() {
            browser.visible = true
            tryVerify(() => browser.tabs.count > 0, 10000)
        }
        function cleanup() { browser.keyBindings.reset() }

        function test_01_toggle_keys_docked_bottom() {
            resetTabs()
            const v = view()
            const action = browser.actions.action("devtools.toggle")
            compare(browser.keyBindings.sequencesFor("devtools.toggle"), ["F12", "Ctrl+Shift+I"])
            verify(!action.checked)
            keyClick(Qt.Key_F12)
            tryVerify(() => v.hasDevTools, 5000, "F12 opens DevTools")
            verify(action.checked)
            const fe = panel.frontend
            verify(fe)
            compare(v.devToolsView, fe)
            verify(panel.docked)
            waitLoaded(browserTest, fe, v)
            // Docked under the page, which keeps the rest.
            const page = panel.pageItem, dock = panel.dockItem
            verify(dock.visible)
            compare(dock.y, page.height)
            compare(page.height + dock.height, panel.height)
            compare(dock.width, panel.width)
            verify(fe.visible && fe.width === dock.width && fe.height > 0)
            compare(browser.tabs.count, 1, "no tab for docked DevTools")
            keyClick(Qt.Key_F12)
            tryVerify(() => !v.hasDevTools, 5000, "F12 closes DevTools")
            tryCompare(panel, "docked", false, 5000)
            compare(page.height, panel.height)
            verify(!action.checked)

            v.forceActiveFocus()
            keyClick(Qt.Key_I, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => v.hasDevTools, 5000, "Ctrl+Shift+I opens DevTools")
            // Focus is in DevTools now; the window-wide key still closes them.
            keyClick(Qt.Key_I, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => !v.hasDevTools, 5000, "Ctrl+Shift+I closes DevTools")
            compare(evalIn(browserTest, v, "document.title"), "start", "the page is unaffected")
        }

        function test_02_rebind() {
            resetTabs()
            const v = view()
            browser.keyBindings.bind("devtools.toggle", ["Ctrl+Alt+J"])
            compare(browser.keyBindings.sequencesFor("devtools.toggle"), ["Ctrl+Alt+J"])
            keyClick(Qt.Key_F12)
            wait(300)
            verify(!v.hasDevTools, "F12 is unbound")
            keyClick(Qt.Key_J, Qt.ControlModifier | Qt.AltModifier)
            tryVerify(() => v.hasDevTools, 5000, "the new key opens DevTools")
            keyClick(Qt.Key_J, Qt.ControlModifier | Qt.AltModifier)
            tryVerify(() => !v.hasDevTools, 5000)
            browser.keyBindings.reset("devtools.toggle")
            keyClick(Qt.Key_F12)
            tryVerify(() => v.hasDevTools, 5000, "the default is back")
            browser.trigger("devtools.toggle")
            tryVerify(() => !v.hasDevTools, 5000, "trigger() toggles too")
        }

        function test_03_dock_right_and_splitter() {
            resetTabs()
            const v = view()
            const fe = browser.showDevTools()
            verify(fe)
            waitLoaded(browserTest, fe, v)
            const size = panel.dockSize
            browser.devTools = "right"
            compare(panel.dock, "right")
            compare(panel.frontend, fe, "bottom <-> right keeps the frontend")
            compare(fe.devToolsConnected, true)
            const page = panel.pageItem, dock = panel.dockItem
            compare(dock.x, page.width)
            compare(page.width + dock.width, panel.width)
            compare(dock.height, panel.height)
            // Dragging the splitter to the left widens DevTools.
            const splitter = find("devToolsSplitter")
            const p = center(splitter)
            mousePress(root, p.x, p.y)
            mouseMove(root, p.x - 100, p.y, 20, Qt.LeftButton)
            mouseMove(root, p.x - 150, p.y, 20, Qt.LeftButton)
            mouseRelease(root, p.x - 150, p.y)
            tryVerify(() => Math.abs(panel.dockSize - (size + 150)) < 2, 2000, "dragged by 150px: " + panel.dockSize)
            compare(page.width + dock.width, panel.width)
            // Clamped: the page keeps its minimum.
            mousePress(root, p.x - 150, p.y)
            mouseMove(root, 5, p.y, 20, Qt.LeftButton)
            mouseRelease(root, 5, p.y)
            compare(page.width, panel.minimumPageSize)
            panel.size = 320
            // The header's buttons dock it back.
            click(find("devToolsDockBottom"))
            compare(browser.devTools, "bottom")
            compare(dock.y, page.height)
            click(find("devToolsClose"))
            tryVerify(() => !v.hasDevTools, 5000, "the header closes DevTools")
            tryCompare(panel, "docked", false, 5000)
        }

        function test_04_dock_tab() {
            resetTabs()
            const v = view()
            browser.devTools = "tab"
            keyClick(Qt.Key_F12)
            tryCompare(browser.tabs, "count", 2, 5000)
            const fe = browser.tabs.views[1]
            compare(fe.devToolsFor, v)
            compare(v.devToolsView, fe)
            compare(browser.tabs.currentIndex, 1, "the DevTools tab is selected")
            verify(!panel.docked)
            waitLoaded(browserTest, fe, v)
            tryVerify(() => browser.title.startsWith("DevTools"), 5000)
            // Not part of the saved session, and not a closed tab to reopen.
            const s = browser.sessionStore.snapshot()
            compare(s.tabs.length, 1)
            compare(s.current, 0)
            // F12 in the DevTools tab closes it.
            keyClick(Qt.Key_F12)
            tryCompare(browser.tabs, "count", 1, 5000)
            verify(!v.hasDevTools)
            compare(browser.controller.closedTabs.filter(c => c.url.startsWith("devtools:")).length, 0)

            // Moving open DevTools between modes.
            keyClick(Qt.Key_F12)
            tryCompare(browser.tabs, "count", 2, 5000)
            browser.devTools = "bottom"
            tryCompare(browser.tabs, "count", 1, 5000)
            browser.selectTab(v)
            tryVerify(() => panel.docked && panel.frontend.devToolsFor === v, 5000, "moved into the panel")
            waitLoaded(browserTest, panel.frontend, v)
            browser.devTools = "tab"
            tryCompare(browser.tabs, "count", 2, 5000)
            verify(!panel.docked)
            compare(browser.tabs.views[1].devToolsFor, v)
            // Closing the DevTools tab like any tab detaches it.
            browser.closeTab(1)
            tryVerify(() => !v.hasDevTools, 5000)
            compare(panel.entries.length, 0)
        }

        function test_05_dock_window() {
            resetTabs()
            const v = view()
            browser.devTools = "window"
            const fe = browser.showDevTools()
            verify(fe)
            compare(browser.tabs.count, 1)
            verify(!panel.docked)
            compare(panel.entries.length, 1)
            const win = panel.entries[0].window
            verify(win)
            verify(win.visible)
            verify(win !== browser.Window.window, "a window of its own")
            compare(fe.parent, win.contentItem)
            waitLoaded(browserTest, fe, v)
            tryVerify(() => win.title.startsWith("DevTools"), 5000)
            compare(evalThroughFrontend(browserTest, fe, "document.title"), "start")
            // Closing the window closes DevTools.
            win.close()
            tryVerify(() => !v.hasDevTools, 5000)
            compare(panel.entries.length, 0)
            // Window -> docked moves them.
            browser.showDevTools()
            compare(panel.entries[0].kind, "window")
            browser.devTools = "bottom"
            tryVerify(() => panel.docked && panel.entries.length === 1, 5000)
            waitLoaded(browserTest, panel.frontend, v)
            browser.closeDevTools()
            tryVerify(() => !v.hasDevTools && panel.entries.length === 0, 5000)
        }

        function test_06_per_tab_devtools() {
            resetTabs()
            const a = view()
            const feA = browser.showDevTools()
            const b = browser.openTab(page("second", root.targetBody))
            tryCompare(b, "title", "second", 15000)
            compare(browser.currentView, b)
            verify(!panel.docked, "tab b has no DevTools")
            verify(!feA.visible, "a's DevTools are hidden with their tab")
            verify(a.hasDevTools)
            const feB = browser.showDevTools()
            verify(feB !== feA)
            compare(panel.frontend, feB)
            waitLoaded(browserTest, feB, b)
            browser.selectTab(a)
            compare(panel.frontend, feA)
            verify(feA.visible && !feB.visible)
            waitLoaded(browserTest, feA, a)
            compare(panel.entries.length, 2)
            panel.closeAll()
            tryVerify(() => !a.hasDevTools && !b.hasDevTools && panel.entries.length === 0, 5000)
        }

        function test_07_context_menu_inspect() {
            resetTabs()
            const v = view()
            const p = v.mapToItem(root, 20, 125)  // over p#other
            mouseClick(root, p.x, p.y, Qt.RightButton)
            const menuPanel = find("contextMenuPanel")
            tryVerify(() => menuPanel.visible && menuPanel.parent.visible, 5000)
            const items = menuPanel.parent.items
            const last = items[items.length - 1]
            compare(last.label, "Inspect")
            // The last entry.
            const q = menuPanel.mapToItem(root, 40, menuPanel.height - 4 - 14)
            mouseClick(root, q.x, q.y)
            tryVerify(() => v.hasDevTools, 5000, "Inspect opens DevTools")
            const fe = panel.frontend
            waitLoaded(browserTest, fe, v)
            tryVerify(() => probe(browserTest, fe).node === "P#other", 20000, "the clicked element is selected")
            compare(probe(browserTest, fe).panel, "elements")
            // The action directly, with DevTools already open.
            browser.trigger("devtools.inspect", { x: 50, y: 50 })
            tryVerify(() => probe(browserTest, fe).node === "DIV#target", 20000)
            verify(browser.inspectElement(30, 125))
            tryVerify(() => probe(browserTest, fe).node === "P#other", 20000)
            browser.closeDevTools()
            tryVerify(() => !v.hasDevTools, 5000)
        }

        function test_08_closing_inspected_tab_closes_devtools() {
            resetTabs()
            // Docked.
            const a = browser.openTab(page("doomed"))
            tryCompare(a, "title", "doomed", 15000)
            const fe = browser.showDevTools()
            waitLoaded(browserTest, fe, a)
            const closed = []
            const onClosed = v => closed.push(v)
            panel.closed.connect(onClosed)
            browser.closeTab(a)
            tryVerify(() => panel.entries.length === 0, 5000, "its DevTools went with the tab")
            panel.closed.disconnect(onClosed)
            compare(closed.length, 1)
            verify(!panel.docked)
            // As a tab.
            browser.devTools = "tab"
            const b = browser.openTab(page("doomed too"))
            tryCompare(b, "title", "doomed too", 15000)
            browser.showDevTools()
            tryCompare(browser.tabs, "count", 3, 5000)
            const tabFe = browser.tabs.views[2]
            compare(tabFe.devToolsFor, b)
            waitLoaded(browserTest, tabFe, b)
            browser.closeTab(b)
            tryCompare(browser.tabs, "count", 1, 5000)
            compare(browser.tabs.views[0].title, "start")
            compare(panel.entries.length, 0)
            // Discarding a tab closes its DevTools as well.
            browser.devTools = "bottom"
            const c = browser.openTab(page("discard me"))
            tryCompare(c, "title", "discard me", 15000)
            browser.showDevTools()
            browser.selectTab(0)
            verify(browser.controller.discardTab(c))
            tryVerify(() => !c.hasDevTools && panel.entries.length === 0, 5000)
            browser.selectTab(c)
            tryCompare(c, "title", "discard me", 15000)
            browser.closeTab(c)
        }

        function test_09_page_survives_closed_devtools() {
            resetTabs()
            const v = view()
            for (let i = 0; i < 2; ++i) {
                const fe = browser.showDevTools()
                waitLoaded(browserTest, fe, v)
                // Something to drop with the session: a highlighted node.
                v.inspectElementAt(50, 50)
                tryVerify(() => probe(browserTest, fe).node === "DIV#target", 20000)
                verify(browser.closeDevTools())
                verify(!browser.closeDevTools(), "already closed")
                compare(evalIn(browserTest, v, "document.getElementById('target').textContent"), "target")
            }
            browser.navigate(page("after"))
            tryCompare(browser, "title", "after", 15000)
            compare(browser.controller.hasDevTools(), false)
        }

        function test_10_left_open_for_shutdown() {
            resetTabs()
            // DevTools windows (and the hot reload suite's docked DevTools)
            // stay open until the test runner exits.
            browser.devTools = "window"
            browser.showDevTools()
            const w = browser.openTab(page("windowed"))
            browser.showDevTools(w)
            compare(panel.entries.map(e => e.kind), ["window", "window"])
            waitLoaded(browserTest, w.devToolsView, w)
        }
    }

    // ---- hot reload with DevTools open --------------------------------------

    readonly property string dir: Cef.environment("CEF_QML_TEST_DIR") + "/test-hotreload"
    function write(test, name, text) {
        const xhr = new XMLHttpRequest()
        xhr.open("PUT", "file://" + dir + "/" + name)
        xhr.send(text)
        test.tryVerify(() => xhr.readyState === XMLHttpRequest.DONE, 5000, "writing " + name)
    }
    function app(title) {
        return `import QtQuick
import CefQml
import CefQml.Components
DevToolsPanel {
    property alias page: v
    view: v
    CefWebView { id: v; anchors.fill: parent; url: "data:text/html,<title>${title}</title>" }
}
`
    }
    Loader { id: hotLoader; anchors.fill: parent; active: false
        sourceComponent: HotReload { watch: false; source: "file://" + root.dir + "/DevToolsApp.qml" } }

    TestCase {
        id: reloadTest
        name: "DevToolsHotReload"
        when: windowShown && browserTest.completed

        function test_reload_with_devtools_open() {
            browser.visible = false
            write(reloadTest, "DevToolsApp.qml", app("one"))
            hotLoader.active = true
            const hot = hotLoader.item
            tryVerify(() => hot.item && hot.generation === 1, 10000)
            tryCompare(hot.item.page, "title", "one", 15000)
            const fe = hot.item.show()
            verify(fe)
            waitLoaded(reloadTest, fe, hot.item.page)

            write(reloadTest, "DevToolsApp.qml", app("two"))
            hot.reload()
            tryCompare(hot, "generation", 2, 10000)
            tryCompare(hot.item.page, "title", "two", 15000)
            verify(!hot.item.page.hasDevTools)
            const fe2 = hot.item.show()
            waitLoaded(reloadTest, fe2, hot.item.page)
            compare(evalThroughFrontend(reloadTest, fe2, "document.title"), "two")
            hot.reload()
            tryCompare(hot, "generation", 3, 10000)
            tryCompare(hot.item.page, "title", "two", 15000)
            // Left open for the shutdown.
            waitLoaded(reloadTest, hot.item.show(), hot.item.page)
        }
    }
}
