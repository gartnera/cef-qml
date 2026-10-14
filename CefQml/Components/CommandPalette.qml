import QtQuick
import CefQml
import "Providers.js" as Providers

// A keyboard-first overlay that finds and runs commands, switches tabs and
// opens bookmarks, history entries or typed addresses (like VS Code's
// command palette or Vivaldi's Quick Commands).
//
//   CommandPalette {
//       id: cmd
//       actions: myActions              // ActionRegistry (e.g. BrowserActions)
//       keyBindings: myKeys             // optional: key hints
//       controller: myController        // BrowserController: tabs, closed tabs, navigation
//       historyStore: history           // optional
//       bookmarkStore: bookmarks        // optional
//   }
//   BrowserActions { commandPalette: cmd; ... }   // "palette.show": Ctrl+Shift+P, Ctrl+K
//
// open(prefix) shows it above the rest of the window and focuses its input;
// close() (Escape, a click outside, or running an entry) gives the focus back
// to the item that had it. What is typed is matched against every source;
// a leading prefix limits it to one:
//   >  commands (the actions of `actions`)
//   @  open tabs and recently closed tabs (% too)
//   *  bookmarks
//   #  history
// Without a prefix, a typed address or search is offered as well.
//
// Up/Down, PageUp/PageDown, Home/End (Shift+Home/End edit the text) and
// Tab/Shift+Tab move the selection, Enter runs it, Alt+Enter or Ctrl+Enter
// runs its alternate (an address opens in a new tab), Shift+Delete removes
// a removable entry (a history entry, a closed tab; an open tab is closed).
// Clicking runs an entry, middle click or Ctrl+click its alternate.
//
// Ranking: an exact title match first, then a title prefix, a match at a word
// start (or an acronym), anywhere in the title, then fuzzy (the characters
// in order); the matched characters are highlighted. Subtitles and keywords
// (an action's name and description) match too, one step lower. Recently
// run commands (`recent`, saved to Cef.dataDir/<recentPath>) move up.
//
// Sources are `providers`, the same shape as AddressSuggestions providers:
// a function `(text, ctx) => items` (listed without a prefix) or an object
// `{ suggest(text, ctx), remove(item), prefix, title, mixed, prefiltered }`
// where `prefix` (a string or a list) gives the provider a mode of its own,
// `title` names it, `mixed: false` lists it only in that mode and
// `prefiltered: true` keeps items that do not match the query (the provider
// searched itself, e.g. by URL). `items`
// is an array or a Promise of one; ctx: { text, query, mode, palette, view,
// tabs, controller, actions, keyBindings, historyStore, bookmarkStore,
// limit }. An item is { type, title, subtitle, icon, category, hint, label,
// keywords, enabled, checked, key, score, sticky } plus what it does: an
// `action(item, alternate)` function, an `actionName` (with `args`) run
// through `actions`, or a `url` to open. `key` makes it count as recently
// used; a numeric `score` places it without matching; `sticky` keeps it when
// results are cut at maxResults. Add your own commands as actions of the
// registry, or as items of a provider of your own.
FocusScope {
    id: cmd

    // ---- sources -------------------------------------------------------------

    // ActionRegistry listed under ">" (actions with showInPalette false are not).
    property var actions: null
    // KeyBindings for the key hints of actions.
    property var keyBindings: null
    // BrowserController: open and closed tabs, opening addresses.
    property var controller: null
    property var tabs: controller ? controller.tabs : null
    property var historyStore: null
    property var bookmarkStore: null
    property string searchUrl: controller ? controller.searchUrl : "https://duckduckgo.com/?q=%s"
    // Opens `url` (a url, or typed text) here or in a new tab. The default
    // uses `controller` and focuses the page.
    property var navigate: (url, newTab) => cmd._defaultNavigate(url, newTab)
    // Shows tab `view` (tab entries).
    property var selectTab: view => {
        if (cmd.controller) cmd.controller.selectTab(view)
        else if (cmd.tabs) cmd.tabs.currentIndex = cmd.tabs.indexOf(view)
        view.forceActiveFocus(Qt.OtherFocusReason)
    }
    // Is `url` an internal page (shown without its address)?
    property var isInternalUrl: url => cmd.controller ? cmd.controller.isInternalUrl(url) : false
    // Offer "Open address" and "Search the web" entries (urlProvider). On
    // by default when there is a controller to open them with; set it with
    // a custom `navigate`.
    property bool openAddresses: controller !== null

    // ---- behaviour -----------------------------------------------------------

    // At most this many entries are listed (sticky ones are always kept).
    property int maxResults: 50
    // Bookmarks, history and closed tabs per source without a prefix (their
    // own mode lists up to maxResults).
    property int sourceLimit: 8
    // Display names of action categories (an action's `category`).
    property var categoryNames: ({
        tab: "Tabs", session: "Session", nav: "Navigation", address: "Address bar", page: "Page",
        zoom: "Zoom", edit: "Edit", window: "Window", userscripts: "Userscripts", history: "History",
        bookmark: "Bookmarks", bookmarks: "Bookmarks", palette: "Palette", hints: "Link hints"
    })
    // Recently run commands, most recent first, saved to this file under
    // Cef.dataDir ("" keeps them in memory). Give each palette of a process
    // its own file.
    property string recentPath: "command-palette.json"
    property int maxRecent: 20
    // Keys of recently run entries ("action:<name>" or an item's `key`).
    readonly property var recent: {
        const d = _recentStore.data
        return d && Array.isArray(d.recent) ? d.recent : []
    }

    // ---- look ----------------------------------------------------------------

    property real panelWidth: 640
    property real topMargin: 56
    property int rowHeight: 34
    property int maxVisibleRows: 10
    property color backdropColor: "#33000000"

    // ---- state ---------------------------------------------------------------

    // The input text (including a prefix); set it to search.
    property alias text: field.text
    property alias input: field
    // The mode prefix in effect ("" for everything) and the text after it.
    readonly property string prefix: _prefix
    readonly property string query: _query
    // The prefixes of `providers`.
    readonly property var prefixes: _prefixList(providers)
    // The listed entries (normalized items) and the selected one.
    readonly property var items: _items
    property int currentIndex: -1
    readonly property bool opened: visible

    // ---- built-in providers --------------------------------------------------

    readonly property var actionProvider: ({
        name: "actions", prefix: ">", title: "Commands",
        suggest: (text, ctx) => cmd._actionItems(ctx)
    })
    readonly property var tabProvider: ({
        name: "tabs", prefix: ["@", "%"], title: "Tabs",
        suggest: (text, ctx) => cmd._tabItems(ctx),
        remove: item => { if (cmd.controller) cmd.controller.closeTab(item._view) }
    })
    readonly property var closedTabProvider: ({
        name: "closedTabs", prefix: ["@", "%"], title: "Recently closed",
        suggest: (text, ctx) => cmd._closedTabItems(ctx),
        remove: item => { if (cmd.controller) cmd.controller.forgetClosedTab(item._closedIndex) }
    })
    readonly property var bookmarkProvider: ({
        name: "bookmarks", prefix: "*", title: "Bookmarks", prefiltered: true,
        suggest: (text, ctx) => cmd._bookmarkItems(ctx)
    })
    readonly property var historyProvider: ({
        name: "history", prefix: "#", title: "History", prefiltered: true,
        suggest: (text, ctx) => cmd._historyItems(ctx),
        remove: item => { if (cmd.historyStore) cmd.historyStore.remove(item.url) }
    })
    // Without a prefix: the typed address, and a web search.
    readonly property var urlProvider: ({
        name: "url", title: "Address",
        suggest: (text, ctx) => cmd._urlItems(ctx)
    })
    property var providers: [tabProvider, actionProvider, bookmarkProvider, historyProvider,
                             closedTabProvider, urlProvider]

    // After an entry ran (by key or mouse).
    signal activated(var item, bool alternate)
    signal closed()

    // ---- API -----------------------------------------------------------------

    // Shows the palette with `prefix` (or any text) typed; true if shown.
    function open(prefix) {
        const w = Window.window
        if (!w) return false
        if (parent !== w.contentItem) parent = w.contentItem
        if (!visible) {
            const f = w.activeFocusItem
            _restoreFocus = f && !_contains(f) ? f : null
        }
        visible = true
        _setText(prefix === undefined || prefix === null ? "" : String(prefix))
        field.forceActiveFocus(Qt.PopupFocusReason)
        return true
    }
    // Hides it and gives the focus back to the item that had it.
    function close() { _close(true) }
    // Closes it when it is open in the mode of `prefix`, else opens it there.
    function toggle(prefix) {
        const p = prefix === undefined || prefix === null ? "" : String(prefix)
        if (visible && _prefix === _parse(p).prefix) close()
        else open(p)
    }

    // Runs entry `index` (default: the selected one); `alternate` as with
    // Alt+Enter. Returns false for a disabled or missing entry.
    function run(index, alternate) {
        if (index === undefined || index === null) index = currentIndex
        const item = items[index]
        if (!item || !item.enabled) return false
        alternate = !!alternate
        _remember(item)
        _close(true)
        let ok = true
        try {
            if (typeof item.action === "function") {
                item.action(item, alternate)
            } else if (item.actionName) {
                ok = !!actions && actions.trigger(item.actionName, item.args || {})
            } else if (item.url) {
                const view = controller ? controller.currentView : null
                if (!alternate && item.type === "url" && historyStore && view) historyStore.markTyped(view)
                navigate(_asUrl(item.url), alternate)
            }
        } catch (e) {
            console.warn("CommandPalette: running failed:", e)
            ok = false
        }
        activated(item, alternate)
        return ok
    }

    // Removes entry `index` from its source, if removable.
    function removeItem(index) {
        if (index === undefined) index = currentIndex
        const item = items[index]
        if (!item || !item.removable) return false
        try {
            if (typeof item.remove === "function") item.remove(item)
            else if (item._provider && typeof item._provider.remove === "function") item._provider.remove(item)
        } catch (e) {
            console.warn("CommandPalette: removing failed:", e)
        }
        _keepIndex = index
        update()
        return true
    }

    // The row showing entry `index` (null if none).
    function rowAt(index) {
        list.forceLayout()
        return list.itemAtIndex(index)
    }

    // Matching as used for ranking: { tier, quality, positions } or null.
    function match(query, text) { return Providers.match(query, text, true) }

    function addProvider(provider, index) {
        const l = providers.slice()
        if (index === undefined || index < 0 || index > l.length) l.push(provider)
        else l.splice(index, 0, provider)
        providers = l
    }
    function removeProvider(provider) { providers = providers.filter(p => p !== provider) }

    function clearRecent() { _recentStore.data = { version: 1, recent: [] } }

    // Recomputes the entries from the text (called on every edit).
    function update() {
        if (!visible || _settingText) return
        const gen = ++_generation
        const parsed = _parse(field.text)
        _prefix = parsed.prefix
        _query = parsed.query
        const active = _providersFor(parsed.prefix)
        const ctx = {
            text: parsed.query, query: parsed.query, mode: parsed.prefix, palette: cmd,
            view: controller ? controller.currentView : (tabs ? tabs.currentView : null),
            tabs: tabs, controller: controller, actions: actions, keyBindings: keyBindings,
            historyStore: historyStore, bookmarkStore: bookmarkStore,
            limit: parsed.prefix === "" ? sourceLimit : maxResults
        }
        const results = []
        active.forEach((p, i) => {
            const r = Providers.call(p, parsed.query, ctx, "CommandPalette")
            if (Providers.isPromise(r)) {
                results[i] = { provider: p, items: [] }
                r.then(l => {
                    if (gen !== _generation) return
                    const res = _results.slice()
                    res[i] = { provider: p, items: _normalizeAll(l, p) }
                    _results = res
                    _rebuild(false)
                }, e => console.warn("CommandPalette: provider failed:", e))
            } else {
                results[i] = { provider: p, items: _normalizeAll(r, p) }
            }
        })
        _results = results
        _rebuild(true)
    }

    // Called for key presses in the input; true if handled.
    function handleKey(event) {
        const k = event.key
        const mods = event.modifiers
        const shift = !!(mods & Qt.ShiftModifier)
        const n = items.length
        const page = Math.max(1, Math.floor(list.height / rowHeight) - 1)
        const move = to => { if (n > 0) currentIndex = Math.max(0, Math.min(n - 1, to)) }
        switch (k) {
        case Qt.Key_Escape: close(); return true
        case Qt.Key_Return:
        case Qt.Key_Enter:
            run(currentIndex, !!(mods & (Qt.AltModifier | Qt.ControlModifier)))
            return true
        case Qt.Key_Down: move(currentIndex + 1); return true
        case Qt.Key_Up: move(currentIndex - 1); return true
        case Qt.Key_Tab: move(currentIndex + 1); return true
        case Qt.Key_Backtab: move(currentIndex - 1); return true
        case Qt.Key_PageDown: move(currentIndex + page); return true
        case Qt.Key_PageUp: move(currentIndex - page); return true
        case Qt.Key_Home: if (shift || n === 0) return false; move(0); return true
        case Qt.Key_End: if (shift || n === 0) return false; move(n - 1); return true
        case Qt.Key_Delete:
            if (shift && n > 0 && items[currentIndex] && items[currentIndex].removable) {
                removeItem(currentIndex)
                return true
            }
            return false
        }
        return false
    }

    // ---- internals -------------------------------------------------------------

    property var _items: []
    property var _results: []
    property string _prefix: ""
    property string _query: ""
    property int _generation: 0
    property var _restoreFocus: null
    property bool _closing: false
    property bool _settingText: false
    property int _keepIndex: -1

    visible: false
    z: 10003
    x: 0
    y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    function _contains(item) {
        for (let p = item; p; p = p.parent) if (p === cmd) return true
        return false
    }

    function _setText(t) {
        _settingText = true
        field.text = t
        field.cursorPosition = t.length
        _settingText = false
        update()
    }

    function _close(restore) {
        if (!visible || _closing) return
        _closing = true
        _generation++
        const f = _restoreFocus
        _restoreFocus = null
        visible = false
        _settingText = true
        field.text = ""
        _settingText = false
        _items = []
        _results = []
        _prefix = ""
        _query = ""
        currentIndex = -1
        if (restore) {
            try { if (f && f.visible) f.forceActiveFocus(Qt.OtherFocusReason) } catch (e) {}
        }
        _closing = false
        closed()
    }

    function _asUrl(u) {
        // Absolute addresses as url values: navigate() treats strings as typed text.
        return typeof u === "string" && /^[a-z][a-z0-9+.-]*:/i.test(u) ? Qt.resolvedUrl(u) : u
    }

    function _defaultNavigate(url, newTab) {
        if (!controller) return
        if (newTab) {
            const v = controller.openTab(url)
            if (v) v.forceActiveFocus(Qt.OtherFocusReason)
            return
        }
        controller.navigate(url)
        const v = controller.currentView
        if (v) v.forceActiveFocus(Qt.OtherFocusReason)
    }

    function _prefixList(list) {
        const out = []
        for (const p of list || [])
            for (const x of Providers.prefixesOf(p))
                if (out.indexOf(x) < 0) out.push(x)
        return out
    }

    function _parse(t) {
        const s = String(t).replace(/^\s+/, "")
        const sorted = prefixes.slice().sort((a, b) => b.length - a.length)
        for (const p of sorted)
            if (s.startsWith(p)) return { prefix: p, query: s.slice(p.length).trim() }
        return { prefix: "", query: s.trim() }
    }

    function _providersFor(prefix) {
        if (prefix === "")
            return providers.filter(p => typeof p === "function" || (p && typeof p === "object" && p.mixed !== false))
        return providers.filter(p => Providers.prefixesOf(p).indexOf(prefix) >= 0)
    }

    // Unique titles of the providers of `prefix`, e.g. "Tabs · Recently closed".
    function _modeTitle(prefix) {
        const titles = []
        for (const p of _providersFor(prefix))
            if (p && p.title && titles.indexOf(p.title) < 0) titles.push(p.title)
        return titles.join(" · ")
    }

    function _normalizeAll(list, provider) {
        return (Array.isArray(list) ? list : []).map(x => Providers.normalize(x, provider)).filter(x => x)
    }

    function _keyOf(item) {
        return item.key || (item.actionName ? "action:" + item.actionName : "")
    }

    function _boost(item) {
        const k = _keyOf(item)
        if (!k) return 0
        const i = recent.indexOf(k)
        return i < 0 ? 0 : 300 * (1 - i / Math.max(maxRecent, 1))
    }

    function _remember(item) {
        const k = _keyOf(item)
        if (!k || maxRecent <= 0) return
        const l = [k].concat(recent.filter(x => x !== k)).slice(0, maxRecent)
        _recentStore.data = { version: 1, recent: l }
    }

    // { score, positions } or null when the item does not match.
    function _score(item, provider, q) {
        let base = 0, positions = []
        if (item.score !== undefined) {
            base = item.score
        } else if (q !== "") {
            const m = Providers.matchItem(q, item.title, [item.subtitle, item.category, item.keywords])
            if (m) {
                base = m.tier * 1000 + m.quality * 100
                positions = m.positions
            } else if (provider && provider.prefiltered) {
                base = 1000   // the source matched it on something else
            } else {
                return null
            }
        }
        if (item.score === undefined) base += _boost(item)
        if (!item.enabled) base -= 400
        return { score: base, positions: positions }
    }

    function _identity(item) {
        return item ? item.type + "\u0001" + (item.key || item.actionName || item.url) + "\u0001" + item.title : ""
    }

    function _rebuild(resetSelection) {
        const selected = resetSelection ? "" : _identity(items[currentIndex])
        const q = _query
        const scored = []
        _results.forEach((r, pi) => {
            if (!r) return
            r.items.forEach((item, ii) => {
                const s = _score(item, r.provider, q)
                if (!s) return
                item._positions = s.positions
                item._score = s.score
                scored.push({ item: item, pi: pi, ii: ii })
            })
        })
        // Explicit tie-breaks (provider order, then the provider's order).
        scored.sort((a, b) => (b.item._score - a.item._score) || (a.pi - b.pi) || (a.ii - b.ii))
        // One entry per URL among bookmarks, history and the like; an open
        // or closed tab (an entry with an action) hides them.
        const urlKey = u => historyStore ? historyStore.normalizeUrl(u) : u
        const navigating = item => !item.actionName && typeof item.action !== "function" && !item.sticky
        const seen = {}
        for (const s of scored)
            if (s.item.url && typeof s.item.action === "function") seen[urlKey(s.item.url)] = true
        const out = []
        const sticky = scored.filter(s => s.item.sticky).length
        let kept = 0
        for (const s of scored) {
            const item = s.item
            if (navigating(item)) {
                const k = urlKey(item.url)
                if (seen[k]) continue
                seen[k] = true
            }
            if (!item.sticky) {
                if (kept >= Math.max(0, maxResults - sticky)) continue
                ++kept
            }
            out.push(item)
        }
        _items = out
        let index = -1
        if (_keepIndex >= 0) {
            index = Math.min(_keepIndex, out.length - 1)
            _keepIndex = -1
        } else if (selected) {
            index = out.findIndex(x => _identity(x) === selected)
        }
        if (index < 0) {
            index = out.findIndex(x => x.enabled)
            if (index < 0 && out.length > 0) index = 0
        }
        currentIndex = index
        _showCurrent()
    }

    function _showCurrent() {
        if (currentIndex < 0 || currentIndex >= items.length) return
        list.forceLayout()
        list.positionViewAtIndex(currentIndex, ListView.Contain)
    }
    onCurrentIndexChanged: _showCurrent()

    function _categoryName(c) {
        if (!c) return ""
        const names = categoryNames || {}
        if (Object.prototype.hasOwnProperty.call(names, c)) return names[c]
        return c.charAt(0).toUpperCase() + c.slice(1)
    }

    function _actionItems(ctx) {
        if (!actions) return []
        const out = []
        for (const a of actions.model) {
            if (!a || a.showInPalette === false) continue
            const category = _categoryName(a.category)
            out.push({
                type: "action", key: "action:" + a.name, actionName: a.name, args: {},
                title: a.text || a.name, category: category,
                keywords: [a.name, a.description, a.category].join(" "),
                hint: keyBindings ? keyBindings.hint(a.name) : "",
                enabled: a.enabled, checked: !!a.checked
            })
        }
        return out
    }

    function _tabItems(ctx) {
        if (!tabs) return []
        const current = tabs.currentView
        const out = []
        for (const v of tabs.views) {
            if (!v) continue
            const isCurrent = v === current
            if (isCurrent && ctx.mode === "") continue
            const url = v.url.toString()
            const internal = url !== "" && isInternalUrl(url)
            out.push({
                type: "tab", title: v.title || (internal ? "New Tab" : Providers.display(url)),
                subtitle: internal ? "" : Providers.display(url), icon: v.icon.toString(),
                url: internal ? "" : url, label: isCurrent ? "Current tab" : "Switch to tab",
                action: () => cmd.selectTab(v), _view: v
            })
        }
        return out
    }

    function _closedTabItems(ctx) {
        if (!controller) return []
        if (ctx.mode === "" && ctx.query === "") return []
        const closed = controller.closedTabs
        const out = []
        for (let i = closed.length - 1; i >= 0; --i) {
            const e = closed[i]
            if (!e) continue
            const idx = i
            out.push({
                type: "closedTab", title: e.title || Providers.display(e.url),
                subtitle: Providers.display(e.url), icon: e.icon ? String(e.icon) : "",
                url: String(e.url), label: "Reopen closed tab", _closedIndex: idx,
                action: () => {
                    const v = cmd.controller.reopenClosedTab(idx)
                    if (v) v.forceActiveFocus(Qt.OtherFocusReason)
                }
            })
            if (ctx.mode === "" && out.length >= ctx.limit) break
        }
        return out
    }

    function _bookmarkItems(ctx) {
        const store = ctx.bookmarkStore
        if (!store || (ctx.mode === "" && ctx.query === "")) return []
        return store.search(ctx.query, ctx.limit).map(b => ({
            type: "bookmark", title: b.title || Providers.display(b.url), url: b.url, icon: b.icon,
            subtitle: Providers.display(b.url)
        }))
    }

    function _historyItems(ctx) {
        const store = ctx.historyStore
        if (!store || (ctx.mode === "" && ctx.query === "")) return []
        return store.search(ctx.query, ctx.limit).map(e => ({
            type: "history", title: e.title || Providers.display(e.url), url: e.url, icon: e.icon,
            subtitle: e.title ? Providers.display(e.url) : ""
        }))
    }

    function _urlItems(ctx) {
        const q = ctx.query
        if (q === "" || !openAddresses) return []
        const out = []
        const u = Cef.urlFromUserInput(q).toString()
        if (u !== "")
            out.push({ type: "url", title: q, subtitle: "Open address", url: u, score: 3500, sticky: true })
        out.push({ type: "search", title: q, subtitle: "Search the web", sticky: true, score: -100000,
                   url: searchUrl.replace("%s", encodeURIComponent(q)) })
        return out
    }

    property var _lastHover: null
    onVisibleChanged: _lastHover = null
    function _hover(index, p) {
        const last = _lastHover
        _lastHover = Qt.point(p.x, p.y)
        if (last && (Math.abs(last.x - p.x) >= 1 || Math.abs(last.y - p.y) >= 1))
            currentIndex = index
    }

    onActiveFocusChanged: if (!activeFocus && visible && !_closing) _close(false)

    property JsonStore _recentStore: JsonStore {
        path: cmd.recentPath
        data: ({ version: 1, recent: [] })
    }
    property Connections _actionsConnection: Connections {
        target: cmd.actions
        function onModelChanged() { if (cmd.visible) cmd.update() }
    }
    property Connections _keysConnection: Connections {
        target: cmd.keyBindings
        function onEntriesChanged() { if (cmd.visible) cmd.update() }
    }
    property Connections _controllerConnection: Connections {
        target: cmd.controller
        function onClosedTabsChanged() { if (cmd.visible) cmd.update() }
    }

    // ---- view ----------------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: cmd.backdropColor
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: cmd.close()
        onWheel: {}
    }

    Rectangle {
        id: panel
        objectName: "palettePanel"
        x: Math.round((cmd.width - width) / 2)
        y: Math.min(cmd.topMargin, Math.max(0, cmd.height - height))
        width: Math.min(cmd.panelWidth, cmd.width - 32)
        height: column.height + 12
        radius: Style.radius + 2
        color: Style.surface
        border.color: Style.border
        border.width: 1

        // Keep presses and wheel events from the backdrop.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: {}
        }

        Column {
            id: column
            x: 6
            y: 6
            width: parent.width - 12

            Rectangle {
                width: parent.width
                height: 38
                radius: Style.radius
                color: Style.background
                border.color: field.activeFocus ? Style.accent : Style.border
                border.width: 1

                TextInput {
                    id: field
                    objectName: "paletteInput"
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Style.text
                    selectionColor: Style.accent
                    selectByMouse: true
                    font.pixelSize: Style.fontSize + 2
                    font.family: Style.fontFamily
                    onTextChanged: cmd.update()
                    Keys.onPressed: event => { if (cmd.handleKey(event)) event.accepted = true }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        text: "Type a command, a tab, bookmark or history entry, or an address"
                        color: Style.textDim
                        font: field.font
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }
            }

            Item { width: 1; height: 6 }

            ListView {
                id: list
                objectName: "paletteList"
                width: parent.width
                height: Math.min(cmd.items.length, cmd.maxVisibleRows) * cmd.rowHeight
                clip: true
                model: cmd.items
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    objectName: "paletteRow" + index
                    readonly property bool current: index === cmd.currentIndex
                    readonly property string titleHtml: Providers.highlight(modelData.title, modelData._positions,
                        "<b><font color=\"" + Style.accent + "\">", "</font></b>")
                    width: list.width
                    height: cmd.rowHeight
                    radius: Style.radius - 2
                    color: current ? Style.surfaceActive : "transparent"
                    opacity: modelData.enabled ? 1 : 0.45

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
                            text: row.modelData.checked ? "✓" : Providers.glyph(row.modelData.type)
                            color: row.modelData.checked ? Style.accent : Style.textDim
                            font.pixelSize: Style.fontSize + 1
                            font.family: Style.fontFamily
                        }
                    }
                    Text {
                        id: categoryText
                        anchors.left: iconBox.right
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.category ? row.modelData.category + ": " : ""
                        color: Style.textDim
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Text {
                        id: titleText
                        objectName: "paletteTitle"
                        anchors.left: categoryText.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, Math.max(40, rightBox.x - x - 12) * (subtitleText.text ? 0.65 : 1))
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        text: row.titleHtml
                        color: Style.text
                        font.pixelSize: Style.fontSize
                        font.family: Style.fontFamily
                    }
                    Text {
                        id: subtitleText
                        anchors.left: titleText.right
                        anchors.leftMargin: text ? 8 : 0
                        anchors.right: rightBox.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: row.modelData.subtitle ? "— " + row.modelData.subtitle : ""
                        color: Style.textDim
                        font.pixelSize: Style.fontSize - 1
                        font.family: Style.fontFamily
                    }
                    Item {
                        id: rightBox
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: hintCap.visible ? hintCap.width : labelText.implicitWidth
                        height: parent.height
                        Rectangle {
                            id: hintCap
                            objectName: "paletteHint"
                            readonly property string text: row.modelData.hint
                            visible: text !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: hintText.implicitWidth + 12
                            height: hintText.implicitHeight + 4
                            radius: 4
                            color: Style.background
                            border.color: Style.border
                            border.width: 1
                            Text {
                                id: hintText
                                anchors.centerIn: parent
                                text: hintCap.text
                                color: Style.textDim
                                font.pixelSize: Style.fontSize - 2
                                font.family: Style.fontFamily
                            }
                        }
                        Text {
                            id: labelText
                            objectName: "paletteLabel"
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !hintCap.visible && text !== ""
                            text: row.modelData.label
                            color: row.modelData.type === "tab" ? Style.accent : Style.textDim
                            font.pixelSize: Style.fontSize - 1
                            font.family: Style.fontFamily
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        // Only real mouse movement selects: not rows that
                        // appear under a resting pointer while typing.
                        onPositionChanged: mouse => cmd._hover(row.index, mapToItem(cmd, mouse.x, mouse.y))
                        onEntered: cmd._hover(row.index, mapToItem(cmd, mouseX, mouseY))
                        onClicked: mouse => cmd.run(row.index, mouse.button === Qt.MiddleButton
                                                        || !!(mouse.modifiers & Qt.ControlModifier))
                    }
                }
            }

            Text {
                objectName: "paletteEmpty"
                width: parent.width
                height: visible ? 36 : 0
                visible: cmd.items.length === 0
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: cmd.query === "" ? "Nothing here yet" : "No matches"
                color: Style.textDim
                font.pixelSize: Style.fontSize
                font.family: Style.fontFamily
            }

            Text {
                objectName: "paletteFooter"
                width: parent.width
                height: 24
                verticalAlignment: Text.AlignBottom
                leftPadding: 6
                elide: Text.ElideRight
                text: cmd.prefix !== "" ? cmd._modeTitle(cmd.prefix)
                      : cmd._helpText(cmd.providers)
                color: Style.textDim
                font.pixelSize: Style.fontSize - 2
                font.family: Style.fontFamily
            }
        }
    }

    function _helpText(list) {
        const parts = []
        const seen = []
        for (const p of list || []) {
            const ps = Providers.prefixesOf(p)
            if (ps.length === 0 || !p.title || seen.indexOf(ps[0]) >= 0) continue
            seen.push(ps[0])
            const titles = _modeTitle(ps[0])
            parts.push(ps[0] + " " + titles.toLowerCase())
        }
        return parts.join("    ")
    }
}
