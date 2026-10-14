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

    // --- Browser: star, bar, suggestions, manager ------------------------------

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
    }

    // A bar in a custom layout (no Browser).
    BookmarksBar {
        id: plainBar
        objectName: "plainBar"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 5
        visible: false
        // Only while its test runs (the store suite changes `store`).
        store: visible ? store : null
        showOtherFolder: false
        property var opened: []
        onOpenRequested: (url, newTab) => opened.push([url, newTab])
    }

    TestCase {
        name: "BookmarkUI"
        when: windowShown

        property var bm: browser.bookmarkStore
        property var star: browser.navigationBar.bookmarkButton
        property var bar: browser.bookmarksBar
        property var mgr: browser.bookmarkManager

        function find(parent, name) {
            const item = findChild(parent, name)
            verify(item, "no child " + name)
            return item
        }
        function view() { return browser.currentView }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item, button, modifiers) {
            const p = center(item)
            mouseClick(root, p.x, p.y, button || Qt.LeftButton, modifiers || Qt.NoModifier)
        }
        function type(text) {
            for (const ch of text) keyClick(ch)
        }
        function closePopups() {
            if (star.editor.opened) star.editor.cancel()
            if (bar.editor.opened) bar.editor.cancel()
            if (mgr.editor.opened) mgr.editor.cancel()
            bar.menu.close()
            bar.contextMenu.close()
            browser.hideBookmarks()
            browser.hideHistory()
        }
        function reset(title) {
            mouseMove(root, root.width - 5, root.height - 5)
            closePopups()
            browser.showBookmarksBar = true
            browser.tabs.restore([page(title || "start")], 0)
            tryCompare(browser, "title", title || "start", 10000)
            view().forceActiveFocus()
            bm.clear()
            browser.historyStore.clear()
        }
        // Bookmarks on the bar: [one, two, Folder [inside, Sub [deep]]].
        function fill() {
            const ids = {}
            ids.one = bm.add(page("Bar one"), "Bar one")
            ids.two = bm.add(page("Bar two"), "Bar two")
            ids.folder = bm.addFolder("Folder")
            ids.inside = bm.add(page("Inside"), "Inside", { folder: ids.folder })
            ids.sub = bm.addFolder("Sub", { folder: ids.folder })
            ids.deep = bm.add(page("Deep"), "Deep", { folder: ids.sub })
            tryCompare(bar, "count", 3, 2000)
            waitForLayout(bar)
            return ids
        }
        // The Row places new items at its next polish.
        function waitForLayout(b) {
            tryVerify(() => {
                for (let i = 1; i < b.count; ++i) {
                    const p = b.itemAt(i - 1), it = b.itemAt(i)
                    if (!p || !it || it.x < p.x + p.width) return false
                }
                return true
            }, 2000, "bar laid out")
        }
        function barItem(i) {
            const it = bar.itemAt(i)
            verify(it, "no bar item " + i)
            return it
        }
        function labels(menu) { return menu.entries.map(e => e ? e.label : "-") }

        function initTestCase() {
            tryCompare(browser.tabs, "count", 1, 10000)
            tryCompare(browser, "title", "New Tab", 15000)
        }

        function test_01_browser_defaults() {
            verify(bm, "Browser creates a BookmarkStore")
            verify(bm.filePath.endsWith("/bookmarks.json"), bm.filePath)
            verify(browser.showBookmarksBar)
            verify(bar.visible)
            verify(star.visible)
            verify(bar.y >= browser.navigationBar.y + browser.navigationBar.height, "bar under the navigation bar")
            compare(browser.addressSuggestions.providers.length, 4)
            for (const name of ["bookmark.toggle", "bookmarks.showBar", "bookmarks.manage"])
                verify(browser.actions.action(name), name)
            compare(browser.keyBindings.hint("bookmark.toggle"), "Ctrl+D")
        }

        function test_02_star_follows_navigation() {
            reset("Starred")
            verify(!star.bookmarked)
            compare(star.text, "☆")
            click(star)
            verify(star.bookmarked)
            compare(star.text, "★")
            compare(bm.count, 1)
            const b = bm.bookmarksFor(view().url)[0]
            compare(b.title, "Starred")
            compare(b.parent, bm.barFolder)
            // The editor: rename, Enter saves.
            const ed = star.editor
            verify(ed.opened)
            const card = find(ed, "bookmarkEditor")
            verify(card.visible)
            const name = ed.nameInput
            tryVerify(() => name.activeFocus, 2000)
            compare(name.text, "Starred")
            type("Renamed star")
            keyClick(Qt.Key_Return)
            verify(!ed.opened)
            compare(bm.get(b.id).title, "Renamed star")
            tryCompare(bar, "count", 1, 2000)
            compare(barItem(0).title, "Renamed star")

            // Another page: not bookmarked; back: bookmarked again.
            browser.navigate(page("Unstarred"))
            tryCompare(browser, "title", "Unstarred", 10000)
            verify(!star.bookmarked)
            // The title arrives before the load ends; going back while the
            // page still loads can be dropped.
            tryVerify(() => !view().loading && view().canGoBack, 10000)
            browser.back()
            tryCompare(browser, "title", "Starred", 10000)
            verify(star.bookmarked)
            // Another tab follows its own page.
            browser.openTab(page("Other tab"))
            tryCompare(browser, "title", "Other tab", 10000)
            verify(!star.bookmarked)
            browser.selectTab(0)
            verify(star.bookmarked)

            // Click on a bookmarked page: the editor; Remove deletes it.
            click(star)
            verify(ed.opened)
            click(find(ed, "bookmarkEditorRemove"))
            verify(!ed.opened)
            verify(!star.bookmarked)
            compare(bm.count, 0)
        }

        function test_03_editor_folder_and_cancel() {
            reset("Folder pick")
            const f = bm.addFolder("Picked", { folder: bm.otherFolder })
            click(star)
            const ed = star.editor
            verify(ed.opened)
            click(find(ed, "bookmarkEditorFolder"))
            const list = find(ed, "bookmarkEditorFolderList")
            tryVerify(() => list.visible && list.count === 3, 2000)
            list.forceLayout()
            const row = list.itemAtIndex(2)
            compare(row.folderId, f)
            click(row)
            compare(ed.folder, f)
            click(find(ed, "bookmarkEditorSave"))
            verify(!ed.opened)
            compare(bm.bookmarksFor(view().url)[0].parent, f)
            // Cancel keeps it unchanged; Escape too.
            click(star)
            ed.name = "Not saved"
            click(find(ed, "bookmarkEditorCancel"))
            compare(bm.bookmarksFor(view().url)[0].title, "Folder pick")
            click(star)
            keyClick(Qt.Key_Escape)
            verify(!ed.opened)
            // Invalid URL: stays open with an error.
            click(star)
            ed.url = "   "
            verify(!ed.accept())
            verify(ed.opened)
            verify(find(ed, "bookmarkEditorError").visible)
            ed.cancel()
            // A click outside saves.
            click(star)
            ed.name = "Outside"
            mouseClick(root, 20, root.height - 40)
            verify(!ed.opened)
            compare(bm.bookmarksFor(view().url)[0].title, "Outside")
        }

        function test_04_ctrl_d() {
            reset("Keyboard star")
            const act = browser.actions.action("bookmark.toggle")
            verify(act.enabled)
            verify(!act.checked)
            keyClick(Qt.Key_D, Qt.ControlModifier)
            verify(star.bookmarked)
            verify(act.checked)
            verify(star.editor.opened, "shows the editor like a click")
            keyClick(Qt.Key_Escape)
            verify(!star.editor.opened)
            tryVerify(() => view().activeFocus, 2000, "focus goes back to the page")
            keyClick(Qt.Key_D, Qt.ControlModifier)
            verify(!star.bookmarked, "Ctrl+D again removes it")
            verify(!act.checked)
            compare(bm.count, 0)
            // Through the store alone (no button), e.g. in a custom layout.
            browser.actions.bookmarkButton = null
            try {
                browser.trigger("bookmark.toggle")
                verify(star.bookmarked)
                verify(!star.editor.opened)
                browser.trigger("bookmark.toggle")
                verify(!star.bookmarked)
            } finally {
                browser.actions.bookmarkButton = Qt.binding(() => browser.navigationBar.bookmarkButton)
            }
        }

        function test_05_bar_click_opens() {
            reset("Bar start")
            fill()
            compare(barItem(0).title, "Bar one")
            verify(barItem(2).isFolder)
            verify(barItem(0).fits && barItem(2).fits)
            verify(!find(bar, "bookmarkBarOverflow").visible)
            click(barItem(0))
            tryCompare(browser, "title", "Bar one", 10000)
            compare(browser.tabs.count, 1)
            // Ctrl+click and middle click: background tabs.
            click(barItem(1), Qt.LeftButton, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            compare(browser.title, "Bar one", "opened in the background")
            click(barItem(1), Qt.MiddleButton)
            tryCompare(browser.tabs, "count", 3, 5000)
            compare(browser.tabs.currentIndex, 0)
            tryCompare(browser.tabs.views[1], "title", "Bar two", 10000)
            // Added bookmarks appear, removed ones go.
            bm.add(page("Bar three"), "Bar three")
            tryCompare(bar, "count", 4, 2000)
            compare(barItem(3).title, "Bar three")
            waitForLayout(bar)
            bm.remove(barItem(0).nodeId)
            tryCompare(bar, "count", 3, 2000)
            compare(barItem(0).title, "Bar two")
        }

        function test_06_folder_dropdown() {
            reset("Dropdown start")
            const ids = fill()
            const menu = bar.menu
            click(barItem(2))
            verify(menu.opened)
            compare(menu.folder, ids.folder)
            const panel = menu.panelAt(0)
            verify(panel)
            verify(panel.y >= barItem(2).mapToItem(null, 0, 0).y + barItem(2).height - 1, "drops down below the item")
            let r = menu.rowAt(0, 0)
            compare(r.title, "Inside")
            // A sub-folder opens a sub-menu.
            click(menu.rowAt(0, 1))
            compare(menu.levels.length, 2)
            compare(menu.levels[1].folder, ids.sub)
            r = menu.rowAt(1, 0)
            compare(r.title, "Deep")
            // Escape closes the sub-menu, then the menu.
            keyClick(Qt.Key_Escape)
            compare(menu.levels.length, 1)
            keyClick(Qt.Key_Escape)
            verify(!menu.opened)
            // Click a bookmark in it: opens and closes the menu.
            click(barItem(2))
            click(menu.rowAt(0, 1))
            click(menu.rowAt(1, 0))
            verify(!menu.opened)
            tryCompare(browser, "title", "Deep", 10000)
            // A press outside closes it.
            click(barItem(2))
            verify(menu.opened)
            mouseClick(root, root.width / 2, root.height - 60)
            verify(!menu.opened)
            // Middle click on the folder: its bookmarks in new tabs.
            bm.add(page("Inside 2"), "Inside 2", { folder: ids.folder })
            click(barItem(2), Qt.MiddleButton)
            tryCompare(browser.tabs, "count", 3, 5000)
            verify(!menu.opened)
            // "Open all" in the menu.
            click(barItem(2))
            const all = find(menu.panelAt(0), "bookmarkMenuOpenAll")
            tryVerify(() => all.visible, 2000)
            click(all)
            tryCompare(browser.tabs, "count", 5, 5000)
        }

        function test_07_overflow_chevron() {
            reset("Overflow start")
            for (let i = 0; i < 40; ++i) bm.add(page("Overflow " + i), "Overflowing bookmark " + i)
            tryCompare(bar, "count", 40, 2000)
            waitForLayout(bar)
            const chevron = find(bar, "bookmarkBarOverflow")
            tryVerify(() => chevron.visible, 2000)
            verify(bar.visibleCount > 2 && bar.visibleCount < 40, "fits " + bar.visibleCount)
            verify(bar.overflowing)
            const lastShown = barItem(bar.visibleCount - 1)
            verify(lastShown.x + lastShown.width <= chevron.mapToItem(lastShown.parent, 0, 0).x, "items end before »")
            verify(!barItem(bar.visibleCount).fits)
            compare(barItem(bar.visibleCount).opacity, 0)
            click(chevron)
            const menu = bar.menu
            verify(menu.opened)
            compare(menu.levels[0].startIndex, bar.visibleCount)
            verify(!menu.rowAt(0, 0).shown, "items on the bar are not repeated")
            const first = menu.rowAt(0, bar.visibleCount)
            verify(first.shown)
            compare(first.title, "Overflowing bookmark " + bar.visibleCount)
            const want = "Overflow " + bar.visibleCount
            click(first)
            tryCompare(browser, "title", want, 10000)
            // A wider window shows more.
            const before = bar.visibleCount
            bm.clear()
            tryVerify(() => !chevron.visible, 2000)
            compare(bar.visibleCount, 0)
            verify(before > 0)
        }

        function test_08_context_menu() {
            reset("Context start")
            const ids = fill()
            const ctx = bar.contextMenu
            click(barItem(0), Qt.RightButton)
            verify(ctx.opened)
            compare(labels(ctx), ["Open", "Open in new tab", "-", "Edit…", "Delete", "-", "New folder…", "Bookmark manager"])
            click(ctx.rowAt(ctx.indexOfLabel("Open in new tab")))
            verify(!ctx.opened)
            tryCompare(browser.tabs, "count", 2, 5000)
            tryCompare(browser.tabs.views[1], "title", "Bar one", 10000)
            // Edit…
            click(barItem(1), Qt.RightButton)
            click(ctx.rowAt(ctx.indexOfLabel("Edit…")))
            verify(bar.editor.opened)
            compare(bar.editor.nodeId, ids.two)
            bar.editor.name = "Second"
            keyClick(Qt.Key_Return)
            compare(bm.get(ids.two).title, "Second")
            // Delete
            click(barItem(0), Qt.RightButton)
            click(ctx.rowAt(ctx.indexOfLabel("Delete")))
            tryCompare(bar, "count", 2, 2000)
            verify(!bm.contains(ids.one))
            // Folder entries; New folder… after it.
            click(barItem(1), Qt.RightButton)
            compare(labels(ctx)[0], "Open all (1) in tabs")
            verify(labels(ctx).indexOf("Rename…") >= 0)
            click(ctx.rowAt(ctx.indexOfLabel("New folder…")))
            verify(bar.editor.opened)
            compare(bar.editor.mode, "newFolder")
            bar.editor.name = "Made here"
            click(find(bar.editor, "bookmarkEditorSave"))
            tryCompare(bar, "count", 3, 2000)
            compare(barItem(2).title, "Made here")
            verify(barItem(2).isFolder)
            // In a folder's drop-down too.
            click(barItem(1))
            click(bar.menu.rowAt(0, 0), Qt.RightButton)
            verify(ctx.opened)
            verify(!bar.menu.opened)
            compare(labels(ctx)[0], "Open")
            ctx.close()
            // Empty space: Bookmark manager / Hide.
            mouseClick(root, bar.mapToItem(root, bar.width - 300, 0).x, bar.mapToItem(root, 0, bar.height / 2).y, Qt.RightButton)
            verify(ctx.opened)
            compare(labels(ctx), ["New folder…", "Bookmark manager", "-", "Hide bookmarks bar"])
            click(ctx.rowAt(ctx.indexOfLabel("Bookmark manager")))
            tryVerify(() => browser.bookmarkManagerVisible, 2000)
            browser.hideBookmarks()
            mouseClick(root, bar.mapToItem(root, bar.width - 300, 0).x, bar.mapToItem(root, 0, bar.height / 2).y, Qt.RightButton)
            click(ctx.rowAt(ctx.indexOfLabel("Hide bookmarks bar")))
            verify(!browser.showBookmarksBar)
            verify(!bar.visible)
        }

        function test_09_show_bar_action() {
            reset("Show bar")
            const act = browser.actions.action("bookmarks.showBar")
            verify(act.checkable)
            verify(act.checked)
            const contentTop = () => browser.tabs.mapToItem(root, 0, 0).y
            const shownTop = contentTop()
            keyClick(Qt.Key_B, Qt.ControlModifier | Qt.ShiftModifier)
            verify(!browser.showBookmarksBar)
            verify(!act.checked)
            verify(!bar.visible)
            tryVerify(() => contentTop() < shownTop, 2000, "the page moves up")
            keyClick(Qt.Key_B, Qt.ControlModifier | Qt.ShiftModifier)
            verify(browser.showBookmarksBar)
            verify(act.checked)
            // The checked state follows the property.
            browser.showBookmarksBar = false
            verify(!act.checked)
            browser.trigger("bookmarks.showBar", { show: true })
            verify(browser.showBookmarksBar)
            verify(act.checked)
        }

        function test_10_drag_to_reorder() {
            reset("Drag start")
            const ids = fill()
            const a = barItem(0), b = barItem(1)
            const from = center(a)
            const to = b.mapToItem(root, b.width - 4, b.height / 2)
            mousePress(root, from.x, from.y)
            for (let i = 1; i <= 10; ++i)
                mouseMove(root, from.x + (to.x - from.x) * i / 10, from.y)
            verify(bar.dropIndex === 2, "drop slot " + bar.dropIndex)
            mouseRelease(root, to.x, to.y)
            compare(bm.children(bm.barFolder).map(n => n.title), ["Bar two", "Bar one", "Folder"])
            compare(browser.title, "Drag start", "a drag does not open the bookmark")
            // Onto a folder: moves it in.
            const f = barItem(2)
            const p = center(barItem(0))
            const q = center(f)
            mousePress(root, p.x, p.y)
            for (let i = 1; i <= 10; ++i)
                mouseMove(root, p.x + (q.x - p.x) * i / 10, p.y)
            compare(bar.dropFolder, ids.folder)
            mouseRelease(root, q.x, q.y)
            compare(bm.get(ids.two).parent, ids.folder)
            tryCompare(bar, "count", 2, 2000)
        }

        function test_11_suggestions_include_bookmarks() {
            reset("Suggest start")
            const sug = browser.addressSuggestions
            const url = page("Zebra page")
            bm.add(url, "Zebra bookmark")
            browser.historyStore.recordVisit(page("Zebra history"), { title: "Zebra history" })
            browser.historyStore.recordVisit(url, { title: "Zebra page" })
            keyClick(Qt.Key_L, Qt.ControlModifier)
            const field = find(browser, "addressInput")
            tryVerify(() => field.activeFocus, 2000)
            type("zebra")
            tryVerify(() => sug.visible, 2000)
            compare(sug.items.map(i => i.type), ["search", "bookmark", "history"],
                    "bookmarks rank above history; a URL shows once")
            compare(sug.items[1].title, "Zebra bookmark")
            const row = sug.rowAt(1)
            verify(row)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "Zebra page", 10000)
            // Without a store: no bookmark entries.
            sug.bookmarkStore = null
            try {
                keyClick(Qt.Key_L, Qt.ControlModifier)
                type("zebra")
                tryVerify(() => sug.visible, 2000)
                verify(sug.items.every(i => i.type !== "bookmark"))
                keyClick(Qt.Key_Escape)
                keyClick(Qt.Key_Escape)
            } finally {
                sug.bookmarkStore = Qt.binding(() => browser.bookmarkStore)
            }
        }

        function test_12_manager() {
            reset("Manager start")
            const ids = fill()
            const act = browser.actions.action("bookmarks.manage")
            keyClick(Qt.Key_O, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => browser.bookmarkManagerVisible, 2000)
            verify(act.checked)
            const search = find(mgr, "bookmarkManagerSearch")
            tryVerify(() => search.activeFocus, 2000)
            compare(mgr.currentFolder, bm.barFolder)
            compare(mgr.count, 3)
            // Folder tree: bar, Folder, Sub, other.
            const tree = find(mgr, "bookmarkFolderList")
            compare(tree.count, 4)
            click(mgr.folderRowAt(1))
            compare(mgr.currentFolder, ids.folder)
            compare(mgr.count, 2)
            // Double click on a folder shows it; Backspace goes up.
            mouseDoubleClickSequence(root, center(mgr.rowAt(1)).x, center(mgr.rowAt(1)).y)
            compare(mgr.currentFolder, ids.sub)
            keyClick(Qt.Key_Backspace)
            compare(mgr.currentFolder, ids.folder)
            compare(mgr.currentIndex, 1, "selects the folder it came from")
            click(find(mgr, "bookmarkUp"))
            compare(mgr.currentFolder, bm.barFolder)

            // Search covers every folder; Enter opens and closes the manager.
            search.forceActiveFocus()
            type("deep")
            compare(mgr.count, 1)
            compare(mgr.entryAt(0).title, "Deep")
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "Deep", 10000)
            verify(!browser.bookmarkManagerVisible)
            browser.showBookmarks()
            compare(mgr.filterText, "deep")
            keyClick(Qt.Key_Escape)
            compare(mgr.filterText, "", "Escape clears the search first")
            compare(mgr.count, 3)

            // Edit (✎) and remove (×).
            click(find(mgr.rowAt(0), "bookmarkEdit"))
            verify(mgr.editor.opened)
            compare(mgr.editor.nodeId, ids.one)
            mgr.editor.name = "First"
            keyClick(Qt.Key_Return)
            compare(bm.get(ids.one).title, "First")
            tryVerify(() => search.activeFocus, 2000, "focus back in the manager")
            click(find(mgr.rowAt(1), "bookmarkRemove"))
            verify(!bm.contains(ids.two))
            compare(mgr.count, 2)
            // Keys: select, Ctrl+Down moves, Delete removes.
            mgr.currentIndex = 0
            keyClick(Qt.Key_Down, Qt.ControlModifier)
            compare(bm.children(bm.barFolder).map(n => n.title), ["Folder", "First"])
            compare(mgr.currentIndex, 1)
            keyClick(Qt.Key_Delete)
            compare(bm.children(bm.barFolder).map(n => n.title), ["Folder"])
            // Middle click: a background tab; Ctrl+click on a folder: all of it.
            click(mgr.rowAt(0), Qt.LeftButton, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            verify(browser.bookmarkManagerVisible)

            // New folder.
            click(find(mgr, "bookmarkNewFolder"))
            verify(mgr.editor.opened)
            compare(mgr.editor.mode, "newFolder")
            mgr.editor.name = "Created"
            keyClick(Qt.Key_Return)
            compare(bm.children(bm.barFolder).map(n => n.title), ["Folder", "Created"])

            // Export, clear, import.
            const dir = Cef.environment("CEF_QML_TEST_DIR")
            click(find(mgr, "bookmarkImportExport"))
            const path = find(mgr, "bookmarkFilePath")
            // (The Column moves it below the title at its next polish.)
            tryVerify(() => path.visible && path.mapToItem(mgr, 0, 0).y > 40, 2000)
            compare(path.text, "~/bookmarks.html")
            mgr.filePath = dir + "/manager.html"
            click(find(mgr, "bookmarkExportHtml"))
            verify(mgr.status.indexOf("Exported 2 bookmarks") === 0, mgr.status)
            click(find(mgr, "bookmarkExportJson"))
            verify(mgr.status.indexOf("manager.json") > 0, mgr.status)
            bm.clear()
            compare(mgr.count, 0)
            verify(find(mgr, "bookmarkEmpty").visible)
            click(find(mgr, "bookmarkImport"))
            compare(mgr.status, "Imported 2 bookmarks and 3 folders")
            compare(mgr.count, 2)
            mgr.filePath = dir + "/nothing-here.html"
            click(find(mgr, "bookmarkImport"))
            verify(mgr.status.indexOf("Import failed") === 0, mgr.status)

            // Close button, and the action toggles.
            const cb = find(mgr, "bookmarkManagerClose")
            click(cb)
            verify(!browser.bookmarkManagerVisible)
            browser.trigger("bookmarks.manage")
            verify(browser.bookmarkManagerVisible)
            browser.trigger("bookmarks.manage")
            verify(!browser.bookmarkManagerVisible)
        }

        function test_13_custom_layout_bar() {
            browser.showBookmarksBar = false
            plainBar.visible = true
            store.clear()
            try {
                const a = store.add(page("Plain"), "Plain")
                tryCompare(plainBar, "count", 1, 2000)
                waitForRendering(plainBar)
                verify(find(plainBar, "bookmarkBarEmpty").visible === false)
                plainBar.opened = []
                click(plainBar.itemAt(0), Qt.MiddleButton)
                compare(plainBar.opened, [[store.get(a).url, true]])
            } finally {
                plainBar.visible = false
                browser.showBookmarksBar = true
                store.clear()
            }
        }

        function cleanupTestCase() {
            closePopups()
            // Other suites share the profile (bookmarks.json, history.json).
            bm.clear()
            bm.save()
            browser.historyStore.clear()
            browser.historyStore.save()
            store.clear()
            store.save()
        }
    }
}
