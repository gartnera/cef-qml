import QtQuick
import CefQml
import "PageTools.js" as PageTools

// Non-visual, programmatic API over a WebTabs: navigate, open/close/select
// tabs, history, zoom, tab lookup, and waiting for loads. `Browser` exposes
// one as `controller` (and forwards most functions); use it directly with
// your own WebTabs in a custom layout.
//
//   BrowserController { id: browse; tabs: myTabs }
//   browse.navigate("example.com").then(r => console.log(r.ok, r.view.title))
//   browse.navigate("https://qt.io", { newTab: true, background: true }, r => ...)
//
// Functions that take a `tab` accept an index (negative counts from the
// end: -1 is the last tab), a CefWebView, or nothing for the current tab.
QtObject {
    id: ctl

    property WebTabs tabs: null
    // Typed text that is not an address is searched; "%s" is the query.
    property string searchUrl: "https://duckduckgo.com/?q=%s"
    property real zoomStep: 0.1
    // scrollPage("up" / "down" / "left" / "right") moves this many CSS pixels.
    property real scrollStep: 60
    // How many closed tabs closedTabs keeps.
    property int closedTabsLimit: 25
    // URLs not worth remembering when their tab closes (e.g. a new-tab page).
    property var isInternalUrl: url => false

    readonly property CefWebView currentView: tabs ? tabs.currentView : null
    readonly property int count: tabs ? tabs.count : 0
    readonly property int currentIndex: tabs ? tabs.currentIndex : -1
    // Recently closed tabs, most recent last: [{ url (string), title, icon,
    // index (its position when closed), time (ms since the epoch), zoom? }].
    // A SessionStore persists it; assign to replace it.
    property var closedTabs: []
    onClosedTabsChanged: {
        if (closedTabs.length > closedTabsLimit)
            closedTabs = closedTabs.slice(closedTabs.length - closedTabsLimit)
    }

    // ---- addresses ---------------------------------------------------------

    // What an address bar does with typed text: an address becomes a URL,
    // anything else a search. url values are returned unchanged.
    function urlFor(text) {
        if (typeof text !== "string") return text
        const u = Cef.urlFromUserInput(text)
        if (u.toString() !== "") return u
        return searchUrl.replace("%s", encodeURIComponent(text.trim()))
    }

    // ---- navigation --------------------------------------------------------

    // Loads `target` (url or typed text) and returns a Promise of the load
    // result (see whenLoaded). Options:
    //   newTab: open a new tab (also when there is no tab yet)
    //   background: with newTab, do not select it
    //   index: with newTab, where to insert it (default: at the end)
    //   tab: navigate this tab (index or view) instead of the current one
    //   timeout: give up waiting after this many ms (result.error "timeout")
    // `callback(result)`, if given, is called with the same result.
    function navigate(target, opts, callback) {
        if (typeof opts === "function") { callback = opts; opts = undefined }
        opts = opts || {}
        const url = urlFor(target)
        let view = null
        if (opts.tab !== undefined) {
            view = viewAt(opts.tab)
            if (!view) return _settled({ ok: false, view: null, error: "noTab" }, callback)
        } else if (!opts.newTab && currentView) {
            view = currentView
        }
        if (!view) {
            view = tabs ? tabs.openTab(url, !!opts.background, opts.index) : null
            if (!view) return _settled({ ok: false, view: null, error: "noTab" }, callback)
            return whenLoaded(view, callback, _navigationOpts(opts))
        }
        // Setting the same URL again is a no-op for CefWebView; an address
        // bar reloads instead. A discarded tab loads its (new) URL.
        if (view.url.toString() === url.toString()) view.reload()
        else view.url = url
        if (view.discarded) view.discarded = false
        return whenLoaded(view, callback, _navigationOpts(opts))
    }

    // Opens a tab and returns its view right away. `opts`: { background,
    // index } (or just `true` for background). `callback(result)` runs when
    // the page has loaded (see whenLoaded).
    function openTab(url, opts, callback) {
        if (typeof opts === "function") { callback = opts; opts = undefined }
        if (typeof opts === "boolean") opts = { background: opts }
        opts = opts || {}
        if (!tabs) return null
        const target = url === undefined || url === null || url === "" ? tabs.homeUrl : urlFor(url)
        const view = tabs.openTab(target, !!opts.background, opts.index)
        if (view && callback) whenLoaded(view, callback, _navigationOpts(opts))
        return view
    }

    // Promise of the result of the next main-frame load of `view` (one that
    // starts after this call, or the one in progress). Always resolves, never
    // rejects, with { ok, view, url, httpStatusCode } or { ok: false, view,
    // url, errorCode, errorText } (Chromium net::Error) or { ok: false, view,
    // error } where error is "timeout", "superseded" (another
    // navigate/whenLoaded on the same view), "closed" (tab closed) or "noTab".
    // `opts.timeout` in ms (default: none).
    function whenLoaded(view, callback, opts) {
        if (typeof callback === "object" && callback !== null) { opts = callback; callback = undefined }
        opts = opts || {}
        if (!view) return _settled({ ok: false, view: null, error: "noTab" }, callback)
        for (const t of _trackers.slice())
            if (t.view === view) t.finish({ ok: false, error: "superseded" })

        return new Promise(resolve => {
            // `committed`: a main-frame load we are waiting for has started,
            // so its loadFinished counts. After navigate() that is only once
            // loadStarted reports it: until then, events still belong to the
            // previous page. A direct whenLoaded() on a loading view waits
            // for the load in progress.
            const t = { view: view, committed: !opts._navigation && view.loading, loadingSeen: view.loading,
                        done: false, timeout: null, grace: null }
            const onStarted = () => { t.committed = true }
            const onLoading = () => {
                if (t.grace) { t.grace.destroy(); t.grace = null }
                if (view.loading) { t.loadingSeen = true; return }
                // Same-document navigations (e.g. to a #fragment) change the
                // loading state without loadStarted/loadFinished; give real
                // loads a moment to report theirs first.
                if (t.loadingSeen)
                    t.grace = _after(300, () => t.finish({ ok: true, url: view.url.toString(), httpStatusCode: 0 }))
            }
            const onFinished = (url, status) => {
                if (t.committed) t.finish({ ok: true, url: url.toString(), httpStatusCode: status })
            }
            const onFailed = (code, text, url) => {
                t.finish({ ok: false, url: url.toString(), errorCode: code, errorText: text })
            }
            const onClosed = closed => { if (closed === view) t.finish({ ok: false, error: "closed" }) }
            t.finish = result => {
                if (t.done) return
                t.done = true
                view.loadStarted.disconnect(onStarted)
                view.loadingChanged.disconnect(onLoading)
                view.loadFinished.disconnect(onFinished)
                view.loadFailed.disconnect(onFailed)
                if (t.tabs) t.tabs.tabClosed.disconnect(onClosed)
                if (t.grace) t.grace.destroy()
                if (t.timeout) t.timeout.destroy()
                ctl._trackers = ctl._trackers.filter(x => x !== t)
                result.view = view
                if (callback) {
                    try { callback(result) } catch (e) { console.warn("BrowserController: load callback failed:", e) }
                }
                resolve(result)
            }
            view.loadStarted.connect(onStarted)
            view.loadingChanged.connect(onLoading)
            view.loadFinished.connect(onFinished)
            view.loadFailed.connect(onFailed)
            if (tabs) { t.tabs = tabs; tabs.tabClosed.connect(onClosed) }
            if (opts.timeout > 0) t.timeout = _after(opts.timeout, () => t.finish({ ok: false, error: "timeout" }))
            ctl._trackers = ctl._trackers.concat([t])
        })
    }

    function back(tab) { const v = viewAt(tab); if (!v || !v.canGoBack) return false; v.goBack(); return true }
    function forward(tab) { const v = viewAt(tab); if (!v || !v.canGoForward) return false; v.goForward(); return true }
    function reload(tab, ignoreCache) {
        const v = viewAt(tab)
        if (!v) return false
        if (ignoreCache) v.reloadIgnoringCache()
        else v.reload()
        return true
    }
    function stop(tab) { const v = viewAt(tab); if (!v) return false; v.stop(); return true }
    // Loads the WebTabs' homeUrl.
    function home(tab) {
        const v = viewAt(tab)
        if (!v) return null
        return navigate(tabs.homeUrl, { tab: v })
    }

    function zoomIn(tab) { const v = viewAt(tab); if (v) v.zoomFactor += zoomStep; return !!v }
    function zoomOut(tab) { const v = viewAt(tab); if (v) v.zoomFactor -= zoomStep; return !!v }
    function resetZoom(tab) { const v = viewAt(tab); if (v) v.zoomFactor = 1; return !!v }

    // ---- keyboard page navigation -------------------------------------------

    // Scrolls the page of `tab` like the keyboard does, without giving it
    // the focus: `how` is "up", "down", "left", "right" (scrollStep CSS px,
    // or opts.amount), "pageUp", "pageDown" (opts.pages of the visible
    // height, default 0.9), "top" or "bottom". It moves the scrollable
    // element around the focused element or the middle of the page, else
    // the document. opts.smooth animates it. Returns a Promise of { ok,
    // moved, element ("document" or the tag name), x, y (its new scroll
    // position) } (ok false with an `error` without a page).
    function scrollPage(how, opts, tab) {
        const v = viewAt(tab)
        const o = Object.assign({ amount: scrollStep }, opts || {})
        return _pageCall(v, "scroll", [how, o])
    }
    // Focuses a text field of the page of `tab` (and the view): the first
    // visible one, or with opts.next / opts.previous the one after / before
    // the focused one, or opts.index; opts.select selects its text (else the
    // caret goes to the end). Returns a Promise of { ok, count, index }.
    function focusInput(opts, tab) {
        const v = viewAt(tab)
        if (v) v.forceActiveFocus(Qt.OtherFocusReason)
        return _pageCall(v, "focusInput", [opts || {}])
    }

    // ---- tabs --------------------------------------------------------------

    // The view of `tab` (index, negative from the end, or view; undefined:
    // the current tab), or null.
    function viewAt(tab) {
        if (!tabs) return null
        if (tab === undefined || tab === null) return currentView
        if (typeof tab === "number") {
            const i = tab < 0 ? tabs.count + tab : tab
            return i >= 0 && i < tabs.count ? tabs.views[i] : null
        }
        return tabs.indexOf(tab) >= 0 ? tab : null
    }
    // Index of `tab` (view or index), or -1.
    function indexOf(tab) {
        const v = viewAt(tab)
        return v ? tabs.indexOf(v) : -1
    }

    function selectTab(tab) {
        const i = indexOf(tab)
        if (i < 0) return false
        tabs.currentIndex = i
        return true
    }
    function closeTab(tab) {
        const i = indexOf(tab)
        if (i < 0) return false
        tabs.closeTab(i)
        return true
    }
    function nextTab() { return count > 0 && selectTab((currentIndex + 1) % count) }
    function previousTab() { return count > 0 && selectTab((currentIndex + count - 1) % count) }
    function moveTab(tab, to) {
        const i = indexOf(tab)
        if (i < 0) return false
        tabs.moveTab(i, to < 0 ? count + to : to)
        return true
    }
    // Opens a copy of `tab` (its URL) next to it.
    function duplicateTab(tab) {
        const v = viewAt(tab)
        return v ? openTab(v.url, { index: tabs.indexOf(v) + 1 }) : null
    }
    // Reopens closedTabs[i] (default: the most recently closed one) at its
    // old position, selects it and returns its view (null for a bad index).
    function reopenClosedTab(i) {
        if (i === undefined || i === null) i = closedTabs.length - 1
        if (!tabs || i < 0 || i >= closedTabs.length) return null
        const list = closedTabs.slice()
        const entry = list.splice(i, 1)[0]
        closedTabs = list
        const props = {}
        if (entry.title) props.title = entry.title
        if (entry.icon) props.icon = entry.icon
        if (entry.zoom > 0 && entry.zoom !== 1) props.zoomFactor = entry.zoom
        // The stored URL as is: urlFor() would treat it as typed text.
        const index = entry.index >= 0 ? Math.min(entry.index, count) : count
        return tabs.openTab(entry.url, false, index, props)
    }
    // Removes closedTabs[i]; returns false for a bad index.
    function forgetClosedTab(i) {
        if (i < 0 || i >= closedTabs.length) return false
        const list = closedTabs.slice()
        list.splice(i, 1)
        closedTabs = list
        return true
    }
    function clearClosedTabs() { closedTabs = [] }

    // Frees the browser of a background tab (see WebTabs.discard()).
    function discardTab(tab) {
        const i = indexOf(tab)
        return i >= 0 && tabs.discard(i)
    }

    // First view for which predicate(view, index) is true, or null.
    function findTab(predicate) {
        const all = findTabs(predicate)
        return all.length > 0 ? all[0] : null
    }
    // All views for which predicate(view, index) is true.
    function findTabs(predicate) {
        if (!tabs) return []
        return tabs.views.filter((v, i) => predicate(v, i))
    }
    // First view whose URL equals `url` (string or url) or matches it (RegExp).
    function tabForUrl(url) {
        if (url instanceof RegExp) return findTab(v => url.test(v.url.toString()))
        const s = url.toString()
        return findTab(v => v.url.toString() === s)
    }

    // ---- internals ---------------------------------------------------------

    property var _trackers: []
    property Component _timerComponent: Component { Timer { running: true } }
    property Connections _tabsConnection: Connections {
        target: ctl.tabs
        function onTabClosed(view, index) {
            const u = view.url.toString()
            if (u === "" || u === "about:blank" || ctl.isInternalUrl(u)) return
            const entry = { url: u, title: view.title, icon: view.icon.toString(),
                            index: index, time: Date.now() }
            if (view.zoomFactor !== 1) entry.zoom = view.zoomFactor
            const list = ctl.closedTabs.concat([entry])
            ctl.closedTabs = list.slice(Math.max(0, list.length - ctl.closedTabsLimit))
        }
    }

    // whenLoaded() options after a navigation was just requested: wait for
    // its loadStarted.
    function _navigationOpts(opts) { return Object.assign({}, opts, { _navigation: true }) }
    function _after(ms, fn) {
        const timer = _timerComponent.createObject(ctl, { interval: ms })
        timer.triggered.connect(fn)
        return timer
    }
    function _pageCall(view, name, args) {
        if (!view || !view.ready) return Promise.resolve({ ok: false, error: "noPage" })
        return new Promise(resolve => PageTools.call(view, name, args, (r, err) => {
            if (err !== undefined || !r) resolve({ ok: false, error: err !== undefined ? String(err) : "failed" })
            else resolve(r)
        }))
    }
    function _settled(result, callback) {
        if (callback) {
            try { callback(result) } catch (e) { console.warn("BrowserController: load callback failed:", e) }
        }
        return Promise.resolve(result)
    }
}
