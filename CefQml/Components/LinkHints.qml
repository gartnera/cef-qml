import QtQuick
import QtQuick.Window
import CefQml
import "PageTools.js" as PageTools

// Keyboard link hints (as in Vimium or qutebrowser): show() labels the
// clickable elements visible in `view`; typing a label acts on its element.
//
//   LinkHints { id: hints; anchors.fill: myView; view: myView }
//   BrowserActions { linkHints: hints; ... }   // hints.open: Alt+F, hints.newTab: Alt+Shift+F
//   hints.show("open")                          // or "newTab", "copy", "focus", "hover"
//
// The labels are drawn by this item, positioned over the elements of `view`
// with mapToItem(), so put it above the view in z order and over it (it may
// cover more, e.g. the whole window); it only shows while hinting. The page
// is not changed: elements are found by a script in an isolated world.
//
// Modes:
//   open    click the element (a real, trusted click through the view)
//   newTab  open the link in a new tab: a middle click, so the view's
//           newWindowRequested opens it (in the background unless
//           options.background is false); links only
//   copy    copy the link's address; links only
//   focus   focus the element (also for elements that cannot be clicked)
//   hover   move the mouse pointer over the element
//   a function(hint, view) does what it likes with the chosen hint
// options (show()'s second argument): { elements: "clickable" | "links" |
// "focusable" | "inputs" (default: by mode), selector (CSS; overrides
// elements), pointer (cursor: pointer heuristic; default pointerHeuristic),
// background (newTab), modifiers (open: Qt.KeyboardModifier flags for the
// click, e.g. Qt.ControlModifier) }.
//
// Keys while hinting: label characters (case does not matter) narrow the
// hints and act on the element when a label is complete. With textFilter,
// other characters (and label characters that start no label) filter the
// hints by their text instead and the labels are made again for the matching
// elements (with activateSingleMatch, a single match acts at once); for
// plenty of filtering, use digits as the alphabet ("1234567890") so letters
// always filter. Enter acts on the first match, Backspace takes back a
// character, Escape (or a click, a scroll, losing the focus, a load or a
// resize of the view) cancels. Hint keys win over window-wide shortcuts.
FocusScope {
    id: hints

    property CefWebView view: null
    // Label characters; labels are as short as the number of hints allows.
    property string alphabet: "sadfjklewcmpgh"
    // Typed text that does not complete a label filters the hints.
    property bool textFilter: true
    // When the filter leaves a single hint, act on it.
    property bool activateSingleMatch: true
    // Show labels in upper case (they are typed in either case).
    property bool uppercaseLabels: true
    // Also hint elements that look clickable (cursor: pointer) without
    // being links, buttons or similar ("clickable" elements only).
    property bool pointerHeuristic: true
    // newTab opens tabs in the background unless options.background says.
    property bool backgroundTabs: true

    // ---- look ----------------------------------------------------------------

    property color labelColor: "#1d1d1f"
    property color typedColor: "#9b7a16"
    property color labelBackground: "#ffd866"
    property color labelBorder: "#b8941f"
    // Outline of the elements whose labels start with what was typed.
    property color outlineColor: Style.accent
    property string fontFamily: "monospace"
    property int fontPixelSize: 12

    // ---- state ---------------------------------------------------------------

    readonly property bool active: _active
    // Collecting hints (keys typed meanwhile are kept).
    readonly property bool busy: _busy
    // The mode of show() while active.
    readonly property var mode: _mode
    // The elements found: [{ index, kind ("link", "button", "input",
    // "select", "label", "element"), tag, text, href, frame (in an iframe),
    // x, y, width, height (this item's coordinates), clickX, clickY (where
    // a click goes, in view coordinates) }].
    readonly property var hints: _hints
    // The label of each hint ("" when the filter hides it).
    readonly property var labels: _labels
    // The hints still offered (label starts with `typed`, filter matches).
    readonly property var matches: _matches
    // Typed label characters.
    readonly property string typed: _typed
    // Text the hints are filtered by (their text, or address if they have none).
    property string filterText: ""

    signal shown(int count)
    signal activated(var hint, var mode)
    signal canceled()

    // ---- API -----------------------------------------------------------------

    // Starts hinting in `mode` (default "open"); returns false when there
    // is no view. Called again in the same mode while active, it cancels.
    function show(mode, options) {
        if (mode === undefined || mode === null || mode === "") mode = "open"
        if (typeof mode !== "function" && _modes.indexOf(mode) < 0) {
            console.warn("LinkHints: unknown mode", mode)
            return false
        }
        if (_active && mode === _mode) { cancel(); return false }
        if (!view || !view.ready || !view.visible) return false
        options = options || {}
        const w = Window.window
        const f = w ? w.activeFocusItem : null
        if (!_active) _restoreFocus = f && !_contains(f) ? f : null
        _clear()
        _mode = mode
        _options = options
        _view = view
        _active = true
        _busy = true
        const gen = ++_generation
        forceActiveFocus(Qt.OtherFocusReason)
        const opts = {
            elements: options.elements || _defaultElements(mode),
            selector: options.selector || "",
            pointer: options.pointer !== undefined ? !!options.pointer : pointerHeuristic
        }
        PageTools.call(view, "collect", [opts], (r, err) => {
            if (gen !== _generation || !_active) return
            _busy = false
            if (err !== undefined || !r || !Array.isArray(r.hints)) {
                if (err !== undefined) console.warn("LinkHints: collecting hints failed:", err)
                shown(0)
                cancel()
                return
            }
            _build(r)
            shown(_hints.length)
            if (gen !== _generation || !_active) return
            if (_hints.length === 0) { cancel(); return }
            const pending = _pending
            _pending = []
            for (const k of pending) {
                if (!_active || gen !== _generation) break
                if (k === "\r") activate(_matches[0])
                else if (k === "\b") _backspace()
                else _typeChar(k)
            }
        })
        return true
    }

    // Stops hinting and gives the focus back.
    function cancel() {
        if (!_active) return
        _finish(true)
        canceled()
    }

    // Acts on `hint` (one of `hints`, its label, or its position in
    // `hints`) in the current mode. Returns false if there is no such hint.
    function activate(hint) {
        if (!_active || _busy) return false
        if (typeof hint === "string") {
            const i = _labels.indexOf(hint.toLowerCase())
            hint = hint !== "" && i >= 0 ? _hints[i] : null
        } else if (typeof hint === "number") {
            hint = _hints[hint] || null
        }
        if (hint && _hints.indexOf(hint) < 0) hint = _hints.find(h => h.index === hint.index) || null
        if (!hint) return false
        const v = _view, mode = _mode, options = _options, xf = _xf
        _finish(true)
        PageTools.call(v, "point", [hint.index], (p, err) => {
            const h = Object.assign({}, hint)
            if (p && typeof p.x === "number") {
                const q = _toView(xf, p.x, p.y)
                h.clickX = q.x
                h.clickY = q.y
            }
            _perform(v, mode, options, h)
            activated(h, mode)
        })
        return true
    }

    // Types `text` as if typed while hinting.
    function type(text) {
        for (const c of String(text)) {
            if (!_active) return
            if (_busy) _pending.push(c)
            else _typeChar(c)
        }
    }

    // The hint labeled `label`, or null.
    function hintFor(label) {
        const i = _labels.indexOf(String(label).toLowerCase())
        return label !== "" && i >= 0 ? _hints[i] : null
    }

    // ---- internals -----------------------------------------------------------

    readonly property var _modes: ["open", "newTab", "copy", "focus", "hover"]
    property bool _active: false
    property bool _busy: false
    property var _mode: ""
    property var _options: ({})
    property CefWebView _view: null
    property var _hints: []
    property var _labels: []
    property var _matches: []
    property string _typed: ""
    property var _pending: []
    property var _xf: null
    property rect _viewRect: Qt.rect(0, 0, 0, 0)
    property var _restoreFocus: null
    property int _generation: 0
    property bool _finishing: false
    property bool _relabeling: false

    visible: _active
    z: 1000

    function _contains(item) {
        for (let p = item; p; p = p.parent) if (p === hints) return true
        return false
    }

    function _defaultElements(mode) {
        switch (mode) {
        case "newTab": case "copy": return "links"
        case "focus": return "focusable"
        default: return "clickable"
        }
    }

    // CSS pixels of the page's layout viewport to view coordinates.
    function _transform(r) {
        const iw = r.innerWidth > 0 ? r.innerWidth : 1
        const byWidth = _view.width / iw
        // The page's devicePixelRatio is the screen's times the zoom: exact
        // where the width ratio is rounded (and right with a scrollbar).
        const screenRatio = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        const byRatio = r.devicePixelRatio / screenRatio
        const z = byWidth > 0 && Math.abs(byRatio - byWidth) <= 0.01 * byWidth ? byRatio : (byWidth > 0 ? byWidth : 1)
        return { z: z, scale: r.scale > 0 ? r.scale : 1, ox: r.offsetX || 0, oy: r.offsetY || 0 }
    }
    function _toView(xf, x, y) {
        const k = xf.z * xf.scale
        return { x: (x - xf.ox) * k, y: (y - xf.oy) * k }
    }

    function _build(r) {
        const v = _view
        const xf = _transform(r)
        _xf = xf
        const tl = v.mapToItem(hints, 0, 0)
        const br = v.mapToItem(hints, v.width, v.height)
        _viewRect = Qt.rect(tl.x, tl.y, br.x - tl.x, br.y - tl.y)
        const list = []
        for (const h of r.hints) {
            const a = _toView(xf, h.x, h.y)
            const b = _toView(xf, h.x + h.width, h.y + h.height)
            const c = _toView(xf, h.px, h.py)
            const p = v.mapToItem(hints, a.x, a.y)
            const q = v.mapToItem(hints, b.x, b.y)
            list.push({
                index: h.index, kind: h.kind, tag: h.tag, text: h.text || "", href: h.href || "",
                frame: !!h.frame, x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y,
                clickX: c.x, clickY: c.y
            })
        }
        _hints = list
        _relabel()
    }

    function _matchesFilter(h, words) {
        if (words.length === 0) return true
        const t = (h.text || h.href).toLowerCase()
        return words.every(w => t.indexOf(w) >= 0)
    }

    // Labels for the hints the filter keeps.
    function _relabel() {
        const words = filterText.toLowerCase().split(/\s+/).filter(w => w !== "")
        const keep = _hints.map(h => _matchesFilter(h, words))
        const names = PageTools.labels(keep.filter(k => k).length, alphabet.toLowerCase())
        let n = 0
        _labels = keep.map(k => k && n < names.length ? names[n++] : "")
        _typed = ""
        _update()
        if (_active && activateSingleMatch && words.length > 0 && _matches.length === 1)
            activate(_matches[0])
    }

    function _update() {
        const t = _typed
        _matches = _hints.filter((h, i) => _labels[i] !== "" && _labels[i].startsWith(t))
        if (t !== "") {
            const i = _labels.indexOf(t)
            if (i >= 0) activate(_hints[i])
        }
    }

    function _typeChar(c) {
        const lc = c.toLowerCase()
        if (alphabet.toLowerCase().indexOf(lc) >= 0) {
            const next = _typed + lc
            if (_labels.some(l => l !== "" && l.startsWith(next))) {
                _typed = next
                _update()
                return
            }
        }
        if (textFilter && _typed === "") filterText += c
    }

    function _backspace() {
        if (_typed !== "") {
            _typed = _typed.slice(0, -1)
            _update()
        } else if (filterText !== "") {
            filterText = filterText.slice(0, -1)
        }
    }

    onFilterTextChanged: if (_active && !_busy && !_relabeling) _relabel()
    onAlphabetChanged: if (_active && !_busy) _relabel()

    function _clear() {
        _generation++
        _busy = false
        _pending = []
        _relabeling = true
        filterText = ""
        _relabeling = false
        _typed = ""
        _hints = []
        _labels = []
        _matches = []
        _xf = null
    }

    function _finish(restore) {
        if (!_active || _finishing) return
        _finishing = true
        const f = _restoreFocus
        _restoreFocus = null
        _clear()
        _active = false
        _mode = ""
        if (restore) {
            try {
                if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason)
                else if (_view && _view.visible) _view.forceActiveFocus(Qt.OtherFocusReason)
            } catch (e) {}
        }
        _view = null
        _finishing = false
    }

    function _perform(v, mode, options, h) {
        if (!v) return
        if (typeof mode === "function") {
            try { mode(h, v) } catch (e) { console.warn("LinkHints: hint action failed:", e) }
            return
        }
        switch (mode) {
        case "open":
            v.sendMouseClick(h.clickX, h.clickY, Qt.LeftButton, options.modifiers || 0)
            break
        case "newTab": {
            const background = options.background !== undefined ? !!options.background : backgroundTabs
            v.sendMouseClick(h.clickX, h.clickY, Qt.MiddleButton, background ? 0 : Qt.ShiftModifier)
            break
        }
        case "copy":
            Cef.copyToClipboard(h.href || h.text)
            break
        case "focus":
            v.forceActiveFocus(Qt.OtherFocusReason)
            PageTools.call(v, "focus", [h.index])
            break
        case "hover":
            v.sendMouseMove(h.clickX, h.clickY)
            break
        }
    }

    // While hinting, typed characters, Escape, Backspace and Enter are ours,
    // not window-wide shortcuts'.
    function _isHintKey(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
        switch (event.key) {
        case Qt.Key_Escape: case Qt.Key_Backspace: case Qt.Key_Return: case Qt.Key_Enter:
            return true
        }
        return event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
    }
    Keys.onShortcutOverride: event => { if (_active && _isHintKey(event)) event.accepted = true }
    Keys.onPressed: event => {
        if (!_active || !_isHintKey(event)) return
        event.accepted = true
        switch (event.key) {
        case Qt.Key_Escape:
            cancel()
            return
        case Qt.Key_Backspace:
            if (_busy) _pending.push("\b")
            else _backspace()
            return
        case Qt.Key_Return: case Qt.Key_Enter:
            if (_busy) _pending.push("\r")
            else if (_matches.length > 0) activate(_matches[0])
            return
        }
        type(event.text)
    }

    onActiveFocusChanged: if (!activeFocus && _active && !_finishing) { _finish(false); canceled() }
    onViewChanged: cancel()

    Connections {
        target: hints._active ? hints._view : null
        function onLoadStarted() { hints.cancel() }
        function onWidthChanged() { hints.cancel() }
        function onHeightChanged() { hints.cancel() }
        function onZoomFactorChanged() { hints.cancel() }
        function onDiscardedChanged() { hints.cancel() }
        function onRenderProcessTerminated() { hints.cancel() }
        function onVisibleChanged() { hints.cancel() }
    }

    // A click or a scroll on the page cancels (and reaches the page).
    MouseArea {
        x: hints._viewRect.x
        y: hints._viewRect.y
        width: hints._viewRect.width
        height: hints._viewRect.height
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => { mouse.accepted = false; hints.cancel() }
        onWheel: wheel => { wheel.accepted = false; hints.cancel() }
    }

    Item {
        id: labelLayer
        x: hints._viewRect.x
        y: hints._viewRect.y
        width: hints._viewRect.width
        height: hints._viewRect.height
        clip: true

        Repeater {
            model: hints._hints.length
            delegate: Item {
                id: hintItem
                required property int index
                readonly property var hint: hints._hints[index] || null
                readonly property string label: hints._labels[index] || ""
                readonly property bool matching: label !== "" && label.startsWith(hints._typed)
                visible: hint !== null && matching

                // The element's outline once its label is being typed.
                Rectangle {
                    visible: hints._typed !== "" && hintItem.hint !== null
                    x: hintItem.hint ? hintItem.hint.x - hints._viewRect.x : 0
                    y: hintItem.hint ? hintItem.hint.y - hints._viewRect.y : 0
                    width: hintItem.hint ? hintItem.hint.width : 0
                    height: hintItem.hint ? hintItem.hint.height : 0
                    color: "transparent"
                    border.color: hints.outlineColor
                    border.width: 1
                }

                Rectangle {
                    id: tag
                    objectName: "linkHintLabel"
                    readonly property string label: hintItem.label
                    x: hintItem.hint ? Math.max(0, Math.min(hintItem.hint.x - hints._viewRect.x, labelLayer.width - width)) : 0
                    y: hintItem.hint ? Math.max(0, Math.min(hintItem.hint.y - hints._viewRect.y, labelLayer.height - height)) : 0
                    width: row.implicitWidth + 6
                    height: row.implicitHeight + 2
                    radius: 2
                    color: hints.labelBackground
                    border.color: hints.labelBorder

                    Row {
                        id: row
                        anchors.centerIn: parent
                        Text {
                            text: hints.uppercaseLabels ? hints._typed.toUpperCase() : hints._typed
                            color: hints.typedColor
                            font.family: hints.fontFamily
                            font.pixelSize: hints.fontPixelSize
                            font.bold: true
                        }
                        Text {
                            readonly property string rest: hintItem.label.slice(hints._typed.length)
                            text: hints.uppercaseLabels ? rest.toUpperCase() : rest
                            color: hints.labelColor
                            font.family: hints.fontFamily
                            font.pixelSize: hints.fontPixelSize
                            font.bold: true
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: if (hintItem.hint) hints.activate(hintItem.hint)
                    }
                }
            }
        }

        // What the hints are filtered by.
        Rectangle {
            visible: hints.filterText !== ""
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 6
            width: filterLabel.implicitWidth + 16
            height: filterLabel.implicitHeight + 8
            radius: Style.radius
            color: Style.surface
            border.color: Style.border
            Text {
                id: filterLabel
                anchors.centerIn: parent
                text: hints.filterText + (hints._matches.length === 0 ? "  (no match)" : "")
                color: Style.text
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSize
            }
        }
    }
}
