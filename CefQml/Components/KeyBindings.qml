import QtQuick

// Window-wide keyboard shortcuts for the actions of an ActionRegistry.
//
// Each action brings its `defaultShortcuts`; `bindings` overrides them per
// action name (an empty list unbinds), and `modeBindings[mode]` overrides
// both while `mode` is set. Entries are key sequence strings ("Ctrl+T",
// "Ctrl+K, Ctrl+S"), StandardKey values, or { sequence, args } objects
// that pass `args` to the action.
//
//   KeyBindings {
//       actions: browser.actions
//       bindings: ({ "tab.new": ["Ctrl+T", "Ctrl+N"], "nav.back": [] })
//   }
//
// The same sequence bound to two actions would make both Qt Shortcuts
// ambiguous (neither fires), so every sequence is given to one action: a
// mode binding beats a user binding, which beats an action default; within
// the same level the binding listed (or bound) last wins. Each conflict is
// logged and listed in `conflicts`. Bindings of names that are not (yet)
// in the registry are inactive.
//
// The item is invisible and takes no space; put it anywhere in the window.
// Disabling or hiding it (or an ancestor) releases all its keys, e.g. while
// a modal overlay has focus, or to hand them to another KeyBindings. Keys of
// disabled actions go through to the focused item.
Item {
    id: kb

    // The ActionRegistry whose actions are triggered.
    property var actions: null
    // User overrides: { actionName: [sequence, ...] }.
    property var bindings: ({})
    // Optional modes (e.g. vim-like modal bindings): while `mode` is a key
    // of `modeBindings`, that map overrides `bindings` and the defaults.
    property string mode: ""
    property var modeBindings: ({})
    // Shortcut context of every binding.
    property int context: Qt.WindowShortcut

    // Effective bindings after overrides and conflict resolution:
    // [{ name, sequence, args, level }] (level 0: default, 1: user, 2: mode).
    readonly property var entries: _resolved.entries
    // Sequences claimed by more than one action:
    // [{ sequence, action, overridden: [names] }].
    readonly property var conflicts: _resolved.conflicts

    // Emitted after a shortcut triggered an action.
    signal activated(string name, var args)

    // Binds `name` to `sequences` (a string or a list; [] unbinds), replacing
    // its defaults, and makes it the most recent user binding (it wins
    // conflicts with other user bindings).
    function bind(name, sequences) {
        // A fresh object: V4 does not move a deleted and re-added key to the
        // end, and the key order decides conflicts.
        const b = {}
        for (const k of Object.keys(bindings || {}))
            if (k !== name) b[k] = bindings[k]
        b[name] = sequences === undefined || sequences === null ? []
                : Array.isArray(sequences) ? sequences.slice() : [sequences]
        bindings = b
    }
    function unbind(name) { bind(name, []) }
    // Drops the user binding of `name` (all of them without a name), going
    // back to the action's defaults.
    function reset(name) {
        if (name === undefined) { bindings = {}; return }
        const b = {}
        for (const k of Object.keys(bindings || {}))
            if (k !== name) b[k] = bindings[k]
        bindings = b
    }
    // The effective sequences of `name` as text (for menus and tooltips).
    function sequencesFor(name) {
        return entries.filter(e => e.name === name).map(e => _text(e.sequence))
    }
    // The first effective sequence of `name`, or "".
    function hint(name) {
        const s = sequencesFor(name)
        return s.length > 0 ? s[0] : ""
    }
    // The action name bound to `sequence`, or "".
    function actionFor(sequence) {
        const key = normalize(sequence)
        const e = entries.find(x => normalize(x.sequence) === key)
        return e ? e.name : ""
    }
    // Canonical form of a key sequence, used to detect conflicts
    // ("ctrl+shift+t" and "Shift+Ctrl+T" are the same).
    function normalize(sequence) {
        if (typeof sequence === "number") return "StandardKey:" + sequence
        return String(sequence).split(",").map(c => _normalizeChord(c.trim())).filter(c => c !== "").join(", ")
    }

    readonly property var _resolved: _resolve(actions ? actions.model : [], bindings, mode, modeBindings)
    property var _warned: ({})

    function _text(sequence) { return String(sequence) }
    function _has(map, key) { return Object.prototype.hasOwnProperty.call(map, key) }

    function _normalizeChord(chord) {
        if (chord === "") return ""
        // Split on '+' separators; a '+' right after a separator (or alone)
        // is the key itself ("Ctrl++").
        const tokens = []
        let cur = ""
        for (const ch of chord) {
            if (ch === "+" && cur !== "") { tokens.push(cur); cur = "" }
            else cur += ch
        }
        if (cur !== "") tokens.push(cur)
        const modifierNames = { ctrl: "Ctrl", control: "Ctrl", alt: "Alt", shift: "Shift", meta: "Meta", super: "Meta", win: "Meta" }
        const keyAliases = { esc: "escape", del: "delete", ins: "insert", pagedown: "pgdown", pageup: "pgup", "page down": "pgdown", "page up": "pgup" }
        const mods = new Set()
        let key = ""
        for (let i = 0; i < tokens.length; ++i) {
            const t = tokens[i].trim()
            const m = modifierNames[t.toLowerCase()]
            if (m && i < tokens.length - 1) mods.add(m)
            else key = t.toLowerCase()
        }
        key = keyAliases[key] || key
        return ["Ctrl", "Alt", "Shift", "Meta"].filter(m => mods.has(m)).concat([key]).join("+")
    }

    function _entriesOf(name, list, level, order) {
        if (list === undefined || list === null) return []
        if (!Array.isArray(list)) list = [list]
        const out = []
        for (const item of list) {
            const isObject = typeof item === "object" && item !== null
            const sequence = isObject ? item.sequence : item
            if (sequence === undefined || sequence === null || sequence === "") continue
            out.push({ name: name, sequence: sequence, args: isObject && item.args !== undefined ? item.args : ({}),
                       level: level, order: order })
        }
        return out
    }

    function _resolve(model, userBindings, currentMode, perMode) {
        const modeMap = currentMode !== "" && perMode && _has(perMode, currentMode) ? perMode[currentMode] : {}
        const userMap = userBindings || {}
        const userKeys = Object.keys(userMap)
        const modeKeys = Object.keys(modeMap)
        let candidates = []
        model.forEach((a, i) => {
            if (_has(modeMap, a.name))
                candidates = candidates.concat(_entriesOf(a.name, modeMap[a.name], 2, modeKeys.indexOf(a.name)))
            else if (_has(userMap, a.name))
                candidates = candidates.concat(_entriesOf(a.name, userMap[a.name], 1, userKeys.indexOf(a.name)))
            else
                candidates = candidates.concat(_entriesOf(a.name, a.defaultShortcuts, 0, i))
        })
        // One action per sequence: higher level wins, then the later binding.
        const winners = new Map()
        const losers = new Map()
        for (const e of candidates) {
            const key = normalize(e.sequence)
            const prev = winners.get(key)
            if (!prev) { winners.set(key, e); continue }
            if (prev.name === e.name) { winners.set(key, e); continue }  // listed twice: keep one
            const win = e.level > prev.level || (e.level === prev.level && e.order >= prev.order) ? e : prev
            const lose = win === e ? prev : e
            winners.set(key, win)
            const l = (losers.get(key) || []).filter(x => x.name !== win.name)
            l.push(lose)
            losers.set(key, l)
        }
        const entries = []
        for (const e of candidates) {
            const key = normalize(e.sequence)
            if (winners.get(key) === e) entries.push(e)
        }
        const conflicts = []
        for (const [key, l] of losers) {
            const win = winners.get(key)
            const names = l.map(x => x.name)
            conflicts.push({ sequence: win.sequence, action: win.name, overridden: names })
            const sameLevel = l.some(x => x.level === win.level)
            const msg = "KeyBindings: \"" + _text(win.sequence) + "\" is bound to " + names.join(", ") + " and " + win.name
                      + "; using " + win.name + (sameLevel ? "" : " (overrides the default)")
            if (!_warned[msg]) {
                _warned[msg] = true
                if (sameLevel) console.warn(msg)
                else console.info(msg)
            }
        }
        return { entries: entries, conflicts: conflicts }
    }

    function _actionEnabled(name) {
        const a = actions ? actions.action(name) : null
        return a !== null && a.enabled
    }

    // Inactive bindings release their key instead of only disabling their
    // Shortcut: Qt counts disabled Shortcuts when it looks for ambiguous
    // ones, so a disabled Shortcut could swallow the key of an enabled one
    // (e.g. of another KeyBindings in the window). For the same reason a
    // removed delegate (deleted only later by the Instantiator) releases its
    // key right away.
    Instantiator {
        model: kb.entries
        onObjectRemoved: (index, object) => object.live = false
        delegate: Shortcut {
            // modelData: one entry of kb.entries
            property bool live: true
            readonly property bool active: live && kb.enabled && kb.visible && kb._actionEnabled(modelData.name)
            sequence: active ? modelData.sequence : ""
            context: kb.context
            onActivated: {
                // The action may change the bindings (e.g. the mode), which
                // removes this delegate and its context (modelData, kb).
                const bindings = kb, name = modelData.name, args = modelData.args
                if (bindings.actions && bindings.actions.trigger(name, args))
                    bindings.activated(name, args)
            }
            onActivatedAmbiguously: console.warn("KeyBindings: ambiguous shortcut", modelData.sequence,
                                                 "(also bound outside this KeyBindings?)")
        }
    }
}
