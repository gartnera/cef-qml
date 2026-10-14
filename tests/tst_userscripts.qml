// Userscripts: metadata and URL rules, injection (run-at order, frames,
// worlds), GM APIs and their persistence, UserScriptStore management and
// WebTabs integration. Pages are data: URLs; no network.
import QtQuick
import QtTest
import CefQml
import CefQml.Components

Item {
    id: root
    width: 800
    height: 600

    function page(title, body, head) {
        return "data:text/html," + encodeURIComponent("<!doctype html><html><head><title>" + title +
            "</title>" + (head || "") + "</head><body>" + (body || "") + "</body></html>")
    }
    function userscript(meta, code) {
        return "// ==UserScript==\n" + meta.map(l => "// @" + l).join("\n") +
               "\n// ==/UserScript==\n" + (code || "")
    }

    UserScriptStore { id: store; directory: "test-userscripts" }

    Component {
        id: viewComponent
        CefWebView { width: 400; height: 300 }
    }
    Component {
        id: storeComponent
        UserScriptStore { }
    }
    Component {
        id: managerComponent
        UserScriptManager { width: 800; height: 600 }
    }
    // Reads the system clipboard (paste()).
    TextEdit { id: clipboardReader; visible: false }

    Component {
        id: tabsComponent
        WebTabs { width: 400; height: 300 }
    }

    TestCase {
        id: test
        name: "UserScripts"
        when: windowShown

        property var views: []
        property var manager: null

        // A new view attached to `s` (default: store) before its first page.
        function newView(url, s) {
            const v = viewComponent.createObject(root, { url: url, z: -1 })
            ;(s || store).attach(v)
            views.push(v)
            return v
        }
        function load(v, url, title) {
            // Changes apply to documents started after their registration.
            tryVerify(() => store.isApplied(v), 5000, "changes registered")
            v.url = url
            tryCompare(v, "title", title, 15000)
            tryCompare(v, "loading", false, 15000)
        }
        function evaluate(v, script) {
            let out = null
            v.evaluateJavaScript(script, (r, e) => out = [r, e])
            tryVerify(() => out !== null, 10000, script)
            if (out[1]) fail(out[1] + " in " + script)
            return out[0]
        }
        // Waits until `script` (evaluated in the page) returns `expected`.
        function waitFor(v, script, expected, message) {
            let last
            tryVerify(() => {
                let out = null
                v.evaluateJavaScript(script, (r, e) => out = [r, e])
                const t = Date.now()
                while (out === null && Date.now() - t < 5000) wait(10)
                last = out && out[0]
                return JSON.stringify(last) === JSON.stringify(expected)
            }, 10000, (message || script) + " (last: " + JSON.stringify(last) + ")")
        }
        function attr(name) {
            return "document.documentElement.getAttribute(" + JSON.stringify(name) + ")"
        }
        function install(meta, code) {
            const r = store.install(userscript(meta, code))
            verify(r.ok, r.error)
            return r.script
        }

        function child(parent, name) {
            let item = null
            tryVerify(() => (item = findChild(parent, name)) !== null, 5000, "no child " + name)
            return item
        }

        function cleanup() {
            for (const v of views) v.destroy()
            views = []
            if (manager) { manager.destroy(); manager = null }
            for (const s of store.scripts.slice()) store.remove(s.id)
        }

        // --- Pure functions -------------------------------------------

        function test_metadata() {
            const m = store.parseMetadata(userscript([
                "name  My Script", "name:de Mein Skript", "namespace https://example.com/",
                "version 1.2.3", "description Does things", "author Someone",
                "match *://example.com/*", "match https://*.example.org/path*",
                "include /^https?://foo\\.com/.*$/", "exclude *://example.com/private/*",
                "exclude-match https://example.com/admin/*", "run-at document-start",
                "grant GM_setValue", "grant GM.getValue", "grant GM_notification",
                "noframes", "require https://cdn.example.com/lib.js", "icon https://x/i.png",
                "downloadURL https://x/s.user.js", "updateURL https://x/s.meta.js",
                "custom one", "custom two"], "code()"))
            compare(m.name, "My Script")
            compare(m.namespace, "https://example.com/")
            compare(m.version, "1.2.3")
            compare(m.description, "Does things")
            compare(m.author, "Someone")
            compare(m.match, ["*://example.com/*", "https://*.example.org/path*"])
            compare(m.include, ["/^https?://foo\\.com/.*$/"])
            compare(m.exclude, ["*://example.com/private/*"])
            compare(m.excludeMatch, ["https://example.com/admin/*"])
            compare(m.runAt, "document-start")
            compare(m.noframes, true)
            compare(m.grant, ["GM_setValue", "GM.getValue", "GM_notification"])
            compare(m.require, ["https://cdn.example.com/lib.js"])
            compare(m.icon, "https://x/i.png")
            compare(m.downloadURL, "https://x/s.user.js")
            compare(m.updateURL, "https://x/s.meta.js")
            compare(m.other.custom, ["one", "two"])
            compare(m.other["name:de"], "Mein Skript")
            verify(m.warnings.some(w => w.indexOf("GM_notification") >= 0), m.warnings)

            const d = store.parseMetadata(userscript(["name x", "run-at document-body"]))
            compare(d.runAt, "document-body")
            compare(store.parseMetadata(userscript(["name x"])).runAt, "document-end", "default")
            const bad = store.parseMetadata(userscript(["name x", "run-at whenever"]))
            compare(bad.runAt, "document-end")
            verify(bad.warnings.length === 1)
            compare(store.parseMetadata("alert(1)"), null)
            const noName = store.install(userscript(["version 1"]))
            verify(!noName.ok)
            verify(!store.install("var x").ok)
        }

        function test_match_patterns_data() {
            return [
                { p: "<all_urls>", u: "https://a.com/x", e: true },
                { p: "<all_urls>", u: "file:///tmp/a.html", e: true },
                { p: "<all_urls>", u: "data:text/html,hi", e: true },
                { p: "<all_urls>", u: "about:blank", e: false },
                { p: "<all_urls>", u: "chrome://version", e: false },
                { p: "*://*/*", u: "http://a.com/", e: true },
                { p: "*://*/*", u: "https://a.com:8443/x?y#z", e: true },
                { p: "*://*/*", u: "file:///x", e: false },
                { p: "*://*/*", u: "ftp://a.com/", e: false },
                { p: "https://*/*", u: "http://a.com/", e: false },
                { p: "http://example.com/*", u: "http://example.com/", e: true },
                { p: "http://example.com/*", u: "http://example.com:8080/a", e: true },
                { p: "http://example.com/*", u: "http://www.example.com/", e: false },
                { p: "*://*.example.com/*", u: "https://example.com/", e: true },
                { p: "*://*.example.com/*", u: "https://a.b.example.com/p", e: true },
                { p: "*://*.example.com/*", u: "https://badexample.com/", e: false },
                { p: "*://*.example.com/*", u: "https://example.com.evil.org/", e: false },
                { p: "https://example.com/foo*bar", u: "https://example.com/foo-x-bar", e: true },
                { p: "https://example.com/foo*bar", u: "https://example.com/foo-x-baz", e: false },
                { p: "https://example.com/foo", u: "https://example.com/foo", e: true },
                { p: "https://example.com/foo", u: "https://example.com/foo?q", e: false },
                { p: "https://example.com/foo", u: "https://example.com/foo#frag", e: true },
                { p: "https://example.com/a?b=*", u: "https://example.com/a?b=1", e: true },
                { p: "file:///tmp/*", u: "file:///tmp/a.html", e: true },
                { p: "file:///tmp/*", u: "file:///etc/passwd", e: false },
                { p: "http://localhost:8080/*", u: "http://localhost:8080/x", e: true },
                { p: "http://localhost:8080/*", u: "http://localhost:9090/x", e: false },
                // Invalid patterns match nothing.
                { p: "*://*", u: "http://a.com/", e: false },
                { p: "http://a*b.com/*", u: "http://ab.com/", e: false },
                // @include globs and regular expressions.
                { p: "*", u: "https://anything/", e: true },
                { p: "http*://example.com/*", u: "https://example.com/x", e: true },
                { p: "*example.com*", u: "http://www.example.com/", e: true },
                { p: "/^https:\\/\\/foo\\.com\\//", u: "https://foo.com/a", e: true },
                { p: "/^https:\\/\\/foo\\.com\\//", u: "http://foo.com/a", e: false },
                { p: "/FOO/i", u: "https://foo.com/", e: true },
            ].map(r => ({ tag: r.p + " " + r.u, pattern: r.p, url: r.u, expected: r.e }))
        }
        function test_match_patterns(data) {
            compare(store.matches(data.pattern, data.url), data.expected)
        }

        function test_rules_and_scriptsFor() {
            const meta = m => store.parseMetadata(userscript(["name t"].concat(m)))
            verify(store.matches(meta([]), "https://x.com/"), "no rules: all pages")
            verify(!store.matches(meta([]), "about:blank"))
            verify(store.matches(meta(["match *://a.com/*", "include *b.com*"]), "https://b.com/"))
            verify(!store.matches(meta(["match *://a.com/*", "exclude *secret*"]), "https://a.com/secret"))
            verify(!store.matches(meta(["match *://a.com/*", "exclude-match *://a.com/x/*"]), "https://a.com/x/1"))
            verify(!store.matches(meta(["match not-a-pattern"]), "https://a.com/"),
                   "only invalid rules: nothing")

            const a = install(["name A", "match *://a.com/*"])
            const b = install(["name B", "include *"])
            const c = install(["name C", "match *://c.com/*"])
            compare(store.scriptsFor("https://a.com/").map(s => s.name), ["A", "B"])
            store.setEnabled(b.id, false)
            compare(store.scriptsFor("https://a.com/").map(s => s.name), ["A"])
            compare(store.scriptsFor("https://a.com/", true).map(s => s.name), ["A", "B"])
            compare(store.script(c.id).matchSummary, "*://c.com/*")
        }

        function test_grants_and_worlds() {
            const g = (meta, code) => install(["name g" + Math.random()].concat(meta), code)
            const none = g(["grant none"])
            compare(none.world, "page")
            compare(none.grants, ["GM_info", "GM_log"])
            const values = g(["grant GM.setValue", "grant GM_getValue"])
            compare(values.world, "content")
            verify(values.grants.indexOf("GM_setValue") >= 0)
            verify(values.grants.indexOf("GM_getValue") >= 0)
            const inferred = g([], "GM_addStyle('x'); GM.openInTab('y')")
            verify(inferred.grants.indexOf("GM_addStyle") >= 0, "no @grant: inferred")
            verify(inferred.grants.indexOf("GM_openInTab") >= 0)
            compare(inferred.world, "content")
            compare(g([]).world, "page", "no @grant, no API use")
            compare(g(["grant GM_setValue", "grant unsafeWindow"]).world, "page")
            compare(g(["grant none", "inject-into content"]).world, "content")
            compare(g(["grant GM_setValue", "inject-into page"]).world, "page")
        }

        // --- Injection ------------------------------------------------

        function test_first_navigation_and_run_order() {
            const push = what => "(window.__order = window.__order || []).push('" + what + "'" +
                                 " + (document.body ? '+body' : ''))"
            install(["name idle", "grant none", "run-at document-idle"], push("idle"))
            install(["name end", "grant none"], push("end"))
            install(["name body", "grant none", "run-at document-body"], push("body"))
            install(["name start", "grant none", "run-at document-start"],
                    push("start") + "; document.addEventListener('DOMContentLoaded', () => " + push("dcl") + ")")
            // A brand-new view: its very first page must get the scripts.
            const v = newView(page("order", "<p>x</p>",
                "<script>" + push("head") + "<\/script>"))
            tryCompare(v, "title", "order", 15000)
            waitFor(v, "window.__order",
                    ["start", "head", "body+body", "end+body", "dcl+body", "idle+body"])
            compare(store.runningScripts(v).length, 4)
        }

        function test_exclude() {
            install(["name ex", "grant none", "include *", "exclude *excluded*"],
                    "document.documentElement.setAttribute('data-ex', 'ran')")
            const v = newView(page("one", "fine"))
            tryCompare(v, "title", "one", 15000)
            waitFor(v, attr("data-ex"), "ran")
            load(v, page("two", "excluded"), "two")
            compare(evaluate(v, attr("data-ex")), null)
            compare(store.runningScripts(v), [])
        }

        function test_noframes() {
            const code = name => "if (window === top) document.documentElement.setAttribute('data-" + name + "', 'top');" +
                                 " else top.postMessage('" + name + "', '*')"
            install(["name framed", "grant none"], code("framed"))
            install(["name topOnly", "grant none", "noframes"], code("toponly"))
            const frame = "data:text/html," + encodeURIComponent("<title>child</title>child")
            const v = newView(page("frames", "<iframe src='" + frame + "'></iframe>",
                "<script>window.__msgs = []; addEventListener('message', e => __msgs.push(e.data))<\/script>"))
            tryCompare(v, "title", "frames", 15000)
            waitFor(v, attr("data-framed") + " + ',' + " + attr("data-toponly"), "top,top")
            waitFor(v, "window.__msgs", ["framed"], "only the framed script runs in the iframe")
            wait(300)
            compare(evaluate(v, "window.__msgs"), ["framed"])
        }

        function test_enable_disable_update_remove() {
            const s = install(["name toggled", "version 1", "grant none"],
                              "document.documentElement.setAttribute('data-t', 'v1')")
            const v = newView(page("t1"))
            tryCompare(v, "title", "t1", 15000)
            waitFor(v, attr("data-t"), "v1")
            store.setEnabled(s.id, false)
            compare(store.script(s.id).enabled, false)
            verify(!store.isApplied(v), "a refresh is queued")
            let applied = false
            store.whenApplied(v, () => applied = true)
            tryVerify(() => applied, 5000, "whenApplied")
            verify(store.isApplied(v))
            load(v, page("t2"), "t2")
            compare(evaluate(v, attr("data-t")), null, "disabled")
            store.setEnabled(s.id, true)
            load(v, page("t3"), "t3")
            waitFor(v, attr("data-t"), "v1", "enabled again")
            const r = store.update(s.id, userscript(["name toggled", "version 2", "grant none"],
                                                    "document.documentElement.setAttribute('data-t', 'v2')"))
            verify(r.ok && r.updated)
            compare(store.script(s.id).version, "2")
            load(v, page("t4"), "t4")
            waitFor(v, attr("data-t"), "v2", "updated")
            // Installing the same @namespace/@name again updates it in place.
            const again = store.install(userscript(["name toggled", "version 3", "grant none"],
                                                   "document.documentElement.setAttribute('data-t', 'v3')"))
            verify(again.updated)
            compare(again.script.id, s.id)
            compare(store.count, 1)
            verify(store.remove(s.id))
            compare(store.count, 0)
            load(v, page("t5"), "t5")
            compare(evaluate(v, attr("data-t")), null, "removed")
        }

        function test_syntax_error_isolated() {
            install(["name broken", "grant none"], "this is not javascript (")
            install(["name works", "grant none"], "document.documentElement.setAttribute('data-ok', '1')")
            install(["name throws", "grant none", "run-at document-start"], "throw new Error('boom')")
            const v = newView(page("syntax"))
            tryCompare(v, "title", "syntax", 15000)
            waitFor(v, attr("data-ok"), "1")
        }

        function test_worlds() {
            const report = "document.documentElement.setAttribute('data-' + GM_info.script.name," +
                " typeof pageVar + ',' + typeof GM_getValue + ',' + (unsafeWindow === window))"
            install(["name pageworld", "grant none"], report + "; window.fromPageWorld = 1")
            install(["name contentworld", "grant GM_getValue"], report + "; window.fromContentWorld = 1")
            const v = newView(page("worlds", "", "<script>var pageVar = 1<\/script>"))
            tryCompare(v, "title", "worlds", 15000)
            waitFor(v, attr("data-pageworld"), "number,undefined,true", "grant none: page world")
            waitFor(v, attr("data-contentworld"), "undefined,function,true", "grants: isolated world")
            compare(evaluate(v, "typeof fromPageWorld + ',' + typeof fromContentWorld"), "number,undefined")
            compare(evaluate(v, "Object.getOwnPropertyNames(window).filter(n => n.indexOf('cefqml') >= 0)"), [],
                    "no hidden globals left for the page")
            compare(evaluate(v, "typeof GM_getValue + typeof GM_info + typeof GM"), "undefinedundefinedundefined")
        }

        function test_gm_values_persist() {
            const s = install(["name counter", "grant GM_getValue", "grant GM_setValue", "grant GM.listValues",
                               "grant GM_deleteValue"],
                "const n = GM_getValue('n', 0);" +
                "GM_setValue('n', n + 1); GM_setValue('obj', { a: [1, 2] }); GM_setValue('tmp', 1); GM_deleteValue('tmp');" +
                "GM.listValues().then(k => document.documentElement.setAttribute('data-n'," +
                " n + ':' + GM_getValue('n') + ':' + k.sort().join('|') + ':' + GM_getValue('obj').a[1]));")
            compare(store.values(s.id), {})
            const v = newView(page("c1"))
            tryCompare(v, "title", "c1", 15000)
            waitFor(v, attr("data-n"), "0:1:n|obj:2")
            tryVerify(() => store.values(s.id).n === 1, 5000, "the host got the value")
            compare(store.values(s.id).obj, { a: [1, 2] })
            verify(!("tmp" in store.values(s.id)))
            load(v, page("c2"), "c2")
            waitFor(v, attr("data-n"), "1:2:n|obj:2", "next navigation sees the value")
            tryVerify(() => store.values(s.id).n === 2, 5000)
            // Another view (another tab) shares them.
            const w = newView(page("c3"))
            tryCompare(w, "title", "c3", 15000)
            waitFor(w, attr("data-n"), "2:3:n|obj:2", "shared across views")
            tryVerify(() => store.values(s.id).n === 3, 5000)
            // Values written by the host are seen by pages too.
            store.setValue(s.id, "n", 10)
            load(v, page("c4"), "c4")
            waitFor(v, attr("data-n"), "10:11:n|obj:2")
            tryVerify(() => store.values(s.id).n === 11, 5000)

            // Persisted: a new store on the same directory reads them from disk.
            verify(store.save())
            const other = storeComponent.createObject(root, { directory: store.directory })
            verify(other.loaded)
            compare(other.count, 1)
            compare(other.values(s.id).n, 11)
            compare(other.script(s.id).name, "counter")
            other.destroy()
            // ... and so does this one after reload().
            store.setValue(s.id, "n", 42)
            verify(store.save())
            store.setValue(s.id, "n", 43)   // unsaved: dropped by reload
            store.reload()
            compare(store.values(s.id).n, 42)
            load(v, page("c5"), "c5")
            waitFor(v, attr("data-n"), "42:43:n|obj:2")

            store.clearValues(s.id)
            compare(store.values(s.id), {})
            load(v, page("c6"), "c6")
            waitFor(v, attr("data-n"), "0:1:n|obj:2", "cleared")
            const id = s.id
            store.remove(id)
            compare(store.values(id), {}, "values go with the script")
        }

        function test_gm_addStyle_and_info() {
            install(["name styler", "version 2.5", "namespace ns", "grant GM_addStyle", "run-at document-start"],
                    "GM_addStyle('#box { width: 123px; }');" +
                    "document.addEventListener('DOMContentLoaded', () => document.documentElement.setAttribute(" +
                    "'data-info', [GM_info.script.name, GM_info.script.version, GM_info.script.namespace," +
                    " GM_info.script.runAt, GM_info.scriptHandler, GM_info.injectInto].join('|')))")
            const v = newView(page("style", "<div id=box>box</div>"))
            tryCompare(v, "title", "style", 15000)
            waitFor(v, "getComputedStyle(document.getElementById('box')).width", "123px")
            waitFor(v, attr("data-info"), "styler|2.5|ns|document-start|CefQml|content")
        }

        function test_gm_openInTab_and_clipboard() {
            install(["name opener", "grant GM_openInTab", "grant GM.setClipboard"],
                    "GM_openInTab('data:text/html,opened', true); GM.openInTab('data:text/html,front');" +
                    " GM.setClipboard('from userscript')")
            const v = newView(page("opener"))
            const spy = Qt.createQmlObject("import QtTest; SignalSpy { signalName: 'newWindowRequested' }", v)
            spy.target = v
            tryCompare(v, "title", "opener", 15000)
            tryCompare(spy, "count", 2, 10000)
            compare(spy.signalArguments[0][0].toString(), "data:text/html,opened")
            compare(spy.signalArguments[0][2], true, "background")
            compare(spy.signalArguments[1][0].toString(), "data:text/html,front")
            compare(spy.signalArguments[1][2], false)
            tryVerify(() => { clipboardReader.text = ""; clipboardReader.paste()
                              return clipboardReader.text === "from userscript" }, 5000, "GM.setClipboard")
        }

        function test_gm_xmlhttpRequest_error() {
            install(["name xhr", "grant GM_xmlhttpRequest"],
                    "GM_xmlhttpRequest({ url: 'http://127.0.0.1:9/nothing'," +
                    " onerror: r => document.documentElement.setAttribute('data-xhr', 'error:' + r.status + ':' + r.readyState) });" +
                    "GM_xmlhttpRequest({ url: 'file:///etc/hostname'," +
                    " onload: () => document.documentElement.setAttribute('data-file', 'loaded')," +
                    " onerror: () => document.documentElement.setAttribute('data-file', 'refused') })")
            const v = newView(page("xhr"))
            tryCompare(v, "title", "xhr", 15000)
            waitFor(v, attr("data-xhr"), "error:0:4")
            waitFor(v, attr("data-file"), "refused", "only http(s)")
        }

        function test_require_and_install_from_url() {
            const lib = "data:text/javascript," + encodeURIComponent("window.libValue = function () { return 'from lib' }")
            const source = userscript(["name required", "grant none", "require " + lib],
                                      "document.documentElement.setAttribute('data-req', libValue())")
            let result = null
            store.installFromUrl("data:text/plain;charset=utf-8," + encodeURIComponent(source), r => result = r)
            tryVerify(() => result !== null, 5000)
            verify(result.ok, result.error)
            tryVerify(() => !store.script(result.script.id).pending, 5000, "@require fetched")
            compare(store.script(result.script.id).error, "")
            compare(store.script(result.script.id).requires[0].url, lib)
            const v = newView(page("req"))
            tryCompare(v, "title", "req", 15000)
            waitFor(v, attr("data-req"), "from lib")

            let bad = null
            store.installFromUrl("data:text/plain,not%20a%20userscript", r => bad = r)
            tryVerify(() => bad !== null, 5000)
            verify(!bad.ok)
        }

        function test_webtabs_integration() {
            install(["name tabs", "grant none"], "document.documentElement.setAttribute('data-tabs', location.href.length > 0)")
            const tabs = tabsComponent.createObject(root, { userScriptStore: store })
            const v = tabs.openTab(page("tab1"))
            verify(store.isAttached(v))
            tryCompare(v, "title", "tab1", 15000)
            waitFor(v, attr("data-tabs"), "true", "first page of a new tab")
            tabs.userScriptStore = null
            verify(!store.isAttached(v))
            load(v, page("tab2"), "tab2")
            compare(evaluate(v, attr("data-tabs")), null, "detached")
            tabs.destroy()
        }

        // --- UserScriptManager ----------------------------------------

        function test_manager_ui() {
            const a = install(["name Alpha", "version 2.0", "description first one", "match *://*/*",
                               "include data:*", "grant none"],
                              "document.documentElement.setAttribute('data-alpha', 'ran')")
            const b = install(["name Beta", "match https://nomatch.invalid/*", "grant GM_setValue"])
            store.setValue(b.id, "k", 1)
            const v = newView(page("mgr"))
            tryCompare(v, "title", "mgr", 15000)
            waitFor(v, attr("data-alpha"), "ran")
            manager = managerComponent.createObject(root, { store: store, view: v })

            // Rows, metadata and "running on this page".
            child(manager, "userScriptRow_" + a.id)
            child(manager, "userScriptRow_" + b.id)
            compare(findChild(manager, "userScriptList").count, 2)
            tryVerify(() => child(manager, "userScriptRunning_" + a.id).visible, 5000, "Alpha runs here")
            verify(!child(manager, "userScriptRunning_" + b.id).visible)
            compare(manager.runningIds, [a.id])
            verify(child(manager, "userScriptClearValues_" + b.id).visible, "Beta has a value")
            verify(!child(manager, "userScriptClearValues_" + a.id).visible)

            // Disable Alpha with its switch: later documents do not run it.
            mouseClick(child(manager, "userScriptToggle_" + a.id))
            tryVerify(() => !store.script(a.id).enabled, 2000)
            verify(!child(manager, "userScriptToggle_" + a.id).checked)
            load(v, page("mgr2"), "mgr2")
            compare(evaluate(v, attr("data-alpha")), null, "disabled")
            tryVerify(() => manager.runningIds.length === 0, 5000, "nothing runs now")
            verify(!child(manager, "userScriptRunning_" + a.id).visible)
            mouseClick(child(manager, "userScriptToggle_" + a.id))
            tryVerify(() => store.script(a.id).enabled, 2000)
            load(v, page("mgr3"), "mgr3")
            waitFor(v, attr("data-alpha"), "ran", "enabled again")
            tryVerify(() => child(manager, "userScriptRunning_" + a.id).visible, 5000)

            // Clear values.
            mouseClick(child(manager, "userScriptClearValues_" + b.id))
            compare(Object.keys(store.values(b.id)).length, 0)
            tryVerify(() => !child(manager, "userScriptClearValues_" + b.id).visible, 2000)

            // Edit Alpha's source in the editor and save.
            mouseClick(child(manager, "userScriptEdit_" + a.id))
            compare(manager.editing, a.id)
            const editor = child(manager, "userScriptEditor")
            verify(editor.visible)
            tryVerify(() => editor.activeFocus, 2000)
            compare(editor.text, store.script(a.id).source)
            editor.text = editor.text.replace("version 2.0", "version 2.1").replace("'ran'", "'edited'")
            verify(manager.editorModified)
            mouseClick(child(manager, "userScriptSave"))
            compare(manager.editing, "")
            compare(store.script(a.id).version, "2.1")
            verify(manager.status.indexOf("Updated Alpha 2.1") === 0, manager.status)
            load(v, page("mgr4"), "mgr4")
            waitFor(v, attr("data-alpha"), "edited")

            // A broken edit is refused and keeps the editor open.
            mouseClick(child(manager, "userScriptEdit_" + a.id))
            editor.text = "no header"
            mouseClick(child(manager, "userScriptSave"))
            compare(manager.editing, a.id)
            verify(manager.statusIsError)
            keyClick(Qt.Key_Escape)
            compare(manager.editing, a.id, "Escape keeps unsaved changes")
            mouseClick(child(manager, "userScriptCancel"))
            compare(manager.editing, "")
            compare(store.script(a.id).version, "2.1", "unchanged")

            // New script from the template (matches the current site).
            mouseClick(child(manager, "userScriptNew"))
            compare(manager.editing, "new")
            verify(editor.text.indexOf("@match       *://*/*") > 0, "data: page: generic match")
            keyClick(Qt.Key_End, Qt.ControlModifier)
            keyClick(Qt.Key_X)
            compare(editor.text.slice(-1), "x", "typing goes to the editor")
            editor.text = userscript(["name Gamma", "grant none"], "")
            keyClick(Qt.Key_S, Qt.ControlModifier)
            compare(manager.editing, "")
            compare(store.count, 3)
            compare(store.scripts[2].name, "Gamma")

            // Paste a script from the clipboard.
            Cef.copyToClipboard(userscript(["name Delta", "grant none"], ""))
            mouseClick(child(manager, "userScriptPaste"))
            compare(manager.editing, "new")
            tryVerify(() => editor.text.indexOf("Delta") > 0, 3000, "pasted")
            mouseClick(child(manager, "userScriptSave"))
            compare(store.count, 4)

            // Review and install from a URL.
            const urlInput = child(manager, "userScriptUrlInput")
            urlInput.text = "data:text/plain," + encodeURIComponent(userscript(["name Epsilon", "version 3"], ""))
            mouseClick(child(manager, "userScriptReviewUrl"))
            tryCompare(manager, "editing", "new", 5000)
            verify(manager.status.indexOf("Install Epsilon 3?") === 0, manager.status)
            compare(manager.editorUrl, urlInput.text)
            mouseClick(child(manager, "userScriptSave"))
            compare(store.count, 5)
            compare(store.scripts[4].url, urlInput.text)
            urlInput.text = "data:text/plain,nothing"
            mouseClick(child(manager, "userScriptReviewUrl"))
            tryVerify(() => manager.statusIsError, 5000)
            compare(manager.editing, "")

            // Remove asks for a second click.
            const remove = child(manager, "userScriptRemove_" + b.id)
            mouseClick(remove)
            compare(store.count, 5)
            compare(remove.text, "Remove?")
            mouseClick(remove)
            compare(store.count, 4)
            verify(!store.script(b.id))

            // Escape in the list asks to close.
            const spy = Qt.createQmlObject("import QtTest; SignalSpy { signalName: 'closeRequested' }", manager)
            spy.target = manager
            manager.forceActiveFocus()
            keyClick(Qt.Key_Escape)
            compare(spy.count, 1)
            mouseClick(child(manager, "userScriptClose"))
            compare(spy.count, 2)
        }
    }
}
