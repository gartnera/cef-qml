// Actions, key bindings and the programmatic browser API
// (CefQml.Components: BrowserAction, ActionRegistry, KeyBindings,
// BrowserController, BrowserActions, Browser). Pages are data: URLs.
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

    property var customCalls: []
    property int stealCount: 0
    property bool quiet: false
    property var log: []

    readonly property var userBindings: ({
        "tab.new": ["Ctrl+N"],                       // rebound: Ctrl+T no longer opens a tab
        "address.focus": ["F6"],                     // Ctrl+L and Alt+D dropped
        "zoom.reset": [],                            // unbound
        // A user binding beats page.find's default Ctrl+F.
        "test.custom": ["Ctrl+Shift+Y", { sequence: "Ctrl+Shift+U", args: { via: "u" } }, "Ctrl+F"],
    })

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
        bindings: root.userBindings
        // Grouped syntax through the keyBindings alias (as in the README).
        keyBindings.modeBindings: ({ "quiet": { "test.custom": [], "test.steal": [] } })
        keyBindings.mode: root.quiet ? "quiet" : ""

        BrowserAction {
            registry: browser.actions
            name: "test.custom"
            text: "Custom action"
            defaultShortcuts: ["Ctrl+Shift+J"]          // overridden by `bindings`
            onTriggered: args => root.customCalls = root.customCalls.concat([args])
        }
        BrowserAction {
            // Same level as nav.reload's default Ctrl+R; registered later, so it wins.
            registry: browser.actions
            name: "test.steal"
            text: "Steal Ctrl+R"
            defaultShortcuts: ["Ctrl+R"]
            onTriggered: root.stealCount++
        }
    }

    // A custom layout from the primitives, without Browser. Its key bindings
    // start disabled: they repeat Browser's, and two enabled Shortcuts with
    // the same keys in one window are ambiguous.
    Item {
        width: 300; height: 200
        WebTabs { id: plainTabs; anchors.fill: parent; visible: false }
        BrowserController { id: plainController; tabs: plainTabs }
        BrowserActions { id: plainActions; controller: plainController }
        KeyBindings { id: plainKeys; actions: plainActions; enabled: false }
    }

    // Standalone registry with keys Browser does not use.
    ActionRegistry {
        id: reg
        BrowserAction { name: "x.one"; text: "One"; defaultShortcuts: ["F7"]; onTriggered: root.log = root.log.concat(["one"]) }
        BrowserAction { name: "x.two"; text: "Two"; defaultShortcuts: ["F8"]; onTriggered: root.log = root.log.concat(["two"]) }
        BrowserAction { name: "x.off"; text: "Off"; enabled: false; defaultShortcuts: ["F9"]; onTriggered: root.log = root.log.concat(["off"]) }
    }
    KeyBindings { id: regKeys; actions: reg }

    TestCase {
        name: "Actions"
        when: windowShown

        function view() { return browser.currentView }
        function evaluate(script) {
            let out = null
            view().evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, script)
            return out[0]
        }
        function find(name) {
            const item = findChild(browser, name)
            verify(item, "no child " + name)
            return item
        }
        function resetTabs() {
            browser.tabs.restore([page("start")], 0)
            tryCompare(browser, "title", "start", 10000)
            view().forceActiveFocus()
        }
        // A key that must not do anything: give it time to be (wrongly) handled.
        function settle() { wait(150) }

        function initTestCase() {
            tryCompare(browser.tabs, "count", 1, 10000)
            tryCompare(browser, "title", "New Tab", 15000)
        }

        // ---- registry ------------------------------------------------------

        function test_01_registry() {
            const acts = browser.actions
            for (const n of ["tab.new", "tab.close", "tab.next", "tab.previous", "tab.select", "tab.reopenClosed",
                             "nav.back", "nav.forward", "nav.reload", "nav.reloadHard", "nav.stop", "nav.home",
                             "address.focus", "page.find", "page.findNext", "page.findPrevious",
                             "zoom.in", "zoom.out", "zoom.reset", "window.fullscreen", "test.custom", "test.steal",
                             "hints.open", "hints.newTab", "hints.copyLink", "hints.focusInput",
                             "page.scrollDown", "page.scrollUp", "page.scrollPageDown", "page.scrollPageUp",
                             "page.scrollTop", "page.scrollBottom", "page.scrollLeft", "page.scrollRight"])
                verify(acts.has(n), n)
            compare(acts.action("tab.new").text, "New tab")
            compare(acts.action("tab.new").category, "tab")
            verify(acts.model.every(a => a.text !== ""), "every action has a text")
            verify(acts.names().indexOf("test.custom") > acts.names().indexOf("window.fullscreen"), "user actions come after the built-ins")
            compare(acts.action("nope"), null)
        }

        function test_02_trigger_by_name() {
            resetTabs()
            browser.openTab(page("second"))
            tryCompare(browser, "title", "second", 10000)
            verify(browser.trigger("tab.select", { index: 0 }))
            compare(browser.tabs.currentIndex, 0)
            verify(browser.trigger("tab.select", { index: -1 }))
            compare(browser.tabs.currentIndex, 1)
            verify(browser.trigger("tab.previous"))
            compare(browser.tabs.currentIndex, 0)
            verify(!browser.trigger("nav.back"), "disabled action (no history) does not run")
            ignoreWarning(/no action named "nope"/)
            verify(!browser.trigger("nope"))

            let seen = null
            const record = (name, args) => seen = [name, args]
            browser.actions.actionTriggered.connect(record)
            browser.trigger("test.custom", { from: "code" })
            browser.actions.actionTriggered.disconnect(record)
            compare(seen[0], "test.custom")
            compare(root.customCalls[root.customCalls.length - 1].from, "code")
        }

        function test_03_add_replace_remove() {
            let calls = 0
            const added = reg.add({ name: "x.added", text: "Added", defaultShortcuts: ["F10"], onTriggered: () => calls++ })
            verify(added)
            compare(regKeys.sequencesFor("x.added"), ["F10"])
            keyClick(Qt.Key_F10)
            tryVerify(() => calls === 1, 2000, "a key of an action added at run time")
            reg.remove("x.added")
            verify(!reg.has("x.added"))
            keyClick(Qt.Key_F10)
            settle()
            compare(calls, 1, "removed action's key is gone")

            // Replacing a built-in: the newest action of a name wins and
            // takes the original's place; removing it restores the original.
            const before = browser.actions.names().indexOf("nav.home")
            let homeCalls = 0
            const mine = browser.actions.add({ name: "nav.home", text: "My home", onTriggered: () => homeCalls++ })
            compare(browser.actions.action("nav.home"), mine)
            compare(browser.actions.names().indexOf("nav.home"), before)
            verify(browser.trigger("nav.home"))
            compare(homeCalls, 1)
            compare(browser.keyBindings.sequencesFor("nav.home"), [], "the replacement brings its own (no) keys")
            browser.actions.remove(mine)
            compare(browser.actions.action("nav.home").text, "Home page")
            compare(browser.keyBindings.sequencesFor("nav.home"), ["Alt+Home"])
        }

        // ---- default and user key bindings ---------------------------------

        function test_04_rebound_key() {
            resetTabs()
            compare(browser.keyBindings.sequencesFor("tab.new"), ["Ctrl+N"])
            compare(browser.keyBindings.hint("tab.new"), "Ctrl+N")
            keyClick(Qt.Key_T, Qt.ControlModifier)
            settle()
            compare(browser.tabs.count, 1, "the default Ctrl+T was replaced")
            keyClick(Qt.Key_N, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            tryVerify(() => find("addressInput").activeFocus, 2000, "tab.new focuses the address field")
            // Defaults of other actions still work.
            keyClick(Qt.Key_W, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 1, 5000)
        }

        function test_05_unbound_and_reduced() {
            resetTabs()
            compare(browser.keyBindings.sequencesFor("zoom.reset"), [])
            keyClick(Qt.Key_Equal, Qt.ControlModifier)
            tryVerify(() => Math.abs(view().zoomFactor - 1.1) < 0.01, 2000)
            keyClick(Qt.Key_0, Qt.ControlModifier)
            settle()
            verify(Math.abs(view().zoomFactor - 1.1) < 0.01, "Ctrl+0 is unbound")
            verify(browser.trigger("zoom.reset"))
            compare(view().zoomFactor, 1)

            const field = find("addressInput")
            verify(!field.activeFocus)
            keyClick(Qt.Key_L, Qt.ControlModifier)
            settle()
            verify(!field.activeFocus, "Ctrl+L no longer focuses the address field")
            keyClick(Qt.Key_F6)
            tryVerify(() => field.activeFocus, 2000, "F6 still does")
            view().forceActiveFocus()
        }

        function test_06_conflicts() {
            const kb = browser.keyBindings
            const byKey = {}
            for (const c of kb.conflicts) byKey[kb.normalize(c.sequence)] = c
            const f = byKey[kb.normalize("Ctrl+F")]
            verify(f, "Ctrl+F conflict listed")
            compare(f.action, "test.custom", "user binding beats a default")
            compare(f.overridden, ["page.find"])
            const r = byKey[kb.normalize("Ctrl+R")]
            verify(r, "Ctrl+R conflict listed")
            compare(r.action, "test.steal", "same level: the later registration wins")
            compare(r.overridden, ["nav.reload"])
            compare(kb.actionFor("ctrl+f"), "test.custom")
            compare(kb.sequencesFor("page.find"), [])
            compare(kb.sequencesFor("nav.reload"), ["F5"])

            resetTabs()
            const calls = root.customCalls.length
            keyClick(Qt.Key_F, Qt.ControlModifier)
            tryVerify(() => root.customCalls.length === calls + 1, 2000)
            verify(!browser.findBar.visible, "Ctrl+F went to the user's action only")
            keyClick(Qt.Key_F3)
            tryVerify(() => browser.findBar.visible, 2000, "F3 opens the find bar")
            keyClick(Qt.Key_Escape)
            verify(!browser.findBar.visible)
            view().forceActiveFocus()
            const steals = root.stealCount
            keyClick(Qt.Key_R, Qt.ControlModifier)
            tryCompare(root, "stealCount", steals + 1, 2000)
        }

        function test_07_custom_action_keys_and_args() {
            resetTabs()
            const n = root.customCalls.length
            keyClick(Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => root.customCalls.length === n + 1, 2000)
            compare(JSON.stringify(root.customCalls[n]), "{}")
            keyClick(Qt.Key_U, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => root.customCalls.length === n + 2, 2000)
            compare(root.customCalls[n + 1].via, "u", "binding args reach the action")
            keyClick(Qt.Key_J, Qt.ControlModifier | Qt.ShiftModifier)
            settle()
            compare(root.customCalls.length, n + 2, "the action's own default was overridden")
        }

        function test_08_bind_unbind_reset_at_runtime() {
            const kb = browser.keyBindings
            const n = root.customCalls.length
            kb.bind("test.custom", "Ctrl+Shift+K")
            compare(kb.sequencesFor("test.custom"), ["Ctrl+Shift+K"])
            keyClick(Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier)
            settle()
            compare(root.customCalls.length, n)
            keyClick(Qt.Key_K, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => root.customCalls.length === n + 1, 2000)
            kb.unbind("test.custom")
            keyClick(Qt.Key_K, Qt.ControlModifier | Qt.ShiftModifier)
            settle()
            compare(root.customCalls.length, n + 1)
            kb.reset("test.custom")
            compare(kb.sequencesFor("test.custom"), ["Ctrl+Shift+J"], "back to the action's defaults")
            keyClick(Qt.Key_J, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => root.customCalls.length === n + 2, 2000)
            browser.bindings = root.userBindings
            compare(kb.sequencesFor("test.custom")[0], "Ctrl+Shift+Y")
        }

        function test_09_same_level_conflict_last_bound_wins() {
            root.log = []
            ignoreWarning(/KeyBindings: "F10" is bound to x.one and x.two; using x.two/)
            regKeys.bind("x.one", ["F10"])
            regKeys.bind("x.two", ["F10"])
            keyClick(Qt.Key_F10)
            tryVerify(() => root.log.length === 1, 2000)
            compare(root.log, ["two"])
            ignoreWarning(/KeyBindings: "F10" is bound to x.two and x.one; using x.one/)
            regKeys.bind("x.one", ["F10"])   // binding again makes it the latest
            keyClick(Qt.Key_F10)
            tryVerify(() => root.log.length === 2, 2000)
            compare(root.log[1], "one")
            regKeys.reset()
            keyClick(Qt.Key_F7)
            keyClick(Qt.Key_F8)
            tryVerify(() => root.log.length === 4, 2000)
            compare(root.log.slice(2), ["one", "two"])
            // A disabled action's key does nothing (and is let through).
            keyClick(Qt.Key_F9)
            settle()
            compare(root.log.length, 4)
            verify(!reg.trigger("x.off"))
        }

        function test_10_disable_all_and_modes() {
            root.log = []
            regKeys.enabled = false
            keyClick(Qt.Key_F7)
            settle()
            compare(root.log.length, 0, "disabled KeyBindings")
            regKeys.enabled = true
            keyClick(Qt.Key_F7)
            tryVerify(() => root.log.length === 1, 2000)

            regKeys.modeBindings = { "alt": { "x.one": ["Shift+F7"] } }
            regKeys.mode = "alt"
            compare(regKeys.sequencesFor("x.one"), ["Shift+F7"])
            keyClick(Qt.Key_F7)
            settle()
            compare(root.log.length, 1, "the mode map replaces x.one's keys")
            keyClick(Qt.Key_F7, Qt.ShiftModifier)
            tryVerify(() => root.log.length === 2, 2000)
            keyClick(Qt.Key_F8)
            tryVerify(() => root.log.length === 3, 2000, "actions the mode does not mention keep their keys")
            regKeys.mode = ""
            keyClick(Qt.Key_F7, Qt.ShiftModifier)
            settle()
            compare(root.log.length, 3)
            keyClick(Qt.Key_F7)
            tryVerify(() => root.log.length === 4, 2000)
        }

        function test_10b_browser_mode() {
            resetTabs()
            root.quiet = true
            compare(browser.keyBindings.sequencesFor("test.custom"), [])
            compare(browser.keyBindings.sequencesFor("nav.reload"), ["Ctrl+R", "F5"], "Ctrl+R back to its default owner")
            compare(browser.keyBindings.sequencesFor("page.find"), ["Ctrl+F"])
            const n = root.customCalls.length
            keyClick(Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier)
            settle()
            compare(root.customCalls.length, n)
            root.quiet = false
            compare(browser.keyBindings.sequencesFor("test.custom")[0], "Ctrl+Shift+Y")
        }

        function test_11_normalize() {
            compare(regKeys.normalize("shift+ctrl+t"), regKeys.normalize("Ctrl+Shift+T"))
            compare(regKeys.normalize("Ctrl+PageDown"), regKeys.normalize("ctrl+pgdown"))
            compare(regKeys.normalize("Ctrl++"), "Ctrl++")
            verify(regKeys.normalize("Ctrl+=") !== regKeys.normalize("Ctrl++"))
            compare(regKeys.normalize("Ctrl+K, ctrl+s"), "Ctrl+k, Ctrl+s")
        }

        // ---- programmatic navigation ---------------------------------------

        function test_12_navigate_callback_and_promise() {
            resetTabs()
            let result = null
            const p = browser.navigate(page("one"), {}, r => result = r)
            verify(p instanceof Promise)
            tryVerify(() => result !== null, 10000)
            verify(result.ok, "load result " + result.errorCode + " " + result.error)
            compare(result.view, browser.currentView)
            compare(result.view.title, "one")
            compare(browser.tabs.count, 1, "navigated the current tab")

            let promised = null
            browser.navigate(page("two")).then(r => promised = r)
            tryVerify(() => promised !== null, 10000)
            verify(promised.ok)
            compare(browser.title, "two")

            // Typed text: an address or a search.
            promised = null
            browser.navigate("hello world").then(r => promised = r)
            tryVerify(() => promised !== null, 10000)
            compare(browser.title, "search")

            // The same URL again reloads (and still resolves).
            promised = null
            browser.navigate(view().url).then(r => promised = r)
            tryVerify(() => promised !== null, 10000)
            verify(promised.ok)
        }

        function test_13_navigate_new_tab_and_failure() {
            resetTabs()
            let r = null
            browser.navigate(page("bg"), { newTab: true, background: true }).then(x => r = x)
            compare(browser.tabs.count, 2)
            compare(browser.tabs.currentIndex, 0, "background tab")
            tryVerify(() => r !== null, 10000)
            verify(r.ok)
            compare(r.view, browser.tabs.views[1])
            compare(r.view.title, "bg")

            r = null
            browser.navigate(page("front"), { newTab: true, index: 0 }, x => r = x)
            compare(browser.tabs.currentIndex, 0)
            tryVerify(() => r !== null, 10000)
            compare(browser.title, "front")

            r = null
            browser.navigate(page("in tab 2"), { tab: -1 }).then(x => r = x)
            tryVerify(() => r !== null, 10000)
            compare(browser.tabs.views[2].title, "in tab 2")
            compare(browser.tabs.currentIndex, 0, "navigating another tab does not select it")

            // Nothing listens on port 1: a load error.
            r = null
            browser.navigate("http://127.0.0.1:1/").then(x => r = x)
            tryVerify(() => r !== null, 15000)
            verify(!r.ok)
            verify(r.errorCode < 0, "net::Error " + r.errorCode)

            // Nothing loads: the wait times out. (The error page of the
            // failed load may still be loading at first.)
            tryCompare(view(), "loading", false, 10000)
            wait(100)
            r = null
            browser.whenLoaded(view(), { timeout: 100 }).then(x => r = x)
            tryVerify(() => r !== null, 2000)
            compare(r.error, "timeout")

            r = null
            browser.navigate(page("x"), { tab: 7 }).then(x => r = x)
            tryVerify(() => r !== null, 2000)
            compare(r.error, "noTab")
        }

        function test_14_tab_helpers() {
            browser.tabs.restore([page("alpha"), page("beta"), page("gamma")], 0)
            tryVerify(() => browser.tabs.views.every(v => v.title !== "" && !v.loading), 10000)
            const beta = browser.findTab(v => v.title === "beta")
            compare(beta, browser.tabs.views[1])
            compare(browser.tabForUrl(beta.url), beta)
            compare(browser.tabForUrl(/gamma/), browser.tabs.views[2])
            compare(browser.tabForUrl("about:nothing"), null)
            compare(browser.controller.findTabs(v => v.title !== "beta").length, 2)
            verify(browser.selectTab(beta))
            compare(browser.tabs.currentIndex, 1)
            verify(browser.selectTab(-1))
            compare(browser.tabs.currentIndex, 2)
            verify(!browser.selectTab(5))
            compare(browser.controller.indexOf(-1), 2)

            verify(browser.closeTab(beta))
            compare(browser.tabs.count, 2)
            verify(browser.findTab(v => v.title === "beta") === null)
            verify(browser.actions.action("tab.reopenClosed").enabled)
            verify(browser.trigger("tab.reopenClosed"))
            compare(browser.tabs.count, 3)
            compare(browser.tabs.currentIndex, 1, "reopened at its old position")
            tryCompare(browser, "title", "beta", 10000)
        }

        function test_15_custom_layout_without_browser() {
            // Swap which KeyBindings owns the keys.
            browser.keyBindings.enabled = false
            plainKeys.enabled = true
            compare(plainTabs.count, 0)
            keyClick(Qt.Key_T, Qt.ControlModifier)
            tryCompare(plainTabs, "count", 1, 2000)
            verify(!plainActions.action("address.focus").enabled, "no address field in this layout")
            let r = null
            plainController.navigate(page("plain")).then(x => r = x)
            tryVerify(() => r !== null, 10000)
            compare(plainTabs.currentView.title, "plain")
            keyClick(Qt.Key_W, Qt.ControlModifier)
            tryCompare(plainTabs, "count", 0, 2000)
            compare(browser.tabs.count, 3, "Browser's tabs untouched")
            plainKeys.enabled = false
            browser.keyBindings.enabled = true
            keyClick(Qt.Key_N, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 4, 5000)
        }

        // Browser's LinkHints over the current tab (see tst_linkhints.qml).
        function test_16_browser_link_hints() {
            browser.tabs.restore([page("links", "<a href='#a' onclick='document.title = \"clicked:\" + event.isTrusted'>A link</a>")], 0)
            tryCompare(browser, "title", "links", 10000)
            compare(evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))"), 1)
            view().forceActiveFocus()
            compare(browser.keyBindings.sequencesFor("hints.open"), ["Alt+F"])
            compare(browser.keyBindings.sequencesFor("hints.newTab"), ["Alt+Shift+F"])
            compare(browser.linkHints.view, view())
            keyClick(Qt.Key_F, Qt.AltModifier)
            tryVerify(() => browser.linkHints.active && !browser.linkHints.busy, 10000)
            compare(browser.linkHints.hints.length, 1)
            keyClick(browser.linkHints.labels[0])
            tryCompare(browser, "title", "clicked:true", 5000)
            verify(!browser.linkHints.active)
            verify(view().activeFocus)
        }
    }
}
