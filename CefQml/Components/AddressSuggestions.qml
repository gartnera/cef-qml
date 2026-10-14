import QtQuick
import CefQml

// Drop-down suggestions and inline autocompletion for an AddressField.
//
//   AddressSuggestions {
//       parent: window.contentItem          // any item the popup can cover
//       addressField: navBar.addressField
//       historyStore: history
//       tabs: webTabs
//   }
//
// While the user types, the popup lists a default entry (what Enter does
// with the text: the inline completion, the typed URL or a search), then the
// results of `providers` in order, without duplicate URLs. Up/Down move the
// selection (the field text stays as typed), Enter opens it (Alt+Enter in a
// new tab), Shift+Delete removes a history entry, Escape closes the popup
// and drops the inline completion. Clicking opens an entry, middle click in
// a new tab.
//
// Inline autocompletion: when typing at the end of the text, the best
// history host or URL is appended and selected, so typing on replaces it and
// Enter accepts it. Backspace and Delete do not complete again.
//
// Providers are functions `(text, ctx) => items` or objects
// `{ suggest(text, ctx), remove(item) }`; `items` is an array or a Promise
// of one. ctx: { text, view, tabs, historyStore, limit }. An item is
// { type, title, url, icon, subtitle, action, remove }: `action(item,
// newTab)` replaces navigating to `url`; `remove(item)` (or the provider's)
// makes it removable with Shift+Delete. `type` picks the glyph: "url",
// "search", "history", "tab", "bookmark", anything else.
Item {
    id: sug

    property Item addressField: null
    property var historyStore: null
    // WebTabs for "switch to tab" entries.
    property var tabs: null
    property int maxItems: 8
    property int rowHeight: 32
    property bool inlineCompletion: true
    // text -> { text, url } or undefined: the inline completion.
    property var completer: text => sug.historyStore && sug.historyStore.enabled
                                    ? sug.historyStore.inlineCompletion(text) : undefined
    // Opens a URL; the default navigates the field's view or opens a tab.
    property var navigate: (url, newTab) => {
        if (newTab && sug.tabs) sug.tabs.openTab(url)
        else if (sug.addressField) sug.addressField.go(url)
    }
    // Shows a tab ("switch to tab" entries).
    property var selectTab: view => {
        if (!sug.tabs) return
        sug.tabs.currentIndex = sug.tabs.indexOf(view)
        view.forceActiveFocus(Qt.OtherFocusReason)
    }

    // The built-in providers, for composing your own `providers` list.
    readonly property var tabProvider: ({ name: "tabs", suggest: (text, ctx) => sug._tabItems(text, ctx) })
    readonly property var historyProvider: ({
        name: "history",
        suggest: (text, ctx) => sug._historyItems(text, ctx),
        remove: item => { if (sug.historyStore) sug.historyStore.remove(item.url) }
    })
    readonly property var searchProvider: ({ name: "search", suggest: text => [sug._searchItem(text)] })
    property var providers: [tabProvider, historyProvider, searchProvider]

    readonly property var items: _items
    property int currentIndex: -1
    // The text as typed (without the inline completion).
    readonly property string userText: _userText
    readonly property bool opened: visible
    readonly property var completion: _completion

    // After an entry was opened (by key or mouse).
    signal activated(var item, bool newTab)

    function addProvider(provider, index) {
        const list = providers.slice()
        if (index === undefined || index < 0 || index > list.length) list.push(provider)
        else list.splice(index, 0, provider)
        providers = list
    }
    function removeProvider(provider) {
        providers = providers.filter(p => p !== provider)
    }

    // Called by AddressField for every key press; true if handled.
    function handleKey(event) {
        const k = event.key
        const input = addressField ? addressField.input : null
        if (!input) return false
        if (k === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier) && _isOpen()) {
            removeItem(currentIndex)
            return true
        }
        if (k === Qt.Key_Backspace || k === Qt.Key_Delete) {
            _suppress = true
            return false
        }
        const enter = k === Qt.Key_Return || k === Qt.Key_Enter
        const newTab = !!(event.modifiers & Qt.AltModifier)
        if (!_isOpen()) {
            if (visible) close()
            if (enter && input.text.trim() !== "") {
                _userText = input.text
                _completion = null
                _open(_defaultItem(input.text.trim()), newTab)
                return true
            }
            return false
        }
        if (k === Qt.Key_Down) {
            currentIndex = Math.min(items.length - 1, currentIndex + 1)
            return true
        }
        if (k === Qt.Key_Up) {
            currentIndex = Math.max(0, currentIndex - 1)
            return true
        }
        if (enter) {
            openItem(currentIndex, newTab)
            return true
        }
        if (k === Qt.Key_Escape) {
            _revertCompletion()
            close()
            return true
        }
        return false
    }

    // Recomputes completion and entries from the field (called on edits).
    function update() {
        const input = addressField ? addressField.input : null
        if (!input) return
        const text = input.text
        const suppress = _suppress
        _suppress = false
        const grew = text.length > _userText.length
        _userText = text
        _completion = null
        if (inlineCompletion && !suppress && grew && completer && input.cursorPosition === text.length
                && text.trim() === text && text !== "") {
            const c = completer(text)
            if (c && c.text && c.text.length > text.length
                    && c.text.substring(0, text.length).toLowerCase() === text.toLowerCase()) {
                _completion = c
                input.text = text + c.text.substring(text.length)
                input.select(text.length, input.text.length)
            }
        }
        _refresh()
    }

    function close() {
        _generation++
        visible = false
        currentIndex = -1
    }

    // Opens entry `index` (default: the current one).
    function openItem(index, newTab) {
        if (index === undefined) index = currentIndex
        const item = items[index]
        if (!item) return false
        _open(item, !!newTab)
        return true
    }

    // The popup row showing entry `index` (null if none).
    function rowAt(index) { return repeater.itemAt(index) }

    // Removes entry `index` from its source (e.g. history), if removable.
    function removeItem(index) {
        const item = items[index]
        if (!item || !item.removable) return false
        try {
            if (typeof item.remove === "function") item.remove(item)
            else if (item._provider && typeof item._provider.remove === "function") item._provider.remove(item)
        } catch (e) {
            console.warn("AddressSuggestions: removing failed:", e)
        }
        if (item._completion) _revertCompletion()
        const keep = currentIndex
        _refresh()
        currentIndex = Math.max(0, Math.min(keep, items.length - 1))
        return true
    }

    // ---- internals ---------------------------------------------------------

    property var _items: []
    property string _userText: ""
    property var _completion: null
    property bool _suppress: false
    property int _generation: 0
    property string _shownFor: ""
    property var _results: []

    visible: false
    z: 1000
    width: addressField ? Math.max(addressField.width, 320) : 320
    height: frame.height

    function _isOpen() {
        return visible && items.length > 0 && addressField && addressField.input.text === _shownFor
    }

    function _key(url) {
        if (!url) return ""
        return historyStore ? historyStore.normalizeUrl(url) : String(url)
    }

    function _display(url) {
        url = String(url)
        try { return decodeURIComponent(url) } catch (e) { return url }
    }

    function _words(text) {
        return text.toLowerCase().split(/\s+/).filter(w => w !== "")
    }

    function _searchUrl(text) {
        const base = addressField ? addressField.searchUrl : "https://duckduckgo.com/?q=%s"
        return base.replace("%s", encodeURIComponent(text.trim()))
    }

    function _searchItem(text) {
        return { type: "search", title: text.trim(), subtitle: "Search", url: _searchUrl(text) }
    }

    function _defaultItem(text) {
        const input = addressField.input
        if (_completion && input.text !== _userText) {
            const e = historyStore ? historyStore.entry(_completion.url) : undefined
            return { type: "history", title: e && e.title ? e.title : _display(_completion.url),
                     url: _completion.url, icon: e ? e.icon : "", removable: !!e, _completion: true,
                     remove: () => { if (historyStore) historyStore.remove(_completion.url) } }
        }
        const u = Cef.urlFromUserInput(text).toString()
        if (u !== "") {
            const e = historyStore ? historyStore.entry(u) : undefined
            return { type: "url", title: e && e.title ? e.title : text, url: u, icon: e ? e.icon : "",
                     subtitle: e && e.title ? _display(u) : "" }
        }
        return _searchItem(text)
    }

    function _historyItems(text, ctx) {
        if (!historyStore) return []
        return historyStore.search(text, ctx.limit).map(e => ({
            type: "history", title: e.title || _display(e.url), url: e.url, icon: e.icon,
            subtitle: e.title ? _display(e.url) : ""
        }))
    }

    function _tabItems(text, ctx) {
        if (!tabs) return []
        const words = _words(text)
        const out = []
        const current = addressField ? addressField.view : null
        for (const v of tabs.views) {
            if (v === current) continue
            const url = v.url.toString()
            if (url === "" || (addressField && addressField.isInternalUrl(url))) continue
            const hay = (_display(url) + " " + v.title).toLowerCase()
            if (!words.every(w => hay.indexOf(w) >= 0)) continue
            out.push({ type: "tab", title: v.title || _display(url), url: v.url, icon: v.icon.toString(),
                       subtitle: "Switch to tab", action: () => sug.selectTab(v) })
        }
        return out
    }

    function _normalize(item, provider) {
        if (!item || (!item.url && typeof item.action !== "function")) return null
        const removable = item.removable !== undefined ? !!item.removable
            : typeof item.remove === "function" || !!(provider && typeof provider.remove === "function")
        return {
            type: item.type || "custom",
            title: String(item.title || _display(item.url || "")),
            subtitle: item.subtitle ? String(item.subtitle) : "",
            url: item.url ? String(item.url) : "",
            icon: item.icon ? String(item.icon) : "",
            action: item.action,
            remove: item.remove,
            removable: removable,
            _completion: !!item._completion,
            _provider: provider
        }
    }

    function _refresh() {
        const text = _userText.trim()
        const gen = ++_generation
        if (!addressField || text === "") {
            visible = false
            _items = []
            currentIndex = -1
            return
        }
        _shownFor = addressField.input.text
        const ctx = { text: text, view: addressField.view, tabs: tabs, historyStore: historyStore,
                      limit: maxItems }
        const results = []
        providers.forEach((p, i) => {
            let r = []
            try {
                r = typeof p === "function" ? p(text, ctx)
                    : p && typeof p.suggest === "function" ? p.suggest(text, ctx) : []
            } catch (e) {
                console.warn("AddressSuggestions: provider failed:", e)
            }
            if (r && typeof r.then === "function") {
                results[i] = []
                r.then(list => {
                    if (gen !== _generation) return
                    _results[i] = (list || []).map(x => _normalize(x, p)).filter(x => x)
                    _rebuild(_defaultItem(text))
                }, e => console.warn("AddressSuggestions: provider failed:", e))
            } else {
                results[i] = (r || []).map(x => _normalize(x, p)).filter(x => x)
            }
        })
        _results = results
        _rebuild(_defaultItem(text))
        currentIndex = 0
        _place()
        visible = _items.length > 0
    }

    function _rebuild(first) {
        const selected = items[currentIndex]
        const out = []
        const seen = {}
        const add = item => {
            if (!item || out.length >= maxItems) return
            const k = item.url ? _key(item.url) : "#" + item.title
            if (seen[k]) return
            seen[k] = true
            out.push(item)
        }
        add(_normalize(first, null))
        for (const list of _results)
            for (const item of list || []) add(item)
        _items = out
        if (selected) {
            const i = out.findIndex(x => x.url === selected.url && x.type === selected.type)
            currentIndex = i >= 0 ? i : 0
        }
    }

    function _revertCompletion() {
        const input = addressField ? addressField.input : null
        if (input && _completion && input.text !== _userText) {
            input.text = _userText
            input.cursorPosition = _userText.length
        }
        _completion = null
    }

    function _open(item, newTab) {
        close()
        _userText = ""
        _completion = null
        try {
            if (typeof item.action === "function") {
                item.action(item, newTab)
                // Still editing: show the page URL again, ready to type over.
                const f = addressField
                if (f && f.input.activeFocus) {
                    f.input.text = f._display()
                    f.input.selectAll()
                }
            } else if (item.url) {
                const view = addressField ? addressField.view : null
                if (!newTab && historyStore && view && (item.type === "url" || item.type === "history"))
                    historyStore.markTyped(view)
                navigate(item.url, newTab)
            }
        } catch (e) {
            console.warn("AddressSuggestions: opening failed:", e)
        }
        activated(item, newTab)
    }

    property var _lastHover: null
    onVisibleChanged: _lastHover = null
    function _hover(index, p) {
        const last = _lastHover
        _lastHover = Qt.point(p.x, p.y)
        if (last && (Math.abs(last.x - p.x) >= 1 || Math.abs(last.y - p.y) >= 1))
            currentIndex = index
    }

    function _place() {
        if (!addressField || !parent) return
        const p = addressField.mapToItem(parent, 0, addressField.height + 3)
        x = Math.max(0, Math.min(p.x, parent.width - width))
        y = p.y
    }

    function _highlight(s) {
        const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        const words = _words(_userText)
        if (words.length === 0) return esc(s)
        // Mark matched ranges, then escape segment by segment.
        const lower = s.toLowerCase()
        const marks = new Array(s.length).fill(false)
        for (const w of words)
            for (let i = lower.indexOf(w); i >= 0; i = lower.indexOf(w, i + 1))
                for (let j = i; j < i + w.length; ++j) marks[j] = true
        let out = "", run = "", bold = false
        for (let i = 0; i <= s.length; ++i) {
            const m = i < s.length ? marks[i] : !bold
            if (m !== bold || i === s.length) {
                out += bold ? "<b>" + esc(run) + "</b>" : esc(run)
                run = ""
                bold = m
            }
            if (i < s.length) run += s[i]
        }
        return out
    }

    function _glyph(type) {
        switch (type) {
        case "search": return "⌕"
        case "history": return "◷"
        case "tab": return "⇥"
        case "bookmark": return "★"
        case "url": return "→"
        default: return "•"
        }
    }

    Connections {
        target: sug.addressField ? sug.addressField.input : null
        function onTextEdited() { sug.update() }
        function onActiveFocusChanged() {
            if (!sug.addressField.input.activeFocus) {
                sug.close()
                sug._userText = ""
                sug._completion = null
            }
        }
    }
    Connections {
        target: sug.addressField
        function onViewChanged() { sug.close() }
    }
    Component.onCompleted: if (addressField) addressField.suggestions = sug
    onAddressFieldChanged: if (addressField) addressField.suggestions = sug

    Rectangle {
        id: frame
        width: parent.width
        height: list.height + 8
        radius: Style.radius
        color: Style.surface
        border.color: Style.border
        border.width: 1

        // Keep clicks and wheel events from reaching the page underneath.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: {}
        }

        // Rows are placed by index rather than by a Column, whose layout is
        // deferred to the next polish.
        Item {
            id: list
            x: 4
            y: 4
            width: parent.width - 8
            height: sug.items.length * sug.rowHeight

            Repeater {
                id: repeater
                model: sug.items
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    objectName: "suggestion" + index
                    readonly property bool current: index === sug.currentIndex
                    y: index * sug.rowHeight
                    width: list.width
                    height: sug.rowHeight
                    radius: Style.radius - 2
                    color: current ? Style.surfaceActive : "transparent"

                    Item {
                        id: iconBox
                        x: 8
                        width: 18
                        height: parent.height
                        Image {
                            id: favicon
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            sourceSize: Qt.size(16, 16)
                            source: row.modelData.icon && row.modelData.type !== "search" ? row.modelData.icon : ""
                            visible: status === Image.Ready
                            asynchronous: true
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !favicon.visible
                            text: sug._glyph(row.modelData.type)
                            color: Style.textDim
                            font.pixelSize: Style.fontSize + 1
                            font.family: Style.fontFamily
                        }
                    }
                    Text {
                        id: titleText
                        anchors.left: iconBox.right
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, (parent.width - iconBox.width - 60) * (subtitleText.text ? 0.6 : 1))
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        text: sug._highlight(row.modelData.title)
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Text {
                        id: subtitleText
                        anchors.left: titleText.right
                        anchors.leftMargin: text ? 8 : 0
                        anchors.right: removeButton.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: row.modelData.subtitle ? "— " + row.modelData.subtitle : ""
                        color: row.modelData.type === "tab" ? Style.accent : Style.textDim
                        font.pixelSize: Style.fontSize - 1
                        font.family: Style.fontFamily
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        // Only real mouse movement selects: not rows that
                        // appear under a resting pointer while typing.
                        onPositionChanged: mouse => sug._hover(row.index, mapToItem(sug, mouse.x, mouse.y))
                        onEntered: sug._hover(row.index, mapToItem(sug, mouseX, mouseY))
                        onClicked: mouse => sug.openItem(row.index, mouse.button === Qt.MiddleButton
                                                         || (mouse.modifiers & Qt.ControlModifier))
                    }
                    IconButton {
                        id: removeButton
                        objectName: "suggestionRemove" + row.index
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.modelData.removable && (row.current || rowMouse.containsMouse)
                        width: row.modelData.removable ? implicitWidth : 0
                        text: "×"
                        toolTip: "Remove from history (Shift+Delete)"
                        onClicked: sug.removeItem(row.index)
                    }
                }
            }
        }
    }
}
