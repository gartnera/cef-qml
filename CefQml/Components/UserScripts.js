.pragma library

// Userscript engine helpers shared by UserScriptStore (host side): metadata
// parsing, URL rule compilation and the JavaScript injected into pages.
//
// Injection model (see README "Userscripts"): each view registers, through
// the DevTools protocol, one Page.addScriptToEvaluateOnNewDocument entry per
// enabled script and per world, followed by one "runtime" entry per world.
// Entries run in registration order at the start of every document (main
// frame and same-process subframes). A script entry only pushes its wrapped
// code onto a hidden queue; the runtime entry, which runs last, takes the
// queue, removes the hidden globals (queue and DevTools binding) before any
// page script can see them, decides which scripts match location.href and
// runs them at their @run-at time with their GM API.

var GRANTS = ["GM_info", "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues",
              "GM_addStyle", "GM_log", "GM_openInTab", "GM_setClipboard",
              "GM_xmlhttpRequest", "unsafeWindow"]
// GM.* (Greasemonkey 4 promise API) name -> GM_* grant.
var GM4 = { info: "GM_info", getValue: "GM_getValue", setValue: "GM_setValue",
            deleteValue: "GM_deleteValue", listValues: "GM_listValues", addStyle: "GM_addStyle",
            log: "GM_log", openInTab: "GM_openInTab", setClipboard: "GM_setClipboard",
            xmlHttpRequest: "GM_xmlhttpRequest" }
// Available whatever @grant says.
var ALWAYS = ["GM_info", "GM_log"]
var RUN_AT = ["document-start", "document-body", "document-end", "document-idle"]
var MULTI = { match: "match", include: "include", exclude: "exclude",
              "exclude-match": "excludeMatch", grant: "grant", require: "require",
              resource: "resource", connect: "connect" }
var SINGLE = { name: "name", namespace: "namespace", version: "version",
               description: "description", author: "author", icon: "icon", iconURL: "icon",
               defaulticon: "icon", homepage: "homepage", homepageURL: "homepage",
               website: "homepage", source: "homepage", downloadURL: "downloadURL",
               updateURL: "updateURL", supportURL: "supportURL", license: "license" }
// Schemes userscripts run on at all (never about:, chrome:, devtools:, ...).
var SCHEMES = /^(https?|file|ftp|data):/i

function _esc(s) { return s.replace(/[.+?^${}()|[\]\\\/]/g, "\\$&") }

// Parses the "// ==UserScript==" block. Returns null without one. Unknown
// keys are kept in `other`; problems are listed in `warnings`.
function parseMetadata(source) {
    var m = /^[ \t]*\/\/[ \t]*==UserScript==[ \t]*\r?$([\s\S]*?)^[ \t]*\/\/[ \t]*==\/UserScript==/m
            .exec(String(source))
    if (!m) return null
    var meta = { name: "", namespace: "", version: "", description: "", author: "", icon: "",
                 homepage: "", downloadURL: "", updateURL: "", supportURL: "", license: "",
                 runAt: "document-end", injectInto: "auto", noframes: false,
                 match: [], include: [], exclude: [], excludeMatch: [], grant: [],
                 require: [], resource: [], connect: [], other: {}, warnings: [],
                 metaStr: m[0] }
    var lines = m[1].split(/\r?\n/)
    for (var i = 0; i < lines.length; ++i) {
        var lm = /^\s*\/\/\s*@([\w.:-]+)(?:\s+(.*?))?\s*$/.exec(lines[i])
        if (!lm) continue
        var key = lm[1], value = lm[2] || ""
        if (MULTI[key]) {
            if (value) meta[MULTI[key]].push(value)
        } else if (SINGLE[key]) {
            if (!meta[SINGLE[key]]) meta[SINGLE[key]] = value
        } else if (key === "run-at") {
            if (RUN_AT.indexOf(value) >= 0) meta.runAt = value
            else meta.warnings.push("unsupported @run-at " + value + " (using document-end)")
        } else if (key === "inject-into") {
            if (["auto", "page", "content"].indexOf(value) >= 0) meta.injectInto = value
            else meta.warnings.push("unsupported @inject-into " + value)
        } else if (key === "noframes") {
            meta.noframes = true
        } else if (key.indexOf(":") > 0 && SINGLE[key.split(":")[0]]) {
            // Localized variant (@name:de): kept, not used.
            meta.other[key] = value
        } else {
            (meta.other[key] = meta.other[key] || []).push(value)
        }
    }
    for (var j = 0; j < meta.match.length; ++j)
        if (!compileMatch(meta.match[j])) meta.warnings.push("invalid @match " + meta.match[j])
    for (var k = 0; k < meta.excludeMatch.length; ++k)
        if (!compileMatch(meta.excludeMatch[k]))
            meta.warnings.push("invalid @exclude-match " + meta.excludeMatch[k])
    if (meta.resource.length) meta.warnings.push("@resource is not supported")
    for (var g = 0; g < meta.grant.length; ++g) {
        var n = normalizeGrant(meta.grant[g])
        if (n === null && meta.grant[g] !== "none")
            meta.warnings.push("unsupported @grant " + meta.grant[g])
    }
    return meta
}

// "GM.getValue" -> "GM_getValue"; unknown -> null.
function normalizeGrant(name) {
    if (GRANTS.indexOf(name) >= 0) return name
    if (name.indexOf("GM.") === 0 && GM4[name.slice(3)]) return GM4[name.slice(3)]
    return null
}

// The GM_* names a script may use. `@grant none` grants nothing; without any
// @grant, the APIs the source mentions are granted (as Tampermonkey does).
function effectiveGrants(meta, source) {
    var out = ALWAYS.slice()
    var add = function (n) { if (n && out.indexOf(n) < 0) out.push(n) }
    if (meta.grant.length === 0) {
        var src = String(source)
        for (var i = 0; i < GRANTS.length; ++i)
            if (src.indexOf(GRANTS[i]) >= 0) add(GRANTS[i])
        for (var k in GM4)
            if (src.indexOf("GM." + k) >= 0) add(GM4[k])
    } else {
        for (var j = 0; j < meta.grant.length; ++j) add(normalizeGrant(meta.grant[j]))
    }
    return out
}

// "page" (the page's own JavaScript world) or "content" (an isolated world
// sharing only the DOM). auto: scripts that need no privileged API, or ask
// for unsafeWindow, run in the page; others are isolated so the page cannot
// reach their storage or GM_xmlhttpRequest.
function worldFor(meta, grants) {
    if (meta.injectInto === "page" || meta.injectInto === "content") return meta.injectInto
    if (grants.indexOf("unsafeWindow") >= 0) return "page"
    for (var i = 0; i < grants.length; ++i)
        if (ALWAYS.indexOf(grants[i]) < 0) return "content"
    return "page"
}

// Chrome match pattern -> [regexSource, flags], or null if invalid.
function compileMatch(pattern) {
    if (pattern === "<all_urls>") return ["^(?:https?|wss?|ftp|file|data|urn):", ""]
    var m = /^(\*|https?|http\*|wss?|ftp|file|urn|data):\/\/(\*|\*\.[^\/*]+|[^\/*]*)(\/.*)$/
            .exec(pattern)
    if (!m) return null
    var scheme = m[1] === "*" || m[1] === "http*" ? "https?" : m[1]
    var host = m[2]
    if (m[1] === "file") host = host === "" || host === "*" || host === "localhost" ? "" : null
    else if (host === "") return null
    if (host === null) return null
    var hostRe = host === "*" ? "[^/]*"
               : host.indexOf("*.") === 0 ? "(?:[^/]*\\.)?" + _esc(host.slice(2))
               : _esc(host)
    // Without an explicit port, any port matches (as in Chrome).
    if (host !== "*" && host !== "" && host.indexOf(":") < 0) hostRe += "(?::\\d+)?"
    var path = _esc(m[3]).replace(/\*/g, ".*")
    return ["^" + scheme + ":\\/\\/" + hostRe + path + "(?:#.*)?$", "i"]
}

// @include/@exclude: a glob ("*" = anything) or a /regular expression/.
function compileGlob(glob) {
    var r = /^\/(.*)\/([a-z]*)$/.exec(glob)
    if (r) {
        try { new RegExp(r[1], r[2]); return [r[1], r[2].replace(/[gy]/g, "")] } catch (e) { return null }
    }
    return ["^" + _esc(glob).replace(/\*/g, ".*") + "$", "i"]
}

// { include: [[src, flags]], exclude: [[src, flags]] }. An empty include
// list (no @match and no @include) matches every URL.
function compileRules(meta) {
    var inc = [], exc = []
    var push = function (list, r) { if (r) list.push(r) }
    meta.match.forEach(function (p) { push(inc, compileMatch(p)) })
    meta.include.forEach(function (p) { push(inc, compileGlob(p)) })
    meta.exclude.forEach(function (p) { push(exc, compileGlob(p)) })
    meta.excludeMatch.forEach(function (p) { push(exc, compileMatch(p)) })
    var any = meta.match.length + meta.include.length > 0
    // Rules were given but none compiled: match nothing rather than everything.
    if (any && inc.length === 0) inc.push(["(?!)", ""])
    return { include: inc, exclude: exc }
}

function _test(rules, url) {
    for (var i = 0; i < rules.length; ++i)
        if (new RegExp(rules[i][0], rules[i][1]).test(url)) return true
    return false
}

// Whether a script with these compiled rules runs on `url` (top frame).
function rulesMatch(rules, url) {
    url = String(url)
    if (!SCHEMES.test(url)) return false
    if (rules.include.length && !_test(rules.include, url)) return false
    return !_test(rules.exclude, url)
}

// Short human-readable summary of where a script runs.
function matchSummary(meta) {
    var list = meta.match.concat(meta.include)
    if (list.length === 0) return "all pages"
    return list.length > 2 ? list.slice(0, 2).join(", ") + " +" + (list.length - 2) : list.join(", ")
}

// Wrapper parameters, in order; non-granted APIs are passed as undefined.
var PARAMS = ["GM_info", "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues",
              "GM_addStyle", "GM_log", "GM_openInTab", "GM_setClipboard", "GM_xmlhttpRequest",
              "unsafeWindow", "GM"]

// The new-document entry of one script: pushes [id, wrapper] onto the
// hidden queue. A syntax error only loses this script.
function entrySource(queueName, id, code) {
    return "(function(){var g=globalThis,n=" + JSON.stringify(queueName) + ";" +
           "if(!Object.prototype.hasOwnProperty.call(g,n))" +
           "Object.defineProperty(g,n,{value:[],configurable:true,writable:true});" +
           "g[n].push([" + JSON.stringify(id) + ",function(" + PARAMS.join(",") + "){" +
           code + "\n}]);})();"
}

// `config`: { queue, binding, bindings: [names to remove], respond, world,
//             handler, scripts: [{ id, name, runAt, noframes, rules, grants,
//             info, values }] }
function runtimeSource(config) {
    return RUNTIME.replace("__CONFIG__", function () { return JSON.stringify(config) })
}

// Runs at the start of each document, after the scripts' entries. Plain
// ES5 strings only (no template literals: this file is QML-side JS).
var RUNTIME = [
"(function () {",
"'use strict';",
"var C = __CONFIG__;",
"var g = globalThis, W = window, D = document;",
"var B = g[C.binding];",
"for (var i = 0; i < C.bindings.length; ++i) { try { delete g[C.bindings[i]]; } catch (e) {} }",
"var hasQ = Object.prototype.hasOwnProperty.call(g, C.queue), Q = hasQ ? g[C.queue] : [];",
"try { delete g[C.queue]; } catch (e) {}",
// No queue although scripts are configured: an older runtime of this view
// already ran in this document (the configuration was being replaced).
"if (!hasQ && C.scripts.length) return;",
// Keep our own references: page scripts may replace these later.
"var stringify = JSON.stringify, parse = JSON.parse, keys = Object.keys, own = Object.prototype.hasOwnProperty;",
"var log = console.log.bind(console), error = console.error.bind(console);",
"var setT = W.setTimeout.bind(W), MO = W.MutationObserver, URL_ = W.URL;",
"function send(m) { if (B) { try { B(stringify(m)); } catch (e) {} } }",
"var href = location.href, top = false;",
"try { top = W.top === W; } catch (e) {}",
"if (!/^(https?|file|ftp|data):/i.test(href)) return;",
"function test(rules, url) { for (var i = 0; i < rules.length; ++i) if (new RegExp(rules[i][0], rules[i][1]).test(url)) return true; return false; }",
"var fns = {};",
"for (var q = 0; q < Q.length; ++q) fns[Q[q][0]] = Q[q][1];",
"var run = [];",
"C.scripts.forEach(function (s) {",
"  if (s.noframes && !top) return;",
"  if (s.rules.include.length && !test(s.rules.include, href)) return;",
"  if (test(s.rules.exclude, href)) return;",
"  if (!fns[s.id]) { error('[userscript ' + s.name + '] not loaded (syntax error?)'); return; }",
"  run.push(s);",
"});",
"if (top) send({ t: 'doc', ids: run.map(function (s) { return s.id; }) });",
"if (!run.length) return;",
"var pending = {}, seq = 0;",
"if (C.respond) Object.defineProperty(g, C.respond, { configurable: false, value: function (rid, res) {",
"  var r = pending[rid]; if (!r) return; if (res.readyState === 4) delete pending[rid]; r(res);",
"} });",
"function clone(v) { var j = stringify(v); return j === undefined ? undefined : parse(j); }",
"function whenRoot(cb) {",
"  if (D.documentElement) return cb();",
"  var mo = new MO(function () { if (D.documentElement) { mo.disconnect(); cb(); } });",
"  mo.observe(D, { childList: true });",
"}",
"function api(s) {",
"  var has = function (n) { return s.grants.indexOf(n) >= 0; };",
"  var cache = s.values || {}, a = {};",
"  var info = { script: s.info, scriptMetaStr: s.info.metaStr, scriptHandler: 'CefQml', version: '1.0',",
"               injectInto: C.world, isIncognito: false };",
"  a.GM_info = info;",
"  a.GM_log = function () { log.apply(null, ['[' + s.name + ']'].concat([].slice.call(arguments))); };",
"  a.GM_getValue = function (k, d) { k = String(k); return own.call(cache, k) ? clone(cache[k]) : d; };",
"  a.GM_deleteValue = function (k) { k = String(k); if (own.call(cache, k)) { delete cache[k]; send({ t: 'del', id: s.id, key: k }); } };",
"  a.GM_setValue = function (k, v) {",
"    if (v === undefined) return a.GM_deleteValue(k);",
"    k = String(k); v = clone(v); if (v === undefined) return a.GM_deleteValue(k);",
"    cache[k] = v; send({ t: 'set', id: s.id, key: k, value: v });",
"  };",
"  a.GM_listValues = function () { return keys(cache); };",
"  a.GM_addStyle = function (css) {",
"    var el = D.createElement('style'); el.textContent = String(css);",
"    whenRoot(function () { (D.head || D.documentElement).appendChild(el); });",
"    return el;",
"  };",
"  a.GM_openInTab = function (url, opt) {",
"    var bg = typeof opt === 'boolean' ? opt : !!(opt && (opt.active === false || opt.loadInBackground));",
"    send({ t: 'open', id: s.id, url: new URL_(String(url), href).href, background: bg });",
"    return { closed: false, close: function () {} };",
"  };",
"  a.GM_setClipboard = function (data) { send({ t: 'clip', id: s.id, text: String(data) }); };",
"  if (C.respond) a.GM_xmlhttpRequest = function (d) {",
"    d = d || {}; var rid = ++seq;",
"    pending[rid] = function (res) {",
"      if (res.responseType === 'json' || d.responseType === 'json') { try { res.response = parse(res.responseText); } catch (e) { res.response = null; } }",
"      else res.response = res.responseText;",
"      res.context = d.context;",
"      var call = function (n) { if (typeof d[n] === 'function') { try { d[n].call(res, res); } catch (e) { error('[' + s.name + ']', e); } } };",
"      call('onreadystatechange');",
"      if (res.readyState !== 4) return;",
"      if (res.error === 'timeout') call('ontimeout'); else if (res.error === 'abort') call('onabort');",
"      else if (res.error) call('onerror'); else call('onload');",
"      call('onloadend');",
"    };",
"    send({ t: 'xhr', id: s.id, rid: rid, method: String(d.method || 'GET'), url: new URL_(String(d.url), href).href,",
"           headers: d.headers || {}, data: d.data == null ? null : String(d.data), timeout: +d.timeout || 0,",
"           user: d.user || '', password: d.password || '' });",
"    return { abort: function () { if (pending[rid]) send({ t: 'abort', id: s.id, rid: rid }); } };",
"  };",
"  var gm = { info: info };",
"  var p = function (f) { return function () { var args = arguments; return new Promise(function (ok, fail) { try { ok(f.apply(null, args)); } catch (e) { fail(e); } }); }; };",
"  var out = { GM_info: info, GM_log: a.GM_log, GM: gm };",
"  ['GM_getValue', 'GM_setValue', 'GM_deleteValue', 'GM_listValues', 'GM_addStyle', 'GM_openInTab', 'GM_setClipboard', 'GM_xmlhttpRequest'].forEach(function (n) {",
"    if (has(n) && a[n]) out[n] = a[n];",
"  });",
"  if (out.GM_getValue) gm.getValue = p(a.GM_getValue);",
"  if (out.GM_setValue) gm.setValue = p(a.GM_setValue);",
"  if (out.GM_deleteValue) gm.deleteValue = p(a.GM_deleteValue);",
"  if (out.GM_listValues) gm.listValues = p(a.GM_listValues);",
"  if (out.GM_addStyle) gm.addStyle = p(a.GM_addStyle);",
"  if (out.GM_openInTab) gm.openInTab = p(a.GM_openInTab);",
"  if (out.GM_setClipboard) gm.setClipboard = p(a.GM_setClipboard);",
"  if (out.GM_xmlhttpRequest) gm.xmlHttpRequest = function (d) { d = d || {}; return new Promise(function (ok, fail) {",
"    var o = {}; for (var k in d) o[k] = d[k];",
"    o.onload = function (r) { if (d.onload) d.onload(r); ok(r); };",
"    o.onerror = o.ontimeout = o.onabort = function (r) { var f = d['on' + (r.error === 'timeout' ? 'timeout' : r.error === 'abort' ? 'abort' : 'error')]; if (f) f(r); fail(r); };",
"    a.GM_xmlhttpRequest(o); }); };",
"  gm.log = a.GM_log;",
"  out.unsafeWindow = W;",
"  return out;",
"}",
"function exec(s) {",
"  var a = api(s);",
"  try {",
"    fns[s.id].call(W, a.GM_info, a.GM_getValue, a.GM_setValue, a.GM_deleteValue, a.GM_listValues,",
"                   a.GM_addStyle, a.GM_log, a.GM_openInTab, a.GM_setClipboard, a.GM_xmlhttpRequest,",
"                   a.unsafeWindow, a.GM);",
"  } catch (e) { error('[userscript ' + s.name + ']', e); }",
"}",
"function at(when) { run.forEach(function (s) { if (s.runAt === when) exec(s); }); }",
"at('document-start');",
"var body = false, end = false;",
"function onBody() { if (body) return; body = true; at('document-body'); }",
"function onReady() {",
"  if (end) return; end = true; onBody(); at('document-end');",
"  setT(function () { at('document-idle'); }, 0);",
"}",
"if (D.readyState !== 'loading') { onReady(); return; }",
"if (D.body) onBody(); else {",
"  var bo = new MO(function () { if (D.body) { bo.disconnect(); onBody(); } });",
"  bo.observe(D, { childList: true, subtree: true });",
"  D.addEventListener('DOMContentLoaded', function () { bo.disconnect(); }, true);",
"}",
"D.addEventListener('DOMContentLoaded', onReady, true);",
"})();"
].join("\n")
