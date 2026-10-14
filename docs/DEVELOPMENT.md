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
  - `plugin.*` — type registration and the `Cef` singleton.
- `CefQml/Components/` — pure-QML module `CefQml.Components`: reusable browser
  building blocks (`WebTabs`, `TabStrip`, `NavigationBar`, `AddressField`,
  `FindBar`, `RequestOverlay`, `ContextMenu`, `DownloadsBar`, ...) and the
  reference `Browser` that composes them. Anything a custom browser could
  reuse belongs here, not in `examples/`.
- `examples/browser/` — the reference application (`main.qml`, `dev.qml` for
  live reload, `BrowserApp.qml`).
- `tests/` — `qmltestrunner` suites, run by `tests/run.sh` (via `meson test`).
- `subprojects/` — the CEF minimal binary distribution, fetched by a Meson wrap;
  `subprojects/packagefiles/cef/meson.build` builds `libcef_dll_wrapper`.
  When editing that overlay, also copy it to the extracted
  `subprojects/cef_binary_*/meson.build` (or wipe the extracted dir).

## Build and test

```sh
meson setup build            # first time; downloads CEF (~100 MB)
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
- Each run gets a fresh profile (`CEF_QML_CACHE_DIR`).
- Tests use `data:` URLs or `loadHtml` — no network.

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
- QML: a `Loader` property named `item` shadows `Loader.item`; ambiguous
  `Shortcut` sequences (the same keys bound twice) never fire.
- XMLHttpRequest file writes in tests are asynchronous; wait for `DONE`.
- `pkill -f <pattern>` can match (and kill) your own shell; prefer pids.
- C string hex escapes are greedy: write `"\x01" "cefqml:..."`, not
  `"\x01cefqml:..."`.

## Conventions

- C++20, Qt 6 (tested against 6.4), CEF minimal distribution (see the wrap).
- Match the surrounding style; comments explain *why*.
- Every new feature gets a test in `tests/`; keep the full suite green
  (`meson test -C build`) before committing. Run it several times when touching
  lifetime/shutdown code — some failures are intermittent.
- New public QML API is documented in `README.md`.
