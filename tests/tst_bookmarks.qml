// Bookmarks: BookmarkStore / BookmarkModel, the star button, the bookmarks
// bar, address-bar suggestions and the bookmark manager. Pages are data:
// URLs, so no network.
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 1100
    height: 750

    function page(title, body) {
        return "data:text/html," + encodeURIComponent("<title>" + title + "</title><body style='margin:0'>" + (body || ""))
    }

    // --- Store ---------------------------------------------------------------

    BookmarkStore {
        id: store
        path: "test-bookmarks/bookmarks.json"
        saveDelay: 20
    }

    BookmarkModel { id: barModel; store: store; folder: store.barFolder }
    BookmarkModel { id: treeModel; store: store; folder: store.rootFolder; recursive: true; foldersOnly: true }

    SignalSpy { id: changedSpy; target: store; signalName: "changed" }
    SignalSpy { id: insertSpy; target: barModel; signalName: "rowsInserted" }
    SignalSpy { id: moveSpy; target: barModel; signalName: "rowsMoved" }
    SignalSpy { id: resetSpy; target: barModel; signalName: "modelReset" }

    TestCase {
        name: "BookmarkStore"

        function init() {
            store.clear()
            compare(store.count, 0)
            compare(store.folderCount, 0)
        }

        function ids(model) {
            const out = []
            for (let i = 0; i < model.count; ++i) out.push(model.get(i).id)
            return out
        }

        function test_01_roots() {
            const roots = store.children(store.rootFolder)
            compare(roots.length, 2)
            compare(roots[0].id, "bar")
            compare(roots[0].title, "Bookmarks bar")
            compare(roots[1].id, "other")
            compare(roots[1].title, "Other bookmarks")
            verify(store.isFolder("bar"))
            // Built-in folders cannot be removed, moved or renamed.
            verify(!store.remove("bar"))
            verify(!store.move("other", "bar"))
            store.update("bar", { title: "x" })
            compare(store.get("bar").title, "Bookmarks bar")
            compare(store.defaultFolder, "bar")
        }

        function test_02_add_get_update_remove() {
            changedSpy.clear()
            const id = store.add("https://example.com", "Example", { icon: "data:image/png;base64,AA==" })
            verify(id !== "")
            compare(changedSpy.count, 1)
            compare(store.count, 1)
            const b = store.get(id)
            compare(b.url, "https://example.com/", "normalized like views report it")
            compare(b.title, "Example")
            compare(b.type, "bookmark")
            compare(b.parent, "bar")
            compare(b.position, 0)
            compare(b.icon, "data:image/png;base64,AA==")
            verify(Math.abs(b.dateAdded - Date.now()) < 60000)
            verify(store.isBookmarked("https://example.com/"))
            verify(store.isBookmarked("https://example.com"))
            verify(!store.isBookmarked("https://example.org/"))
            compare(store.bookmarksFor("https://example.com").length, 1)

            verify(store.update(id, { title: "Renamed", url: "https://example.org/x" }))
            compare(store.get(id).title, "Renamed")
            verify(store.isBookmarked("https://example.org/x"))
            verify(!store.isBookmarked("https://example.com/"))
            verify(!store.update(id, { url: "not a url" }), "invalid URLs are rejected")

            compare(store.add("", "nothing"), "")
            compare(store.add("https://a.test/", "x", { folder: "nope" }), "")
            compare(store.add("https://a.test/", "x", { folder: id }), "", "not a folder")

            verify(store.remove(id))
            compare(store.count, 0)
            verify(store.get(id) === undefined)
            verify(!store.remove(id))
        }

        function test_03_tree_and_positions() {
            const a = store.add("https://a.test/", "A")
            const b = store.add("https://b.test/", "B")
            const f = store.addFolder("Folder")
            const c = store.add("https://c.test/", "C", { folder: f })
            const d = store.add("https://d.test/", "D", { folder: f, index: 0 })
            const e = store.add("https://e.test/", "E", { index: 1 })
            compare(store.folderCount, 1)
            compare(store.count, 5)
            compare(store.children("bar").map(n => n.id), [a, e, b, f])
            compare(store.children(f).map(n => n.title), ["D", "C"])
            compare(store.get(c).path, ["Bookmarks bar", "Folder"])
            compare(store.get(f).childCount, 2)
            compare(ids(barModel), [a, e, b, f])
            compare(barModel.get(3).isFolder, true)
            compare(store.urls("bar"), ["https://a.test/", "https://e.test/", "https://b.test/",
                                        "https://d.test/", "https://c.test/"])
            const sub = store.addFolder("Sub", { folder: f })
            compare(store.folders().map(x => x.title + x.depth),
                    ["Bookmarks bar0", "Folder1", "Sub2", "Other bookmarks0"])
            compare(ids(treeModel), ["bar", f, sub, "other"])
            compare(treeModel.get(2).depth, 2)
            verify(store.isAncestor(f, sub))
            verify(!store.isAncestor(sub, f))

            // Removing a folder removes its contents.
            verify(store.remove(f))
            compare(store.count, 3)
            compare(store.folderCount, 0)
            verify(!store.contains(c) && !store.contains(sub))
        }

        function test_04_move() {
            const a = store.add("https://a.test/", "A")
            const b = store.add("https://b.test/", "B")
            const c = store.add("https://c.test/", "C")
            const f = store.addFolder("F")
            moveSpy.clear(); resetSpy.clear()
            verify(store.move(c, "bar", 0))
            compare(store.children("bar").map(n => n.title), ["C", "A", "B", "F"])
            compare(moveSpy.count, 1, "a single move is a row move")
            verify(store.move(c, "bar", 2))
            compare(store.children("bar").map(n => n.title), ["A", "B", "C", "F"])
            verify(store.move(c, "bar", -1))
            compare(store.children("bar").map(n => n.title), ["A", "B", "F", "C"])
            compare(moveSpy.count, 3)
            compare(resetSpy.count, 0)
            verify(store.move(a, f))
            compare(store.get(a).parent, f)
            compare(store.children("bar").map(n => n.title), ["B", "F", "C"])
            verify(store.move(a, "other", 0))
            compare(store.get(a).parent, "other")
            // Folders cannot move into themselves.
            const g = store.addFolder("G", { folder: f })
            verify(!store.move(f, g))
            verify(!store.move(f, f))
            verify(store.move(g, "other"))
            compare(store.get(g).path, ["Other bookmarks"])
        }

        function test_05_toggle_and_model_rows() {
            insertSpy.clear(); resetSpy.clear()
            verify(store.toggle("https://t.test/", "T"))
            compare(insertSpy.count, 1)
            compare(barModel.count, 1)
            compare(barModel.get(0).title, "T")
            // Also in a second folder: toggling removes both.
            store.add("https://t.test/", "T2", { folder: "other" })
            compare(store.bookmarksFor("https://t.test/").length, 2)
            verify(!store.toggle("https://t.test/"))
            verify(!store.isBookmarked("https://t.test/"))
            compare(barModel.count, 0)
            compare(resetSpy.count, 0)
            store.defaultFolder = "other"
            verify(store.toggle("https://t.test/", "T"))
            compare(store.bookmarksFor("https://t.test/")[0].parent, "other")
            store.defaultFolder = "bar"
            // setIcon updates every bookmark of the URL.
            store.setIcon("https://t.test/", "data:image/png;base64,BB==")
            compare(store.bookmarksFor("https://t.test/")[0].icon, "data:image/png;base64,BB==")
        }

        function test_06_revision_binding() {
            const r = store.revision
            store.add("https://r.test/", "R")
            verify(store.revision > r)
        }

        function test_07_search() {
            store.add("https://news.example.com/", "Daily News")
            store.add("https://example.com/recipes", "Pasta recipes")
            const f = store.addFolder("Work")
            store.add("https://wiki.corp.test/page", "Team wiki", { folder: f })
            store.add("https://renewal.test/", "Renewal")
            let r = store.search("news", 10)
            compare(r.length, 1, "matches title or URL")
            compare(r[0].title, "Daily News")
            r = store.search("ne", 10)
            compare(r[0].title, "Daily News", "prefix matches rank first")
            r = store.search("wiki team", 10)
            compare(r.length, 1, "all words must match")
            compare(r[0].path, ["Bookmarks bar", "Work"])
            verify(r[0].score > 0)
            compare(store.search("example", 10).length, 2)
            compare(store.search("example", 1).length, 1)
            compare(store.search("", 10).length, 4)
            compare(store.search("", 10)[0].title, "Renewal", "newest first without text")
            compare(store.search("wiki", 10, "other").length, 0, "limited to a folder")
            // BookmarkModel filterText searches a subtree.
            barModel.filterText = "recipes"
            compare(barModel.count, 1)
            compare(barModel.get(0).title, "Pasta recipes")
            barModel.filterText = "team"
            compare(barModel.get(0).title, "Team wiki")
            barModel.filterText = ""
            compare(barModel.count, 4)
        }

        function test_08_persistence() {
            const f = store.addFolder("Saved folder")
            const a = store.add("https://saved.test/", "Saved & <sound>", { folder: f, icon: "data:image/png;base64,CC==" })
            store.add("https://other.test/", "Other", { folder: "other" })
            verify(store.save())
            verify(store.filePath.indexOf(Cef.dataDir) === 0, store.filePath)
            const loaded = Qt.createQmlObject(
                'import CefQml; BookmarkStore { path: "test-bookmarks/bookmarks.json" }', root)
            compare(loaded.count, 2)
            compare(loaded.folderCount, 1)
            compare(loaded.get(a).title, "Saved & <sound>")
            compare(loaded.get(a).parent, f)
            compare(loaded.get(a).icon, "data:image/png;base64,CC==")
            compare(loaded.children("other")[0].title, "Other")
            // New ids do not collide with stored ones.
            const n = loaded.add("https://new.test/", "New")
            verify(n !== a && n !== f)
            loaded.destroy()

            // Debounced save, then reload() reads the file again.
            store.add("https://later.test/", "Later")
            const xhr = new XMLHttpRequest
            tryVerify(() => {
                xhr.open("GET", "file://" + store.filePath, false)
                xhr.send()
                return xhr.responseText.indexOf("later.test") > 0
            }, 5000)
            verify(store.reload())
            verify(store.isBookmarked("https://later.test/"))
            compare(store.count, 3)
        }

        function test_09_html_round_trip() {
            const f = store.addFolder("Dev & Docs")
            store.add("https://qt.io/", "Qt <Framework>", { folder: f, icon: "data:image/png;base64,DD==" })
            const sub = store.addFolder("Nested", { folder: f })
            store.add("https://cef.test/?a=1&b=2", "CEF \"quoted\"", { folder: sub })
            store.add("https://bar.test/", "On the bar")
            store.add("https://other.test/", "Other one", { folder: "other" })
            const html = store.exportHtml()
            verify(html.indexOf("<!DOCTYPE NETSCAPE-Bookmark-file-1>") === 0)
            verify(html.indexOf('PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>') > 0)
            verify(html.indexOf("Qt &lt;Framework&gt;") > 0)
            verify(html.indexOf('HREF="https://cef.test/?a=1&amp;b=2"') > 0)
            verify(html.indexOf('ICON="data:image/png;base64,DD=="') > 0)
            const before = store.exportJson()

            store.clear()
            let r = store.importHtml(html)
            verify(r.ok, r.error)
            compare(r.bookmarks, 4)
            compare(r.folders, 2)
            const bar = store.children("bar")
            compare(bar.map(n => n.title), ["Dev & Docs", "On the bar"])
            const dev = store.children(bar[0].id)
            compare(dev[0].title, "Qt <Framework>")
            compare(dev[0].icon, "data:image/png;base64,DD==")
            compare(dev[1].title, "Nested")
            compare(store.children(dev[1].id)[0].url, "https://cef.test/?a=1&b=2")
            compare(store.children(dev[1].id)[0].title, "CEF \"quoted\"")
            compare(store.children("other").map(n => n.title), ["Other one"])
            compare(store.exportHtml(), html, "export(import(export)) is stable")

            // Importing again adds nothing.
            r = store.importHtml(html)
            compare(r.bookmarks, 0)
            compare(r.folders, 0)
            compare(r.skipped, 4)
            compare(store.count, 4)

            // Into a folder.
            const target = store.addFolder("Imported", { folder: "other" })
            r = store.importHtml(html, { folder: target })
            compare(r.bookmarks, 4)
            compare(store.children(target).map(n => n.title), ["Bookmarks bar", "Other one"])

            // replace: clears first.
            r = store.importHtml(html, { replace: true })
            compare(store.count, 4)
            compare(store.folderCount, 2)
        }

        function test_10_foreign_html() {
            // Firefox-style file: lower case tags, a menu folder, unfiled folder,
            // descriptions, place: queries and entities.
            const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<meta charset="UTF-8">\n<title>Bookmarks</title>\n'
                + '<h1>Bookmarks Menu</h1>\n<dl><p>\n'
                + '  <dt><h3 add_date="1600000000">Menu &amp; stuff</h3>\n  <dl><p>\n'
                + '    <dt><a href="https://menu.test/" add_date="1600000001" icon_uri="https://menu.test/fav.ico">Caf&#233; &#x2014; menu</a>\n'
                + '    <dd>A description\n'
                + '    <dt><a href="place:sort=8&maxResults=10">Recent</a>\n'
                + '  </dl><p>\n'
                + '  <dt><h3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</h3>\n  <dl><p>\n'
                + '    <dt><a href="https://toolbar.test">Tool</a>\n'
                + '  </dl><p>\n'
                + '  <dt><h3 UNFILED_BOOKMARKS_FOLDER="true">Other Bookmarks</h3>\n  <dl><p>\n'
                + '    <dt><a href="https://unfiled.test/">Unfiled</a>\n'
                + '  </dl><p>\n'
                + '</dl>\n'
            const r = store.importHtml(html)
            verify(r.ok, r.error)
            compare(r.bookmarks, 3)
            compare(r.skipped, 1, "place: queries are skipped")
            compare(store.children("bar").map(n => n.title), ["Tool"])
            compare(store.children("bar")[0].url, "https://toolbar.test/")
            const other = store.children("other")
            compare(other.map(n => n.title), ["Menu & stuff", "Unfiled"])
            const menu = store.children(other[0].id)[0]
            compare(menu.title, "Café — menu")
            compare(menu.icon, "https://menu.test/fav.ico")
            compare(menu.dateAdded, 1600000001000)

            const bad = store.importHtml("hello")
            verify(!bad.ok)
            verify(bad.error.length > 0)
        }

        function test_11_json_import_export() {
            const f = store.addFolder("J")
            store.add("https://j.test/", "J1", { folder: f })
            store.add("https://o.test/", "O1", { folder: "other" })
            const json = store.exportJson()
            const doc = JSON.parse(json)
            compare(doc.roots.length, 2)
            compare(doc.roots[0].id, "bar")
            compare(doc.roots[0].children[0].children[0].url, "https://j.test/")
            store.clear()
            let r = store.importJson(json)
            verify(r.ok, r.error)
            compare(r.bookmarks, 2)
            compare(store.children("bar")[0].title, "J")
            compare(store.children("other")[0].title, "O1")
            // Objects work too; and Chrome's Bookmarks file.
            store.clear()
            r = store.importJson({ roots: {
                bookmark_bar: { type: "folder", name: "Bookmarks bar", children: [
                    { type: "url", name: "Chrome one", url: "https://chrome.test/", date_added: "13300000000000000" } ] },
                other: { type: "folder", name: "Other", children: [
                    { type: "folder", name: "CF", children: [ { type: "url", name: "Deep", url: "https://deep.test/" } ] } ] } } })
            verify(r.ok, r.error)
            compare(store.children("bar")[0].title, "Chrome one")
            compare(store.children("bar")[0].dateAdded, 13300000000000 - 11644473600000)
            compare(store.children("other")[0].title, "CF")
            verify(!store.importJson("{ nope").ok)
        }

        function test_12_files() {
            store.add("https://file.test/", "File")
            const dir = Cef.environment("CEF_QML_TEST_DIR")
            verify(dir.length > 0)
            verify(store.exportFile(dir + "/bm-export.html"))
            verify(store.exportFile("file://" + dir + "/bm-export.json"))
            store.clear()
            let r = store.importFile(dir + "/bm-export.html")
            verify(r.ok, r.error)
            compare(store.count, 1)
            store.clear()
            r = store.importFile(dir + "/bm-export.json")
            verify(r.ok, r.error)
            compare(store.children("bar")[0].url, "https://file.test/")
            verify(!store.importFile(dir + "/missing.html").ok)
        }

        function cleanupTestCase() {
            store.clear()
            store.save()
        }
    }
}
