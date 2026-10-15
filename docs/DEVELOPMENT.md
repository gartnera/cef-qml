# Developing cef-qml

Notes for contributors (human or agent). Read this before changing anything.

## Layout

- `src/` — the C++ plugin (`CefQml` module) and `cef-qml-helper` subprocess.
  - `cefcontext.*` — process-wide CEF init/shutdown, the external message
    pump (driven by a Qt timer), runtime-dir discovery, downloads list.
  - `cefclient.*` — `CefClient` implementation; forwards CEF callbacks to the view.
  - `cefwebview.*` — `CefWebView` (QQuickItem): off-screen rendering into a
    scene-graph texture, input, navigation, DevTools-protocol scripting,
    clipboard bridge, about:blank bootstrap (see comments in the file).
  - `requests.*` — objects handed to QML for decisions (JS dialogs,
    permissions, file dialogs, downloads).
  - `hotreload.*` — `HotReload` item (live QML reloading).
  - `jsonstore.*` — `JsonStore` (persisted JSON documents under
    `Cef.dataDir`; the storage of userscripts and future app state).
  - `historystore.*` — `HistoryStore` (browsing history: in-memory hash +
    newest-first list, frecency search, JSON file), its per-view
    `HistoryTracker` (what counts as a visit) and `HistoryModel` (filter
    proxy for history pages).
  - `bookmarkstore.*` — `BookmarkStore` (bookmark tree: node tree + id map
    + URL hash, Netscape HTML / JSON import and export, JSON file) and
    `BookmarkModel` (one folder, a subtree or search results as a list model
    updated row by row).
  - `plugin.*` — type registration and the `Cef` singleton.
- `CefQml/Components/` — pure-QML module `CefQml.Components`: reusable browser
  building blocks (`WebTabs`, `TabStrip`, `NavigationBar`, `AddressField`,
  `FindBar`, `RequestOverlay`, `ContextMenu`, `DownloadsBar`, ...) and the
  reference `Browser` that composes them. Anything a custom browser could
  reuse belongs here, not in `examples/`. Userscripts: `UserScripts.js`
  (metadata parser, URL rules, and the in-page runtime as a string),
  `UserScriptStore.qml` (persistence, DevTools registration per view, the
  page -> host message handler) and `UserScriptManager.qml` (UI).
  History UI: `AddressSuggestions.qml` (omnibox drop-down, inline
  completion, providers), `HistoryView.qml` (history page) and
  `PanelOverlay.qml` (the modal panel host `Browser` uses for its managers).
  Bookmark UI: `BookmarkButton.qml` (star), `BookmarksBar.qml`,
  `BookmarkMenu.qml` (folder drop-downs), `BookmarkEditor.qml` (edit card),
  `BookmarkManager.qml` and the internal `PopupMenu.qml` (context menus).
  Sessions: `SessionStore.qml` (session file, crash mark, restore),
  `SessionRegistry.js` (one writer per session file in a process) and
  `RecentlyClosedMenu.qml`.
  Command palette: `CommandPalette.qml` (overlay, built-in providers,
  ranking, recently used commands) and `Providers.js` (shared with
  `AddressSuggestions`: calling providers, normalizing items, glyphs, and
  the fuzzy matcher with highlighting).
  Keyboard browsing: `LinkHints.qml` (hint overlay, labels, keys, modes)
  and `PageTools.js` (the in-page library run in an isolated world:
  collecting hint targets, click points, `focusInput`, `scroll`; label
  generation), also used by `BrowserController.scrollPage` / `focusInput`.
  DevTools: `DevToolsPanel.qml` (docking, splitter, tab and window modes;
  the frontend bridge itself is C++, "DevTools" in `cefwebview.cpp`).
- `examples/browser/` — the reference application (`main.qml`, `dev.qml` for
  live reload, `BrowserApp.qml`).
- `tests/` — `qmltestrunner` suites, run by `tests/run.sh` (via `meson test`),
  and `cdp_remote.py` (external DevTools-protocol control, see below).
- `subprojects/` — the CEF minimal binary distribution, fetched by a Meson wrap;
  `subprojects/packagefiles/cef/meson.build` builds `libcef_dll_wrapper`.
  When editing that overlay, also copy it to the extracted
  `subprojects/cef_binary_*/meson.build` (or wipe the extracted dir).
- `scripts/` — `make-release.sh` / `verify-release.sh` (prebuilt tarball),
  `cargo-build.sh` (builds `libservo_qml.so` for meson).
- Servo (`-Dservo=enabled`, off by default; see "Servo (experimental)" in
  the README):
  - `servo/` — Rust crate `servo-qml`: the C API (`include/servo_qml.h`,
    `src/lib.rs`) over the `servo` crate, built as `libservo_qml.so`.
    `Cargo.lock` started from the one published with `servo`; keep the
    `servo` version pinned (`=0.7.0`) and update both together. Its QML
    suite is `servo/tests/` (outside `tests/`, which `qmltestrunner` scans
    recursively and which must not need the Servo module).
  - `src/servo/` — `ServoWebView` (QQuickItem) and `ServoEngine` (starts,
    spins and shuts down the process-wide Servo); `servoplugin.*`.
  - `ServoQml/` — the module's `qmldir` and `meson.build`.
  - `examples/servo/main.qml` — minimal Servo browser, optionally next to a
    `CefWebView`.
  - Gotchas: Servo objects are `Rc`s bound to the GUI thread; every call
    into Servo runs inside `QtGlGuard` (Servo makes its EGL context current
    there). A load sent before Servo reported a view's first URL is dropped
    by Servo, so `ServoWebView` holds it until then.
- `.github/` — CI and release workflows; `apt-packages.txt` is the Ubuntu
  24.04 dependency list both use (`apt-packages-servo.txt` adds what the
  `servo` CI job needs to build Servo).

## Build and test

```sh
meson setup build            # first time; downloads CEF (~310 MB)
meson compile -C build
meson test -C build --print-errorlogs        # offscreen + wayland suites
tests/run.sh build offscreen                 # all suites, offscreen only
TEST_INPUT=tests/tst_browser.qml tests/run.sh build offscreen
QML_IMPORT_PATH=build qml examples/browser/main.qml
```

- Offscreen mode: `QT_QPA_PLATFORM=offscreen`, Chromium ozone `headless`.
- Wayland mode starts a private headless Weston. It has no seat, so window
  shortcuts never fire there; `tst_browser.qml`-style keyboard tests only work
  offscreen (the meson `wayland` test runs `tst_webview.qml` only).
- Each run gets a fresh profile (`CEF_QML_CACHE_DIR`) and scratch dir
  (`CEF_QML_TEST_DIR`, for downloads and the files `tst_hotreload` writes);
  nothing is written into `<builddir>`, so `tests/run.sh` also runs against
  an installed or extracted `qml/` dir.
- Tests use `data:` URLs, `loadHtml` or the local HTTP server `run.sh`
  starts (`tests/http_server.py`, `TEST_HTTP_ORIGIN=http://127.0.0.1:<port>`;
  `localhost:<port>` is a second origin on it; `?html=<markup>` serves the
  markup) — no network. Per-origin features (site settings, permissions,
  `Storage.clearDataForOrigin`) need it: `data:` URLs have opaque origins.
- `run.sh` adds `--use-fake-device-for-media-stream` to `CEF_QML_FLAGS` so
  `getUserMedia` has devices and reaches `OnRequestMediaAccessPermission`.
  Never add `--use-fake-ui-for-media-stream`: it grants every media request
  inside Chromium before CefQml sees it, which would make the permission
  tests pass for the wrong reason.
- The profile is shared by all suites of a run: a suite that changes
  Chromium state (content settings, cookies, zoom of a host) must undo it in
  `cleanup()` (e.g. `SiteSettings.clear()` resets every exception it pushed).
- `meson test -C build cdp-remote` runs `tests/cdp_remote.py build`: it starts
  the reference browser, drives it over the remote-debugging port and checks
  the clean SIGTERM exit (stdlib-only Python; skips with 77 without a `qml`
  runtime, override with `QML_RUNTIME`).

## Remote control (Chrome DevTools Protocol)

Set `CEF_QML_REMOTE_DEBUGGING_PORT` to expose Chromium's remote-debugging
endpoint on 127.0.0.1 for any CefQml app; every `CefWebView` is a `page`
target:

```sh
CEF_QML_REMOTE_DEBUGGING_PORT=9222 QML_IMPORT_PATH=build qml examples/browser/main.qml &
curl -s http://127.0.0.1:9222/json/version   # browser-level webSocketDebuggerUrl
curl -s http://127.0.0.1:9222/json/list      # page targets (one per view/tab)
```

Connect any CDP client (or a raw WebSocket, as `tests/cdp_remote.py` does) to a
target's `webSocketDebuggerUrl` and use `Page.navigate`, `Runtime.evaluate`,
... as with Chrome; the app reflects the changes as usual (title, URL,
history). A view's target exists while it is still on its about:blank
bootstrap page; wait for its first page (`location.href`, `readyState`) before
navigating, or the app's own first load supersedes yours. Anyone on the
machine can connect, so only enable it for development or automation. `QT_LOGGING_RULES=cefqml.browser.info=true` makes the reference
browser log its window title, which is handy for headless checks.

Chromium installs SIGTERM/SIGINT/SIGHUP handlers that `_exit(0)` from inside
the message pump. After `CefInitialize` the plugin restores the host's own
handlers, or (when the host had none) turns these signals into
`QCoreApplication::exit(0)`, so `aboutToQuit` and `CefShutdown` run; a second
signal kills the process the default way.

## CI and releases

- `.github/workflows/ci.yml`: Ubuntu 24.04 (Qt 6.4.2), `meson setup`,
  compile, `meson test --print-errorlogs` on pushes and PRs to `main`; the
  CEF download (`subprojects/packagecache`) is cached by the hash of
  `subprojects/cef.wrap`; `meson-logs/` is uploaded on failure.
- `.github/workflows/release.yml`: on a `v*` tag (must match the `meson.build`
  version, optionally with a `-suffix`, which makes a prerelease) or a manual
  run. Builds `cef-qml-<version>-linux-x86_64.tar.gz` and publishes it on tags.
- Local equivalent:

  ```sh
  meson setup build-release --prefix=/ --libdir=lib -Dqml_dir=qml -Druntime_dir=lib/cef-qml
  scripts/make-release.sh build-release dist     # strips libcef.so (1.4 GB -> ~270 MB)
  scripts/verify-release.sh dist/cef-qml-*.tar.gz
  ```

  `verify-release.sh` extracts into a temp dir, checks with `ldd` that
  libcef.so resolves inside the extracted tree and runs the offscreen and
  cdp-remote suites against it. Move `build*/` and
  `subprojects/cef_binary_*` aside first to prove nothing depends on them.
  The plugin's RUNPATH is relative (`$ORIGIN/../../lib/cef-qml`) whenever
  `qml_dir` and `runtime_dir` are both inside the prefix (`meson.build`).
- Keep the scratch dir short: Chromium puts its singleton socket in `TMPDIR`,
  and a `TMPDIR` too long for a Unix socket path aborts at startup
  ("Socket path too long").

## Gotchas (learned the hard way)

- All CEF browser-process callbacks run on the Qt GUI thread (external pump).
  Never call back into CEF synchronously from a DevTools observer callback;
  post with `Qt::QueuedConnection` (observer-list reentrancy CHECKs).
- Every `CefRefPtr` to a CEF callback held by a QObject must be released before
  `CefShutdown` (`CefContext::shutdown`, on `aboutToQuit`), or CEF asserts
  "Object reference incorrectly held at CefShutdown".
- `aboutToQuit` is only emitted when `QCoreApplication::exec()` returns;
  `qmltestrunner` never calls it. CEF is therefore also shut down from a
  `qAddPostRoutine` (run by `~QGuiApplication`). Exiting with CEF still running
  segfaults intermittently at exit.
- `CefBrowserHost::CreateBrowser` is asynchronous: a view can be destroyed
  (e.g. by a HotReload reload or test teardown) before `OnAfterCreated`. Never
  close a browser synchronously from inside `OnAfterCreated` (CEF keeps using
  it in `CreateInternal` and crashes); post a `CefTask`. Clients stay
  registered with `CefContext` until `OnBeforeClose` so shutdown waits for them.
- The host process must use glibc malloc. jemalloc/tcmalloc (e.g. Quickshell)
  crash inside libcef's allocator shim; the plugin refuses to initialize
  (override: `CEF_QML_ALLOW_MALLOC_REPLACEMENT=1`).
- Qt 6.4 QtWayland crashes in `TextInput` when the compositor lacks a
  text-input protocol; tests set `QT_IM_MODULE=compose`.
- QtWayland < 6.5.1 `~QWaylandDisplay` calls `wl_display_disconnect` before
  `wl_event_queue_destroy` (use-after-free; upstream fix a76bf824). Under
  meson's `MALLOC_PERTURB_` every Qt Wayland client, even without CefQml,
  then hangs or aborts at exit (`tpp.c:83`, `pthread_mutex_lock.c:450`) after
  all tests passed. `tests/run.sh` unsets `MALLOC_PERTURB_` for the wayland
  mode on affected Qt. CEF is not involved: `CefShutdown` (post routine) runs
  at the top of `~QGuiApplication`, before the platform integration dies.
- Wait for `loading == false`, not just the title, before `find()` in tests.
- Chromium drops input sent to a document that has not painted its first
  frame yet, and `title`/`loadFinished` arrive before that frame. In tests,
  wait for two animation frames (`evaluate("new Promise(r =>
  requestAnimationFrame(() => requestAnimationFrame(() => r(1))))")`) after a
  load before sending keys or clicks to the page. Such races hide until
  something shifts the timing (here: importing `QtQuick.Dialogs`, or a loaded
  machine).
- Positioners (`Column`, `Row`) lay out at the next polish, not when their
  children change. Code that reads their size or relies on the children's
  positions right after changing the model (e.g. `ContextMenu.show`) must
  call `forceLayout()` first; a test clicking before the next frame hits a
  stale layout.
- QML: a `Loader` property named `item` shadows `Loader.item`; ambiguous
  `Shortcut` sequences (the same keys bound twice) never fire.
  Disabled `Shortcut`s still count: with a disabled and an enabled one on the
  same keys, Qt may send the (ambiguous) event to the disabled one and nothing
  fires. `Instantiator` (through the delegate model) deletes removed delegates
  with `deleteLater`, so their `Shortcut`s stay registered for a while (in
  `qmltestrunner`, until the test function returns). `KeyBindings` therefore
  clears a delegate's `sequence` when it is removed or inactive.
  `QT_LOGGING_RULES=qt.gui.shortcutmap=true` shows what the shortcut map does.
- V4 keeps the original position of an object key that is deleted and added
  again; build a new object to move a key to the end (`KeyBindings.bind`
  relies on key order).
- `url.toString()` in QML decodes `%20` and the like; keep `url` values
  (not their text) when the URL goes through `urlFor()` (typed text) again.
  Assigning the decoded string straight to a `url` property re-encodes it,
  which is how `closedTabs` and the session file store URLs (and why
  `reopenClosedTab()` bypasses `urlFor()`). Test pages without spaces
  (`tst_session.qml`) compare as strings.
- `CefWebView.loadStarted` exists so that waiting for a load
  (`BrowserController.whenLoaded`) does not take the previous page's
  `loadFinished`; `loadFinished` alone cannot tell the two apart.
- XMLHttpRequest file writes in tests are asynchronous; wait for `DONE`.
- `pkill -f <pattern>` can match (and kill) your own shell; prefer pids.
- Userscripts / DevTools protocol:
  - `Page.addScriptToEvaluateOnNewDocument` entries run in registration
    (identifier) order in every new document, main frame and same-process
    subframes; `worldName` puts one in an isolated world. Replacing entries
    means add-new-then-remove-old (values) or remove-then-add (scripts,
    whose order matters).
  - Identifiers arrive asynchronously. An entry replaced before its
    identifier arrived must be removed when it does, or it leaks and runs
    twice (`UserScriptStore` marks such registrations `dropped`). Replies can
    also arrive after the host object is destroyed (detach): callbacks must
    not touch a destroyed QML object's scope.
  - Registrations are not instantaneous: a navigation started right after a
    change may miss it (notably across a renderer-process switch, e.g.
    `file:` -> `data:`). Tests wait for `store.isApplied(view)` first.
  - `Runtime.addBinding` only delivers `Runtime.bindingCalled` after
    `Runtime.enable`. Without `executionContextName` the binding exists in
    every world (page and isolated); with it, only in that world. Deleting
    the global (`delete globalThis[name]`) keeps a captured reference
    working, which is how the runtime hides the channel from the page.
  - `Runtime.executionContextsCleared` marks a main-frame cross-document
    navigation (used to reset "running on this page").
  - A `srcdoc` iframe in a test page makes DevTools hang (`Runtime.evaluate`
    never answers, `loading` stays true): use `data:` iframes. A `data:`
    iframe has an opaque origin, though, so it is cross-origin to its page:
    to test same-origin frames (link hints), let a script fill an
    `about:blank` iframe (`frame.contentDocument.body.innerHTML = ...`).
  - Out-of-process iframes are separate DevTools targets; the view's session
    does not cover them, so they get no scripts.
- History / address bar:
  - What counts as a visit lives in `HistoryTracker` (historystore.cpp): a
    visit starts at `loadStarted` (document commit) and is recorded at
    `loadFinished` unless `loadFailed` fired (ERR_ABORTED, -3, is ignored);
    same-URL loads only refresh the time; `Page.navigatedWithinDocument`
    with a new path (pushState) is a visit, a fragment change is not. Only a
    title seen *after* `loadStarted` is used: `view.title` still holds the
    previous page's title at commit, so a page without `<title>` would
    inherit it.
  - Every `tst_*.qml` file runs in one process with one profile, so all
    `Browser`s share `Cef.dataDir/history.json`; tests `clear()` the store
    first instead of assuming it is empty.
  - `tryCompare(store.entry(url), ...)` never updates: `entry()` returns a
    snapshot. Use `tryVerify(() => store.entry(url).visitCount === 2)`.
  - Repeater delegates that were replaced (the suggestion list is rebuilt
    on every keystroke) linger until deferred deletion, so `findChild(..,
    "suggestion0")` can return a stale row; use `rowAt(i)`
    (`AddressSuggestions`, `HistoryView`). Positioners (`Column`) lay out
    late, so the rows are placed by index instead.
  - A hover-enter is delivered to rows that appear under a stationary mouse
    pointer; selecting on that would move the keyboard selection while
    typing. `AddressSuggestions` only follows real mouse movement, and the
    tests park the pointer in a corner.
  - `AddressField` handles keys in a single `Keys.onPressed` that asks
    `suggestions.handleKey()` first: specific handlers such as
    `Keys.onEscapePressed` run before `onPressed`, which would let the field
    act on Escape before the popup could close.
  - Inline completion must not re-complete after Backspace/Delete (the user
    is removing the completion); `AddressSuggestions` checks the key before
    `textEdited` is processed.
- Bookmarks:
  - `BookmarkModel`'s id role is `nodeId`: a delegate cannot see a role
    named `id` (it is the delegate's own id), and `model.id` is easy to
    forget. `get(row)` and the store's objects still use `id`.
  - Menus, the editor card and context menus reparent themselves to
    `Window.window.contentItem` with a high `z` (BookmarkMenu 10000,
    PopupMenu 10001, BookmarkEditor 10002) and fill it, with a backdrop
    `MouseArea` that closes them; otherwise a bar inside a `Column` would
    clip them or be covered by later siblings (the web view). They save and
    restore `activeFocusItem`. Tests find them with `findChild` on the
    window's content item, not on the bar.
  - Bar and manager tests must wait for positioners after changing the
    store (`tryVerify` on the item's `x`/`y`, see `waitForLayout` in
    `tst_bookmarks.qml`): a click right after `fill()` lands on the item that
    used to be there. The same holds after showing the manager's file row.
  - `BookmarksBar` keeps items that do not fit in its `Row` (opacity 0,
    disabled) so indexes stay stable; overflow is computed from the row's
    `implicitWidth`.
  - `BookmarkEditor` only validates the URL when the user changed the text:
    re-parsing the displayed `data:` / IDN URL can fail or change it.
  - Every suite shares `bookmarks.json` and `history.json`; a suite that
    adds bookmarks or visits must `clear()` and `save()` both in
    `cleanupTestCase`, or later suites (history ranking, suggestion counts)
    see its leftovers.
  - A `checkable` `BrowserAction` flips `checked` itself in `trigger()`,
    which breaks a `checked` binding; `bookmarks.showBar` restores it with
    `Qt.binding` after writing the target property.
- Command palette:
  - Ctrl+K does not open the palette from a focused `TextInput` (e.g.
    the address field) under Qt's X11 key scheme, which the generic Unix
    platform theme uses. That scheme maps Ctrl+K to DeleteEndOfLine, so
    the text field accepts the ShortcutOverride before the window-wide
    `Shortcut` sees the key. Ctrl+Shift+P always works, so the tests use
    it from the address field. The offscreen platform uses the Windows key
    scheme, so a test that passes there does not prove Ctrl+K works in a
    field on Linux.
  - No action defaults to Ctrl+Shift+P or Ctrl+K, and `KeyBindings` would
    log a conflict if one did. Both keys are window-wide shortcuts, so
    pages never see them; users who need Ctrl+K in pages rebind
    `palette.show`.
  - Like the bookmark menus, the palette reparents itself to
    `Window.window.contentItem` (z 10003, above `PopupMenu`). It saves
    `activeFocusItem` in `open()`, but only when that item is outside the
    palette, so switching modes while open keeps the original. `close()`
    restores it. Losing the focus to something else (a click in another
    window, another overlay) closes the palette without restoring, so it
    never steals the focus back.
  - Do not name the root id `palette`. Since Qt 6 every `Item` has a
    `palette` property, and inside a delegate (a separate context) the
    delegate's own `palette` shadows the outer id. `height:
    palette.rowHeight` silently became 0, and clicks called `run` on a
    `QQuickPalette`. The component uses `id: cmd`, and `Browser` uses
    `cmdPalette`.
  - Sorting is explicit about ties (score, then provider order, then the
    provider's own order), so the ranking does not depend on the sort
    algorithm or on declaration order.
  - Rows that appear under a resting pointer must not take the selection
    (see `AddressSuggestions`). `_hover` compares positions, and tests park
    the pointer in a corner.
  - Recently used commands go to `Cef.dataDir/command-palette.json`, which
    every suite shares. `tst_palette.qml` calls `clearRecent()` in `init`
    and `save()`s in `cleanupTestCase`. A second palette in a process
    needs its own `recentPath` (the test's own palette uses `""`, in
    memory).
  - URLs are not remembered as recent entries. History already ranks
    them, and the MRU file would duplicate browsing data. Only actions and
    items with an explicit `key` are remembered.
  - Typed addresses go through `BrowserController.navigate()`, which
    treats strings as typed text (so `data:text/html,hello world` would
    become a search). `run()` passes absolute addresses as `url` values
    (`Qt.resolvedUrl`).
- QML: an `alias` cannot go through a property (`alias text: field.input.text`
  fails with "Invalid alias reference"); give the inner item an alias and
  alias that (`Field.text`). A property with the same name as an id in the
  same scope (`property Item menu: menu`) binds to itself; use distinct ids.
- QML's `URL` mangles `data:` URLs (and `new URL(rel, base)` with them);
  leave absolute URLs alone.
- Sessions / discarded tabs:
  - `CefWebView.discarded` releases the browser like destruction does
    (`detachView`, `closeBrowser`) and clears the DevTools queue, pending
    callbacks, request objects and bootstrap state; the next browser starts
    over with the about:blank bootstrap. Anything that set the view up
    through DevTools must do it again: `UserScriptStore` listens to
    `discardedChanged` and re-registers (its old replies never arrive).
    `HistoryTracker` only uses signals and needs nothing.
  - A view declared `discarded: true` creates no browser at
    `componentComplete`; `title`/`icon` are writable placeholders and
    `cefIconChange` ignores the bootstrap page's (empty) favicon.
  - `navigationHistory()` hides the bootstrap `about:blank` entry while
    `m_dropInitialHistoryEntry` is set, and `goToHistoryEntry(i)` maps `i`
    from the end of DevTools' list (which may still contain it).
  - `SessionStore` writes running:true at start-up *with the previously
    saved tabs* (not the still-empty WebTabs), so a crash during start-up
    keeps them; the next change overwrites them. `saved` keeps the old
    session in memory for a later `restore()`.
  - The save timer does not restart on every change (a page that changes
    its title every second would postpone the save forever).
  - Every suite shares `Cef.dataDir`, so every default `Browser` writes
    `session.json`. Stores in tests use their own `tst-session-*` names,
    and only one store per process may write a file (`SessionRegistry.js`
    warns otherwise); a store releases its file in `onDestruction`, which
    is deferred, so wait for the file's `running: false` before creating
    the next store on it. `tst_session.qml` empties its files in
    `cleanupTestCase`.
  - An object-valued default property (`property SessionStore sessionStore:
    SessionStore {}`) is still created when `createObject(..., {
    sessionStore: null })` replaces it; `Browser`'s default store therefore
    goes inert (`name: ""`, no tabs) unless it is the current value.
  - `HotReload.generation` is incremented after the new tree is created,
    so a tree's `Component.onCompleted` sees the number of earlier loads:
    0 for the first load, 1 for the first reload. `BrowserApp` opens
    command-line URLs only at 0. On reload the old tree is deleted
    synchronously before the new one loads, so the old `SessionStore` has
    written the session file (and released it) by then.
- Link hints / keyboard browsing:
  - Chromium blocks renderer-initiated top-level navigations to `data:`
    URLs, so a hinted click on a `data:` link does nothing. Test links point
    at `#fragments` or an unreachable `http://127.0.0.1:9/...` (the load
    fails, but `loadStarted` and `newWindowRequested` happen).
  - `PageTools.js` creates one isolated world per view
    (`Page.getFrameTree` + `Page.createIsolatedWorld`) and evaluates with
    its `contextId`. The id dies with the document; it is dropped on
    `loadStarted`, `discardedChanged`, `readyChanged` and
    `renderProcessTerminated`, but a same-document change or a race can
    still leave a stale id, and Chromium may reuse a number for another
    context. So the first run marks the world (`__cefqmlWorld`), a later
    run that finds no mark throws, and the call is retried once in a new
    world.
  - Hint coordinates are CSS pixels of the layout viewport. The scale to
    item coordinates is `view.width / innerWidth` (page zoom), or
    `devicePixelRatio / Screen.devicePixelRatio` when both agree (more
    precise); pinch zoom adds `visualViewport.scale` and offsets.
  - Test pages without a doctype are in quirks mode, where
    `documentElement.clientHeight` is the document height, not the
    viewport's: use `visualViewport.height` / `innerHeight` for the visible
    size (`PageTools` scroll does).
  - Keys for an overlay that must beat window-wide `Shortcut`s: accept
    them in `Keys.onShortcutOverride` (then they arrive in `Keys.onPressed`).
    `CefWebView` does not accept ShortcutOverride, which is why
    single-letter mode bindings fire while the page has the focus;
    `editableFocused` (from a focusin/focusout script and a
    `\x01cefqml:editable:` console message) is what lets a mode step aside
    while the user types in the page.
  - A `KeyBindings` `Shortcut` delegate can be destroyed synchronously
    while its action runs (an action that changes `mode` rebuilds the
    bindings): read `modelData` and other context into locals before
    triggering.
  - `item.children` (a `QQmlListProperty`) is not iterable with `for ... of`
    in Qt 6.4 ("Type error"): use an index loop.
  - A model reset (`beginResetModel`) while a `ListView` is incubating a
    cache-buffer delegate asynchronously makes Qt 6.4 warn
    "DelegateModel::cancel: index out range" (`QQuickItemViewPrivate::clear`
    cancels the old index against the new, smaller count). `HistoryView` and
    `BookmarkManager` use `cacheBuffer: 0`, which creates no delegates
    asynchronously.
- Site settings / content settings:
  - Content settings set through `CefRequestContext::SetContentSetting`
    persist in the Chromium profile, independently of `site-settings.json`.
    `SiteSettings` remembers every origin it applied and writes `"default"`
    for it when a value goes away (`clear()`, `reset()`, `reload()`), and
    pushes the `*` defaults on load, so a stale exception cannot outlive the
    store.
  - Touching the MIDI content setting type (`CEF_CONTENT_SETTING_TYPE_MIDI`,
    get or set) hits a `CHECK` in Chromium 154 and kills the browser
    process; it is not in `contentSettingTypes`. `midi-sysex` works.
  - The settings must be in place before the request of the navigation
    goes out: `CefWebView.navigationRequested` (from `OnBeforeBrowse`) is the
    hook; `loadStarted` is too late for JavaScript and images.
  - Chromium's zoom is per host (`HostZoomMap`), not per origin or tab: two
    tabs on one host always show the same zoom, and a view re-applies its
    own `zoomFactor` on load start only while it is visible and active.
    `WebTabs` (zoomPolicy "origin") sets the stored zoom from `loadStarted`.
  - Off-screen Chromium has no permission prompt UI of its own: CefQml
    answers prompts (`OnShowPermissionPrompt`, `OnRequestMediaAccessPermission`)
    through `permissionRequested`. `navigator.permissions.query()` does not
    ask CefQml, it reads the content setting, so a remembered "allow" /
    "block" is only visible to the page ("granted" / "denied" instead of
    "prompt") because `SiteSettings.apply()` pushed it before the load.
    Media requests (`getUserMedia`) need `--use-fake-device-for-media-stream`
    to get as far as `OnRequestMediaAccessPermission`.
- DevTools (`devToolsFor`, `DevToolsPanel`):
  - `CefBrowserHost::ShowDevTools` is unusable off-screen: in CEF 154 it
    always opens a Chrome-style native top-level window, whatever the
    window info says ("Windowless rendering is not supported for this
    DevTools window"). The frontend is therefore an ordinary off-screen
    browser on `devtools://devtools/bundled/devtools_app.html?ws=...`
    whose `WebSocket` a shim (`kDevToolsShim`, added with
    `Page.addScriptToEvaluateOnNewDocument`) replaces with a bridge; the
    comment at "DevTools" in `cefwebview.cpp` has the message flow. Do not
    switch to a remote-debugging port for this: it needs the port open for
    every app and every local process.
  - The bridge binding (`Runtime.addBinding`) only reaches the host after
    `Runtime.enable` on the frontend browser, and both must be in place
    before the frontend document loads (the shim runs once, at document
    start): the frontend browser is created on `about:blank` and set up
    before it loads the frontend URL, like the user-script bootstrap.
  - The frontend's session is a child session of the inspected browser
    (`Target.attachToTarget` to its own target, `flatten: true`).
    `CefQmlClient::OnDevToolsMessage` routes every message that ends in
    `,"sessionId":"<id>"}` (Chromium appends it last) to the view and
    returns true, so CEF's own observers (`devToolsMethod`, events) only
    see the root session. The shim adds the root child session's id to the
    frontend's messages and strips it from the replies, because the
    frontend expects to be the root of its connection.
  - The token the host gives the frontend's main frame is the only
    authority: the binding exists in every frame of the frontend (and
    `devtools:` pages can embed others), so messages without the token are
    dropped. A frontend view never leaves `devtools:` (`cefAllowNavigation`
    allows only that and `about:blank`), and `setUrl` ignores anything else
    while `devToolsFor` is set: property initialization order in
    `createObject(..., { devToolsFor, url })` then does not matter.
  - Overlay.inspectNodeRequested is what makes the frontend reveal a node
    (`inspectElementAt`); it is synthesized only after the frontend's own
    `Overlay.enable` reply, otherwise the frontend's Elements panel is not
    listening yet and the event is lost.
  - `DevToolsPanel` connects to views it does not own. In teardown (hot
    reload, test exit) the QML context of the panel can be gone before the
    views' signals stop: every handler checks `alive()` (entry not dead,
    panel not null and not `_dying`), and `Component.onDestruction`
    disconnects all entries. Calling a function through `panel.` (not bare)
    keeps a dead context from turning into a ReferenceError.
  - The offscreen QPA warns "This plugin does not support raise()": the
    panel raises a DevTools window only when it is already visible.
  - Tests probe the frontend through its own modules
    (`import('./ui/legacy/legacy.js')`, `./core/sdk/sdk.js`): the inspected
    URL of `primaryPageTarget()`, the selected `DOMNode` flavor of
    `UI.Context` and `InspectorView`'s current panel. Evaluating in the
    page through the frontend's `RuntimeModel` proves the whole round trip.
    The frontend takes a few seconds to load; waits use 15 s timeouts.
  - `Browser` binds F12 and Ctrl+Shift+I (`devtools.toggle`): other test
    registries in a `Browser`'s window must not use those keys (ambiguous
    shortcuts never fire; `tst_actions.qml` uses F10).
  - DevTools tabs are `WebTabs` tabs: `SessionStore` skips views with
    `devToolsFor`, and `BrowserController` keeps them (and `devtools:` URLs)
    out of `closedTabs`.
- QML TestCase:
  - A function whose name ends in `_data` is a data provider for the
    test of the same name without it and is never run as a test
    (`test_clear_site_data` silently disappears).
  - The TestCases of one file do not necessarily run in file order: every
    case must set up the state it needs (e.g. hide items another case
    shows) and undo it in `cleanupTestCase()`.
  - A `Browser` with `keepOneTab` opens a new tab whenever the last one
    closes, so `tabs.closeAll()` never ends: destroy the browser (a
    `Loader` going inactive) instead.
  - Items in a `Flow`/`Row` laid out after a property change are not
    placed until the next polish: `waitForItemPolished(flow)` before
    `mouseClick()` on them.
- `destroy()` is deferred: a test that checks a `JsonStore` flush on
  destruction must wait (`tryVerify`) for it.
- C string hex escapes are greedy: write `"\x01" "cefqml:..."`, not
  `"\x01cefqml:..."`.

## Conventions

- C++20, Qt 6 (tested against 6.4), CEF minimal distribution (see the wrap).
- Match the surrounding style; comments explain *why*.
- Every new feature gets a test in `tests/`; keep the full suite green
  (`meson test -C build`) before committing. Run it several times when touching
  lifetime/shutdown code — some failures are intermittent.
- New public QML API is documented in `README.md`.
