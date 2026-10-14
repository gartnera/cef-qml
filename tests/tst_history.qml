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
            const t0 = Date.now()
            for (let i = 0; i < 5000; ++i)
                store.recordVisit("https://site" + (i % 500) + ".test/page/" + i, { title: "Page " + i, time: now - i * 1000 })
            const t1 = Date.now()
            compare(store.count, 5000)
            const r = store.search("site42 page", 8)
            const t2 = Date.now()
            verify(r.length > 0)
            verify(store.inlineCompletion("site49"))
            verify(t2 - t1 < 200, "search over 5000 entries took " + (t2 - t1) + " ms")
            console.log("history: 5000 inserts", t1 - t0, "ms, search", t2 - t1, "ms")
        }
    }
}
