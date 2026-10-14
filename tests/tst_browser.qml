// End-to-end tests of the reference Browser (CefQml.Components), driven
// through real keyboard/mouse input. Pages are data: URLs, so no network.
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

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        searchUrl: "data:text/html,<title>search</title><p id=q>%s</p>"
    }

    TestCase {
        name: "Browser"
        when: windowShown

        function find(name) {
            const item = findChild(browser, name)
            verify(item, "no child " + name)
            return item
        }
        function view() { return browser.currentView }
        function evaluate(script) {
            let out = null
            view().evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, script)
            return out[0]
        }
        function center(item) { return item.mapToItem(root, item.width / 2, item.height / 2) }
        function click(item, button) {
            const p = center(item)
            mouseClick(root, p.x, p.y, button || Qt.LeftButton)
        }
        function navigate(url) {
            const field = find("addressInput")
            keyClick(Qt.Key_L, Qt.ControlModifier)
            tryVerify(() => field.activeFocus, 2000, "Ctrl+L focuses the address field")
            field.text = url
            keyClick(Qt.Key_Return)
        }
        function resetTabs() {
            browser.tabs.restore([page("start")], 0)
            tryCompare(browser, "title", "start", 10000)
        }

        function initTestCase() {
            tryCompare(browser.tabs, "count", 1, 10000)
            tryCompare(browser, "title", "New Tab", 15000)
        }

        function test_01_new_tab_page() {
            compare(find("addressInput").text, "", "new-tab page URL is hidden")
            verify(!find("backButton").enabled)
            verify(!find("forwardButton").enabled)
        }

        function test_02_address_bar_navigation() {
            navigate(page("first"))
            tryCompare(browser, "title", "first", 10000)
            tryVerify(() => view().activeFocus, 2000, "page gets focus after navigating")
            navigate(page("second"))
            tryCompare(browser, "title", "second", 10000)
            tryVerify(() => find("backButton").enabled, 5000)
        }

        function test_03_back_forward_buttons() {
            click(find("backButton"))
            tryCompare(browser, "title", "first", 10000)
            tryVerify(() => find("forwardButton").enabled, 5000)
            click(find("forwardButton"))
            tryCompare(browser, "title", "second", 10000)
            keyClick(Qt.Key_Left, Qt.AltModifier)
            tryCompare(browser, "title", "first", 10000)
        }

        function test_04_search_fallback() {
            const field = find("addressInput")
            keyClick(Qt.Key_L, Qt.ControlModifier)
            tryVerify(() => field.activeFocus, 2000)
            keyClick(Qt.Key_H); keyClick(Qt.Key_I); keyClick(Qt.Key_Space); keyClick(Qt.Key_Y); keyClick(Qt.Key_O)
            compare(field.text, "hi yo")
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "search", 10000)
            compare(evaluate("q.textContent"), "hi yo")
        }

        function test_05_address_bar_typed_host() {
            compare(browser.navigationBar.addressField.urlFor("example.com").toString(), "https://example.com")
            verify(browser.navigationBar.addressField.urlFor("two words").toString().startsWith("data:text/html"))
        }

        function test_06_tab_shortcuts() {
            resetTabs()
            keyClick(Qt.Key_T, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 2, 5000)
            compare(browser.tabs.currentIndex, 1)
            tryVerify(() => find("addressInput").activeFocus, 2000, "new tab focuses the address field")
            navigate(page("tab two"))
            tryCompare(browser, "title", "tab two", 10000)
            keyClick(Qt.Key_Tab, Qt.ControlModifier)
            tryCompare(browser.tabs, "currentIndex", 0, 2000)
            compare(browser.title, "start")
            keyClick(Qt.Key_2, Qt.ControlModifier)
            tryCompare(browser.tabs, "currentIndex", 1, 2000)
            keyClick(Qt.Key_W, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 1, 5000)
            compare(browser.title, "start")
        }

        function test_07_tab_strip_mouse() {
            resetTabs()
            click(find("newTabButton"))
            tryCompare(browser.tabs, "count", 2, 5000)
            browser.currentView.url = page("other")
            tryCompare(browser, "title", "other", 10000)
            click(find("tab0"))
            tryCompare(browser.tabs, "currentIndex", 0, 2000)
            compare(browser.title, "start")
            click(find("tab1"), Qt.MiddleButton)
            tryCompare(browser.tabs, "count", 1, 5000)
        }

        function test_08_link_opens_tab_next_to_opener() {
            resetTabs()
            browser.tabs.openTab(page("last"), true)
            compare(browser.tabs.count, 2)
            view().url = page("opener", "<a href='" + page("popup") + "' target=_blank style='display:block;width:300px;height:60px'>open</a>")
            tryCompare(browser, "title", "opener", 10000)
            wait(200)
            const v = view()
            const p = v.mapToItem(root, 100, 30)
            mouseClick(root, p.x, p.y)
            tryCompare(browser.tabs, "count", 3, 5000)
            compare(browser.tabs.currentIndex, 1, "foreground popup tab becomes current")
            tryCompare(browser, "title", "popup", 10000)
            compare(browser.tabs.views[2].title, "last", "popup inserted after its opener")
        }

        function test_09_window_close_closes_tab() {
            resetTabs()
            browser.tabs.openTab(page("closing"))
            tryCompare(browser.tabs, "count", 2, 5000)
            tryCompare(browser, "title", "closing", 10000)
            // Scripts may close a tab whose history holds a single document
            // (so the bootstrap about:blank entry must not linger).
            view().runJavaScript("window.close()")
            tryCompare(browser.tabs, "count", 1, 5000)
            compare(browser.title, "start")
        }

        function test_10_find_bar() {
            resetTabs()
            view().url = page("find", "<p>apple pear apple plum apple</p>")
            tryCompare(browser, "title", "find", 10000)
            keyClick(Qt.Key_F, Qt.ControlModifier)
            const input = find("findInput")
            tryVerify(() => input.activeFocus, 2000)
            keyClick(Qt.Key_A); keyClick(Qt.Key_P); keyClick(Qt.Key_P); keyClick(Qt.Key_L); keyClick(Qt.Key_E)
            const status = find("findStatus")
            tryCompare(status, "text", "1 / 3", 5000)
            keyClick(Qt.Key_Return)
            tryCompare(status, "text", "2 / 3", 5000)
            keyClick(Qt.Key_Return, Qt.ShiftModifier)
            tryCompare(status, "text", "1 / 3", 5000)
            keyClick(Qt.Key_Escape)
            verify(!browser.findBar.visible)
        }

        function test_11_prompt_dialog_overlay() {
            resetTabs()
            view().url = page("dialog")
            tryCompare(browser, "title", "dialog", 10000)
            view().runJavaScript("setTimeout(() => document.title = 'answer:' + prompt('Your name?', 'def'), 10)")
            const message = find("requestMessage")
            tryCompare(message, "text", "Your name?", 5000)
            const input = find("promptInput")
            tryVerify(() => input.activeFocus, 2000)
            compare(input.text, "def")
            input.selectAll()
            keyClick(Qt.Key_Z)
            keyClick(Qt.Key_Return)
            tryCompare(browser, "title", "answer:z", 5000)
        }

        function test_12_confirm_cancel_via_button() {
            view().runJavaScript("setTimeout(() => document.title = 'confirmed:' + confirm('Sure?'), 10)")
            tryCompare(find("requestMessage"), "text", "Sure?", 5000)
            click(find("rejectButton"))
            tryCompare(browser, "title", "confirmed:false", 5000)
        }

        function test_13_context_menu_open_link() {
            resetTabs()
            view().url = page("ctx", "<a href='" + page("from menu") + "' style='display:block;width:300px;height:60px'>link</a>")
            tryCompare(browser, "title", "ctx", 10000)
            // The title arrives before the link is laid out and painted; a
            // right click before that hits the page instead of the link.
            compare(evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))"), 1)
            const p = view().mapToItem(root, 100, 30)
            mouseClick(root, p.x, p.y, Qt.RightButton)
            const panel = find("contextMenuPanel")
            tryVerify(() => panel.visible && panel.parent.visible, 5000)
            verify(panel.parent.linkUrl.toString().startsWith("data:"), "menu opened on the link")
            // First entry: "Open link in new tab".
            mouseClick(root, panel.mapToItem(root, 40, 18).x, panel.mapToItem(root, 40, 18).y)
            tryCompare(browser.tabs, "count", 2, 5000)
            compare(browser.tabs.currentIndex, 0, "opened in the background")
            tryCompare(browser.tabs.views[1], "title", "from menu", 10000)
        }

        function test_14_zoom_shortcuts() {
            keyClick(Qt.Key_Equal, Qt.ControlModifier)
            tryVerify(() => Math.abs(view().zoomFactor - 1.1) < 0.01, 2000)
            keyClick(Qt.Key_0, Qt.ControlModifier)
            compare(view().zoomFactor, 1)
        }

        function test_15_session_roundtrip() {
            browser.tabs.restore([page("a"), page("b"), page("c")], 2)
            tryCompare(browser, "title", "c", 10000)
            const urls = browser.tabs.urls()
            compare(urls.length, 3)
            browser.tabs.restore(urls, 1)
            tryCompare(browser, "title", "b", 10000)
        }

        function test_16_last_tab_close_opens_new_tab() {
            resetTabs()
            keyClick(Qt.Key_W, Qt.ControlModifier)
            tryCompare(browser.tabs, "count", 1, 5000)
            tryCompare(browser, "title", "New Tab", 10000)
        }

        function test_17_userscript_manager_and_install_prompt() {
            resetTabs()
            const store = browser.userScriptStore
            verify(store)
            const overlay = find("userScriptOverlay")
            verify(!overlay.visible)
            // Ctrl+Shift+U toggles the manager.
            keyClick(Qt.Key_U, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(() => overlay.visible, 2000)
            verify(browser.userScriptManagerVisible)
            verify(browser.actions.action("userscripts.manage").checked)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !overlay.visible, 2000, "Escape closes it")

            // A *.user.js page offers to install the script.
            const source = "// ==UserScript==\n// @name Prompted\n// @version 1.5\n// @grant none\n" +
                           "// ==/UserScript==\ndocument.documentElement.setAttribute('data-prompted', 'yes')\n"
            const path = Cef.profileDir + "/prompted.user.js"
            const xhr = new XMLHttpRequest()
            xhr.open("PUT", "file://" + path)
            xhr.send(source)
            tryVerify(() => xhr.readyState === XMLHttpRequest.DONE, 5000)
            view().url = "file://" + path
            tryVerify(() => overlay.visible, 10000, "install prompt")
            const manager = browser.userScriptManager
            tryCompare(manager, "editing", "new", 5000)
            verify(manager.status.indexOf("Install Prompted 1.5?") === 0, manager.status)
            compare(manager.editorText, source)
            click(find("userScriptSave"))
            tryCompare(store, "count", 1, 2000)
            compare(store.scripts[0].url, "file://" + path)
            click(find("userScriptClose"))
            tryVerify(() => !overlay.visible, 2000)

            // It runs on the next page, and the manager shows it running.
            tryVerify(() => store.isApplied(view()), 5000)
            view().url = page("us page")
            tryCompare(browser, "title", "us page", 10000)
            tryVerify(() => evaluate("document.documentElement.getAttribute('data-prompted')") === "yes", 5000)
            browser.trigger("userscripts.manage")
            tryVerify(() => overlay.visible, 2000)
            tryVerify(() => find("userScriptRunning_" + store.scripts[0].id).visible, 5000)
            browser.hideUserScripts()
            verify(!overlay.visible)
            store.remove(store.scripts[0].id)
        }
    }
}
