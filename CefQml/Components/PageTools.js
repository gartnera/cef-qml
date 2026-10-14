.pragma library

// Keyboard page navigation in the page: collecting link hint targets,
// focusing text fields, scrolling. Used by LinkHints and BrowserController.
//
// The page-side code runs in an isolated world (Page.createIsolatedWorld):
// it shares the DOM with the page but not its JavaScript globals, so pages
// can neither see the hint state nor break it by patching built-ins, and the
// page's own globals are untouched. Same-origin iframes are reachable from
// there too. If no isolated world can be created, the main world is used.

// ---- the in-page library -----------------------------------------------------

// Defines globalThis.__cefqmlTools (once per world and document). All
// coordinates it returns are CSS pixels of the top-level layout viewport.
const PAGE_LIB = String.raw`(() => {
const VERSION = 1;
if (globalThis.__cefqmlTools && globalThis.__cefqmlTools.version === VERSION) return;
const T = { version: VERSION, els: [] };

const NON_TEXT = new Set(['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio',
                          'range', 'reset', 'submit']);
const CLICK_ROLES = new Set(['button', 'link', 'tab', 'checkbox', 'menuitem', 'menuitemcheckbox',
                             'menuitemradio', 'option', 'radio', 'switch', 'treeitem', 'combobox',
                             'textbox', 'searchbox', 'slider', 'spinbutton', 'gridcell']);

const textInput = el => {
  if (el.disabled || el.readOnly) return false;
  if (el.localName === 'input') return !NON_TEXT.has(el.type);
  if (el.localName === 'textarea') return true;
  if (el.isContentEditable) return !el.parentElement || !el.parentElement.isContentEditable;
  const role = (el.getAttribute('role') || '').toLowerCase();
  return role === 'textbox' || role === 'searchbox';
};
const linkHref = el => {
  if ((el.localName !== 'a' && el.localName !== 'area') || !el.hasAttribute('href')) return '';
  const h = el.href;
  return typeof h === 'string' && !/^javascript:/i.test(h) ? h : '';
};

// What an element is for the given set of elements, or '' to skip it.
function kindOf(el, what) {
  if (what === 'links') return linkHref(el) ? 'link' : '';
  if (what === 'inputs') return textInput(el) ? 'input' : '';
  if (linkHref(el)) return 'link';
  const t = el.localName;
  switch (t) {
    case 'input':
      if (el.type === 'hidden' || el.disabled) return '';
      return textInput(el) ? 'input' : 'button';
    case 'textarea': return el.disabled ? '' : 'input';
    case 'select': return el.disabled ? '' : 'select';
    case 'button': return el.disabled ? '' : 'button';
    case 'summary': return 'button';
    case 'a': return el.hasAttribute('tabindex') ? 'link' : '';
    case 'label': return what === 'clickable' && el.control && !el.control.disabled ? 'label' : '';
  }
  if (el.isContentEditable) return el.parentElement && el.parentElement.isContentEditable ? '' : 'input';
  const tabbable = el.hasAttribute('tabindex') && el.tabIndex >= 0;
  if (what === 'focusable') return tabbable ? 'element' : '';
  const role = (el.getAttribute('role') || '').toLowerCase();
  if (role && CLICK_ROLES.has(role))
    return el.getAttribute('aria-disabled') === 'true' ? '' : (role === 'textbox' || role === 'searchbox' ? 'input' : 'button');
  if (el.hasAttribute('onclick') || tabbable) return 'button';
  return '';
}

// Every element of a document or shadow root, shadow trees included.
function* walk(root) {
  for (const el of root.querySelectorAll('*')) {
    yield el;
    if (el.shadowRoot) yield* walk(el.shadowRoot);
  }
}

// The part of el's box inside clip (frame-local viewport coordinates), or
// null. Zero-sized wrappers (e.g. a link around a floated image) use their
// children's boxes.
function visibleRect(el, clip) {
  const fit = r => {
    const l = Math.max(r.left, clip.l), t = Math.max(r.top, clip.t);
    const rr = Math.min(r.right, clip.r), b = Math.min(r.bottom, clip.b);
    return rr - l >= 2 && b - t >= 2 ? { l, t, r: rr, b } : null;
  };
  for (const r of el.getClientRects()) {
    const f = fit(r);
    if (f) return f;
  }
  for (const c of el.children) {
    const r = c.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) {
      const f = fit(r);
      if (f) return f;
    }
  }
  return null;
}

const styleVisible = el => {
  if (typeof el.checkVisibility === 'function')
    return el.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true });
  const s = getComputedStyle(el);
  return s.visibility === 'visible' && s.display !== 'none';
};

// Is hit el or inside it (across shadow roots)?
const within = (hit, el) => {
  for (let n = hit; n; n = n.parentNode || n.host) if (n === el) return true;
  return false;
};

// A point of rect r (frame-local) where el is on top, or null. chain
// lists the enclosing frames, which must be on top at that point too.
function hitPoint(el, r, chain) {
  const doc = el.ownerDocument;
  const cx = (r.l + r.r) / 2, cy = (r.t + r.b) / 2;
  const pts = [[cx, cy], [r.l + 2, r.t + 2], [r.r - 2, r.t + 2], [r.l + 2, r.b - 2], [r.r - 2, r.b - 2],
               [cx, r.t + 2], [cx, r.b - 2], [r.l + 2, cy], [r.r - 2, cy]];
  for (const [x, y] of pts) {
    let root = el.getRootNode();
    let hit = root.elementFromPoint ? root.elementFromPoint(x, y) : doc.elementFromPoint(x, y);
    if (!hit || !within(hit, el)) continue;
    if (!framesOnTop(chain, x, y)) continue;
    return { x, y };
  }
  return null;
}

function framesOnTop(chain, x, y) {
  // chain: innermost first; x/y are local to the innermost frame.
  for (const f of chain) {
    x += f.dx; y += f.dy;
    const hit = f.frame.ownerDocument.elementFromPoint(x, y);
    if (hit !== f.frame) return false;
  }
  return true;
}

// The documents to search: the top document and same-origin frames (with
// their offsets and clip rectangles in their own coordinates).
function* documents(doc, ox, oy, clip, chain) {
  yield { doc, ox, oy, clip, chain };
  for (const f of walk(doc)) {
    if (f.localName !== 'iframe' && f.localName !== 'frame') continue;
    let child = null;
    try { child = f.contentDocument; } catch (e) {}
    if (!child || !child.documentElement) continue;
    const r = f.getBoundingClientRect();
    const s = getComputedStyle(f);
    const dx = r.left + f.clientLeft + parseFloat(s.paddingLeft || 0);
    const dy = r.top + f.clientTop + parseFloat(s.paddingTop || 0);
    const w = f.clientWidth - parseFloat(s.paddingLeft || 0) - parseFloat(s.paddingRight || 0);
    const h = f.clientHeight - parseFloat(s.paddingTop || 0) - parseFloat(s.paddingBottom || 0);
    const c = { l: Math.max(clip.l, dx) - dx, t: Math.max(clip.t, dy) - dy,
                r: Math.min(clip.r, dx + w) - dx, b: Math.min(clip.b, dy + h) - dy };
    if (c.r - c.l < 2 || c.b - c.t < 2) continue;
    yield* documents(child, ox + dx, oy + dy, c, [{ frame: f, dx, dy }].concat(chain));
  }
}

const textOf = el => {
  let t = '';
  if (el.localName === 'input' || el.localName === 'textarea' || el.localName === 'select')
    t = (el.labels && el.labels[0] && el.labels[0].innerText) || el.placeholder || el.value || '';
  if (!t) t = el.innerText || '';
  if (!t.trim()) {
    const img = el.querySelector && el.querySelector('img[alt]');
    t = el.getAttribute('aria-label') || (img && img.alt) || el.getAttribute('title') || el.getAttribute('alt') || '';
  }
  return t.replace(/\s+/g, ' ').trim().slice(0, 200);
};

function viewport() {
  const vv = visualViewport;
  return { l: 0, t: 0, r: innerWidth, b: innerHeight,
           scale: vv ? vv.scale : 1, ox: vv ? vv.offsetLeft : 0, oy: vv ? vv.offsetTop : 0 };
}

// Visible hint targets. opts: { elements: 'clickable' | 'links' |
// 'focusable' | 'inputs', selector, pointer (cursor: pointer heuristic) }.
T.collect = function (opts) {
  opts = opts || {};
  const what = opts.elements || 'clickable';
  const vp = viewport();
  const out = [], els = [], frames = [];
  const accepted = new Map();  // element -> hint
  for (const d of documents(document, 0, 0, { l: 0, t: 0, r: innerWidth, b: innerHeight }, [])) {
    const candidates = opts.selector ? Array.from(d.doc.querySelectorAll(opts.selector)) : walk(d.doc);
    for (const el of candidates) {
      let kind = opts.selector ? (linkHref(el) ? 'link' : 'element') : kindOf(el, what);
      const heuristic = !kind && what === 'clickable' && opts.pointer !== false;
      if (!kind && !heuristic) continue;
      const r = visibleRect(el, d.clip);
      if (!r) continue;
      // Inside an accepted clickable ancestor: skip unless it is a control of its own.
      let ancestor = null;
      for (let p = el.parentElement || (el.parentNode && el.parentNode.host); p;
           p = p.parentElement || (p.parentNode && p.parentNode.host)) {
        if (accepted.has(p)) { ancestor = accepted.get(p); break; }
      }
      if (heuristic) {
        if (ancestor) continue;
        const cursor = getComputedStyle(el).cursor;
        const parent = el.parentElement;
        if (cursor !== 'pointer' || (parent && getComputedStyle(parent).cursor === 'pointer')) continue;
        kind = 'button';
      } else if (ancestor && kind !== 'input' && kind !== 'select' && !opts.selector &&
                 !(kind === 'link' && linkHref(el) !== ancestor.href)) {
        continue;
      }
      if (!styleVisible(el)) continue;
      const p = hitPoint(el, r, d.chain);
      if (!p) continue;
      const hint = {
        index: els.length, kind, tag: el.localName,
        x: r.l + d.ox, y: r.t + d.oy, width: r.r - r.l, height: r.b - r.t,
        px: p.x + d.ox, py: p.y + d.oy,
        text: textOf(el), href: linkHref(el), frame: d.chain.length > 0
      };
      accepted.set(el, hint);
      els.push(el);
      frames.push(d.chain);
      out.push(hint);
    }
  }
  // A label whose control has its own hint is redundant.
  const keep = out.filter((h, i) => !(h.kind === 'label' && accepted.has(els[i].control)));
  T.els = els;
  T.frames = frames;
  return {
    hints: keep, innerWidth, innerHeight, devicePixelRatio,
    scale: vp.scale, offsetX: vp.ox, offsetY: vp.oy
  };
};

// A fresh click point for hint i (the page may have moved it), or null.
T.point = function (i) {
  const el = T.els[i];
  if (!el || !el.isConnected) return null;
  const chain = T.frames[i] || [];
  let ox = 0, oy = 0;
  let clip = { l: 0, t: 0, r: el.ownerDocument.defaultView.innerWidth, b: el.ownerDocument.defaultView.innerHeight };
  for (const f of chain) { ox += f.dx; oy += f.dy; }
  const r = visibleRect(el, clip);
  if (!r) return null;
  const p = hitPoint(el, r, chain);
  return p ? { x: p.x + ox, y: p.y + oy } : null;
};

T.focus = function (i) {
  const el = T.els[i];
  if (!el || !el.isConnected) return false;
  el.focus();
  return true;
};

// The focused element, through frames and shadow roots.
function deepActive() {
  let el = document.activeElement;
  for (;;) {
    if (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
    if (el && (el.localName === 'iframe' || el.localName === 'frame')) {
      let d = null;
      try { d = el.contentDocument; } catch (e) {}
      if (d && d.activeElement) { el = d.activeElement; continue; }
    }
    return el;
  }
}

// Focuses a text field: the first visible one, or (opts.next / opts.previous)
// the one after / before the focused one; opts.index picks one. Falls back
// to text fields outside the viewport.
T.focusInput = function (opts) {
  opts = opts || {};
  let list = T.collect({ elements: 'inputs' }).hints.map(h => T.els[h.index]);
  if (list.length === 0) {
    list = [];
    for (const d of documents(document, 0, 0, { l: -1e9, t: -1e9, r: 1e9, b: 1e9 }, []))
      for (const el of walk(d.doc))
        if (textInput(el) && el.getClientRects().length > 0 && styleVisible(el)) list.push(el);
  }
  if (list.length === 0) return { ok: false, count: 0, index: -1 };
  const cur = list.indexOf(deepActive());
  let i = 0;
  if (typeof opts.index === 'number') i = ((opts.index % list.length) + list.length) % list.length;
  else if (cur >= 0 && opts.next) i = (cur + 1) % list.length;
  else if (cur >= 0 && opts.previous) i = (cur - 1 + list.length) % list.length;
  const el = list[i];
  el.focus();
  if (opts.select) {
    if (typeof el.select === 'function') el.select();
  } else {
    try {
      const n = (el.value || '').length;
      if (typeof el.setSelectionRange === 'function') el.setSelectionRange(n, n);
    } catch (e) {}
  }
  return { ok: true, count: list.length, index: i };
};

// ---- scrolling ---------------------------------------------------------------

const scrollable = (el, axis) => {
  const s = getComputedStyle(el);
  const o = axis === 'y' ? s.overflowY : s.overflowX;
  const size = axis === 'y' ? el.scrollHeight - el.clientHeight : el.scrollWidth - el.clientWidth;
  return size > 1 && (o === 'auto' || o === 'scroll' || o === 'overlay');
};
const room = (el, axis, dir) => {
  if (axis === 'y')
    return dir < 0 ? el.scrollTop > 0 : el.scrollTop < el.scrollHeight - el.clientHeight - 1;
  return dir < 0 ? el.scrollLeft > 0 : el.scrollLeft < el.scrollWidth - el.clientWidth - 1;
};

// The element a scroll should move: from the focused element or the one at
// the centre of the viewport up to the document, the first that can scroll
// that way.
function scroller(axis, dir) {
  const root = document.scrollingElement || document.documentElement;
  let start = document.activeElement;
  if (!start || start === document.body || start === document.documentElement)
    start = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
  for (let el = start; el; el = el.parentElement || (el.parentNode && el.parentNode.host)) {
    if (el === root || el === document.body) break;
    if (scrollable(el, axis) && room(el, axis, dir)) return el;
  }
  return root;
}

// how: up, down, left, right, pageUp, pageDown, top, bottom.
// opts: { amount (CSS px, for up/down/left/right), pages (fraction of the
// visible height, for pageUp/pageDown), smooth }.
T.scroll = function (how, opts) {
  opts = opts || {};
  const axis = how === 'left' || how === 'right' ? 'x' : 'y';
  const dir = how === 'up' || how === 'left' || how === 'pageUp' || how === 'top' ? -1 : 1;
  const el = scroller(axis, dir);
  const root = el === (document.scrollingElement || document.documentElement);
  const vv = visualViewport;
  const visible = axis === 'y' ? (root ? (vv ? vv.height : innerHeight) : el.clientHeight)
                               : (root ? (vv ? vv.width : innerWidth) : el.clientWidth);
  let d;
  switch (how) {
    case 'up': case 'down': case 'left': case 'right':
      d = dir * (typeof opts.amount === 'number' ? opts.amount : 60); break;
    case 'pageUp': case 'pageDown':
      d = dir * Math.max(1, Math.round(visible * (typeof opts.pages === 'number' ? opts.pages : 0.9))); break;
    case 'top': case 'bottom':
      d = dir * (axis === 'y' ? el.scrollHeight : el.scrollWidth) * 2; break;
    default:
      throw new Error('unknown scroll direction: ' + how);
  }
  const before = [el.scrollLeft, el.scrollTop];
  const behavior = opts.smooth ? 'smooth' : 'instant';
  el.scrollBy(axis === 'y' ? { top: d, behavior } : { left: d, behavior });
  return { ok: true, element: root ? 'document' : el.localName,
           x: el.scrollLeft, y: el.scrollTop,
           moved: el.scrollLeft !== before[0] || el.scrollTop !== before[1] };
};

globalThis.__cefqmlTools = T;
})()`

// ---- running it ---------------------------------------------------------------

// view -> { id: execution context of our isolated world, marked: bool }
const _worlds = new WeakMap()
// view -> callbacks waiting for a world being created
const _creating = new WeakMap()
// views whose signals invalidate their world
const _hooked = new WeakSet()

function _hook(view) {
    if (_hooked.has(view)) return
    _hooked.add(view)
    const drop = () => _worlds.delete(view)
    // A new document (possibly in a new renderer process, where context ids
    // start over) or a new browser.
    view.loadStarted.connect(drop)
    view.discardedChanged.connect(drop)
    view.readyChanged.connect(drop)
    view.renderProcessTerminated.connect(drop)
}

function _createWorld(view, done) {
    const waiting = _creating.get(view)
    if (waiting) { waiting.push(done); return }
    _creating.set(view, [done])
    const finish = world => {
        const cbs = _creating.get(view) || []
        _creating.delete(view)
        if (world) _worlds.set(view, world)
        for (const cb of cbs) cb(world)
    }
    _hook(view)
    view.devToolsMethod("Page.getFrameTree", {}, (tree, err) => {
        const frameId = !err && tree && tree.frameTree && tree.frameTree.frame ? tree.frameTree.frame.id : ""
        if (!frameId) { finish(null); return }
        view.devToolsMethod("Page.createIsolatedWorld", { frameId: frameId, worldName: "cefqml-tools" }, (w, e) => {
            finish(!e && w && w.executionContextId ? { id: w.executionContextId, marked: false } : null)
        })
    })
}

function _unwrap(r, err) {
    if (err) return { error: err }
    if (r && r.exceptionDetails) {
        const ex = r.exceptionDetails
        return { error: (ex.exception && ex.exception.description) || ex.text || "exception" }
    }
    return { value: r && r.result ? r.result.value : undefined }
}

function _inWorld(view, world, body, callback, retry) {
    // The first run in a world marks it; a run that finds no mark landed in
    // a context that is not ours (stale id) and is retried in a new world.
    const marked = world.marked
    const expression = "(() => { if (!globalThis.__cefqmlWorld) { if (" + marked + ") throw new Error('cefqml:stale-world');"
                     + " globalThis.__cefqmlWorld = true } " + PAGE_LIB + "; return (" + body + ") })()"
    view.devToolsMethod("Runtime.evaluate", {
        expression: expression, contextId: world.id, returnByValue: true, awaitPromise: true, userGesture: true
    }, (r, err) => {
        const out = _unwrap(r, err)
        const stale = out.error !== undefined && /cefqml:stale-world|context/i.test(out.error)
        if (stale && retry) {
            if (_worlds.get(view) === world) _worlds.delete(view)
            evaluate(view, body, callback, false)
            return
        }
        if (out.error === undefined) world.marked = true
        callback(out.value, out.error)
    })
}

// Evaluates `body` (an expression; `__cefqmlTools` is defined) in the page
// and calls callback(result, error).
function evaluate(view, body, callback, retry) {
    if (!view) { callback(undefined, "no view"); return }
    if (retry === undefined) retry = true
    const world = _worlds.get(view)
    if (world) { _inWorld(view, world, body, callback, retry); return }
    _createWorld(view, w => {
        if (w) { _inWorld(view, w, body, callback, retry); return }
        // No isolated world: the main world will do.
        view.evaluateJavaScript("(() => { " + PAGE_LIB + "; return (" + body + ") })()", callback)
    })
}

// Calls __cefqmlTools[name](...args).
function call(view, name, args, callback) {
    evaluate(view, "__cefqmlTools." + name + "(" + (args || []).map(a => JSON.stringify(a === undefined ? null : a)).join(", ") + ")",
             callback || (() => {}))
}

// ---- labels -----------------------------------------------------------------

// `count` distinct, prefix-free labels over `alphabet`, as short as possible
// (lengths differ by at most one), as Vimium makes them.
function labels(count, alphabet) {
    const chars = Array.from(new Set(String(alphabet).split("")))
    if (count <= 0 || chars.length === 0) return []
    if (chars.length === 1) return Array.from({ length: count }, (_, i) => chars[0].repeat(i + 1)).slice(0, 1)
    const list = [""]
    let offset = 0
    while (list.length - offset < count || list.length === 1) {
        const h = list[offset++]
        for (const c of chars) list.push(c + h)
    }
    return list.slice(offset, offset + count).sort().map(s => s.split("").reverse().join(""))
}
