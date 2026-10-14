// Keyboard link hints and page navigation (CefQml.Components: LinkHints,
// BrowserController.scrollPage/focusInput, the hints.* and page.scroll*
// actions) and CefWebView's synthetic input (sendMouseClick, sendKey) and
// editableFocused, in a custom layout without Browser. Pages are data: URLs.
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 1000
    height: 700

    function page(title, body) {
        return "data:text/html," + encodeURIComponent("<title>" + title + "</title>" + (body || ""))
    }

    // Records clicks and the like: clicks = ["id:isTrusted", ...].
    readonly property string recorder:
        "<style>body{margin:0;font:16px sans-serif} p{margin:4px 0}</style>" +
        "<script>window.clicks = []; function rec(e, id) { clicks.push(id + ':' + e.isTrusted) }</script>"

    readonly property string mainPage: page("main", recorder +
        "<p><a id=alpha href='#alpha' onclick=\"rec(event,'alpha')\">Alpha link</a></p>" +
        "<p><button id=bunny onclick=\"rec(event,'bunny')\">Bunny button</button></p>" +
        "<p><input id=field placeholder='Text field'></p>" +
        "<div role=button id=role onclick=\"rec(event,'role')\">Role div</div>" +
        "<div id=pointer style='cursor:pointer' onclick=\"rec(event,'pointer')\">Pointer div <span>with a span</span></div>" +
        "<div id=pure style='cursor:pointer;width:200px'>Pure pointer</div>" +
        "<p><span id=onclick onclick=\"rec(event,'onclick')\">Onclick span</span></p>" +
        "<p><span id=hover onmouseover=\"rec(event,'hover')\" tabindex=0>Hover target</span></p>" +
        "<details><summary id=summary>Summary</summary>Details</details>" +
        "<p><label for=check>Check me</label><input type=checkbox id=check></p>" +
        "<div contenteditable id=editable style='width:200px'>Editable</div>" +
        "<p><a id=external href='http://127.0.0.1:9/x'>External link</a></p>" +
        // A same-origin frame (srcdoc frames never finish loading in a data: page).
        "<iframe id=frame style='border:0;height:30px;width:300px;display:block'></iframe><script>" +
            "frame.contentDocument.body.style.margin = '0';" +
            "frame.contentDocument.body.innerHTML = \"<a id=inframe href='#f'>Frame link</a>\";" +
            "frame.contentDocument.getElementById('inframe').onclick = e => rec(e, 'inframe')</script>" +
        // Not hinted:
        "<a href='#n' style='display:none'>Display none</a>" +
        "<a href='#n' style='visibility:hidden'>Visibility hidden</a>" +
        "<div style='position:relative;height:24px'><a href='#n'>Covered link</a>" +
            "<div style='position:absolute;left:0;top:0;right:0;bottom:0;background:white'></div></div>" +
        "<div style='overflow:hidden;height:20px'><div style='height:100px'></div><a href='#n'>Clipped link</a></div>" +
        "<a href='#n' style='position:absolute;top:2000px'>Below the fold</a>" +
        "<a href='#n' style='position:absolute;left:-400px;top:10px'>Left of the page</a>" +
        "<button disabled>Disabled button</button>" +
        "<div style='height:3000px'></div>")

    readonly property var mainTexts: ["Alpha link", "Bunny button", "Text field", "Role div", "Pointer div with a span",
        "Pure pointer", "Onclick span", "Hover target", "Summary", "Check me", "Editable", "External link", "Frame link"]

    property bool modal: false

    // The custom layout: primitives only.
    Item {
        id: layout
        width: 800
        height: 600
        WebTabs { id: tabs; anchors.fill: parent }
        LinkHints { id: hints; anchors.fill: parent; view: tabs.currentView }
    }
    BrowserController { id: ctl; tabs: tabs }
    BrowserActions { id: acts; controller: ctl; linkHints: hints }
    // The README's vim-like modal setup: single keys while the page (not a
    // text field of it) has the focus.
    KeyBindings {
        id: keys
        actions: acts
        mode: root.modal && tabs.currentView && tabs.currentView.activeFocus
              && !tabs.currentView.editableFocused ? "normal" : ""
        modeBindings: ({
            "normal": {
                "page.scrollDown": ["J"], "page.scrollUp": ["K"],
                "page.scrollLeft": ["H"], "page.scrollRight": ["L"],
                "page.scrollPageDown": [{ sequence: "D", args: { pages: 0.5 } }],
                "page.scrollPageUp": [{ sequence: "U", args: { pages: 0.5 } }],
                "page.scrollTop": ["G, G"], "page.scrollBottom": ["Shift+G"],
                "hints.open": ["F"], "hints.newTab": ["Shift+F"],
                "hints.copyLink": ["Y, F"], "page.copyUrl": ["Y, Y"],
                "hints.focusInput": ["G, I"],
                "nav.back": ["Shift+H"], "nav.forward": ["Shift+L"], "nav.reload": ["R"],
                "tab.next": ["Shift+K"], "tab.previous": ["Shift+J"],
                "tab.close": ["X"], "tab.reopenClosed": ["Shift+X"]
            }
        })
    }

    TextInput { id: elsewhere; x: 900; y: 10; width: 80; height: 20 }
    // Reads the system clipboard (paste()).
    TextEdit { id: clipboardReader; visible: false }

    SignalSpy { id: shownSpy; target: hints; signalName: "shown" }
    SignalSpy { id: activatedSpy; target: hints; signalName: "activated" }
    SignalSpy { id: canceledSpy; target: hints; signalName: "canceled" }

    TestCase {
        name: "LinkHints"
        when: windowShown

        function view() { return tabs.currentView }
        function evaluate(script, v) {
            let out = null
            ;(v || view()).evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, script)
            if (out[1] !== undefined) fail(script + ": " + out[1])
            return out[0]
        }
        function frames() {
            compare(evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))"), 1)
        }
        function load(url, title) {
            hints.cancel()
            tabs.restore([url], 0)
            tryCompare(view(), "title", title, 10000)
            tryVerify(() => !view().loading, 10000, "loaded: " + evaluate("document.readyState"))
            frames()
            view().forceActiveFocus()
            tryVerify(() => view().activeFocus)
        }
        function clicks() { return JSON.parse(evaluate("JSON.stringify(clicks)")) }
        function show(mode, options) {
            shownSpy.clear()
            verify(hints.show(mode, options), "show " + mode)
            tryCompare(shownSpy, "count", 1, 10000)
            verify(hints.active, "active")
            verify(!hints.busy)
            return hints.hints
        }
        function hintWith(text) {
            const h = hints.hints.find(x => x.text === text)
            verify(h, "a hint for " + text + " in " + JSON.stringify(hints.hints.map(x => x.text)))
            return h
        }
        function labelOf(text) { return hints.labels[hints.hints.indexOf(hintWith(text))] }
        function typeKeys(text) { for (const c of text) keyClick(c) }
        function scrollPos() { return evaluate("[scrollX, scrollY]") }

        function cleanup() {
            hints.cancel()
            hints.activateSingleMatch = true
            hints.textFilter = true
            root.modal = false
            Cef.copyToClipboard("")
        }

        // ---- CefWebView input ---------------------------------------------

        function test_01_synthetic_input_and_editableFocused() {
            load(page("input", recorder + "<button id=b onclick=\"rec(event,'b')\" style='position:absolute;left:10px;top:10px;width:100px;height:30px'>B</button>" +
                      "<input id=i style='position:absolute;left:10px;top:60px;width:200px;height:30px'>" +
                      "<div contenteditable id=ce style='position:absolute;left:10px;top:110px;width:200px;height:30px'>x</div>"), "input")
            const v = view()
            verify(!v.editableFocused)
            v.sendMouseClick(50, 25)
            tryVerify(() => clicks().length === 1, 5000)
            compare(clicks(), ["b:true"])
            verify(!v.editableFocused, "a button takes no text")

            v.sendMouseClick(100, 75)
            tryVerify(() => v.editableFocused, 5000, "clicked into the input")
            v.sendKey(Qt.Key_H)
            v.sendKey(Qt.Key_I, Qt.ShiftModifier)
            tryVerify(() => evaluate("document.getElementById('i').value") === "hI", 5000)

            // Focus moving out of the view, and back.
            elsewhere.forceActiveFocus()
            tryVerify(() => !v.editableFocused, 5000, "the view lost the focus")
            v.forceActiveFocus()
            tryVerify(() => v.editableFocused, 5000, "back in the input")
            evaluate("document.activeElement.blur(); 1")
            tryVerify(() => !v.editableFocused, 5000, "blurred")
            evaluate("document.getElementById('ce').focus(); 1")
            tryVerify(() => v.editableFocused, 5000, "contenteditable")
            // A new page starts without.
            load(page("other", "<p>other"), "other")
            verify(!view().editableFocused)
        }

        // ---- collecting ----------------------------------------------------

        function test_02_hints_for_the_right_elements() {
            load(mainPage, "main")
            const list = show("open")
            compare(list.map(h => h.text).sort(), mainTexts.slice().sort())
            compare(hints.mode, "open")
            compare(hints.matches.length, list.length)
            // Inside the view, with click points inside the boxes.
            for (const h of list) {
                verify(h.x >= -1 && h.y >= -1 && h.x + h.width <= 801 && h.y + h.height <= 601, h.text)
                verify(h.clickX >= h.x - 1 && h.clickX <= h.x + h.width + 1, h.text + " clickX")
                verify(h.clickY >= h.y - 1 && h.clickY <= h.y + h.height + 1, h.text + " clickY")
            }
            verify(hintWith("Frame link").frame)
            compare(hintWith("External link").href, "http://127.0.0.1:9/x")
            compare(hintWith("External link").kind, "link")
            compare(hintWith("Text field").kind, "input")
            // Labels: one each, unique, over the alphabet.
            compare(hints.labels.length, list.length)
            compare(new Set(hints.labels).size, list.length)
            verify(hints.labels.every(l => l.length === 1 && hints.alphabet.indexOf(l) >= 0), JSON.stringify(hints.labels))
            // Links only.
            hints.cancel()
            compare(show("newTab").map(h => h.text).sort(), ["Alpha link", "External link", "Frame link"])
            hints.cancel()
            // A selector.
            compare(show("open", { selector: "summary, #bunny" }).map(h => h.text).sort(), ["Bunny button", "Summary"])
            hints.cancel()
            // Without the pointer heuristic.
            verify(show("open", { pointer: false }).every(h => h.text !== "Pure pointer"))
            hints.cancel()
            // Scrolled: what was below is hinted, what scrolled away is not.
            evaluate("scrollTo(0, 1800); 1")
            frames()
            const below = show("open").map(h => h.text)
            verify(below.indexOf("Below the fold") >= 0, JSON.stringify(below))
            verify(below.indexOf("Alpha link") < 0, JSON.stringify(below))
        }

        function test_03_labels_unique_and_prefix_free() {
            let links = ""
            for (let i = 0; i < 60; i++)
                links += "<a href='#l" + i + "' onclick=\"rec(event,'l" + i + "')\" style='display:inline-block;width:90px'>Link " + i + "</a> "
            load(page("many", recorder + links), "many")
            const list = show("open")
            compare(list.length, 60)
            const labels = hints.labels
            compare(new Set(labels).size, 60)
            for (const a of labels)
                for (const b of labels)
                    if (a !== b) verify(!b.startsWith(a), a + " is a prefix of " + b)
            verify(labels.every(l => l.length >= 1 && l.length <= 2))
            // As short as possible: 60 hints over 14 characters need two
            // characters for some, and one-character labels where possible.
            verify(labels.some(l => l.length === 1))
            verify(labels.some(l => l.length === 2))

            // Typing narrows; Backspace takes it back.
            const two = labels.find(l => l.length === 2)
            keyClick(two[0])
            compare(hints.typed, two[0])
            verify(hints.active)
            compare(hints.matches.length, labels.filter(l => l.startsWith(two[0])).length)
            keyClick(Qt.Key_Backspace)
            compare(hints.typed, "")
            compare(hints.matches.length, 60)
            // Without textFilter, other characters do nothing.
            hints.textFilter = false
            keyClick("z")
            compare(hints.typed, "")
            compare(hints.filterText, "")
            compare(hints.matches.length, 60)
            hints.textFilter = true
            // Upper case works too.
            const text = hints.hints[labels.indexOf(two)].text
            keyClick(two[0].toUpperCase())
            keyClick(two[1])
            tryCompare(activatedSpy, "count", 1, 5000)
            activatedSpy.clear()
            verify(!hints.active)
            tryVerify(() => clicks().length === 1, 5000)
            compare(clicks(), ["l" + text.slice(5) + ":true"])
        }

        // ---- activating ----------------------------------------------------

        function test_04_typing_a_label_clicks() {
            load(mainPage, "main")
            show("open")
            activatedSpy.clear()
            typeKeys(labelOf("Bunny button"))
            tryCompare(activatedSpy, "count", 1, 5000)
            compare(activatedSpy.signalArguments[0][1], "open")
            compare(activatedSpy.signalArguments[0][0].text, "Bunny button")
            verify(!hints.active)
            tryVerify(() => clicks().length === 1, 5000)
            compare(clicks(), ["bunny:true"])
            verify(view().activeFocus, "the page has the focus")

            // In a same-origin frame.
            show("open")
            typeKeys(labelOf("Frame link"))
            tryVerify(() => clicks().length === 2, 5000)
            compare(clicks()[1], "inframe:true")

            // A role=button, a click into a text field.
            show("open")
            typeKeys(labelOf("Role div"))
            tryVerify(() => clicks().length === 3, 5000)
            compare(clicks()[2], "role:true")
            show("open")
            typeKeys(labelOf("Text field"))
            tryVerify(() => view().editableFocused, 5000)
            compare(evaluate("document.activeElement.id"), "field")

            // activate() by label, from code.
            evaluate("document.activeElement.blur(); 1")
            show("open")
            verify(!hints.activate("nonexistent"))
            verify(hints.activate(labelOf("Onclick span")))
            tryVerify(() => clicks().length === 4, 5000)
            compare(clicks()[3], "onclick:true")
            verify(!hints.activate(0), "not active any more")
        }

        function test_05_new_tab_copy_focus_hover() {
            load(mainPage, "main")
            // newTab: a background tab next to this one.
            show("newTab")
            typeKeys(labelOf("External link"))
            tryCompare(tabs, "count", 2, 10000)
            compare(tabs.currentIndex, 0)
            tryVerify(() => tabs.views[1].url.toString() === "http://127.0.0.1:9/x", 5000)
            verify(!hints.active)
            // In front.
            show("newTab", { background: false })
            typeKeys(labelOf("External link"))
            tryCompare(tabs, "count", 3, 10000)
            tryCompare(tabs, "currentIndex", 1, 5000)
            tabs.closeTab(1)
            tabs.closeTab(1)
            compare(tabs.currentIndex, 0)
            view().forceActiveFocus()

            // copy: the link's address.
            show("copy")
            typeKeys(labelOf("External link"))
            tryVerify(() => { clipboardReader.text = ""; clipboardReader.paste()
                              return clipboardReader.text === "http://127.0.0.1:9/x" }, 5000, "copied")
            compare(tabs.count, 1)

            // focus: no click, just the focus.
            const before = clicks().length
            show("focus")
            typeKeys(labelOf("Bunny button"))
            tryVerify(() => evaluate("document.activeElement.id") === "bunny", 5000)
            verify(view().activeFocus)
            compare(clicks().length, before)

            // hover: the pointer moves over it.
            show("hover")
            typeKeys(labelOf("Hover target"))
            tryVerify(() => clicks().indexOf("hover:true") >= 0, 5000)

            // A function as the mode.
            let got = null
            show((h, v) => got = [h.text, v])
            typeKeys(labelOf("Summary"))
            tryVerify(() => got !== null, 5000)
            compare(got[0], "Summary")
            compare(got[1], view())
        }

        // ---- filtering, cancelling -----------------------------------------

        function test_06_filter_and_cancel() {
            load(mainPage, "main")
            // "bunny": no label character, so it filters.
            hints.activateSingleMatch = false
            show("open")
            typeKeys("bunnyq")
            compare(hints.filterText, "bunnyq")
            compare(hints.matches.length, 0)
            keyClick(Qt.Key_Backspace)
            compare(hints.filterText, "bunny")
            compare(hints.matches.length, 1)
            compare(hints.matches[0].text, "Bunny button")
            // Relabeled from the start of the alphabet.
            compare(hints.labels.filter(l => l !== "").length, 1)
            compare(hints.labels[hints.hints.indexOf(hints.matches[0])], hints.alphabet[0])
            keyClick(Qt.Key_Return)
            tryVerify(() => clicks().indexOf("bunny:true") >= 0, 5000)
            verify(!hints.active)

            // Several words, in any order; a single match acts at once.
            hints.activateSingleMatch = true
            show("open")
            typeKeys("o")
            verify(hints.active)
            verify(hints.matches.length > 1)
            typeKeys(" bu")
            tryVerify(() => !hints.active, 5000)
            tryVerify(() => clicks().filter(c => c === "bunny:true").length === 2, 5000)

            // Typed while still collecting: kept and applied.
            hints.show("open")
            hints.type("bunny")
            tryVerify(() => clicks().filter(c => c === "bunny:true").length === 3, 10000)
            verify(!hints.active)

            // Escape cancels and gives the focus back.
            canceledSpy.clear()
            show("open")
            verify(!view().activeFocus)
            keyClick(Qt.Key_Escape)
            verify(!hints.active)
            compare(canceledSpy.count, 1)
            verify(view().activeFocus)
            // show() again in the same mode toggles.
            show("open")
            verify(!hints.show("open"))
            verify(!hints.active)
            // Losing the focus cancels.
            show("open")
            elsewhere.forceActiveFocus()
            verify(!hints.active)
            // A load cancels.
            view().forceActiveFocus()
            show("open")
            evaluate("location.hash = 'x'; 1")
            view().reload()
            tryVerify(() => !hints.active, 10000)
            // Nothing to hint.
            load(page("empty", "<p>nothing here"), "empty")
            canceledSpy.clear()
            shownSpy.clear()
            verify(hints.show("open"))
            tryCompare(shownSpy, "count", 1, 10000)
            compare(shownSpy.signalArguments[0][0], 0)
            verify(!hints.active)
            compare(canceledSpy.count, 1)
        }

        // While hinting, hint keys beat window-wide shortcuts.
        function test_07_keys_and_actions() {
            load(mainPage, "main")
            compare(keys.conflicts, [])
            compare(keys.sequencesFor("hints.open"), ["Alt+F"])
            compare(keys.sequencesFor("hints.newTab"), ["Alt+Shift+F"])
            compare(keys.sequencesFor("hints.copyLink"), [])
            compare(keys.sequencesFor("page.scrollDown"), [])
            shownSpy.clear()
            keyClick(Qt.Key_F, Qt.AltModifier)
            tryCompare(shownSpy, "count", 1, 10000)
            compare(hints.mode, "open")
            // Label keys bound window-wide do not fire while hinting.
            let fired = 0
            acts.add({ name: "test.never", text: "Never", onTriggered: () => fired++ })
            keys.bind("test.never", hints.alphabet.toUpperCase().split(""))
            typeKeys(labelOf("Bunny button"))
            tryVerify(() => clicks().indexOf("bunny:true") >= 0, 5000)
            compare(fired, 0)
            keys.reset("test.never")
            acts.remove("test.never")

            keyClick(Qt.Key_F, Qt.AltModifier | Qt.ShiftModifier)
            tryVerify(() => hints.active && hints.mode === "newTab", 10000)
            keyClick(Qt.Key_Escape)
            verify(acts.trigger("hints.copyLink"))
            tryVerify(() => hints.active && hints.mode === "copy", 10000)
            keyClick(Qt.Key_Escape)
            verify(!hints.active)
            // Not offered without a LinkHints.
            acts.linkHints = null
            verify(!acts.action("hints.open").enabled)
            verify(acts.action("hints.focusInput").enabled)
            acts.linkHints = hints
        }

        // ---- focusInput, scrolling -----------------------------------------

        function test_08_focus_input() {
            load(page("inputs", "<button>b</button><input id=i1><input type=checkbox><textarea id=i2></textarea>" +
                      "<input id=ro readonly><input id=i3 value=abc>"), "inputs")
            verify(!view().editableFocused)
            elsewhere.forceActiveFocus()
            verify(acts.trigger("hints.focusInput"))
            tryVerify(() => view().editableFocused, 5000)
            verify(view().activeFocus)
            compare(evaluate("document.activeElement.id"), "i1")
            acts.trigger("hints.focusInput")
            tryVerify(() => evaluate("document.activeElement.id") === "i2", 5000)
            acts.trigger("hints.focusInput")
            tryVerify(() => evaluate("document.activeElement.id") === "i3", 5000)
            compare(evaluate("document.activeElement.selectionStart"), 3, "caret at the end")
            acts.trigger("hints.focusInput")
            tryVerify(() => evaluate("document.activeElement.id") === "i1", 5000)
            let r = null
            ctl.focusInput({ index: -1, select: true }).then(x => r = x)
            tryVerify(() => r !== null, 5000)
            compare(r.ok, true)
            compare(r.count, 3)
            compare(r.index, 2)
            compare(evaluate("document.activeElement.id + document.activeElement.selectionStart + document.activeElement.selectionEnd"), "i303")
            // Typed text goes there.
            view().sendKey(Qt.Key_X)
            tryVerify(() => evaluate("document.activeElement.value") === "x", 5000)
            // A page without text fields.
            load(page("none", "<button>b</button>"), "none")
            r = null
            ctl.focusInput().then(x => r = x)
            tryVerify(() => r !== null, 5000)
            compare(r.ok, false)
            compare(r.count, 0)
        }

        function test_09_scroll_actions() {
            load(page("tall", "<body style='margin:0'><div style='width:3000px;height:5000px'></div>"), "tall")
            compare(scrollPos(), [0, 0])
            verify(acts.trigger("page.scrollDown"))
            tryVerify(() => scrollPos()[1] === 60, 5000)
            acts.trigger("page.scrollDown", { amount: 100 })
            tryVerify(() => scrollPos()[1] === 160, 5000)
            acts.trigger("page.scrollUp")
            tryVerify(() => scrollPos()[1] === 100, 5000)
            const h = evaluate("visualViewport.height")  // without the horizontal scrollbar
            acts.trigger("page.scrollPageDown")
            tryVerify(() => scrollPos()[1] === 100 + Math.round(h * 0.9), 5000)
            acts.trigger("page.scrollPageUp", { pages: 0.5 })
            tryVerify(() => scrollPos()[1] === 100 + Math.round(h * 0.9) - Math.round(h * 0.5), 5000)
            acts.trigger("page.scrollBottom")
            tryVerify(() => scrollPos()[1] === 5000 - h, 5000)
            acts.trigger("page.scrollTop")
            tryVerify(() => scrollPos()[1] === 0, 5000)
            acts.trigger("page.scrollRight")
            tryVerify(() => scrollPos()[0] === 60, 5000)
            acts.trigger("page.scrollLeft")
            tryVerify(() => scrollPos()[0] === 0, 5000)
            let r = null
            ctl.scrollPage("down", { amount: 10 }).then(x => r = x)
            tryVerify(() => r !== null, 5000)
            compare(r.ok, true)
            compare(r.moved, true)
            compare(r.element, "document")
            compare(r.y, 10)
            r = null
            ctl.scrollPage("sideways").then(x => r = x)
            tryVerify(() => r !== null, 5000)
            compare(r.ok, false)

            // A scrollable box around the focused element scrolls instead.
            load(page("box", "<body style='margin:0'><div id=box style='height:200px;overflow:auto'>" +
                      "<button id=b>b</button><div style='height:2000px'></div></div><div style='height:5000px'></div>"), "box")
            evaluate("document.getElementById('b').focus(); 1")
            acts.trigger("page.scrollDown")
            tryVerify(() => evaluate("document.getElementById('box').scrollTop") === 60, 5000)
            compare(scrollPos()[1], 0)
            acts.trigger("page.scrollBottom")
            tryVerify(() => evaluate("document.getElementById('box').scrollTop") > 1000, 5000)
            // At its end, the next scroll moves the document.
            acts.trigger("page.scrollDown")
            tryVerify(() => scrollPos()[1] === 60, 5000)
        }

        // ---- zoom ----------------------------------------------------------

        function test_10_zoomed_page() {
            tabs.restore([page("zoom", recorder +
                "<button id=z onclick=\"rec(event,'z')\" style='position:absolute;left:300px;top:200px;width:100px;height:40px'>Zoomed</button>" +
                "<button id=y onclick=\"rec(event,'y')\" style='position:absolute;left:20px;top:20px;width:20px;height:20px'>Y</button>")], 0)
            tryCompare(view(), "title", "zoom", 10000)
            view().zoomFactor = 1.5
            tryVerify(() => evaluate("devicePixelRatio") === 1.5, 10000, "zoom applied")
            frames()
            view().forceActiveFocus()
            show("open")
            const z = hintWith("Zoomed")
            fuzzyCompare(z.x, 450, 2)
            fuzzyCompare(z.y, 300, 2)
            fuzzyCompare(z.width, 150, 2)
            fuzzyCompare(z.height, 60, 2)
            const y = hintWith("Y")
            fuzzyCompare(y.x, 30, 2)
            fuzzyCompare(y.width, 30, 2)
            typeKeys(labelOf("Y"))
            tryVerify(() => clicks().length === 1, 5000)
            compare(clicks(), ["y:true"])
            show("open")
            typeKeys(labelOf("Zoomed"))
            tryVerify(() => clicks().length === 2, 5000)
            compare(clicks()[1], "z:true")
            // The label sits on the element.
            show("open")
            const item = findLabel(labelOf("Zoomed"))
            verify(item)
            const p = item.mapToItem(view(), 0, 0)
            fuzzyCompare(p.x, 450, 2)
            fuzzyCompare(p.y, 300, 2)
            hints.cancel()
            view().zoomFactor = 1
        }
        function findLabel(label) {
            const find = item => {
                for (let i = 0; i < item.children.length; i++) {
                    const c = item.children[i]
                    if (c.objectName === "linkHintLabel" && c.label === label && c.visible) return c
                    const r = find(c)
                    if (r) return r
                }
                return null
            }
            return find(hints)
        }

        // ---- the modal example ---------------------------------------------

        function test_11_modal_bindings() {
            root.modal = true
            load(mainPage, "main")
            compare(keys.mode, "normal")
            compare(keys.conflicts, [])
            keyClick(Qt.Key_J)
            tryVerify(() => scrollPos()[1] === 60, 5000)
            keyClick(Qt.Key_J)
            tryVerify(() => scrollPos()[1] === 120, 5000)
            keyClick(Qt.Key_K)
            tryVerify(() => scrollPos()[1] === 60, 5000)
            keyClick(Qt.Key_G, Qt.ShiftModifier)
            tryVerify(() => scrollPos()[1] > 1000, 5000)
            keyClick(Qt.Key_G)
            keyClick(Qt.Key_G)
            tryVerify(() => scrollPos()[1] === 0, 5000)

            // F: hints; their keys are not the mode's (S is not bound, but
            // F, J, K are, and labels use them).
            keyClick(Qt.Key_F)
            tryVerify(() => hints.active && !hints.busy, 10000)
            compare(keys.mode, "")
            typeKeys(labelOf("Text field"))
            tryVerify(() => view().editableFocused, 5000)
            // Typing in a text field: no mode, letters reach the page.
            compare(keys.mode, "")
            keyClick(Qt.Key_J)
            keyClick(Qt.Key_K)
            tryVerify(() => evaluate("document.getElementById('field').value") === "jk", 5000)
            compare(scrollPos()[1], 0)
            evaluate("document.activeElement.blur(); 1")
            tryCompare(keys, "mode", "normal", 5000)
            // G, I: the first text field.
            keyClick(Qt.Key_G)
            keyClick(Qt.Key_I)
            tryVerify(() => view().editableFocused, 5000)
            compare(evaluate("document.activeElement.id"), "field")
            evaluate("document.activeElement.blur(); 1")
            tryCompare(keys, "mode", "normal", 5000)
            // Shift+F: a background tab.
            keyClick(Qt.Key_F, Qt.ShiftModifier)
            tryVerify(() => hints.active && hints.mode === "newTab" && !hints.busy, 10000)
            typeKeys(labelOf("External link"))
            tryCompare(tabs, "count", 2, 10000)
            compare(tabs.currentIndex, 0)
            // Shift+K: the next tab; X closes it.
            view().forceActiveFocus()
            tryCompare(keys, "mode", "normal", 5000)
            keyClick(Qt.Key_K, Qt.ShiftModifier)
            tryCompare(tabs, "currentIndex", 1, 5000)
            view().forceActiveFocus()
            tryCompare(keys, "mode", "normal", 5000)
            keyClick(Qt.Key_X)
            tryCompare(tabs, "count", 1, 5000)
            // Without the focus in the page, no mode.
            elsewhere.forceActiveFocus()
            compare(keys.mode, "")
        }
    }
}
