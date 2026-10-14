import QtQml

// A set of BrowserActions, looked up and triggered by name. Declare actions
// inside it, add them at run time with add(), or give an action a
// `registry`. When several actions share a name the one registered last
// wins (it takes the original's place in `model`), so an application can
// replace a built-in action by registering its own under the same name.
//
//   ActionRegistry {
//       id: actions
//       BrowserAction { name: "app.hello"; text: "Say hello"; onTriggered: console.log("hi") }
//   }
//   actions.trigger("app.hello")
//   actions.add({ name: "app.bye", text: "Say bye", onTriggered: args => console.log("bye") })
QtObject {
    id: registry

    default property list<QtObject> actions

    // Effective actions (one per name) in registration order; reassigned on
    // every change, so bindings (menus, palettes, KeyBindings) follow it.
    readonly property var model: _model
    readonly property int count: _model.length

    // Emitted after trigger() ran an action.
    signal actionTriggered(string name, var args)

    // The action called `name`, or null.
    function action(name) {
        const a = _byName[name]
        return a === undefined ? null : a
    }
    function has(name) { return action(name) !== null }
    function names() { return _model.map(a => a.name) }

    // Runs the action `name` with `args` (an object, passed to its
    // `triggered` handler). Returns false when there is no such action or
    // it is disabled.
    function trigger(name, args) {
        const a = action(name)
        if (!a) {
            console.warn("ActionRegistry: no action named", JSON.stringify(name))
            return false
        }
        if (args === undefined || args === null) args = {}
        if (!a.trigger(args)) return false
        actionTriggered(name, args)
        return true
    }

    // Adds a BrowserAction, or creates one from a plain object
    // ({ name, text, description, category, enabled, defaultShortcuts,
    // onTriggered: function(args) }). Returns the action.
    function add(a) {
        if (!a) return null
        if (typeof a.trigger !== "function") {
            const props = {}
            for (const k in a)
                if (k !== "onTriggered") props[k] = a[k]
            const created = _actionComponent.createObject(registry, props)
            if (!created) {
                console.warn("ActionRegistry: could not create action", JSON.stringify(a.name))
                return null
            }
            if (typeof a.onTriggered === "function") created.triggered.connect(a.onTriggered)
            created._ownedBy = registry
            a = created
        }
        if (_extra.indexOf(a) < 0) {
            const list = _extra.slice()
            list.push(a)
            _extra = list
        }
        _rebuild()
        return a
    }

    // Removes an action (object) or every action called `name`. Actions
    // declared inside the registry are hidden rather than destroyed.
    function remove(nameOrAction) {
        const match = typeof nameOrAction === "string" ? (a => a.name === nameOrAction)
                                                       : (a => a === nameOrAction)
        const keep = [], drop = []
        for (const a of _extra) (match(a) ? drop : keep).push(a)
        _extra = keep
        const hidden = _hidden.slice()
        for (let i = 0; i < actions.length; ++i)
            if (match(actions[i]) && hidden.indexOf(actions[i]) < 0) hidden.push(actions[i])
        _hidden = hidden
        _rebuild()
        for (const a of drop)
            if (a._ownedBy === registry) a.destroy()
    }

    property var _extra: []
    property var _hidden: []
    property var _model: []
    property var _byName: Object.create(null)
    property bool _completed: false
    property Component _actionComponent: Component { BrowserAction { property var _ownedBy: null } }

    function _rebuild() {
        const all = []
        for (let i = 0; i < actions.length; ++i) {
            const a = actions[i]
            if (a && typeof a.trigger === "function" && _hidden.indexOf(a) < 0) all.push(a)
        }
        for (const a of _extra)
            if (all.indexOf(a) < 0) all.push(a)
        const byName = Object.create(null)
        const order = []
        for (const a of all) {
            if (!a.name) continue
            if (!(a.name in byName)) order.push(a.name)
            byName[a.name] = a
        }
        _byName = byName
        _model = order.map(n => byName[n])
    }

    onActionsChanged: if (_completed) _rebuild()
    Component.onCompleted: { _completed = true; _rebuild() }
}
