// Browsing history (HistoryStore), address-bar suggestions and the history
// page. Pages are data: URLs, so no network.
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
    readonly property real day: 24 * 60 * 60 * 1000

    // --- Store and recording ------------------------------------------------

    HistoryStore {
        id: store
        path: "test-history/history.json"
        saveDelay: 50
        ignoreUrl: u => u.indexOf("ignore-me") >= 0
    }

    WebTabs {
        id: tabs
        width: 400
        height: 300
        historyStore: store
    }

    TestCase {
        name: "HistoryStore"
        when: windowShown

        function view() { return tabs.currentView }
        function load(url) {
            const v = view()
            let done = false
            const f = () => done = true
            v.loadFinished.connect(f)
            v.url = url
            tryVerify(() => done, 10000, "loaded " + url)
            v.loadFinished.disconnect(f)
        }

        function init() {
            store.enabled = true
            store.recording = true
            store.maxEntries = 20000
            store.maxAgeDays = 90
            store.clear()
            compare(store.count, 0)
        }

        function test_01_records_navigations() {
            if (tabs.count === 0) tabs.openTab(page("blank"))
            tryVerify(() => tabs.currentView && store.isAttached(tabs.currentView), 5000)
            store.clear()
            const a = page("Alpha page"), b = page("Beta page")
            load(a)
            tryVerify(() => store.contains(a), 5000)
            compare(store.entry(a).title, "Alpha page")
            compare(store.entry(a).visitCount, 1)
            load(b)
            tryVerify(() => store.contains(b), 5000)
            compare(store.get(0).url, store.normalizeUrl(b), "newest first")
            compare(store.get(1).url, store.normalizeUrl(a))
            load(a)
            tryVerify(() => store.entry(a).visitCount === 2, 5000)
            compare(store.get(0).url, store.normalizeUrl(a), "a visit moves the entry to the top")
            // A reload refreshes the time but does not count as a visit.
            const before = store.entry(a).lastVisit
            wait(5)
            let done = false
            const f = () => done = true
            view().loadFinished.connect(f)
            view().reload()
            tryVerify(() => done, 10000)
            view().loadFinished.disconnect(f)
            compare(store.entry(a).visitCount, 2)
            verify(store.entry(a).lastVisit >= before)
            compare(store.count, 2)
        }

        function test_02_title_updates() {
            const u = page("Initial", "<script>setTimeout(() => document.title = 'Changed', 100)</script>")
            load(u)
            tryVerify(() => store.contains(u), 5000)
            tryVerify(() => store.entry(u).title === "Changed", 5000, store.entry(u).title)
            // Pages without a title get no URL-as-title.
            const plain = "data:text/html,no%20title"
            load(plain)
            tryVerify(() => store.contains(plain), 5000)
            compare(store.entry(plain).title, "")
        }

        function test_03_ignores_internal_and_failed() {
            load(page("before"))
            load("about:blank")
            load(page("ignore-me"))
            load("http://127.0.0.1:1/")   // connection refused: error page
            load(page("after"))
            tryVerify(() => store.contains(page("after")), 5000)
            verify(!store.contains("about:blank"))
            verify(!store.contains(page("ignore-me")))
            verify(!store.contains("http://127.0.0.1:1/"))
            compare(store.count, 2)
            verify(!store.recordVisit("javascript:alert(1)"))
            verify(!store.recordVisit("chrome://version"))
            verify(!store.isRecordable("data:text/html," + "x".repeat(5000)), "too long")
        }

        function test_04_private_mode() {
            store.recording = false
            load(page("secret"))
            wait(200)
            verify(!store.contains(page("secret")))
            verify(!store.recordVisit("https://example.com/"))
            store.recording = true
            load(page("public"))
            tryVerify(() => store.contains(page("public")), 5000)
            // Disabled: no recording and no search results.
            store.enabled = false
            load(page("public2"))
            wait(200)
            verify(!store.contains(page("public2")))
            compare(store.search("public").length, 0)
            store.enabled = true
            compare(store.search("public").length, 1)
        }

        function test_05_typed() {
            store.markTyped(view())
            load(page("typed"))
            tryVerify(() => store.contains(page("typed")), 5000)
            compare(store.entry(page("typed")).typedCount, 1)
            load(page("clicked"))
            tryVerify(() => store.contains(page("clicked")), 5000)
            compare(store.entry(page("clicked")).typedCount, 0)
        }

        function test_06_search_ranking() {
            const now = Date.now()
            store.recordVisit("https://news.example.com/", { title: "Example News", time: now - 60000 })
            for (let i = 0; i < 5; ++i)
                store.recordVisit("https://blog.test/about-news", { title: "About", time: now - 1000 })
            store.recordVisit("https://newsy.org/", { title: "Newsy", typed: true, time: now - 120000 })
            store.recordVisit("https://old.example.com/news", { title: "Old news", time: now - 60 * day })
            store.recordVisit("https://www.github.com/", { title: "GitHub" })

            let r = store.search("news", 10)
            compare(r.length, 4)
            // Host prefix beats a high visit count deeper in the URL.
            verify(r[0].url === "https://newsy.org/" || r[0].url === "https://news.example.com/", r[0].url)
            verify(r.findIndex(e => e.url === "https://old.example.com/news") > r.findIndex(e => e.url === "https://blog.test/about-news"))
            verify(r[0].score > 0)
            // Every word has to match (url or title).
            r = store.search("example old", 10)
            compare(r.length, 1)
            compare(r[0].url, "https://old.example.com/news")
            r = store.search("GIT", 10)
            compare(r[0].url, "https://www.github.com/", "www. is ignored for prefix matches, case-insensitive")
            compare(store.search("news", 2).length, 2, "limit")
            compare(store.search("", 3).length, 3, "empty text: top entries")
            compare(store.search("nothing-matches").length, 0)
        }

        function test_07_inline_completion() {
            store.recordVisit("https://example.com/a/page", { title: "A" })
            store.recordVisit("https://example.com/b", { title: "B" })
            store.recordVisit("https://www.exa.org/", { title: "Exa", time: Date.now() - 50 * day })
            let c = store.inlineCompletion("exa")
            compare(c.text, "example.com/")
            compare(c.completion, "mple.com/")
            compare(c.url, "https://example.com/")
            c = store.inlineCompletion("ExA")
            compare(c.text, "ExAmple.com/", "keeps the typed case")
            c = store.inlineCompletion("www.exam")
            compare(c.text, "www.example.com/")
            c = store.inlineCompletion("https://exam")
            compare(c.text, "https://example.com/")
            c = store.inlineCompletion("example.com/a")
            compare(c.text, "example.com/a/page")
            compare(c.url, "https://example.com/a/page")
            compare(store.inlineCompletion("example.com/"), store.inlineCompletion("example.com/"))
            verify(!store.inlineCompletion("zzz"))
            verify(!store.inlineCompletion("exa mple"), "no completion with spaces")
            verify(!store.inlineCompletion(""))
            store.recordVisit(page("Data page"))
            c = store.inlineCompletion("data:text/html,<title>Da")
            compare(c.text, "data:text/html,<title>Data page</title><body style='margin:0'>")
            compare(c.url, store.normalizeUrl(page("Data page")))
        }

        function test_08_remove_and_clear() {
            const now = Date.now()
            store.recordVisit("https://a.test/", { time: now - 3 * day })
            store.recordVisit("https://b.test/", { time: now - 2 * 3600000 })
            store.recordVisit("https://c.test/", { time: now - 60000 })
            store.recordVisit("https://d.test/")
            verify(store.remove("https://d.test/"))
            verify(!store.remove("https://d.test/"))
            compare(store.count, 3)
            compare(store.clear(now - 3600000), 1, "last hour")
            verify(!store.contains("https://c.test/"))
            compare(store.clear(new Date(now - 4 * day)), 2, "Date argument")
            compare(store.count, 0)
        }

        function test_09_pruning() {
            const now = Date.now()
            for (let i = 0; i < 10; ++i)
                store.recordVisit("https://p" + i + ".test/", { time: now - i * 1000 })
            store.recordVisit("https://ancient.test/", { time: now - 100 * day })
            verify(!store.contains("https://ancient.test/"), "older than maxAgeDays")
            compare(store.count, 10)
            store.recordVisit("https://old.test/", { time: now - 40 * day })
            compare(store.get(store.count - 1).url, "https://old.test/", "kept in time order")
            store.maxAgeDays = 30
            verify(!store.contains("https://old.test/"))
            store.maxEntries = 5
            compare(store.count, 5)
            verify(store.contains("https://p0.test/"))
            verify(!store.contains("https://p5.test/"), "the oldest are dropped")
            store.recordVisit("https://new.test/")
            compare(store.count, 5)
            verify(!store.contains("https://p4.test/"))
        }

        function test_10_persistence() {
            store.recordVisit("https://persist.test/x", { title: "Persisted", typed: true })
            store.recordVisit("https://persist.test/x")
            store.setIcon("https://persist.test/x", "https://persist.test/favicon.ico")
            verify(store.save())
            const copy = Qt.createQmlObject('import CefQml; HistoryStore { path: "test-history/history.json" }', root)
            tryVerify(() => copy.loaded, 5000)
            compare(copy.count, 1)
            const e = copy.entry("https://persist.test/x")
            compare(e.title, "Persisted")
            compare(e.visitCount, 2)
            compare(e.typedCount, 1)
            compare(e.icon, "https://persist.test/favicon.ico")
            copy.destroy()
            // Debounced autosave + reload().
            store.recordVisit("https://persist.test/y")
            tryVerify(() => {
                const c = Qt.createQmlObject('import CefQml; HistoryStore { path: "test-history/history.json" }', root)
                const ok = c.contains("https://persist.test/y")
                c.destroy()
                return ok
            }, 5000, "autosaved")
            store.remove("https://persist.test/y")
            verify(store.save())
            verify(store.reload())
            compare(store.count, 1)
            verify(store.filePath.endsWith("/test-history/history.json"))
        }

        function test_11_model() {
            const now = Date.now()
            store.recordVisit("https://m1.test/", { title: "One", time: now - 2 * day })
            store.recordVisit("https://m2.test/", { title: "Two", time: now })
            compare(store.count, 2)
            const filtered = Qt.createQmlObject('import CefQml; HistoryModel {}', root)
            filtered.store = store
            compare(filtered.count, 2)
            filtered.filterText = "one"
            compare(filtered.count, 1)
            compare(filtered.get(0).url, "https://m1.test/")
            compare(filtered.get(0).day, Qt.formatDate(new Date(now - 2 * day), "yyyy-MM-dd"))
            store.recordVisit("https://m3.test/one-more")
            compare(filtered.count, 2)
            compare(filtered.get(0).url, "https://m3.test/one-more")
            filtered.filterText = ""
            compare(filtered.count, 3)
            filtered.destroy()
        }

        function test_11b_same_document_navigation() {
            // history.pushState() to a new URL is a visit; a fragment change
            // is not. (data: documents cannot pushState, so use a file.)
            const path = Cef.environment("CEF_QML_TEST_DIR") + "/spa.html"
            const xhr = new XMLHttpRequest()
            xhr.open("PUT", "file://" + path)
            xhr.send("<title>SPA</title><script>function go(q) { history.pushState({}, '', q) }</script>")
            tryVerify(() => xhr.readyState === XMLHttpRequest.DONE, 5000)
            const url = "file://" + path
            load(url)
            tryVerify(() => store.contains(url), 5000)
            let out = null
            view().evaluateJavaScript("location.hash = 'frag'; go('?page=2'); location.href", (r, e) => out = [r, e])
            tryVerify(() => out !== null, 5000)
            tryVerify(() => store.contains(url + "?page=2"), 5000, "pushState recorded")
            verify(!store.contains(url + "#frag"))
            compare(store.entry(url + "?page=2").title, "SPA")
            compare(store.count, 2)
        }

        function test_12_large_history() {
            const now = Date.now()
            for (let i = 0; i < 5000; ++i)
                store.recordVisit("https://site" + (i % 500) + ".test/page/" + i, { title: "Page " + i, time: now - i * 1000 })
            const t1 = Date.now()
            compare(store.count, 5000)
            const r = store.search("site42 page", 8)
            const t2 = Date.now()
            verify(r.length > 0)
            verify(store.inlineCompletion("site49"))
            verify(t2 - t1 < 200, "search over 5000 entries took " + (t2 - t1) + " ms")
        }
    }

    // --- Browser: address-bar suggestions -------------------------------------

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
    }

    TestCase {
        name: "AddressSuggestions"
        when: windowShown

        property var history: browser.historyStore
        property var sug: browser.addressSuggestions

        function find(name) {
            const item = findChild(browser, name)
            verify(item, "no child " + name)
            return item
        }
        function view() { return browser.currentView }
        function field() { return find("addressInput") }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item, button) {
            const p = center(item)
            mouseClick(root, p.x, p.y, button || Qt.LeftButton)
        }
        function focusField() {
            if (!field().activeFocus) {
                view().forceActiveFocus()
                keyClick(Qt.Key_L, Qt.ControlModifier)
            }
            tryVerify(() => field().activeFocus, 2000, "Ctrl+L focuses the address field")
        }
        function type(text) {
            for (const ch of text) keyClick(ch)
        }
        function resetTabs(title) {
            mouseMove(root, root.width - 5, root.height - 5)
            browser.hideHistory()
            browser.hideUserScripts()
            browser.historyView.filterText = ""
            browser.tabs.restore([page(title || "start")], 0)
            tryCompare(browser, "title", title || "start", 10000)
            view().forceActiveFocus()
            history.clear()
        }
        function types() { return sug.items.map(i => i.type) }
        // Not find("suggestionN"): replaced rows linger until deferred deletion.
        function row(i) {
            const r = sug.rowAt(i)
            verify(r, "no suggestion row " + i)
            return r
        }

        function initTestCase() {
            tryCompare(browser.tabs, "count", 1, 10000)
            tryCompare(browser, "title", "New Tab", 15000)
        }

        function test_01_browser_records_history() {
            verify(history, "Browser creates a HistoryStore")
            verify(history.isAttached(view()))
            verify(history.filePath.endsWith("/history.json"))
            resetTabs()
            browser.navigate(page("Recorded"))
            tryCompare(browser, "title", "Recorded", 10000)
            tryVerify(() => history.contains(page("Recorded")), 5000)
            // The new-tab page is internal.
            browser.newTab()
            tryCompare(browser, "title", "New Tab", 10000)
            wait(200)
            for (let i = 0; i < history.count; ++i)
                verify(!browser.isNewTabUrl(history.get(i).url), "new-tab page recorded")
            compare(history.count, 1)
        }

        function test_02_keyboard_navigation_and_enter() {
            resetTabs()
            history.recordVisit(page("Alpha one"), { title: "Alpha one" })
            history.recordVisit(page("Alpha two"), { title: "Alpha two" })
            history.recordVisit(page("Beta"), { title: "Beta" })
            focusField()
            type("alpha")
            tryVerify(() => sug.visible, 2000, "popup opens while typing")
            compare(field().text, "alpha", "no inline completion for a non-address")
            compare(types(), ["search", "history", "history"])
            compare(sug.items[0].url, "data:text/html,<title>search</title><p id=q>%s</p>".replace("%s", "alpha"))
            compare(sug.currentIndex, 0)
            verify(row(2))
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(sug.currentIndex, 2)
            keyClick(Qt.Key_Down)
            compare(sug.currentIndex, 2, "stops at the last entry")
            keyClick(Qt.Key_Up)
            compare(sug.currentIndex, 1)
            const target = sug.items[1]
            compare(field().text, "alpha", "arrowing keeps the typed text")
            keyClick(Qt.Key_Return)
            verify(!sug.visible)
            tryCompare(browser, "title", target.title, 10000)
            tryVerify(() => view().activeFocus, 2000, "the page gets focus")
            tryVerify(() => history.entry(target.url).visitCount === 2, 5000)
            compare(history.entry(target.url).typedCount, 1, "opened from the address bar: typed")

            // Enter on the default entry searches.
            focusField()
            type("alpha")
            tryVerify(() => sug.visible, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "search", 10000)
        }

        function test_03_escape() {
            resetTabs()
            history.recordVisit(page("Alpha one"))
            const url = field().text
            focusField()
            type("alp")
            tryVerify(() => sug.visible, 2000)
            keyClick(Qt.Key_Escape)
            verify(!sug.visible, "first Escape closes the popup")
            compare(field().text, "alp")
            verify(field().activeFocus)
            keyClick(Qt.Key_Escape)
            compare(field().text, url, "second Escape restores the URL")
            compare(field().selectedText, url)
            verify(field().activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => view().activeFocus, 2000, "third Escape returns to the page")
            // Focus loss closes the popup.
            focusField()
            type("alp")
            tryVerify(() => sug.visible, 2000)
            view().forceActiveFocus()
            verify(!sug.visible)
        }

        function test_04_inline_autocomplete() {
            resetTabs()
            history.recordVisit("https://example.com/foo", { title: "Example" })
            history.recordVisit("https://example.com/bar", { title: "Example bar" })
            focusField()
            type("exa")
            compare(field().text, "example.com/")
            compare(field().selectedText, "mple.com/", "the completed part is selected")
            compare(sug.items[0].url, "https://example.com/")
            compare(sug.items[0].type, "history")
            type("m")
            compare(field().text, "example.com/", "typing over the completion keeps completing")
            compare(field().selectedText, "ple.com/")
            keyClick(Qt.Key_Backspace)
            compare(field().text, "exam", "Backspace removes the completion")
            compare(field().selectedText, "")
            keyClick(Qt.Key_Backspace)
            compare(field().text, "exa", "and does not complete again")
            type("m")
            compare(field().text, "example.com/")
            keyClick(Qt.Key_Delete)
            compare(field().text, "exam", "Delete removes the completion too")
            type("ple.com/f")
            compare(field().text, "example.com/foo", "with a path: completes the URL")
            compare(field().selectedText, "oo")
            keyClick(Qt.Key_Escape)
            compare(field().text, "example.com/f", "Escape drops the completion")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryVerify(() => view().activeFocus, 2000)

            // Enter accepts the completion (a data: URL, no network).
            history.recordVisit(page("Gamma page"))
            focusField()
            type("data:text/html,<title>ga")
            compare(field().text, "data:text/html,<title>gamma page</title><body style='margin:0'>", "typed case kept")
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "Gamma page", 10000)
            tryVerify(() => history.entry(page("Gamma page")).typedCount === 1, 5000)
            sug.inlineCompletion = false
            focusField()
            type("exa")
            compare(field().text, "exa", "inlineCompletion: false")
            sug.inlineCompletion = true
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
        }

        function test_05_switch_to_tab() {
            resetTabs("Tab One")
            const other = browser.openTab(page("Other Zeta"), { background: true })
            tryCompare(other, "title", "Other Zeta", 10000)
            compare(browser.tabs.currentIndex, 0)
            history.clear()
            focusField()
            type("zeta")
            tryVerify(() => sug.visible, 2000)
            compare(types(), ["search", "tab"])
            compare(sug.items[1].subtitle, "Switch to tab")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(browser.tabs, "currentIndex", 1, 2000)
            compare(browser.tabs.count, 2, "no new tab")
            tryVerify(() => other.activeFocus, 2000)
            // The current tab is not offered; mouse click selects too.
            focusField()
            type("tab one")
            tryVerify(() => sug.visible, 2000)
            compare(types(), ["search", "tab"])
            click(row(1))
            tryCompare(browser.tabs, "currentIndex", 0, 2000)
            compare(browser.tabs.count, 2)
        }

        function test_06_custom_provider_and_mouse() {
            resetTabs()
            let actions = 0
            const bookmarks = {
                suggest: text => text.startsWith("bm") ? [
                    { type: "bookmark", title: "My bookmark", url: page("Bookmarked") },
                    { type: "command", title: "Run command", action: () => actions++ }
                ] : []
            }
            const later = text => new Promise(resolve => resolve(text.startsWith("bm") ? [{ title: "Async result", url: page("Async") }] : []))
            sug.addProvider(bookmarks, 0)
            sug.addProvider(later)
            try {
                focusField()
                type("bm")
                tryVerify(() => sug.visible, 2000)
                tryVerify(() => types().join() === "search,bookmark,command,custom", 2000, types().join())
                compare(sug.items[1].title, "My bookmark")
                // Hover moves the selection; click opens.
                const row2 = row(2)
                const p = center(row2)
                mouseMove(root, p.x, p.y - 8)
                mouseMove(root, p.x, p.y)
                tryCompare(sug, "currentIndex", 2, 2000)
                mouseClick(root, p.x, p.y)
                compare(actions, 1, "action items run their action")
                verify(!sug.visible)
                compare(field().text, field().selectedText, "and the URL is shown again, selected")
                focusField()
                type("bm")
                tryVerify(() => sug.items.length === 4, 2000)
                click(row(1))
                tryCompare(browser, "title", "Bookmarked", 10000)
                tryVerify(() => history.contains(page("Bookmarked")), 5000)
                compare(history.entry(page("Bookmarked")).typedCount, 0, "provider items are not 'typed'")
                // Middle click / Alt+Enter: new tab.
                focusField()
                type("bm")
                tryVerify(() => sug.items.length === 4, 2000)
                click(row(3), Qt.MiddleButton)
                tryCompare(browser.tabs, "count", 2, 5000)
                tryCompare(browser, "title", "Async", 10000)
                focusField()
                type("bm")
                tryVerify(() => sug.items.length === 4, 2000)
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Return, Qt.AltModifier)
                tryCompare(browser.tabs, "count", 3, 5000)
                tryCompare(browser, "title", "Bookmarked", 10000)
            } finally {
                sug.removeProvider(bookmarks)
                sug.removeProvider(later)
            }
            compare(sug.providers.length, 4)
        }

        function test_07_shift_delete_removes_history() {
            resetTabs()
            history.recordVisit(page("Removable one"))
            history.recordVisit(page("Removable two"))
            focusField()
            type("removable")
            tryVerify(() => sug.visible, 2000)
            compare(types(), ["search", "history", "history"])
            keyClick(Qt.Key_Down)
            const url = sug.items[1].url
            keyClick(Qt.Key_Delete, Qt.ShiftModifier)
            verify(!history.contains(url))
            compare(types(), ["search", "history"])
            compare(sug.currentIndex, 1)
            compare(field().text, "removable", "text unchanged")
            // Not removable: the search entry.
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Delete, Qt.ShiftModifier)
            compare(types(), ["search", "history"])
            // The × button.
            const x = findChild(row(1), "suggestionRemove1")
            sug.currentIndex = 1
            tryVerify(() => x.visible, 2000)
            click(x)
            compare(history.count, 0)
            compare(types(), ["search"])
            keyClick(Qt.Key_Escape)
        }

        function test_08_history_view_keyboard_and_ctrl_h() {
            resetTabs()
            const now = Date.now()
            history.recordVisit(page("Charlie visit"), { title: "Charlie visit", time: now - 3 * root.day })
            history.recordVisit(page("Bravo visit"), { title: "Bravo visit", time: now - root.day })
            history.recordVisit(page("Alpha visit"), { title: "Alpha visit", time: now })
            const hv = browser.historyView
            const overlay = find("historyOverlay")
            const search = find("historySearch")
            verify(!browser.historyVisible)
            verify(!browser.actions.action("history.show").checked)
            keyClick(Qt.Key_H, Qt.ControlModifier)
            tryVerify(() => browser.historyVisible, 2000, "Ctrl+H shows the history")
            verify(overlay.visible)
            verify(browser.actions.action("history.show").checked)
            tryVerify(() => search.activeFocus, 2000, "the search field has focus")
            compare(hv.count, 3)
            compare(hv.entryAt(0).title, "Alpha visit", "newest first")
            compare(hv.entryAt(2).title, "Charlie visit")
            compare(hv.dayLabel(hv.entryAt(0).day), "Today")
            compare(hv.dayLabel(hv.entryAt(1).day), "Yesterday")
            verify(hv.dayLabel(hv.entryAt(2).day).length > 9, "older days show the date")
            compare(find("historyList").section.property, "day")
            verify(hv.rowAt(2), "rows are created")
            compare(hv.currentIndex, -1)

            // Searching filters and selects the first match.
            type("bravo")
            compare(hv.filterText, "bravo")
            compare(hv.count, 1)
            compare(hv.currentIndex, 0)
            compare(hv.entryAt(0).title, "Bravo visit")
            keyClick(Qt.Key_Escape)
            compare(hv.filterText, "", "the first Escape clears the search")
            verify(browser.historyVisible)
            compare(hv.count, 3)

            // Arrows, Shift+Delete, Enter.
            type("visit")
            compare(hv.currentIndex, 0)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(hv.currentIndex, 2, "stops at the last row")
            keyClick(Qt.Key_Up)
            compare(hv.currentIndex, 1)
            keyClick(Qt.Key_Delete, Qt.ShiftModifier)
            verify(!history.contains(page("Bravo visit")))
            compare(hv.count, 2)
            compare(hv.currentIndex, 1)
            compare(hv.filterText, "visit", "the search text is kept")
            compare(hv.entryAt(1).title, "Charlie visit")
            keyClick(Qt.Key_Return)
            tryVerify(() => !browser.historyVisible, 2000, "opening closes the overlay")
            tryCompare(browser, "title", "Charlie visit", 10000)
            tryVerify(() => view().activeFocus, 2000, "the page gets focus back")

            // Ctrl+H toggles, also while typing in the search field.
            keyClick(Qt.Key_H, Qt.ControlModifier)
            tryVerify(() => browser.historyVisible && search.activeFocus, 2000)
            keyClick(Qt.Key_H, Qt.ControlModifier)
            tryVerify(() => !browser.historyVisible, 2000, "Ctrl+H hides it again")
            browser.trigger("history.show")
            tryVerify(() => search.activeFocus, 2000)
            hv.filterText = ""
            keyClick(Qt.Key_Escape)
            verify(!browser.historyVisible, "Escape with an empty search closes")
            tryVerify(() => view().activeFocus, 2000)

            // One manager overlay at a time.
            browser.showHistory()
            verify(browser.historyVisible)
            browser.trigger("userscripts.manage")
            verify(browser.userScriptManagerVisible)
            verify(!browser.historyVisible, "opening the userscript manager closes the history")
            browser.showHistory()
            verify(!browser.userScriptManagerVisible, "and the other way round")
            browser.hideHistory()
            verify(!browser.historyVisible)
        }

        function test_09_history_view_mouse_and_clear() {
            resetTabs()
            const now = Date.now()
            history.recordVisit(page("Old one"), { title: "Old one", time: now - 2 * 3600 * 1000 })
            history.recordVisit(page("Mouse one"), { title: "Mouse one", time: now - 1000 })
            history.recordVisit(page("Mouse two"), { title: "Mouse two", time: now })
            const hv = browser.historyView
            browser.showHistory()
            tryVerify(() => find("historySearch").activeFocus, 2000)
            compare(hv.count, 3)

            // Click opens in the current tab and closes the overlay.
            click(hv.rowAt(0))
            tryVerify(() => !browser.historyVisible, 2000)
            tryCompare(browser, "title", "Mouse two", 10000)
            compare(browser.tabs.count, 1)

            // Middle click opens a background tab and keeps the overlay.
            browser.showHistory()
            tryCompare(hv, "count", 3, 5000)
            compare(hv.entryAt(1).title, "Mouse one")
            click(hv.rowAt(1), Qt.MiddleButton)
            tryCompare(browser.tabs, "count", 2, 5000)
            verify(browser.historyVisible)
            compare(browser.tabs.currentIndex, 0, "opened in the background")
            tryCompare(browser.tabs.views[1], "title", "Mouse one", 10000)
            tryVerify(() => history.entry(page("Mouse one")).visitCount === 2, 5000)
            compare(hv.entryAt(0).title, "Mouse one", "background tabs are recorded too")

            // × removes one entry.
            compare(hv.count, 3)
            const top = hv.entryAt(0).url
            click(findChild(hv.rowAt(0), "historyRemove"))
            verify(!history.contains(top))
            compare(hv.count, 2)

            // Clear history: last hour keeps the older entry, then everything.
            const clear = find("historyClear")
            click(clear)
            verify(hv.clearing)
            click(find("historyClearCancel"))
            verify(!hv.clearing)
            compare(history.count, 2)
            click(clear)
            click(find("historyClearHour"))
            verify(!hv.clearing)
            compare(history.count, 1)
            compare(history.get(0).title, "Old one")
            compare(hv.status, "Removed 1 entry")
            click(clear)
            click(find("historyClearAll"))
            compare(history.count, 0)
            compare(hv.count, 0)
            verify(find("historyEmpty").visible)
            verify(!clear.enabled, "nothing left to clear")

            // A click on the dimmed backdrop closes the overlay.
            const panel = find("historyOverlay").panelItem
            const p = panel.mapToItem(root, -40, panel.height / 2)
            mouseClick(root, p.x, p.y)
            tryVerify(() => !browser.historyVisible, 2000)
            tryVerify(() => view().activeFocus, 2000)
        }
    }
}
