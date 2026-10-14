import QtQuick
import CefQml

// The "star" of an address bar: filled (★, accent colour) when the URL of
// `view` is bookmarked in `store`. A click bookmarks the page and shows a
// small editor (name, folder, remove); on a bookmarked page it opens the
// editor of its bookmark. NavigationBar shows one when it has a
// bookmarkStore; in your own layout:
//
//   BookmarkButton { store: bookmarks; view: tabs.currentView }
//
// toggle() adds / removes without asking (the "bookmark.toggle" action and
// Ctrl+D use it when BrowserActions.bookmarkButton is set).
IconButton {
    id: star

    property BookmarkStore store: null
    property CefWebView view: null
    // Click on a bookmarked page: open the editor (true) or remove the
    // bookmark (false).
    property bool editOnClick: true
    // Show the editor after a click / toggle() added a bookmark.
    property bool showEditorOnAdd: true
    readonly property bool bookmarked: store && view
                                       ? (store.revision, store.isBookmarked(view.url)) : false
    readonly property BookmarkEditor editor: editorItem

    // The click: bookmark the page (and show the editor), or edit / remove
    // its bookmark. Returns the bookmark's id ("" when removed or nothing).
    function activate() {
        if (!store || !view || !_bookmarkable()) return ""
        if (!bookmarked) return _add()
        if (!editOnClick) {
            toggle()
            return ""
        }
        const id = store.bookmarksFor(view.url)[0].id
        editorItem.edit(id, star)
        return id
    }
    // Bookmarks the page, or removes all its bookmarks. Returns whether it
    // is bookmarked afterwards.
    function toggle() {
        if (!store || !view || !_bookmarkable()) return false
        if (!bookmarked) return _add() !== ""
        editorItem.cancel()
        store.toggle(view.url)
        return false
    }

    function _bookmarkable() {
        const u = view.url.toString()
        return u !== "" && u !== "about:blank"
    }
    function _add() {
        const id = store.add(view.url, view.title, { icon: _icon() })
        if (id !== "" && showEditorOnAdd) editorItem.edit(id, star, { added: true })
        return id
    }
    function _icon() {
        const i = view ? view.icon.toString() : ""
        return i.startsWith("http") || i.startsWith("data:") ? i : ""
    }

    objectName: "bookmarkButton"
    text: bookmarked ? "★" : "☆"
    textColor: bookmarked ? Style.accent : Style.textDim
    toolTip: bookmarked ? "Edit bookmark" : "Bookmark this page"
    enabled: store !== null && view !== null
    onClicked: activate()

    Connections {
        target: star.view
        function onIconChanged() {
            if (star.bookmarked && star._icon() !== "") star.store.setIcon(star.view.url, star._icon())
        }
    }

    BookmarkEditor {
        id: editorItem
        store: star.store
    }
}
