import QtQuick
import CefQml

// The standard browser actions (with their default keys), operating on a
// BrowserController. `Browser` has one as `actions`; in a custom layout:
//
//   BrowserController { id: browse; tabs: myTabs }
//   BrowserActions { id: actions; controller: browse; addressField: nav.addressField; findBar: find }
//   KeyBindings { actions: actions }
//
// UI-dependent actions are disabled until their target is set:
// address.focus needs `addressField` (anything with focusAndSelect()),
// page.find* need `findBar` (open(), findNext(forward), visible, text),
// window.fullscreen needs `window`, userscripts.manage needs
// `userScriptManager` and history.show `historyView` (both: toggle(),
// visible; e.g. a PanelOverlay). bookmark.toggle needs `bookmarkStore` (or
// a `bookmarkButton`, whose toggle() also shows its editor), bookmarks.manage
// a `bookmarkManager` (toggle(), visible) and bookmarks.showBar a
// `bookmarksBarTarget` whose boolean `bookmarksBarProperty` (default
// "visible") it flips. tab.recentlyClosed needs a `recentlyClosedMenu`
// (popup(item, x, y), e.g. a RecentlyClosedMenu) and session.restore a
// `sessionStore` (a SessionStore with a saved session). Declare more
// BrowserActions inside, or replace one
// by adding an action with the same name.
ActionRegistry {
    id: acts

    property BrowserController controller: null
    property var addressField: null
    property var findBar: null
    property var window: null
    property var userScriptManager: null
    property var historyView: null
    property var bookmarkStore: null
    property var bookmarkButton: null
    property var bookmarkManager: null
    property var bookmarksBarTarget: null
    property string bookmarksBarProperty: "visible"
    property var recentlyClosedMenu: null
    property var sessionStore: null

    readonly property CefWebView view: controller ? controller.currentView : null
    readonly property bool hasView: view !== null

    // tab.*
    BrowserAction {
        name: "tab.new"; text: "New tab"
        description: "Open a tab (args: { url, background, index }); without a url, the home page with the address field focused."
        defaultShortcuts: ["Ctrl+T"]
        enabled: acts.controller !== null
        onTriggered: args => {
            acts.controller.openTab(args.url, { background: !!args.background, index: args.index })
            if (args.url === undefined && !args.background && acts.addressField) acts.addressField.focusAndSelect()
        }
    }
    BrowserAction {
        name: "tab.close"; text: "Close tab"
        description: "Close the current tab (args: { index })."
        defaultShortcuts: ["Ctrl+W", "Ctrl+F4"]
        enabled: acts.hasView
        onTriggered: args => acts.controller.closeTab(args.index)
    }
    BrowserAction {
        name: "tab.next"; text: "Next tab"
        defaultShortcuts: ["Ctrl+Tab", "Ctrl+PgDown"]
        enabled: acts.hasView
        onTriggered: acts.controller.nextTab()
    }
    BrowserAction {
        name: "tab.previous"; text: "Previous tab"
        defaultShortcuts: ["Ctrl+Shift+Tab", "Ctrl+PgUp"]
        enabled: acts.hasView
        onTriggered: acts.controller.previousTab()
    }
    BrowserAction {
        name: "tab.select"; text: "Select tab"
        description: "Select the tab at args.index (negative counts from the end; past the end selects the last tab)."
        // Ctrl+1..8 select tabs 1..8, Ctrl+9 the last tab.
        defaultShortcuts: [1, 2, 3, 4, 5, 6, 7, 8].map(n => ({ sequence: "Ctrl+" + n, args: { index: n - 1 } }))
                          .concat([{ sequence: "Ctrl+9", args: { index: -1 } }])
        enabled: acts.hasView
        onTriggered: args => {
            const c = acts.controller
            const i = args.index === undefined ? 0 : args.index
            c.selectTab(Math.min(i, c.count - 1))
        }
    }
    BrowserAction {
        name: "tab.duplicate"; text: "Duplicate tab"
        enabled: acts.hasView
        onTriggered: acts.controller.duplicateTab()
    }
    BrowserAction {
        name: "tab.reopenClosed"; text: "Reopen closed tab"
        defaultShortcuts: ["Ctrl+Shift+T"]
        enabled: acts.controller !== null && acts.controller.closedTabs.length > 0
        onTriggered: acts.controller.reopenClosedTab()
    }
    BrowserAction {
        name: "tab.recentlyClosed"; text: "Recently closed tabs"
        description: "Show the recently closed tabs menu (args: { item, x, y }: where; default: the window's top left)."
        enabled: acts.recentlyClosedMenu !== null
        onTriggered: args => acts.recentlyClosedMenu.popup(args.item || null, args.x || 8, args.y || 8)
    }
    BrowserAction {
        name: "tab.discardOthers"; text: "Discard background tabs"
        description: "Free the memory of every tab but the current one; they load again when selected."
        enabled: acts.controller !== null && acts.controller.count > 1
        onTriggered: {
            const c = acts.controller
            for (let i = 0; i < c.count; ++i) c.discardTab(i)
        }
    }
    BrowserAction {
        name: "session.restore"; text: "Restore previous session"
        description: "Reopen the tabs of the previous session next to the current ones."
        enabled: acts.sessionStore !== null && acts.sessionStore.hasSavedSession
        onTriggered: acts.sessionStore.restore()
    }

    // nav.*
    BrowserAction {
        name: "nav.back"; text: "Back"
        defaultShortcuts: ["Alt+Left"]
        enabled: acts.hasView && acts.view.canGoBack
        onTriggered: acts.controller.back()
    }
    BrowserAction {
        name: "nav.forward"; text: "Forward"
        defaultShortcuts: ["Alt+Right"]
        enabled: acts.hasView && acts.view.canGoForward
        onTriggered: acts.controller.forward()
    }
    BrowserAction {
        name: "nav.reload"; text: "Reload"
        defaultShortcuts: ["Ctrl+R", "F5"]
        enabled: acts.hasView
        onTriggered: acts.controller.reload()
    }
    BrowserAction {
        name: "nav.reloadHard"; text: "Reload, ignoring the cache"
        defaultShortcuts: ["Ctrl+Shift+R", "Shift+F5"]
        enabled: acts.hasView
        onTriggered: acts.controller.reload(undefined, true)
    }
    BrowserAction {
        // No default key: a window-wide Escape would take Escape away from
        // pages and text fields.
        name: "nav.stop"; text: "Stop loading"
        enabled: acts.hasView && acts.view.loading
        onTriggered: acts.controller.stop()
    }
    BrowserAction {
        name: "nav.home"; text: "Home page"
        defaultShortcuts: ["Alt+Home"]
        enabled: acts.hasView
        onTriggered: acts.controller.home()
    }

    // address.* / page.*
    BrowserAction {
        name: "address.focus"; text: "Focus the address bar"
        defaultShortcuts: ["Ctrl+L", "F6", "Alt+D"]
        enabled: acts.addressField !== null
        onTriggered: acts.addressField.focusAndSelect()
    }
    BrowserAction {
        name: "page.find"; text: "Find in page"
        defaultShortcuts: ["Ctrl+F"]
        enabled: acts.findBar !== null && acts.hasView
        onTriggered: acts.findBar.open()
    }
    BrowserAction {
        name: "page.findNext"; text: "Find next"
        description: "Next match; opens the find bar when it is closed or empty."
        defaultShortcuts: ["F3", "Ctrl+G"]
        enabled: acts.findBar !== null && acts.hasView
        onTriggered: acts._findStep(true)
    }
    BrowserAction {
        name: "page.findPrevious"; text: "Find previous"
        defaultShortcuts: ["Shift+F3", "Ctrl+Shift+G"]
        enabled: acts.findBar !== null && acts.hasView
        onTriggered: acts._findStep(false)
    }

    // zoom.*
    BrowserAction {
        name: "zoom.in"; text: "Zoom in"
        defaultShortcuts: ["Ctrl+=", "Ctrl++"]
        enabled: acts.hasView
        onTriggered: acts.controller.zoomIn()
    }
    BrowserAction {
        name: "zoom.out"; text: "Zoom out"
        defaultShortcuts: ["Ctrl+-"]
        enabled: acts.hasView
        onTriggered: acts.controller.zoomOut()
    }
    BrowserAction {
        name: "zoom.reset"; text: "Reset zoom"
        defaultShortcuts: ["Ctrl+0"]
        enabled: acts.hasView
        onTriggered: acts.controller.resetZoom()
    }

    // edit.*: no default keys; the focused page or text field handles the
    // usual ones itself (window-wide shortcuts would steal them).
    BrowserAction { name: "edit.undo"; text: "Undo"; enabled: acts.hasView; onTriggered: acts.view.undo() }
    BrowserAction { name: "edit.redo"; text: "Redo"; enabled: acts.hasView; onTriggered: acts.view.redo() }
    BrowserAction { name: "edit.cut"; text: "Cut"; enabled: acts.hasView; onTriggered: acts.view.cut() }
    BrowserAction { name: "edit.copy"; text: "Copy"; enabled: acts.hasView; onTriggered: acts.view.copy() }
    BrowserAction { name: "edit.paste"; text: "Paste"; enabled: acts.hasView; onTriggered: acts.view.paste() }
    BrowserAction { name: "edit.selectAll"; text: "Select all"; enabled: acts.hasView; onTriggered: acts.view.selectAll() }
    BrowserAction {
        name: "page.copyUrl"; text: "Copy page address"
        enabled: acts.hasView
        onTriggered: Cef.copyToClipboard(acts.view.url.toString())
    }

    // window.*
    BrowserAction {
        name: "window.fullscreen"; text: "Full screen"
        defaultShortcuts: ["F11"]
        // Reflects the window state (not toggled by trigger(), so not checkable).
        checked: acts.window !== null && acts.window.visibility === Window.FullScreen
        enabled: acts.window !== null
        onTriggered: {
            if (acts.window.visibility === Window.FullScreen) acts.window.showNormal()
            else acts.window.showFullScreen()
        }
    }

    // userscripts.*
    BrowserAction {
        name: "userscripts.manage"; text: "Manage userscripts"
        description: "Show or hide the userscript manager."
        defaultShortcuts: ["Ctrl+Shift+U"]
        checked: acts.userScriptManager !== null && acts.userScriptManager.visible
        enabled: acts.userScriptManager !== null
        onTriggered: acts.userScriptManager.toggle()
    }

    // history.*
    BrowserAction {
        name: "history.show"; text: "History"
        description: "Show or hide the browsing history."
        defaultShortcuts: ["Ctrl+H"]
        checked: acts.historyView !== null && acts.historyView.visible
        enabled: acts.historyView !== null
        onTriggered: acts.historyView.toggle()
    }

    // bookmark.*, bookmarks.*
    BrowserAction {
        name: "bookmark.toggle"; text: "Bookmark this page"
        description: "Bookmark the current page, or remove its bookmarks."
        defaultShortcuts: ["Ctrl+D"]
        checked: acts.hasView && acts.bookmarkStore !== null
                 && (acts.bookmarkStore.revision, acts.bookmarkStore.isBookmarked(acts.view.url))
        enabled: acts.hasView && (acts.bookmarkStore !== null || acts.bookmarkButton !== null)
        onTriggered: {
            if (acts.bookmarkButton && acts.bookmarkButton.view === acts.view) {
                acts.bookmarkButton.toggle()
                return
            }
            const u = acts.view.url.toString()
            if (u === "" || u === "about:blank") return
            const icon = acts.view.icon.toString()
            acts.bookmarkStore.toggle(acts.view.url, acts.view.title,
                                      { icon: icon.startsWith("http") || icon.startsWith("data:") ? icon : "" })
        }
    }
    BrowserAction {
        id: showBarAction
        name: "bookmarks.showBar"; text: "Show bookmarks bar"
        description: "Show or hide the bookmarks bar (args: { show })."
        defaultShortcuts: ["Ctrl+Shift+B"]
        checkable: true
        checked: acts._barShown()
        enabled: acts.bookmarksBarTarget !== null
        onTriggered: args => {
            const show = args.show !== undefined ? !!args.show : checked
            acts.bookmarksBarTarget[acts.bookmarksBarProperty] = show
            checked = Qt.binding(() => acts._barShown())
        }
    }
    BrowserAction {
        name: "bookmarks.manage"; text: "Bookmark manager"
        description: "Show or hide the bookmark manager."
        defaultShortcuts: ["Ctrl+Shift+O"]
        checked: acts.bookmarkManager !== null && acts.bookmarkManager.visible
        enabled: acts.bookmarkManager !== null
        onTriggered: acts.bookmarkManager.toggle()
    }

    function _barShown() {
        return bookmarksBarTarget !== null && !!bookmarksBarTarget[bookmarksBarProperty]
    }

    function _findStep(forward) {
        if (!findBar.visible || findBar.text === "") findBar.open()
        else findBar.findNext(forward)
    }
}
