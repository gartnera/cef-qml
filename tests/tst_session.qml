// Session persistence: SessionStore with a custom WebTabs/BrowserController
// layout, discarded (lazy) tabs, recently closed tabs and their menu, and
// the Browser's restoreSession policies. Pages are data: URLs, so no
// network. Every store uses its own "tst-session-*" file (the profile is
// shared with the other suites); cleanupTestCase empties them.
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 1000
    height: 700

    // No characters that url.toString() would decode (e.g. spaces), so
    // URLs compare as strings.
    function page(title) {
        return "data:text/html," + encodeURIComponent("<title>" + title + "</title>")
    }
    // `u` as a url property reports it.
    property url _probeUrl
    function asUrl(u) { _probeUrl = u; return _probeUrl.toString() }

    // --- custom layout --------------------------------------------------------

    WebTabs {
        id: tabs
        anchors.fill: parent
        homeUrl: root.page("home")
    }
    BrowserController { id: ctl; tabs: tabs }
    RecentlyClosedMenu { id: closedMenu; controller: ctl }

    Component { id: storeComponent; SessionStore { saveDelay: 50 } }
    Component { id: fileComponent; JsonStore { autoSave: false } }
    Component {
        id: browserComponent
        Browser {
            anchors.fill: parent
            sessionName: "tst-session-browser"
            historyStore: null
            bookmarkStore: null
            searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
        }
    }

    // Reads / writes "<name>.json" under Cef.dataDir with a separate JsonStore.
    function readFile(name) {
        const f = fileComponent.createObject(root, { path: name + ".json" })
        const d = f.data
        f.destroy()
        return d || {}
    }
    function writeFile(name, data) {
        const f = fileComponent.createObject(root, { path: name + ".json" })
        f.data = data
        const ok = f.save()
        f.destroy()
        return ok
    }

    TestCase {
        name: "SessionStore"
        when: windowShown

        property var store: null

        function createStore(name, props) {
            const s = storeComponent.createObject(root, Object.assign({ name: name, tabs: tabs, controller: ctl }, props || {}))
            verify(s, "SessionStore created")
            verify(s.loaded)
            return s
        }
        // Destroys `s` and waits until its final (clean) state is on disk.
        function destroyStore(s, name) {
            s.destroy()
            tryVerify(() => readFile(name).running === false, 5000, "clean-exit mark written")
        }
        function resetTabs() {
            tabs.restore([], 0)
            compare(tabs.count, 0)
            ctl.clearClosedTabs()
        }
        function titles() { return tabs.views.map(v => v.title) }
        function waitTitles(list) {
            tryVerify(() => JSON.stringify(titles()) === JSON.stringify(list), 15000,
                      "titles " + JSON.stringify(list) + ", got " + JSON.stringify(titles()))
        }

        function initTestCase() {
            for (const n of ["tst-session-a", "tst-session-b", "tst-session-dup", "tst-session-browser"])
                verify(writeFile(n, {}))
        }

        function test_01_saves_tab_changes() {
            resetTabs()
            store = createStore("tst-session-a")
            verify(!store.crashed, "no previous session")
            verify(!store.hasSavedSession)
            compare(store.filePath, Cef.dataDir + "/tst-session-a.json")
            let d = readFile("tst-session-a")
            compare(d.running, true, "marked running at start")
            compare(d.tabs.length, 0)

            tabs.restore([page("one"), page("two"), page("three")], 1)
            waitTitles(["one", "two", "three"])
            tabs.views[0].zoomFactor = 1.5
            tabs.views[2].audioMuted = true
            tabs.moveTab(2, 0)  // three, one, two; "two" stays current
            compare(tabs.currentIndex, 2)
            tryVerify(() => {
                d = readFile("tst-session-a")
                return d.tabs.length === 3 && d.tabs[0].title === "three" && d.current === 2
            }, 5000, "tab changes saved")
            compare(d.tabs.map(t => t.url), [page("three"), page("one"), page("two")])
            compare(d.tabs[0].muted, true)
            compare(d.tabs[1].zoom, 1.5)
            verify(d.tabs[2].zoom === undefined && d.tabs[2].muted === undefined, "defaults not saved")
            compare(d.running, true)

            // Closing a tab saves the tab list and the recently closed tab.
            ctl.closeTab(0)
            compare(ctl.closedTabs.length, 1)
            tryVerify(() => readFile("tst-session-a").tabs.length === 2, 5000)
            d = readFile("tst-session-a")
            compare(d.current, 1)
            compare(d.closed.length, 1)
            compare(d.closed[0].url, page("three"))
            compare(d.closed[0].title, "three")
            compare(d.closed[0].index, 0)

            // A snapshot is the same data.
            const snap = store.snapshot()
            compare(snap.tabs.map(t => t.title), ["one", "two"])
            compare(snap.current, 1)

            destroyStore(store, "tst-session-a")
            store = null
            d = readFile("tst-session-a")
            compare(d.tabs.length, 2, "final state kept")
        }

        function test_02_restore_and_reopen() {
            resetTabs()
            store = createStore("tst-session-a")
            verify(!store.crashed, "the previous store exited cleanly")
            verify(store.hasSavedSession)
            compare(store.saved.tabs.length, 2)
            compare(store.saved.current, 1)
            compare(ctl.closedTabs.length, 1, "recently closed tabs restored into the controller")
            compare(ctl.closedTabs[0].title, "three")

            const views = store.restore({ replace: true })
            compare(views.length, 2)
            verify(!store.hasSavedSession, "restore() uses the saved session up")
            compare(tabs.count, 2)
            compare(tabs.currentIndex, 1, "saved current tab selected")
            const bg = tabs.views[0]
            verify(bg.discarded, "background tab restored without a browser")
            compare(bg.title, "one", "saved title shown")
            compare(bg.url.toString(), page("one"))
            compare(bg.zoomFactor, 1.5)
            const cur = tabs.views[1]
            verify(!cur.discarded, "the current tab loads")
            tryVerify(() => cur.ready && !cur.loading, 15000)
            compare(cur.title, "two")
            wait(300)
            verify(!bg.ready, "no browser until selected")
            verify(bg.discarded)

            // Selecting it loads it.
            tabs.currentIndex = 0
            verify(!bg.discarded)
            tryVerify(() => bg.ready, 15000)
            tryCompare(bg, "loading", false, 15000)
            compare(bg.title, "one")
            compare(bg.zoomFactor, 1.5)

            // Recently closed tabs: closedTabs = [three]. Add two more.
            tabs.openTab(page("four"), true)
            tabs.openTab(page("five"), true)
            waitTitles(["one", "two", "four", "five"])
            tabs.views[3].zoomFactor = 1.25
            ctl.closeTab(2)
            ctl.closeTab(2)
            compare(ctl.closedTabs.map(c => c.title), ["three", "four", "five"])
            tryVerify(() => {
                const d = readFile("tst-session-a")
                return d.closed && d.closed.length === 3
            }, 5000, "closed tabs saved")

            // The oldest one, out of order.
            const v = ctl.reopenClosedTab(0)
            verify(v)
            compare(ctl.closedTabs.map(c => c.title), ["four", "five"])
            compare(tabs.indexOf(v), 0, "back at its old position")
            compare(tabs.currentView, v)
            tryCompare(v, "title", "three", 15000)
            const w = ctl.reopenClosedTab()
            compare(w.zoomFactor, 1.25, "zoom restored")
            tryCompare(w, "title", "five", 15000)
            verify(ctl.reopenClosedTab(5) === null, "bad index")
            verify(ctl.forgetClosedTab(0))
            compare(ctl.closedTabs.length, 0)
            tryVerify(() => readFile("tst-session-a").closed.length === 0, 5000)

            // The limit applies to assignments too.
            ctl.closedTabsLimit = 2
            ctl.closedTabs = [{ url: page("a") }, { url: page("b") }, { url: page("c") }]
            compare(ctl.closedTabs.map(c => c.url), [page("b"), page("c")])
            ctl.closedTabsLimit = 25
            ctl.clearClosedTabs()

            destroyStore(store, "tst-session-a")
            store = null
        }

        function test_03_crash_marker() {
            resetTabs()
            verify(writeFile("tst-session-b", {
                version: 1, running: true, current: 0,
                tabs: [{ url: page("crashed"), title: "Crashed" }], closed: []
            }))
            store = createStore("tst-session-b")
            verify(store.crashed)
            verify(store.hasSavedSession)
            // The saved tabs stay in the file until the session changes.
            let d = readFile("tst-session-b")
            compare(d.running, true)
            compare(d.tabs[0].url, page("crashed"))

            compare(store.restore({ lazy: false }).length, 1)
            tryCompare(tabs, "count", 1)
            tryCompare(tabs.views[0], "title", "crashed", 15000)
            tryVerify(() => readFile("tst-session-b").tabs[0].title === "crashed", 5000)
            destroyStore(store, "tst-session-b")

            // A store that is not enabled reads but never writes.
            verify(writeFile("tst-session-b", { version: 1, running: true, current: 0, tabs: [{ url: page("x") }] }))
            store = createStore("tst-session-b", { enabled: false })
            verify(!store.crashed, "a disabled store does not own the mark")
            verify(store.hasSavedSession)
            verify(!store.save())
            store.destroy()
            store = null
            wait(100)
            compare(readFile("tst-session-b").running, true)
            compare(readFile("tst-session-b").tabs[0].url, page("x"))
        }

        function test_04_discard() {
            resetTabs()
            tabs.restore([page("d0"), page("d1")], 0)
            waitTitles(["d0", "d1"])
            const v0 = tabs.views[0], v1 = tabs.views[1]
            tryVerify(() => v1.ready && !v1.loading, 15000)
            verify(!tabs.discard(0), "current tab cannot be discarded")
            verify(!ctl.discardTab(0))
            verify(tabs.discard(1))
            verify(v1.discarded)
            verify(!v1.ready)
            verify(!v1.loading)
            compare(v1.title, "d1", "title kept")
            compare(v1.url.toString(), page("d1"))
            verify(!tabs.discard(1), "already discarded")

            // Navigating a discarded tab loads the new page.
            let result = null
            ctl.navigate(page("d2"), { tab: v1 }, r => result = r)
            verify(!v1.discarded)
            tryVerify(() => result !== null, 15000)
            verify(result.ok)
            compare(v1.title, "d2")
            compare(v1.navigationHistory().length, 1, "history starts over")

            // Navigation history of the current tab.
            ctl.navigate(page("d0b"), { tab: v0 }, r => result = r)
            result = null
            tryVerify(() => result !== null, 15000)
            tryVerify(() => v0.navigationHistory().length === 2, 5000)
            const h = v0.navigationHistory()
            compare(h.map(e => e.title), ["d0", "d0b"])
            compare(h.map(e => e.url.toString()), [page("d0"), page("d0b")])
            compare(h.map(e => e.current), [false, true])
            verify(h[1].time instanceof Date)
            verify(v0.goToHistoryEntry(0))
            tryCompare(v0, "title", "d0", 15000)
            tryVerify(() => v0.navigationHistory()[0].current, 5000)
            compare(tabs.views[1].navigationHistory().length, 1)

            // A declared discarded view: no browser until un-discarded.
            v1.discarded = true
            compare(v1.navigationHistory().length, 0)
            tabs.currentIndex = 1
            verify(!v1.discarded)
            tryCompare(v1, "title", "d2", 15000)
            v0.title = "placeholder"
            compare(v0.title, "placeholder", "title is writable (until the page sets its own)")
        }

        function test_05_recently_closed_menu() {
            resetTabs()
            tabs.openTab(page("keep"))
            ctl.closedTabs = [
                { url: page("r1"), title: "R1", index: 0, time: 1 },
                { url: page("r2"), title: "", index: 5, time: 2 },
                { url: page("r3"), title: "R3", index: 0, time: 3 }
            ]
            compare(closedMenu.entries[0].label, "R3", "most recent first")
            compare(closedMenu.entries[1].label, page("r2"), "URL when untitled")
            compare(closedMenu.entries[2].label, "R1")
            verify(closedMenu.popup(root, 10, 10))
            verify(closedMenu.opened)
            verify(closedMenu.rowAt(0))
            let reopened = null
            closedMenu.reopened.connect(v => reopened = v)
            verify(closedMenu.trigger(2))
            verify(!closedMenu.opened)
            verify(reopened)
            compare(reopened.url.toString(), page("r1"))
            compare(tabs.indexOf(reopened), 0)
            compare(ctl.closedTabs.map(c => c.time), [2, 3])

            verify(closedMenu.trigger(closedMenu.indexOfLabel("Reopen all")))
            compare(ctl.closedTabs.length, 0)
            compare(tabs.count, 4)
            // Oldest first, each at its old position (r2's is past the end).
            compare(tabs.views.map(v => v.url.toString()), [page("r3"), page("r1"), page("keep"), page("r2")])

            ctl.closedTabs = [{ url: page("r4"), title: "R4", index: 0, time: 4 }]
            compare(closedMenu.indexOfLabel("Reopen all"), -1, "only for several entries")
            verify(closedMenu.trigger(closedMenu.indexOfLabel("Clear list")))
            compare(ctl.closedTabs.length, 0)
            compare(closedMenu.entries.length, 1)
            compare(closedMenu.entries[0].enabled, false)
            verify(!closedMenu.trigger(0))
        }

        function test_06_duplicate_name() {
            resetTabs()
            const a = createStore("tst-session-dup")
            ignoreWarning(new RegExp("another SessionStore already writes .*tst-session-dup\\.json"))
            const b = createStore("tst-session-dup")
            ignoreWarning(new RegExp("another SessionStore already writes .*tst-session-dup\\.json"))
            verify(!b.save())
            verify(a.save())
            b.enabled = false
            b.destroy()
            destroyStore(a, "tst-session-dup")
        }

        function cleanup() {
            // A failed test leaves its store behind.
            if (store) {
                store.enabled = false
                store.destroy()
                store = null
                wait(50)
            }
        }
        function cleanupTestCase() { resetTabs() }
    }

    // --- Browser ---------------------------------------------------------------

    TestCase {
        name: "BrowserSession"
        when: windowShown

        property var browser: null

        function seed(props) {
            verify(writeFile("tst-session-browser", Object.assign({
                version: 1, running: false, current: 1,
                tabs: [
                    { url: page("s1"), title: "S1" },
                    { url: page("s2"), title: "S2" },
                    { url: "", internal: true, title: "New Tab" }
                ],
                closed: [{ url: page("c1"), title: "C1", index: 0, time: 1 }]
            }, props || {})))
        }
        function create(props) {
            browser = browserComponent.createObject(root, props || {})
            verify(browser, "Browser created")
            return browser
        }
        function destroyBrowser() {
            if (!browser) return
            browser.destroy()
            browser = null
            tryVerify(() => readFile("tst-session-browser").running === false, 5000, "clean-exit mark written")
        }
        function views() { return browser.tabs.views }

        function cleanup() { destroyBrowser() }

        function test_01_never() {
            seed()
            create({ restoreSession: "never", initialUrls: [page("cli")] })
            compare(browser.tabs.count, 1)
            verify(!browser.sessionRestored)
            tryCompare(browser, "title", "cli", 15000)
            verify(browser.sessionStore.hasSavedSession)
            compare(browser.controller.closedTabs.map(c => c.title), ["C1"], "closed tabs are always kept")

            // The previous session is still available.
            verify(browser.actions.action("session.restore").enabled)
            verify(browser.trigger("session.restore"))
            compare(browser.tabs.count, 4, "added after the open tabs")
            compare(browser.tabs.currentIndex, 2, "saved current tab selected")
            compare(views()[1].title, "S1")
            verify(views()[1].discarded)
            compare(views()[3].url.toString(), root.asUrl(browser.newTabUrl), "internal tab restored as the new-tab page")
            verify(!browser.actions.action("session.restore").enabled)
            tryCompare(browser, "title", "s2", 15000)
        }

        function test_02_always_with_initial_urls() {
            seed()
            create({ restoreSession: "always", initialUrls: [page("cli")] })
            verify(browser.sessionRestored)
            compare(browser.tabs.count, 4, "session, then the command-line URL")
            compare(browser.tabs.currentIndex, 3, "the command-line URL is selected")
            tryCompare(browser, "title", "cli", 15000)
            compare(views()[0].title, "S1", "saved title until selected")
            compare(views()[2].title, "New Tab")
            verify(views()[0].discarded)
            verify(!views()[1].discarded, "the saved current tab loads")
            verify(views()[2].discarded)
            compare(views()[2].url.toString(), root.asUrl(browser.newTabUrl))
            tryCompare(views()[1], "title", "s2", 15000)

            wait(300)
            verify(!views()[0].ready, "background tabs stay unloaded")
            browser.tabs.currentIndex = 0
            tryCompare(views()[0], "title", "s1", 15000)
            verify(!browser.actions.action("session.restore").enabled, "nothing more to restore")
        }

        function test_03_if_crashed() {
            seed({ running: true })
            create({ restoreSession: "ifCrashed" })
            verify(browser.sessionStore.crashed)
            verify(browser.sessionRestored)
            compare(browser.tabs.count, 3)
            compare(browser.tabs.currentIndex, 1)
            tryCompare(browser, "title", "s2", 15000)
            destroyBrowser()

            // Clean exit: a home tab, and the session can still be restored.
            seed()
            create({ restoreSession: "ifCrashed" })
            verify(!browser.sessionStore.crashed)
            verify(!browser.sessionRestored)
            compare(browser.tabs.count, 1)
            tryCompare(browser, "title", "New Tab", 15000)
            verify(browser.trigger("session.restore"))
            compare(browser.tabs.count, 4)
        }

        function test_04_keep_one_tab() {
            seed()
            create({ restoreSession: "never" })
            compare(browser.tabs.count, 1)
            // Replacing the tabs does not count as closing the last one.
            const snap = { tabs: [{ url: page("k1"), title: "K1" }], current: 0 }
            compare(browser.sessionStore.restore({ replace: true, session: snap }).length, 1)
            compare(browser.tabs.count, 1)
            tryCompare(browser, "title", "k1", 15000)
            verify(browser.sessionStore.hasSavedSession, "an explicit session leaves `saved` alone")
            // Closing the last tab opens a new-tab page; the closed one is remembered.
            browser.controller.closeTab(0)
            compare(browser.tabs.count, 1)
            compare(views()[0].url.toString(), root.asUrl(browser.newTabUrl))
            const closed = browser.controller.closedTabs
            compare(closed[closed.length - 1].title, "k1")
            tryVerify(() => {
                const d = readFile("tst-session-browser")
                return d.tabs && d.tabs.length === 1 && d.tabs[0].internal === true
            }, 5000, "the new-tab page is saved without its URL")
            compare(readFile("tst-session-browser").tabs[0].url, "")
        }

        function test_05_policy_off_and_no_store() {
            seed({ running: true })
            create({ restoreSession: "never" })
            verify(browser.sessionStore.crashed)
            verify(!browser.sessionRestored)
            compare(browser.tabs.count, 1)
            destroyBrowser()

            seed({ running: true })
            create({ sessionStore: null, restoreSession: "always", initialUrls: [page("cli")] })
            compare(browser.tabs.count, 1)
            verify(!browser.actions.action("session.restore").enabled)
            tryCompare(browser, "title", "cli", 15000)
            browser.destroy()
            browser = null
            wait(100)
            compare(readFile("tst-session-browser").running, true, "no store, file untouched")
        }

        function test_06_tab_menu() {
            seed()
            create({ restoreSession: "never", initialUrls: [page("m0"), page("m1"), page("m2")] })
            tryVerify(() => views().every(v => v.title.startsWith("m")), 15000)
            const tab1 = findChild(browser.tabStrip, "tab1")
            verify(tab1)
            mouseClick(tab1, tab1.width / 2, tab1.height / 2, Qt.RightButton)
            const menu = browser.tabMenu
            tryVerify(() => menu.opened, 2000, "right click opens the tab menu")
            compare(browser.tabs.currentIndex, 0, "right click does not select")
            verify(menu.trigger(menu.indexOfLabel("Discard tab")))
            verify(views()[1].discarded)

            mouseClick(tab1, tab1.width / 2, tab1.height / 2, Qt.RightButton)
            tryVerify(() => menu.opened, 2000)
            const discard = menu.entries[menu.indexOfLabel("Discard tab")]
            compare(discard.enabled, false, "already discarded")
            verify(menu.trigger(menu.indexOfLabel("Close other tabs")))
            compare(browser.tabs.count, 1)
            compare(views()[0].title, "m1")
            compare(browser.controller.closedTabs.slice(-2).map(c => c.title), ["m0", "m2"])

            // The recently closed menu, from its action.
            verify(browser.trigger("tab.recentlyClosed"))
            const rc = browser.recentlyClosedMenu
            tryVerify(() => rc.opened, 2000)
            compare(rc.entries[0].label, "m2")
            compare(rc.entries[1].label, "m0")
            verify(rc.trigger(1))
            compare(browser.tabs.count, 2)
            compare(views()[0].url.toString(), page("m0"))
            compare(browser.tabs.currentIndex, 0)
            tryCompare(browser, "title", "m0", 15000)

            // Discard other tabs.
            verify(browser.trigger("tab.discardOthers"))
            verify(views()[1].discarded)
            verify(!views()[0].discarded)
        }

        function cleanupTestCase() {
            destroyBrowser()
            for (const n of ["tst-session-a", "tst-session-b", "tst-session-dup", "tst-session-browser"])
                verify(writeFile(n, {}))
        }
    }
}
