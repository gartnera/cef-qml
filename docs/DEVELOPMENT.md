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
- `tests/` — `qmltestrunner` suites, run by `tests/run.sh` (via `meson test`),
  and `cdp_remote.py` (external DevTools-protocol control, see below).
- `subprojects/` — the CEF minimal binary distribution, fetched by a Meson wrap;
  `subprojects/packagefiles/cef/meson.build` builds `libcef_dll_wrapper`.
  When editing that overlay, also copy it to the extracted
  `subprojects/cef_binary_*/meson.build` (or wipe the extracted dir).
- `scripts/` — `make-release.sh` / `verify-release.sh` (prebuilt tarball).
- `.github/` — CI and release workflows; `apt-packages.txt` is the Ubuntu
  24.04 dependency list both use.

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
- Tests use `data:` URLs or `loadHtml` — no network.
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
- With `qml6-module-qtquick-dialogs` installed, `tst_browser`'s
  `test_13_context_menu_open_link` and `test_21_clipboard_bridge` were seen
  to fail intermittently (about half of the offscreen runs); without it they
  pass reliably. CI does not install it. Not yet investigated
  (`FileDialogHandler` creating Qt's dialogs is the likely difference).
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
