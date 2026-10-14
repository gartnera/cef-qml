import QtQuick
import CefQml

// Menu of a BrowserController's recently closed tabs, most recent first;
// clicking one reopens it (BrowserController.reopenClosedTab()). Drawn
// above the rest of the window; a press outside or Escape closes it.
//
//   RecentlyClosedMenu { id: closedMenu; controller: ctl }
//   IconButton { text: "↺"; onClicked: closedMenu.popup(this, 0, height) }
//
// For a list of your own, use controller.closedTabs (most recent last) and
// controller.reopenClosedTab(i) / forgetClosedTab(i).
PopupMenu {
    id: menu

    property BrowserController controller: null
    // At most this many entries are listed.
    property int maxEntries: 15
    property bool showClearEntry: true
    property bool showReopenAllEntry: true

    // A tab was reopened from the menu.
    signal reopened(CefWebView view)

    menuWidth: 320
    entries: _entries(controller ? controller.closedTabs : [])

    function _label(e) {
        if (e.title) return e.title
        const u = String(e.url)
        return u.length > 80 ? u.substring(0, 80) + "…" : u
    }
    function _host(e) {
        const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(String(e.url))
        return m ? m[1] : ""
    }
    function _entries(closed) {
        if (closed.length === 0) return [{ label: "No recently closed tabs", enabled: false }]
        const list = []
        const n = Math.min(closed.length, maxEntries)
        for (let k = 0; k < n; ++k) {
            const i = closed.length - 1 - k
            const e = closed[i]
            list.push({ label: _label(e), hint: e.title ? _host(e) : "",
                        action: () => menu._reopen(i) })
        }
        if (showReopenAllEntry && closed.length > 1 || showClearEntry) list.push(null)
        if (showReopenAllEntry && closed.length > 1)
            list.push({ label: "Reopen all", action: () => menu._reopenAll() })
        if (showClearEntry)
            list.push({ label: "Clear list", action: () => menu.controller.clearClosedTabs() })
        return list
    }
    function _reopen(i) {
        const v = controller.reopenClosedTab(i)
        if (v) reopened(v)
    }
    function _reopenAll() {
        // Oldest first, so that each goes back to its position.
        const n = controller.closedTabs.length
        for (let k = 0; k < n; ++k) {
            const v = controller.reopenClosedTab(0)
            if (v) reopened(v)
        }
    }
}
