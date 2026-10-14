.pragma library

// Shared by AddressSuggestions and CommandPalette: calling providers,
// normalizing their items, glyphs, and fuzzy matching with highlighting.
//
// A provider is a function `(text, ctx) => items` or an object
// `{ suggest(text, ctx), remove(item), ... }`; `items` is an array or a
// Promise of one.

// Calls `provider`; returns its result (an array, a Promise or null).
// Exceptions are logged with `owner` ("AddressSuggestions") as prefix.
function call(provider, text, ctx, owner) {
    try {
        if (typeof provider === "function") return provider(text, ctx)
        if (provider && typeof provider.suggest === "function") return provider.suggest(text, ctx)
    } catch (e) {
        console.warn((owner || "Providers") + ": provider failed:", e)
    }
    return []
}

function isPromise(r) { return !!r && typeof r.then === "function" }

// The prefixes of a provider object (`prefix`: a string or a list).
function prefixesOf(provider) {
    if (!provider || typeof provider !== "object" || provider.prefix === undefined || provider.prefix === null) return []
    const list = Array.isArray(provider.prefix) ? provider.prefix : [provider.prefix]
    return list.map(String).filter(p => p !== "")
}

function display(url) {
    url = String(url)
    try { return decodeURIComponent(url) } catch (e) { return url }
}

// A plain copy of a provider item with every field present, or null when
// it can do nothing (no url, action or actionName).
function normalize(item, provider) {
    if (!item || typeof item !== "object") return null
    if (!item.url && typeof item.action !== "function" && !item.actionName) return null
    const removable = item.removable !== undefined ? !!item.removable
        : typeof item.remove === "function" || !!(provider && typeof provider.remove === "function")
    // Other fields (e.g. a provider's own bookkeeping) are kept.
    return Object.assign({}, item, {
        type: item.type || "custom",
        title: String(item.title || display(item.url || "") || item.actionName || ""),
        subtitle: item.subtitle ? String(item.subtitle) : "",
        url: item.url ? String(item.url) : "",
        icon: item.icon ? String(item.icon) : "",
        action: item.action,
        actionName: item.actionName ? String(item.actionName) : "",
        args: item.args,
        remove: item.remove,
        removable: removable,
        // CommandPalette fields.
        category: item.category ? String(item.category) : "",
        hint: item.hint ? String(item.hint) : "",
        label: item.label ? String(item.label) : "",
        keywords: item.keywords ? String(item.keywords) : "",
        enabled: item.enabled !== false,
        checked: !!item.checked,
        key: item.key ? String(item.key) : "",
        score: typeof item.score === "number" ? item.score : undefined,
        sticky: !!item.sticky,
        _completion: !!item._completion,
        _provider: provider
    })
}

function glyph(type) {
    switch (type) {
    case "search": return "⌕"
    case "history": return "◷"
    case "tab": return "⇥"
    case "closedTab": return "↺"
    case "bookmark": return "★"
    case "url": return "→"
    case "action": return "›"
    default: return "•"
    }
}

function escapeHtml(t) {
    return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// `text` as StyledText with the characters at `positions` (sorted or not)
// wrapped in openTag/closeTag (default <b>…</b>).
function highlight(text, positions, openTag, closeTag) {
    text = String(text)
    if (openTag === undefined) openTag = "<b>"
    if (closeTag === undefined) closeTag = "</b>"
    if (!positions || positions.length === 0) return escapeHtml(text)
    const marks = new Array(text.length).fill(false)
    for (const p of positions)
        if (p >= 0 && p < text.length) marks[p] = true
    let out = "", run = "", on = false
    for (let i = 0; i <= text.length; ++i) {
        const m = i < text.length ? marks[i] : !on
        if (m !== on || i === text.length) {
            if (run !== "") out += on ? openTag + escapeHtml(run) + closeTag : escapeHtml(run)
            run = ""
            on = m
        }
        if (i < text.length) run += text[i]
    }
    return out
}

// ---- matching ---------------------------------------------------------------

// Match tiers, best first.
const EXACT = 5, PREFIX = 4, WORD_START = 3, SUBSTRING = 2, FUZZY = 1

// Fuzzy matching only looks at the start of long texts.
const FUZZY_MAX = 256

function _isDigit(c) { return c >= "0" && c <= "9" }
function _isLetter(c) { return c.toLowerCase() !== c.toUpperCase() }
function _isAlnum(c) { return _isDigit(c) || _isLetter(c) }
function _isUpper(c) { return _isLetter(c) && c === c.toUpperCase() && c !== c.toLowerCase() }
function _isLower(c) { return _isLetter(c) && c === c.toLowerCase() && c !== c.toUpperCase() }

// Lower case with the same length (and indices) as `s`.
function _lower(s) {
    let out = ""
    for (let i = 0; i < s.length; ++i) {
        const l = s[i].toLowerCase()
        out += l.length === 1 ? l : s[i]
    }
    return out
}

// Index 0, after a separator, or a camelCase hump.
function isWordStart(s, i) {
    if (i <= 0) return true
    const c = s[i], p = s[i - 1]
    if (!_isAlnum(c)) return false
    if (!_isAlnum(p)) return true
    return _isLower(p) && _isUpper(c)
}

function words(text) {
    return String(text).trim().split(/\s+/).filter(w => w !== "")
}

function _range(from, n) {
    const r = []
    for (let i = 0; i < n; ++i) r.push(from + i)
    return r
}

// Best subsequence match of q (lower case) in t: maximizes word-start and
// consecutive characters. { score, positions } or null.
function _fuzzy(q, t, tl) {
    const n = Math.min(t.length, FUZZY_MAX), m = q.length
    if (m === 0 || m > n) return null
    let k = 0
    for (let j = 0; j < n && k < m; ++j) if (tl[j] === q[k]) ++k
    if (k < m) return null
    const NEG = -1e9
    const back = []
    let prev = null
    for (let i = 0; i < m; ++i) {
        const cur = new Array(n).fill(NEG)
        const bp = new Array(n).fill(-1)
        let best = NEG, bestAt = -1   // max of prev[0 .. j-2]
        for (let j = i; j < n; ++j) {
            if (i > 0 && j >= 2 && prev[j - 2] > best) { best = prev[j - 2]; bestAt = j - 2 }
            if (tl[j] !== q[i]) continue
            const bonus = 1 + (isWordStart(t, j) ? 3 : 0)
            if (i === 0) { cur[j] = bonus - j * 0.001; continue }
            const gap = best > NEG ? best + bonus : NEG
            const run = j >= 1 && prev[j - 1] > NEG ? prev[j - 1] + bonus + 2 : NEG
            if (run >= gap && run > NEG) { cur[j] = run; bp[j] = j - 1 }
            else if (gap > NEG) { cur[j] = gap; bp[j] = bestAt }
        }
        back.push(bp)
        prev = cur
    }
    let end = -1, score = NEG
    for (let j = 0; j < n; ++j) if (prev[j] > score) { score = prev[j]; end = j }
    if (end < 0) return null
    const positions = new Array(m)
    for (let i = m - 1, j = end; i >= 0; --i) {
        positions[i] = j
        j = back[i][j]
    }
    return { score: score, positions: positions }
}

// One word (lower case) against t.
function _matchWord(w, t, tl, allowFuzzy) {
    const n = t.length
    if (w === "" || n === 0) return null
    if (tl === w) return { tier: EXACT, quality: 1, positions: _range(0, n) }
    if (tl.startsWith(w)) return { tier: PREFIX, quality: w.length / n, positions: _range(0, w.length) }
    let first = -1
    for (let i = tl.indexOf(w); i >= 0; i = tl.indexOf(w, i + 1)) {
        if (first < 0) first = i
        if (isWordStart(t, i))
            return { tier: WORD_START, quality: 0.5 * w.length / n + 0.5 * (1 - i / n), positions: _range(i, w.length) }
    }
    if (first >= 0)
        return { tier: SUBSTRING, quality: 0.5 * w.length / n + 0.5 * (1 - first / n), positions: _range(first, w.length) }
    if (!allowFuzzy) return null
    const f = _fuzzy(w, t, tl)
    if (!f) return null
    const quality = Math.max(0, Math.min(1, f.score / (w.length * 6)))
    // Every character on a word start: an acronym ("nt" for "New tab").
    if (w.length > 1 && f.positions.every(p => isWordStart(t, p)))
        return { tier: WORD_START, quality: quality * 0.3, positions: f.positions }
    return { tier: FUZZY, quality: quality, positions: f.positions }
}

// Matches `query` against `text`: { tier, quality (0..1), positions } or
// null. Tiers: 5 exact, 4 prefix, 3 word start (or an acronym), 2
// substring, 1 fuzzy (characters in order, only with allowFuzzy). A query
// of several words that is not found as a whole matches when every word
// does; its tier is the worst word's, at most 3. Case-insensitive.
function match(query, text, allowFuzzy) {
    const q = _lower(String(query).trim())
    text = String(text === undefined || text === null ? "" : text)
    if (q === "") return { tier: 0, quality: 0, positions: [] }
    if (text === "") return null
    const tl = _lower(text)
    const whole = _matchWord(q, text, tl, false)
    if (whole) return whole
    const ws = words(q)
    if (ws.length === 1) return _matchWord(q, text, tl, allowFuzzy !== false)
    let tier = WORD_START, quality = 0
    const positions = []
    for (const w of ws) {
        const m = _matchWord(w, text, tl, allowFuzzy !== false)
        if (!m) return null
        tier = Math.min(tier, m.tier)
        quality += m.quality / ws.length
        for (const p of m.positions) if (positions.indexOf(p) < 0) positions.push(p)
    }
    positions.sort((a, b) => a - b)
    return { tier: tier, quality: quality, positions: positions }
}

// Matches `query` against an item: fuzzily against `title` (positions are
// the title's), else exactly (no fuzzy) against any of `extras` (subtitle,
// keywords...) one tier lower, else word by word across all of them (at
// most tier 2).
function matchItem(query, title, extras) {
    const t = match(query, title, true)
    if (t) return t
    extras = (extras || []).filter(e => e)
    let best = null
    for (const e of extras) {
        const m = match(query, e, false)
        if (m && (!best || m.tier > best.tier || (m.tier === best.tier && m.quality > best.quality))) best = m
    }
    if (best) return { tier: Math.max(FUZZY, best.tier - 1), quality: best.quality * 0.5, positions: [] }
    const ws = words(query)
    if (ws.length < 2) return null
    let tier = SUBSTRING, quality = 0
    const positions = []
    for (const w of ws) {
        let m = match(w, title, true)
        if (m) {
            for (const p of m.positions) if (positions.indexOf(p) < 0) positions.push(p)
        } else {
            for (const e of extras) {
                const x = match(w, e, false)
                if (x && (!m || x.tier > m.tier)) m = { tier: Math.max(FUZZY, x.tier - 1), quality: x.quality * 0.5 }
            }
            if (!m) return null
        }
        tier = Math.min(tier, m.tier)
        quality += m.quality / ws.length
    }
    positions.sort((a, b) => a - b)
    return { tier: tier, quality: quality, positions: positions }
}
