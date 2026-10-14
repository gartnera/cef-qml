import QtQuick
import CefQml
import "UserScripts.js" as US

// Installed userscripts (Greasemonkey/Tampermonkey/Violentmonkey-style) and
// their GM_* values, persisted with JsonStore under Cef.dataDir/<directory>,
// and injected into every view attached with attach(view) (WebTabs does it
// for its tabs when its `userScriptStore` is set).
//
//   UserScriptStore { id: scripts }
//   CefWebView { id: web; Component.onCompleted: scripts.attach(web) }
//   scripts.install(source)        // -> { ok, script, updated, error, warnings }
//
// Changes (install, update, enable, remove, values) apply to documents that
// start afterwards, in every attached view; pages already open keep what
// they started with.
QtObject {
    id: store

    // Subdirectory of Cef.dataDir (or an absolute path) holding scripts.json
    // and values.json.
    property string directory: "userscripts"

    // Installed scripts in order (reassigned on every change). Each entry:
    // { id, name, namespace, version, description, author, icon, homepage,
    //   enabled, source, url, installDate, updateDate (ms since epoch),
    //   meta (all parsed metadata), grants, world ("page" | "content"),
    //   runAt, noframes, matchSummary, warnings, requires: [{ url, error }],
    //   pending (fetching @require), error ("" or why it cannot run) }
    readonly property var scripts: _scripts
    readonly property int count: _scripts.length
    readonly property bool loaded: _scriptsFile.loaded && _valuesFile.loaded

    signal installed(var script, bool updated)
    signal removed(string id)
    // GM values of a script changed (from a page or through setValue()).
    signal valuesChanged(string id)
    // The scripts running in an attached view's top document changed.
    signal runningChanged(var view)

    // --- Scripts --------------------------------------------------------

    // Installs `source`, or updates the installed script with the same
    // @namespace and @name (keeping its id, enabled state and values).
    // options: { url (where it came from; base for relative @require),
    //            enabled (default true) }.
    // Returns { ok, script, updated, error, warnings }. @require files are
    // then fetched in the background (`pending`); the script runs once all
    // of them arrived.
    function install(source, options) {
        options = options || {}
        source = String(source === undefined ? "" : source)
        const meta = US.parseMetadata(source)
        if (!meta)
            return { ok: false, error: "Not a userscript: no // ==UserScript== block" }
        if (!meta.name)
            return { ok: false, error: "The userscript has no @name" }
        const list = _records()
        let index = options.id !== undefined ? list.findIndex(r => r.id === options.id)
                  : list.findIndex(r => {
                        const m = US.parseMetadata(r.source) || {}
                        return m.name === meta.name && (m.namespace || "") === meta.namespace
                    })
        const now = Date.now()
        const old = index >= 0 ? list[index] : null
        const url = String(options.url || (old && old.url) || "")
        const record = {
            id: old ? old.id : _newId(),
            source: source,
            enabled: old ? old.enabled : options.enabled !== false,
            url: url,
            installDate: old ? old.installDate : now,
            updateDate: now,
            requires: meta.require.map(r => {
                const abs = _resolve(r, url)
                const prev = old && (old.requires || []).find(p => p.url === abs && p.source !== undefined)
                return prev ? { url: abs, source: prev.source } : { url: abs }
            })
        }
        if (old) list[index] = record
        else list.push(record)
        _store(list)
        _fetchRequires(record.id)
        const result = store.script(record.id)
        installed(result, !!old)
        return { ok: true, script: result, updated: !!old, error: "", warnings: meta.warnings }
    }

    // Fetches `url` (http(s), file: or data:) and installs it; calls
    // callback(result) with install()'s result.
    function installFromUrl(url, callback) {
        url = String(url)
        _fetch(url, (text, error) => {
            const result = error ? { ok: false, error: error }
                                 : install(text, { url: url })
            if (callback) callback(result)
        })
    }

    // Fetches a script's text without installing it (e.g. to review it
    // first); calls callback(text, error).
    function fetchSource(url, callback) { _fetch(String(url), callback) }

    // Replaces the source of script `id` (metadata may change, even @name).
    function update(id, source) {
        if (!script(id)) return { ok: false, error: "No such script: " + id }
        return install(source, { id: id })
    }

    function remove(id) {
        const list = _records()
        const index = list.findIndex(r => r.id === id)
        if (index < 0) return false
        list.splice(index, 1)
        _store(list)
        if (_valuesFile.get(id) !== undefined) {
            _valuesFile.remove(id)
        }
        removed(id)
        return true
    }

    function setEnabled(id, enabled) {
        const list = _records()
        const r = list.find(r => r.id === id)
        if (!r || r.enabled === !!enabled) return
        r.enabled = !!enabled
        _store(list)
    }

    // Moves a script; scripts run in list order (per @run-at).
    function move(from, to) {
        const list = _records()
        if (from < 0 || to < 0 || from >= list.length || to >= list.length || from === to) return
        list.splice(to, 0, list.splice(from, 1)[0])
        _store(list)
    }

    function script(id) { return _scripts.find(s => s.id === id) || null }

    // Enabled scripts that run on `url` in a top-level document (pass
    // includeDisabled to list disabled ones too).
    function scriptsFor(url, includeDisabled) {
        return _scripts.filter(s => (includeDisabled || s.enabled) && US.rulesMatch(s._rules, url))
    }

    // Exposed for tools and tests.
    function parseMetadata(source) { return US.parseMetadata(source) }
    function matches(patternOrRules, url) {
        if (typeof patternOrRules === "string") {
            const p = patternOrRules
            const r = /^(<all_urls>$|[a-z*]+:\/\/)/.test(p) ? US.compileMatch(p) : US.compileGlob(p)
            return !!r && US.rulesMatch({ include: [r], exclude: [] }, url)
        }
        return US.rulesMatch(US.compileRules(patternOrRules), url)
    }

    // --- GM values ------------------------------------------------------

    function values(id) {
        const v = _valuesFile.get(id)
        return v && typeof v === "object" ? v : ({})
    }
    function setValue(id, key, value) {
        const v = values(id)
        if (value === undefined) delete v[key]
        else v[key] = JSON.parse(JSON.stringify(value))
        _setValues(id, v)
    }
    function deleteValue(id, key) { setValue(id, key, undefined) }
    function clearValues(id) { _setValues(id, {}) }

    // Writes pending changes now (they are also saved shortly after every
    // change and at exit).
    function save() { return _scriptsFile.save() && _valuesFile.save() }
    // Reads both files again, discarding unsaved changes.
    function reload() {
        _scriptsFile.reload()
        _valuesFile.reload()
        _rebuild()
    }

    // --- Views ----------------------------------------------------------

    // Injects the scripts into `view` from its next document on (before its
    // first page if the view is new). Returns false if already attached.
    function attach(view) {
        if (!view || _hostFor(view)) return false
        const host = _hostComponent.createObject(view, { view: view, store: store })
        _hosts = _hosts.concat([host])
        return true
    }
    function detach(view) {
        const host = _hostFor(view)
        if (!host) return false
        host.unregister()
        _hosts = _hosts.filter(h => h !== host)
        host.destroy()
        return true
    }
    function isAttached(view) { return !!_hostFor(view) }
    // True once every change made so far is registered with `view`, i.e.
    // its next document gets it (also true for views not attached).
    function isApplied(view) {
        const host = _hostFor(view)
        return !host || host.settled()
    }
    // Calls callback() once isApplied(view) (e.g. before navigating in
    // tests or automation).
    function whenApplied(view, callback) {
        const host = _hostFor(view)
        if (!host) { callback(); return }
        host.waiters.push(callback)
        host.checkWaiters()
    }
    // Ids of the scripts that run in `view`'s current top-level document,
    // as reported by the page.
    function runningScripts(view) {
        const host = _hostFor(view)
        return host ? host.running.page.concat(host.running.content) : []
    }

    // --- Internals ------------------------------------------------------

    property var _scripts: []
    property var _hosts: []
    // Per store, so that the hidden page globals are not predictable.
    readonly property string _token: Math.random().toString(36).slice(2, 10)
    readonly property string _queue: "__cefqml_usq_" + _token
    readonly property string _pageBinding: "__cefqml_usp_" + _token
    readonly property string _contentBinding: "__cefqml_usc_" + _token
    readonly property string _respond: "__cefqml_usr_" + _token
    readonly property string _world: "cefqml-userscripts"
    property int _generation: 0

    function _dir() {
        const d = directory.replace(/\/+$/, "")
        return d === "" ? "" : d + "/"
    }

    property JsonStore _scriptsFile: JsonStore {
        path: store._dir() + "scripts.json"
        data: ({ version: 1, scripts: [] })
        onDataChanged: store._rebuild()
    }
    property JsonStore _valuesFile: JsonStore {
        path: store._dir() + "values.json"
        data: ({})
    }

    function _records() {
        const d = _scriptsFile.data
        return d && Array.isArray(d.scripts) ? d.scripts.map(r => Object.assign({}, r)) : []
    }
    function _store(list) {
        _scriptsFile.data = { version: 1, scripts: list }
    }
    function _setValues(id, v) {
        _valuesFile.set(id, v)
        valuesChanged(id)
        _hosts.forEach(h => h.valuesChanged(id))
    }
    function _newId() {
        let id
        do id = "us-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 7)
        while (_records().some(r => r.id === id))
        return id
    }
    function _resolve(url, base) {
        if (/^[a-z][a-z0-9+.-]*:/i.test(url) || !base) return url
        try { return new URL(url, base).toString() } catch (e) { return url }
    }

    function _rebuild() {
        const list = _records().map(r => {
            const meta = US.parseMetadata(r.source) || US.parseMetadata("// ==UserScript==\n// ==/UserScript==")
            const grants = US.effectiveGrants(meta, r.source)
            const requires = (r.requires || []).map(q => ({ url: q.url, error: q.error || "",
                                                           loaded: q.source !== undefined }))
            const failed = requires.filter(q => q.error)
            const pending = requires.some(q => !q.loaded && !q.error)
            const world = US.worldFor(meta, grants)
            const warnings = meta.warnings.slice()
            if (world === "page" && grants.indexOf("GM_xmlhttpRequest") >= 0)
                warnings.push("GM_xmlhttpRequest is only available in the content world (@inject-into content)")
            return {
                id: r.id, name: meta.name || "Unnamed script", namespace: meta.namespace,
                version: meta.version, description: meta.description, author: meta.author,
                icon: meta.icon, homepage: meta.homepage, enabled: r.enabled !== false,
                source: r.source, url: r.url || "", installDate: r.installDate || 0,
                updateDate: r.updateDate || r.installDate || 0, meta: meta, grants: grants,
                world: world, runAt: meta.runAt, noframes: meta.noframes,
                matchSummary: US.matchSummary(meta), warnings: warnings,
                requires: requires, pending: pending,
                error: failed.length ? "could not load @require " + failed[0].url + ": " + failed[0].error : "",
                _rules: US.compileRules(meta),
                _code: (r.requires || []).map(q => (q.source || "") + "\n;").join("") + r.source
            }
        })
        _scripts = list
        _generation++
        _hosts.forEach(h => h.scriptsChanged())
    }

    // Scripts to inject into `world`, in order.
    function _active(world) {
        return _scripts.filter(s => s.enabled && !s.pending && !s.error && s.world === world)
    }
    function _entries(world) {
        return _active(world).map(s => US.entrySource(_queue, s.id, s._code))
    }
    function _runtime(world) {
        const page = world === "page"
        return US.runtimeSource({
            queue: _queue,
            binding: page ? _pageBinding : _contentBinding,
            bindings: page ? [_pageBinding] : [_pageBinding, _contentBinding],
            respond: page ? "" : _respond,
            world: world,
            scripts: _active(world).map(s => ({
                id: s.id, name: s.name, runAt: s.runAt, noframes: s.noframes,
                rules: s._rules, grants: s.grants, values: values(s.id),
                info: {
                    uuid: s.id, name: s.name, namespace: s.namespace, version: s.version,
                    description: s.description, author: s.author, icon: s.icon,
                    homepage: s.homepage, downloadURL: s.meta.downloadURL,
                    updateURL: s.meta.updateURL, matches: s.meta.match, includes: s.meta.include,
                    excludes: s.meta.exclude, excludeMatches: s.meta.excludeMatch,
                    grant: s.meta.grant, require: s.meta.require, runAt: s.runAt,
                    noframes: s.noframes, injectInto: s.meta.injectInto, metaStr: s.meta.metaStr
                }
            }))
        })
    }

    function _fetch(url, callback) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            const http = /^https?:/i.test(url)
            if (http ? xhr.status >= 200 && xhr.status < 300 : xhr.responseText !== "")
                callback(xhr.responseText, "")
            else
                callback("", http ? "HTTP " + xhr.status + (xhr.statusText ? " " + xhr.statusText : "")
                                  : "cannot read " + url)
        }
        try {
            xhr.open("GET", url)
            xhr.send()
        } catch (e) {
            callback("", String(e))
        }
    }

    function _fetchRequires(id) {
        const r = _records().find(r => r.id === id)
        if (!r) return
        for (const q of r.requires || []) {
            if (q.source !== undefined || q.error) continue
            const url = q.url
            _fetch(url, (text, error) => {
                const list = _records()
                const rec = list.find(x => x.id === id)
                if (!rec) return
                rec.requires = (rec.requires || []).map(p => p.url !== url ? p
                    : error ? { url: url, error: error } : { url: url, source: text })
                _store(list)
            })
        }
    }

    function _hostFor(view) { return _hosts.find(h => h.view === view) || null }
    function _hostGone(host) { _hosts = _hosts.filter(h => h !== host) }

    Component.onDestruction: {
        for (const h of _hosts) { h.unregister(); h.destroy() }
        _hosts = []
    }

    // Per attached view: DevTools registrations and the page -> host channel.
    property Component _hostComponent: Component {
        QtObject {
            id: host
            property CefWebView view
            property var store
            // Registrations: { kind: "entry" | "runtime", id (once known), dropped }
            property var regs: []
            property var running: ({ page: [], content: [] })
            property bool registered: false
            property var xhrs: ({})
            // Pending DevTools (un)registrations and queued refreshes.
            property int outstanding: 0
            property bool queuedAll: false
            property bool queuedRuntime: false
            property var waiters: []

            signal scriptsChanged()
            signal valuesChanged(string id)

            Component.onCompleted: setup()
            function setup() {
                const v = view
                v.devToolsMethod("Runtime.enable", {})
                v.devToolsMethod("Runtime.addBinding", { name: store._pageBinding })
                v.devToolsMethod("Runtime.addBinding", { name: store._contentBinding,
                                                         executionContextName: store._world })
                registered = true
                refreshAll()
            }
            // The view was discarded: its browser, with every registration
            // and pending DevTools reply, is gone. Queue the setup again for
            // the next browser (calls made while discarded wait for it).
            function reset() {
                life.alive = false
                life = { alive: true }
                regs = []
                outstanding = 0
                for (const k in xhrs) xhrs[k].abort()
                xhrs = {}
                if (running.page.length || running.content.length) {
                    running = { page: [], content: [] }
                    store.runningChanged(view)
                }
                setup()
            }
            Component.onDestruction: {
                life.alive = false
                if (store) store._hostGone(host)
            }

            onScriptsChanged: { queuedAll = true; Qt.callLater(refreshAll) }
            onValuesChanged: id => {
                if (store && store._scripts.some(s => s.id === id && s.enabled)) {
                    queuedRuntime = true
                    Qt.callLater(refreshRuntime)
                }
            }

            function settled() { return !queuedAll && !queuedRuntime && outstanding === 0 }
            function checkWaiters() {
                if (!settled() || !waiters.length) return
                const w = waiters
                waiters = []
                for (const cb of w) cb()
            }
            function done() {
                outstanding--
                checkWaiters()
            }

            // Replies can arrive after this host is gone (detach()); they
            // then only use what the closures captured.
            property var life: ({ alive: true })

            function add(source, world, kind) {
                const reg = { kind: kind, id: null, dropped: false }
                const v = view, life = host.life
                regs.push(reg)
                const params = { source: source }
                if (world === "content") params.worldName = store._world
                outstanding++
                v.devToolsMethod("Page.addScriptToEvaluateOnNewDocument", params, (r, err) => {
                    if (life.alive) host.done()
                    if (!r || r.identifier === undefined) {
                        console.warn("UserScriptStore: could not register a script:", err)
                        return
                    }
                    reg.id = r.identifier
                    // Superseded (or detached) before its identifier arrived.
                    if (!reg.dropped) return
                    if (life.alive) host.removeId(reg.id)
                    else v.devToolsMethod("Page.removeScriptToEvaluateOnNewDocument", { identifier: reg.id })
                })
            }
            function removeId(id) {
                const life = host.life
                outstanding++
                view.devToolsMethod("Page.removeScriptToEvaluateOnNewDocument", { identifier: id },
                                    () => { if (life.alive) host.done() })
            }
            function drop(kinds) {
                for (const reg of regs) {
                    if (kinds.indexOf(reg.kind) < 0) continue
                    reg.dropped = true
                    if (reg.id !== null) removeId(reg.id)
                }
                regs = regs.filter(r => !r.dropped)
            }
            function worlds() { return store._active("content").length ? ["page", "content"] : ["page"] }

            // Everything again: entries must precede their runtime.
            function refreshAll() {
                queuedAll = false
                queuedRuntime = false   // refreshAll includes the runtimes
                if (!registered || !store || !view) { checkWaiters(); return }
                drop(["entry", "runtime"])
                for (const w of worlds()) {
                    for (const src of store._entries(w)) add(src, w, "entry")
                    add(store._runtime(w), w, "runtime")
                }
            }
            // Only the runtimes (new GM values): the new ones are added
            // before the old ones go, so no document misses its runtime.
            function refreshRuntime() {
                if (!queuedRuntime) return   // superseded by refreshAll
                queuedRuntime = false
                if (!registered || !store || !view) { checkWaiters(); return }
                const old = regs.filter(r => r.kind === "runtime")
                for (const w of worlds()) add(store._runtime(w), w, "runtime")
                for (const reg of old) {
                    reg.dropped = true
                    if (reg.id !== null) removeId(reg.id)
                }
                regs = regs.filter(r => !r.dropped)
            }
            function unregister() {
                if (!registered || !view) return
                registered = false
                drop(["entry", "runtime"])
                view.devToolsMethod("Runtime.removeBinding", { name: store._pageBinding })
                view.devToolsMethod("Runtime.removeBinding", { name: store._contentBinding })
                for (const k in xhrs) xhrs[k].abort()
                xhrs = {}
            }
            function setRunning(world, ids) {
                const r = Object.assign({}, running)
                r[world] = ids
                running = r
                store.runningChanged(view)
            }

            property Connections _events: Connections {
                target: host.view
                function onDiscardedChanged() {
                    if (host.view.discarded && host.registered) host.reset()
                }
                function onDevToolsEvent(method, params) {
                    // The top document went away (cross-document navigation):
                    // its new document reports its scripts afresh.
                    if (method === "Runtime.executionContextsCleared") {
                        if (host.running.page.length || host.running.content.length) {
                            host.running = { page: [], content: [] }
                            host.store.runningChanged(host.view)
                        }
                        return
                    }
                    if (method !== "Runtime.bindingCalled" || !host.registered) return
                    const world = params.name === host.store._pageBinding ? "page"
                                : params.name === host.store._contentBinding ? "content" : ""
                    if (!world) return
                    let msg
                    try { msg = JSON.parse(params.payload) } catch (e) { return }
                    if (!msg || typeof msg !== "object") return
                    host.handle(world, msg, params.executionContextId)
                }
            }

            function handle(world, msg, contextId) {
                if (msg.t === "doc") {
                    const ids = (Array.isArray(msg.ids) ? msg.ids : [])
                        .filter(id => store._scripts.some(s => s.id === id && s.world === world))
                    setRunning(world, ids)
                    return
                }
                // A page can call its world's binding itself: only accept
                // messages for scripts of that world, within their grants.
                const s = store.script(msg.id)
                if (!s || s.world !== world) return
                const granted = n => s.grants.indexOf(n) >= 0
                switch (msg.t) {
                case "set":
                    if (!granted("GM_setValue")) return
                    store.setValue(s.id, String(msg.key), msg.value)
                    break
                case "del":
                    if (!granted("GM_deleteValue") && !granted("GM_setValue")) return
                    store.deleteValue(s.id, String(msg.key))
                    break
                case "open":
                    if (!granted("GM_openInTab") || !/^(https?|ftp|file|data):/i.test(String(msg.url))) return
                    view.newWindowRequested(String(msg.url), true, !!msg.background)
                    break
                case "clip":
                    if (!granted("GM_setClipboard")) return
                    Cef.copyToClipboard(String(msg.text))
                    break
                case "xhr":
                    if (world === "content" && granted("GM_xmlhttpRequest")) xhr(msg, contextId)
                    break
                case "abort": {
                    const x = xhrs[contextId + ":" + msg.rid]
                    if (x) x.abort()
                    break
                }
                }
            }

            // GM_xmlhttpRequest: performed by Qt (no Chromium cookies),
            // answered in the calling frame's isolated world.
            function xhr(msg, contextId) {
                const key = contextId + ":" + msg.rid
                const reply = res => {
                    view.devToolsMethod("Runtime.evaluate", {
                        expression: "globalThis[" + JSON.stringify(store._respond) + "](" +
                                    JSON.stringify(msg.rid) + "," + JSON.stringify(res) + ")",
                        contextId: contextId
                    })
                }
                const url = String(msg.url)
                if (!/^https?:/i.test(url)) {
                    reply({ readyState: 4, status: 0, statusText: "", responseText: "",
                            responseHeaders: "", finalUrl: url, error: "error" })
                    return
                }
                const x = new XMLHttpRequest()
                let done = false
                let timer = null
                const finish = error => {
                    if (done) return
                    done = true
                    delete xhrs[key]
                    if (timer) timer.destroy()
                    reply({ readyState: 4, status: error ? 0 : x.status, statusText: error ? "" : x.statusText,
                            responseText: error ? "" : x.responseText,
                            responseHeaders: error ? "" : x.getAllResponseHeaders(),
                            finalUrl: url, error: error })
                }
                x.onreadystatechange = () => {
                    if (x.readyState === XMLHttpRequest.DONE)
                        finish(x.status === 0 ? "error" : "")
                }
                xhrs[key] = { abort: () => { finish("abort"); x.abort() } }
                try {
                    x.open(String(msg.method || "GET").toUpperCase(), url)
                    const headers = msg.headers || {}
                    for (const h in headers) x.setRequestHeader(h, String(headers[h]))
                    if (msg.timeout > 0) {
                        timer = Qt.createQmlObject("import QtQuick; Timer { running: true }", host)
                        timer.interval = msg.timeout
                        timer.triggered.connect(() => { finish("timeout"); x.abort() })
                    }
                    x.send(msg.data === null || msg.data === undefined ? undefined : String(msg.data))
                } catch (e) {
                    finish("error")
                }
            }
        }
    }
}
