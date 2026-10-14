// The command palette (CefQml.Components: CommandPalette, the "palette.show"
// action, Browser.commandPalette): keys, matching and ranking, prefix modes,
// sources, custom providers, key hints and recently used commands. Pages are
// data: URLs.
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
    function read(path) {
        const xhr = new XMLHttpRequest()
        let done = false
        xhr.onreadystatechange = () => { if (xhr.readyState === XMLHttpRequest.DONE) done = true }
        xhr.open("GET", "file://" + path)
        xhr.send()
        uiTest.tryVerify(() => done, 5000, "reading " + path)
        return xhr.status === 200 || xhr.status === 0 ? xhr.responseText : null
    }

    property var log: []

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        sessionName: "tst-palette-session"
        searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
    }

    // A palette in a custom layout: its own registry, no Browser, no key
    // bindings (Browser's KeyBindings already own the palette keys), and
    // recently used commands kept in memory.
    ActionRegistry {
        id: reg
        // Declared out of rank order: ranking must not depend on it.
        BrowserAction { name: "t.e"; text: "Fix old rm"; onTriggered: root.log = root.log.concat(["e"]) }
        BrowserAction { name: "t.d"; text: "Platform info"; onTriggered: root.log = root.log.concat(["d"]) }
        BrowserAction { name: "t.c"; text: "Auto form fill"; onTriggered: root.log = root.log.concat(["c"]) }
        BrowserAction { name: "t.b"; text: "Formatting"; onTriggered: root.log = root.log.concat(["b"]) }
        BrowserAction { name: "t.a"; text: "Form"; onTriggered: root.log = root.log.concat(["a"]) }
        BrowserAction { name: "z.one"; text: "Zap one"; onTriggered: root.log = root.log.concat(["zap1"]) }
        BrowserAction { name: "z.two"; text: "Zap two"; onTriggered: root.log = root.log.concat(["zap2"]) }
        BrowserAction { name: "z.hidden"; text: "Zap hidden"; showInPalette: false }
    }
    CommandPalette {
        id: plain
        objectName: "plainPalette"
        actions: reg
        recentPath: ""
    }

    TestCase {
        id: uiTest
        name: "CommandPalette"
        when: windowShown

        property var palette: browser.commandPalette

        function view() { return browser.currentView }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item, button, modifiers) {
            const p = center(item)
            mouseClick(root, p.x, p.y, button || Qt.LeftButton, modifiers || Qt.NoModifier)
        }
        function type(text) { for (const ch of text) keyClick(ch) }
        function titles(p) { return (p || palette).items.map(i => i.title) }
        function indexOf(p, pred) { return p.items.findIndex(pred) }
        function addressInput() { return browser.navigationBar.addressField.input }
        function closeAll() {
            palette.close()
            plain.close()
        }
        function resetTabs(titles) {
            mouseMove(root, root.width - 5, root.height - 5)
            closeAll()
            titles = titles || ["start"]
            browser.tabs.restore(titles.map(t => page(t)), 0, { lazy: false })
            tryCompare(browser.tabs, "count", titles.length, 5000)
            for (let i = 0; i < titles.length; ++i)
                tryCompare(browser.tabs.views[i], "title", titles[i], 10000)
            browser.controller.clearClosedTabs()
            view().forceActiveFocus()
            tryVerify(() => view().activeFocus, 2000)
        }

        function initTestCase() {
            tryCompare(browser.tabs, "count", 1, 10000)
            tryCompare(browser, "title", "New Tab", 15000)
        }

        function init() {
            root.log = []
            plain.clearRecent()
            palette.clearRecent()
        }

        // ---- opening and closing -------------------------------------------

        function test_01_open_with_keys_and_escape_restores_focus() {
            resetTabs()
            verify(browser.actions.has("palette.show"))
            compare(browser.keyBindings.sequencesFor("palette.show"), ["Ctrl+Shift+P", "Ctrl+K"])
            compare(browser.keyBindings.conflicts.filter(c => c.action === "palette.show").length, 0)

            keyClick(Qt.Key_K, Qt.ControlModifier)
            tryVerify(() => palette.visible, 2000)
            verify(browser.commandPaletteVisible)
            compare(palette.prefix, "")
            verify(palette.input.activeFocus, "the input has the focus")
            verify(browser.actions.action("palette.show").checked)
            verify(palette.items.length > 0)
            verify(palette.items.every(i => i.type === "action"), "empty query: commands (no other tab)")
            const footer = findChild(palette, "paletteFooter")
            verify(footer.text.indexOf("> commands") >= 0, footer.text)
            verify(footer.text.indexOf("@ tabs") >= 0, footer.text)
            keyClick(Qt.Key_Escape)
            verify(!palette.visible)
            verify(view().activeFocus, "Escape gives the focus back to the page")

            // Ctrl+Shift+P: commands mode.
            keyClick(Qt.Key_P, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => palette.visible, 2000)
            compare(palette.text, ">")
            compare(palette.prefix, ">")
            compare(findChild(palette, "paletteFooter").text, "Commands")
            // The same key again closes it; the other key switches mode.
            keyClick(Qt.Key_K, Qt.ControlModifier)
            verify(palette.visible)
            compare(palette.prefix, "")
            keyClick(Qt.Key_K, Qt.ControlModifier)
            verify(!palette.visible)
            verify(view().activeFocus)

            // From the address bar, focus goes back there.
            keyClick(Qt.Key_L, Qt.ControlModifier)
            tryVerify(() => addressInput().activeFocus, 2000)
            keyClick(Qt.Key_P, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => palette.visible, 2000)
            verify(!addressInput().activeFocus)
            keyClick(Qt.Key_Escape)
            verify(!palette.visible)
            verify(addressInput().activeFocus, "focus restored to the address field")
            view().forceActiveFocus()

            // A press outside the panel closes it too.
            browser.showCommandPalette()
            verify(palette.visible)
            mouseClick(root, 5, root.height - 5)
            verify(!palette.visible)
            verify(view().activeFocus)

            // Programmatic API.
            verify(browser.showCommandPalette("#"))
            compare(palette.prefix, "#")
            browser.hideCommandPalette()
            verify(!palette.visible)
            verify(view().activeFocus)
        }

        // ---- matching ------------------------------------------------------

        function test_02_match_tiers() {
            compare(plain.match("form", "Form").tier, 5)
            compare(plain.match("form", "Formatting").tier, 4)
            compare(plain.match("form", "Auto form fill").tier, 3)
            compare(plain.match("form", "Platform info").tier, 2)
            compare(plain.match("form", "Fix old rm").tier, 1)
            compare(plain.match("form", "Fix old rm").positions, [0, 4, 8, 9])
            compare(plain.match("form", "nothing"), null)
            compare(plain.match("nt", "New tab").tier, 3, "acronym")
            compare(plain.match("tab", "closeTab").tier, 3, "camelCase hump")
            compare(plain.match("tab new", "New tab").tier, 3, "every word")
            compare(plain.match("NEW", "new tab").tier, 4, "case-insensitive")
        }

        function test_03_ranking_and_highlight() {
            mouseMove(root, root.width - 5, root.height - 5)
            verify(plain.open())
            verify(plain.input.activeFocus)
            type("form")
            compare(plain.query, "form")
            compare(titles(plain), ["Form", "Formatting", "Auto form fill", "Platform info", "Fix old rm"])
            compare(plain.currentIndex, 0)
            const row = plain.rowAt(2)
            verify(row)
            const title = findChild(row, "paletteTitle")
            verify(title.text.indexOf("Auto <b>") === 0, title.text)
            verify(title.text.indexOf(">form</font></b> fill") > 0, title.text)
            compare(plain.items[4]._positions, [0, 4, 8, 9])
            // Category prefix, without a key hint (no keyBindings).
            compare(plain.items[0].category, "T")
            verify(!findChild(plain.rowAt(0), "paletteHint").visible)
            // Selection keys.
            keyClick(Qt.Key_Down)
            compare(plain.currentIndex, 1)
            keyClick(Qt.Key_End)
            compare(plain.currentIndex, 4)
            keyClick(Qt.Key_Down)
            compare(plain.currentIndex, 4, "stops at the end")
            keyClick(Qt.Key_Home)
            compare(plain.currentIndex, 0)
            keyClick(Qt.Key_PageDown)
            compare(plain.currentIndex, 4)
            keyClick(Qt.Key_PageUp)
            compare(plain.currentIndex, 0)
            keyClick(Qt.Key_Up)
            compare(plain.currentIndex, 0)
            // Typing narrows; the text is the query.
            type("at")
            compare(plain.query, "format")
            compare(titles(plain), ["Formatting"])
            compare(plain.items.filter(i => i.title === "Zap hidden").length, 0)
            // Nothing matches.
            plain.text = "qqqq"
            compare(plain.items.length, 0)
            verify(findChild(plain, "paletteEmpty").visible)
            keyClick(Qt.Key_Escape)
            verify(!plain.visible)
        }

        // ---- prefix modes --------------------------------------------------

        function test_04_prefix_modes() {
            resetTabs(["Alpha tab", "Beta tab", "Gamma tab"])
            const bm = browser.bookmarkStore
            const hs = browser.historyStore
            bm.clear()
            bm.add(page("Bookmarked page"), "Bookmarked page")
            tryVerify(() => hs.contains(page("Gamma tab")), 5000)

            palette.open(">")
            verify(palette.items.length > 10)
            verify(palette.items.every(i => i.type === "action"))
            compare(palette.items.filter(i => i.actionName === "tab.select" || i.actionName === "palette.show").length, 0,
                    "actions that need arguments, and the palette itself, are not listed")

            for (const p of ["@", "%"]) {
                palette.text = p
                compare(palette.prefix, p)
                compare(titles(), ["Alpha tab", "Beta tab", "Gamma tab"])
                verify(palette.items.every(i => i.type === "tab"))
                compare(palette.items[0].label, "Current tab")
                compare(palette.items[1].label, "Switch to tab")
                compare(findChild(palette, "paletteFooter").text, "Tabs · Recently closed")
            }
            palette.text = "@ gam"
            compare(palette.query, "gam")
            compare(titles(), ["Gamma tab"])

            palette.text = "*"
            compare(titles(), ["Bookmarked page"])
            compare(palette.items[0].type, "bookmark")
            palette.text = "* nothing like it"
            compare(palette.items.length, 0)

            palette.text = "#"
            verify(palette.items.length >= 3)
            verify(palette.items.every(i => i.type === "history"))
            palette.text = "#alpha"
            compare(titles(), ["Alpha tab"])

            // Without a prefix: everything matching, one entry per URL (the
            // tab wins over its history entry), and a web search last.
            palette.text = "beta"
            compare(palette.items[0].type, "tab")
            compare(palette.items[0].title, "Beta tab")
            compare(palette.items.filter(i => i.title === "Beta tab").length, 1)
            compare(palette.items[palette.items.length - 1].type, "search")
            palette.text = "bookmarked"
            compare(palette.items[0].type, "bookmark")
            // The current tab is not offered for switching there.
            palette.text = "alpha"
            compare(palette.items.filter(i => i.type === "tab").length, 0)
            palette.close()
            bm.clear()
        }

        // ---- running -------------------------------------------------------

        function test_05_run_action_with_enter() {
            resetTabs()
            const count = browser.tabs.count
            keyClick(Qt.Key_P, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => palette.visible, 2000)
            type("new tab")
            compare(palette.items[0].actionName, "tab.new")
            compare(palette.items[0].title, "New tab")
            compare(palette.items[0].category, "Tabs")
            keyClick(Qt.Key_Return)
            verify(!palette.visible)
            tryCompare(browser.tabs, "count", count + 1, 5000)
            tryVerify(() => addressInput().activeFocus, 2000, "tab.new focuses the address field")

            // Disabled actions are listed, dimmed, and do not run.
            resetTabs()
            palette.open("> back")
            const i = indexOf(palette, x => x.actionName === "nav.back")
            verify(i >= 0)
            verify(!palette.items[i].enabled)
            compare(palette.rowAt(i).opacity < 1, true)
            verify(!palette.run(i))
            verify(palette.visible, "still open")
            palette.close()

            // Checked state (an open overlay's action).
            browser.showHistory()
            browser.showCommandPalette("> history")
            const h = indexOf(palette, x => x.actionName === "history.show")
            verify(palette.items[h].checked)
            palette.run(h)
            verify(!browser.historyVisible, "history.show toggled the overlay")
        }

        function test_06_switch_to_tab() {
            resetTabs(["Alpha tab", "Beta tab", "Gamma tab"])
            compare(browser.tabs.currentIndex, 0)
            keyClick(Qt.Key_K, Qt.ControlModifier)
            tryVerify(() => palette.visible, 2000)
            type("gamma")
            compare(palette.items[0].type, "tab")
            keyClick(Qt.Key_Return)
            verify(!palette.visible)
            compare(browser.tabs.currentIndex, 2)
            tryVerify(() => view().activeFocus, 2000)

            // Shift+Delete on a tab entry closes the tab.
            palette.open("@beta")
            compare(titles(), ["Beta tab"])
            keyClick(Qt.Key_Delete, Qt.ShiftModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            verify(palette.visible)
            compare(palette.items.filter(i => i.type === "tab" && i.title === "Beta tab").length, 0)
            // ... and it is offered again as a closed tab.
            compare(palette.items[0].type, "closedTab")
            palette.close()
        }

        function test_07_open_url_and_search() {
            resetTabs()
            const url = page("Typed URL")
            keyClick(Qt.Key_K, Qt.ControlModifier)
            tryVerify(() => palette.visible, 2000)
            palette.text = url
            compare(palette.items[0].type, "url")
            keyClick(Qt.Key_Return)
            verify(!palette.visible)
            tryCompare(browser, "title", "Typed URL", 10000)
            compare(browser.tabs.count, 1)
            tryVerify(() => view().activeFocus, 2000)

            // Alt+Enter: a new tab.
            palette.open()
            palette.text = page("New tab URL")
            keyClick(Qt.Key_Return, Qt.AltModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            tryCompare(browser, "title", "New tab URL", 10000)

            // Anything else: a web search (always the last entry).
            palette.open()
            type("hello world")
            const last = palette.items.length - 1
            compare(palette.items[last].type, "search")
            compare(palette.items[last].title, "hello world")
            palette.currentIndex = last
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "search", 10000)
            verify(decodeURIComponent(view().url.toString()).indexOf("hello world") >= 0, view().url)
        }

        function test_08_reopen_closed_tab() {
            resetTabs(["Keep", "Closed one"])
            browser.closeTab(1)
            tryCompare(browser.tabs, "count", 1, 5000)
            compare(browser.controller.closedTabs.length, 1)
            palette.open("@")
            const i = indexOf(palette, x => x.type === "closedTab")
            compare(palette.items[i].title, "Closed one")
            compare(palette.items[i].label, "Reopen closed tab")
            palette.text = "@closed"
            compare(palette.items[0].type, "closedTab")
            keyClick(Qt.Key_Return)
            tryCompare(browser.tabs, "count", 2, 5000)
            tryCompare(browser, "title", "Closed one", 10000)
            compare(browser.controller.closedTabs.length, 0)
        }

        // ---- sources -------------------------------------------------------

        function test_09_custom_providers_and_commands() {
            resetTabs()
            const runs = []
            const sync = (text, ctx) => text === "" ? [] : [{
                title: "Custom " + text, subtitle: ctx.mode === "" ? "mixed" : ctx.mode,
                action: (item, alt) => runs.push(["sync", item.title, alt])
            }]
            const later = {
                suggest: text => new Promise(resolve => resolve(text === "" ? [] : [{
                    type: "custom", title: "Later " + text, label: "async",
                    action: () => runs.push(["later"])
                }]))
            }
            const bangs = {
                prefix: "!", title: "Bangs", mixed: false,
                suggest: (text, ctx) => [{ title: "Bang " + (text || "all"), score: 1, actionName: "test.palette.hello",
                                           args: { from: "bang" } }]
            }
            palette.addProvider(sync)
            palette.addProvider(later, 0)
            palette.addProvider(bangs)
            verify(palette.prefixes.indexOf("!") >= 0)
            const hello = browser.actions.add({
                name: "test.palette.hello", text: "Say hello",
                onTriggered: args => runs.push(["hello", args.from || ""])
            })
            try {
                palette.open()
                type("wibble")
                verify(titles().indexOf("Custom wibble") >= 0, JSON.stringify(titles()))
                tryVerify(() => titles().indexOf("Later wibble") >= 0, 2000, "async results arrive")
                compare(titles().filter(t => t.startsWith("Bang")).length, 0, "mixed: false")
                palette.currentIndex = titles().indexOf("Custom wibble")
                keyClick(Qt.Key_Return, Qt.ControlModifier)
                compare(runs[0], ["sync", "Custom wibble", true])

                palette.open("!")
                compare(titles(), ["Bang all"])
                compare(findChild(palette, "paletteFooter").text, "Bangs")
                keyClick(Qt.Key_Return)
                compare(runs[1], ["hello", "bang"])

                // A command added to the registry is a palette entry.
                palette.open("> say hel")
                compare(palette.items[0].actionName, "test.palette.hello")
                compare(palette.items[0].category, "Test")
                keyClick(Qt.Key_Return)
                compare(runs[2], ["hello", ""])

                palette.removeProvider(sync)
                palette.removeProvider(later)
                palette.removeProvider(bangs)
                verify(palette.prefixes.indexOf("!") < 0)
                palette.open()
                palette.text = "wibble"
                compare(titles().filter(t => t.indexOf("wibble") >= 0 && t !== "wibble").length, 0)
                palette.close()
            } finally {
                browser.actions.remove(hello)
                palette.removeProvider(sync)
                palette.removeProvider(later)
                palette.removeProvider(bangs)
            }
            verify(!browser.actions.has("test.palette.hello"))
        }

        function test_10_key_hints() {
            resetTabs()
            palette.open(">new tab")
            compare(palette.items[0].actionName, "tab.new")
            compare(palette.items[0].hint, "Ctrl+T")
            let hint = findChild(palette.rowAt(0), "paletteHint")
            verify(hint.visible)
            compare(hint.text, "Ctrl+T")
            // Rebinding updates the open palette.
            browser.keyBindings.bind("tab.new", ["Ctrl+Alt+N"])
            try {
                compare(palette.items[0].hint, "Ctrl+Alt+N")
                tryVerify(() => findChild(palette.rowAt(0), "paletteHint").text === "Ctrl+Alt+N", 2000)
            } finally {
                browser.keyBindings.reset("tab.new")
            }
            compare(palette.items[0].hint, "Ctrl+T")
            // Unbound actions have no hint.
            palette.text = ">duplicate tab"
            compare(palette.items[0].actionName, "tab.duplicate")
            compare(palette.items[0].hint, "")
            verify(!findChild(palette.rowAt(0), "paletteHint").visible)
            palette.close()
        }

        function test_11_recently_used_first() {
            mouseMove(root, root.width - 5, root.height - 5)
            plain.open()
            type("zap")
            compare(titles(plain), ["Zap one", "Zap two"])
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            compare(root.log, ["zap2"])
            compare(plain.recent, ["action:z.two"])
            plain.open()
            type("zap")
            compare(titles(plain), ["Zap two", "Zap one"], "the recently used command first")
            // The boost does not beat a better match.
            plain.text = "zap one"
            compare(plain.items[0].title, "Zap one")
            // The empty query lists recent commands first.
            plain.text = ""
            compare(plain.items[0].title, "Zap two")
            plain.run(indexOf(plain, x => x.title === "Form"))
            compare(plain.recent, ["action:t.a", "action:z.two"])
            plain.open()
            compare(titles(plain).slice(0, 2), ["Form", "Zap two"])
            plain.close()

            // Browser's palette saves them under Cef.dataDir.
            resetTabs()
            palette.open(">zoom in")
            compare(palette.items[0].actionName, "zoom.in")
            keyClick(Qt.Key_Return)
            tryVerify(() => view().zoomFactor > 1, 2000)
            browser.controller.resetZoom()
            compare(palette.recent[0], "action:zoom.in")
            tryVerify(() => !palette._recentStore.dirty, 3000)
            const saved = JSON.parse(read(Cef.dataDir + "/command-palette.json"))
            compare(saved.recent[0], "action:zoom.in")
        }

        function test_12_mouse() {
            mouseMove(root, root.width - 5, root.height - 5)
            plain.open()
            plain.text = "form"
            const row = plain.rowAt(1)
            compare(row.modelData.title, "Formatting")
            compare(plain.currentIndex, 0, "rows under a resting pointer are not selected")
            click(row)
            verify(!plain.visible)
            compare(root.log, ["b"])
        }

        function test_13_remove_history_entry() {
            resetTabs(["Forget me"])
            const hs = browser.historyStore
            tryVerify(() => hs.contains(page("Forget me")), 5000)
            palette.open("#forget")
            compare(titles(), ["Forget me"])
            verify(palette.items[0].removable)
            keyClick(Qt.Key_Delete, Qt.ShiftModifier)
            verify(!hs.contains(page("Forget me")))
            compare(palette.items.length, 0)
            palette.close()
        }

        function cleanupTestCase() {
            closeAll()
            // Other suites share the profile.
            palette.clearRecent()
            palette._recentStore.save()
            browser.bookmarkStore.clear()
            browser.bookmarkStore.save()
            browser.historyStore.clear()
            browser.historyStore.save()
        }
    }
}
