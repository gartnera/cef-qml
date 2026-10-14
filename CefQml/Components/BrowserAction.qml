import QtQml

// A named, triggerable command: the unit that key bindings, menus, buttons
// and (later) a command palette all refer to.
//
//   BrowserAction {
//       registry: browser.actions          // optional: registers itself
//       name: "app.hello"
//       text: "Say hello"
//       defaultShortcuts: ["Ctrl+Shift+H"]
//       onTriggered: args => console.log("hello", args)
//   }
QtObject {
    id: action

    // Unique, namespaced id, e.g. "tab.new". Should not change once registered.
    property string name
    // Human-readable label ("New tab") and optional longer description.
    property string text
    property string description
    // Grouping for menus/palettes; defaults to the name's namespace ("tab").
    property string category: name.indexOf(".") > 0 ? name.slice(0, name.indexOf(".")) : ""
    // Disabled actions do not run, and their key bindings let keys through
    // to the focused item.
    property bool enabled: true
    // A check mark state for menus; trigger() toggles it when checkable.
    property bool checkable: false
    property bool checked: false
    // Key sequences this action is bound to unless KeyBindings overrides it
    // (strings in QKeySequence portable format, StandardKey values, or
    // { sequence, args } objects to pass arguments).
    property var defaultShortcuts: []
    // An ActionRegistry to add this action to (and remove it from on
    // destruction). Leave null when the action is declared inside a registry.
    property var registry: null

    signal triggered(var args)

    // Runs the action; returns false (and does nothing) when it is disabled.
    function trigger(args) {
        if (!enabled) return false
        if (checkable) checked = !checked
        triggered(args === undefined ? ({}) : args)
        return true
    }

    property var _registeredIn: null
    function _register() {
        if (_registeredIn === registry) return
        if (_registeredIn) _registeredIn.remove(action)
        _registeredIn = registry
        if (registry) registry.add(action)
    }
    onRegistryChanged: if (_completed) _register()
    property bool _completed: false
    Component.onCompleted: { _completed = true; _register() }
    Component.onDestruction: {
        // The registry may be torn down first (e.g. at application exit).
        try { if (_registeredIn) _registeredIn.remove(action) } catch (e) {}
    }
}
