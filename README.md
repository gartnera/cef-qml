# cef-qml

QML bindings for the [Chromium Embedded Framework](https://github.com/chromiumembedded/cef)
(CEF), rendered off-screen into Qt Quick.

cef-qml gives you the primitives to build **your own web browser in QML**, the
way [Quickshell](https://quickshell.outfoxxed.me/) gives you the primitives to
build your own desktop shell: a Chromium web view item, decision requests
(dialogs, permissions, file pickers, downloads), DevTools-protocol scripting
and live QML reloading, plus a library of ready-made browser building blocks
(tabs, address bar, find bar, ...). A complete reference browser built from
those blocks is included.

```qml
import QtQuick
import QtQuick.Window
import CefQml

Window {
    width: 1024; height: 768; visible: true
    CefWebView { anchors.fill: parent; url: "https://example.com"; focus: true }
}
```

| | |
|---|---|
| ![New tab page](docs/screenshots/1-new-tab.png) | ![A web site](docs/screenshots/3-site.png) |
| ![Find in page](docs/screenshots/5-find.png) | ![JavaScript dialog](docs/screenshots/6-dialog.png) |

*The reference browser (`examples/browser/`): new-tab page, a site, find in
page, and a `confirm()` dialog drawn by `RequestOverlay`.*

Contents: [Install](#install) · [Quickstart](#quickstart) ·
[`CefQml` API](#cefqml-module-api) · [`CefQml.Components`](#cefqmlcomponents) ·
[Hot reload](#hot-reload) · [Remote control (CDP)](#remote-control-chrome-devtools-protocol) ·
[Environment variables](#environment-variables) · [Limitations](#limitations) ·
[Testing](#testing) · [License](#license)

## Install

Linux x86_64 only. Requires Qt 6 (tested with Qt 6.4.2, Ubuntu 24.04) with
Qt Quick; the browser itself (CEF 154 / Chromium 154, minimal distribution)
ships with cef-qml.

### Prebuilt tarball

Download `cef-qml-<version>-linux-x86_64.tar.gz` from the
[releases page](https://github.com/gartnera/cef-qml/releases) and extract it
anywhere:

```sh
tar xf cef-qml-0.1.0-linux-x86_64.tar.gz      # creates ./cef-qml/
export QML_IMPORT_PATH=$PWD/cef-qml/qml
/usr/lib/qt6/bin/qml cef-qml/share/cef-qml/examples/browser/main.qml
```

The tree is relocatable; the plugin finds Chromium relative to itself, so
`QML_IMPORT_PATH` is the only thing to set:

```
cef-qml/
  qml/CefQml/                 QML plugin, qmldir, Components/ (CefQml.Components)
  lib/cef-qml/                libcef.so, Chromium resources, locales/, cef-qml-helper
  share/cef-qml/examples/     reference browser
  README.md  BUILDINFO  LICENSES/
```

The tarball is built against Qt 6.4 on Ubuntu 24.04. The plugin only uses
public Qt API, so later Qt 6 releases should load it as well (Qt keeps binary
compatibility within Qt 6), but only Qt 6.4 is tested. Chromium needs the usual
desktop libraries (`libnss3`, `libasound2`, `libgbm1`, `libxkbcommon0`, ...);
any system that runs Chrome has them. Use glibc malloc (see
[Limitations](#limitations)).

### Build from source

```sh
# Ubuntu 24.04
sudo apt install meson ninja-build g++ pkg-config qt6-base-dev qt6-declarative-dev \
  qml6-module-qtquick qml6-module-qtquick-window qml6-module-qtqml-workerscript \
  qml6-module-qttest qml-qt6 qt6-declarative-dev-tools
meson setup build            # downloads the CEF minimal distribution (~310 MB)
meson compile -C build
QML_IMPORT_PATH=build /usr/lib/qt6/bin/qml examples/browser/main.qml
```

Requires Meson >= 1.3. The complete package list CI uses, including the Wayland
test suite's `weston` and `qt6-wayland`, is
[`.github/apt-packages.txt`](.github/apt-packages.txt).

The build tree is directly usable (`QML_IMPORT_PATH=<builddir>`), and
`meson install` installs the module into `<libdir>/qt6/qml` and the runtime
into `<libdir>/cef-qml`. Options (`meson configure`): `qml_dir`,
`runtime_dir`, `examples`. When both directories are inside the prefix the
plugin's RPATH is relative (`$ORIGIN/...`), so the whole prefix can be moved;
`scripts/make-release.sh` builds the release tarball that way. Contributor
notes: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Optional: `qml6-module-qtquick-dialogs` lets the reference browser answer
`<input type=file>` with Qt's file dialog (otherwise file pickers are
canceled).

## Quickstart

### A web view

```qml
import QtQuick
import QtQuick.Window
import CefQml

Window {
    width: 1024; height: 768; visible: true
    title: web.title

    CefWebView {
        id: web
        anchors.fill: parent
        focus: true
        url: "https://example.com"
        onLoadFinished: (url, status) => console.log("loaded", url, status)
        onNewWindowRequested: (url, userGesture, background) => web.url = url
    }
}
```

`CefWebView` handles mouse, wheel, keyboard and IME input, the clipboard
(through Qt's clipboard), `<select>` popups, tooltips and cursors. Hidden
views (`visible: false` or `active: false`) stop rendering.

### Scripting

```qml
CefWebView {
    id: web
    url: "https://example.com"

    // Run in every document before the page's own scripts.
    userScripts: ["document.addEventListener('DOMContentLoaded', () => console.log('hi'))"]
    onConsoleMessage: (level, message, source, line) => console.log("page:", message)

    onLoadFinished: {
        // Evaluate JavaScript; promises are awaited, the result comes back as JSON.
        web.evaluateJavaScript("document.querySelectorAll('a').length",
                               (result, error) => console.log("links:", result, error))
        // Any Chrome DevTools Protocol method...
        web.devToolsMethod("Page.captureScreenshot", { format: "png" },
                           (result, error) => shot.source = "data:image/png;base64," + result.data)
    }

    // ...and its events (enable the domain first).
    Component.onCompleted: web.devToolsMethod("Network.enable")
    onDevToolsEvent: (method, params) => {
        if (method === "Network.requestWillBeSent") console.log(params.request.url)
    }
}
Image { id: shot }
```

### Answering requests

Connect a handler to take over a decision; leave it unconnected for the
default (JavaScript dialogs dismissed, permissions denied, file dialogs
canceled, downloads saved to the user's download directory).

```qml
CefWebView {
    onJavaScriptDialogRequested: dialog => {
        if (dialog.type === CefJavaScriptDialog.Confirm) dialog.accept()
        else dialog.reject()
    }
    onPermissionRequested: request => request.origin.toString().startsWith("https://meet.example")
                                      ? request.grant() : request.deny()
    onFileDialogRequested: request => request.accept(["/home/me/report.pdf"])
    onDownloadRequested: download => download.accept("/tmp/downloads/")
}
```

### A whole browser

```qml
import QtQuick
import QtQuick.Window
import CefQml.Components

Window {
    width: 1280; height: 820; visible: true
    title: browser.title
    color: Style.background
    Component.onCompleted: Style.accent = "#e0a"   // theme every component

    Browser {
        id: browser
        anchors.fill: parent
        focus: true
        initialUrls: ["https://example.com", "https://github.com"]
    }
}
```

Or compose your own from the pieces:

```qml
import QtQuick
import QtQuick.Window
import CefQml
import CefQml.Components

Window {
    width: 1280; height: 820; visible: true
    Column {
        anchors.fill: parent
        TabStrip { id: strip; width: parent.width; tabs: tabs; onNewTabRequested: tabs.openTab("https://duckduckgo.com") }
        NavigationBar { id: nav; width: parent.width; view: tabs.currentView }
        WebTabs {
            id: tabs
            width: parent.width; height: parent.height - strip.height - nav.height
            Component.onCompleted: openTab("https://example.com")
            RequestOverlay { anchors.fill: parent; tabs: tabs }
        }
    }
}
```

## `CefQml` module API

`import CefQml` (version 1.0).

### `CefWebView` (Item)

A Chromium browser rendered off-screen into a Qt Quick texture. The browser is
created when the item is completed; it starts on an internal `about:blank`
page while user scripts are registered, then loads `url`.

| Property | Type | | Description |
|---|---|---|---|
| `url` | url | read/write | Current URL; setting it navigates. Follows in-page navigation. |
| `title` | string | read-only | Page title. |
| `icon` | url | read-only | Favicon URL. |
| `loading` | bool | read-only | A navigation is in progress. Wait for `false` before inspecting the page. |
| `loadProgress` | real | read-only | 0..1. |
| `canGoBack`, `canGoForward` | bool | read-only | History state. |
| `hoveredUrl` | string | read-only | Link under the mouse (status text). |
| `tooltip` | string | read-only | Tooltip requested by the page. |
| `zoomFactor` | real | read/write | Page zoom, clamped to 0.25..5 (default 1). |
| `audioMuted` | bool | read/write | Mute the page. |
| `fullscreen` | bool | read-only | The page requested fullscreen (`element.requestFullscreen()`); resize the view accordingly. |
| `backgroundColor` | color | read/write | Default page background (default white). Only applies before the browser is created; use `"transparent"` for see-through pages. |
| `frameRate` | int | read/write | Maximum frames per second, 1..240 (default 60). |
| `active` | bool | read/write | `false` keeps the browser alive but stops rendering (as does `visible: false`). |
| `ready` | bool | read-only | The underlying CEF browser exists. |
| `frameCount` | int | read-only | Frames received so far (notifies through `frameSwapped`). |
| `userScripts` | list&lt;string&gt; | read/write | JavaScript sources run in every new document before the page's own scripts (`Page.addScriptToEvaluateOnNewDocument`). |

Enum `CefWebView.ConsoleLevel`: `Debug`, `Info`, `Warning`, `Error`.

| Method | Description |
|---|---|
| `goBack()`, `goForward()` | Navigate history. |
| `reload()`, `reloadIgnoringCache()`, `stop()` | |
| `loadHtml(string html)` | Load an HTML string (as a `data:` URL). |
| `runJavaScript(string script)` | Fire-and-forget JavaScript in the main frame. |
| `evaluateJavaScript(string script, function callback(result, error))` | Evaluate in the main frame; promises are awaited and the result must be JSON-serializable. On failure `result` is `undefined` and `error` is a message. |
| `int devToolsMethod(string method, object params = {}, function callback(result, error))` | Call any [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/) method. Calls made before the browser exists are queued. Returns the message id. |
| `find(string text, bool forward = true, bool matchCase = false)` | Find in page; results arrive through `findResult`. Repeat with the same text for the next match. |
| `stopFinding(bool clearSelection = true)` | |
| `copy()`, `cut()`, `paste()`, `selectAll()`, `undo()`, `redo()` | Edit commands on the focused frame (`paste()` uses the system clipboard). |

| Signal | Description |
|---|---|
| `urlChanged()`, `titleChanged()`, `iconChanged()`, `loadingChanged()`, `loadProgressChanged()`, `navigationStateChanged()` (`canGoBack`/`canGoForward`), `hoveredUrlChanged()`, `tooltipChanged()`, `zoomFactorChanged()`, `audioMutedChanged()`, `fullscreenChanged()`, `backgroundColorChanged()`, `frameRateChanged()`, `activeChanged()`, `readyChanged()`, `userScriptsChanged()` | Property notifications. |
| `frameSwapped()` | A new frame was rendered. |
| `loadFinished(url url, int httpStatusCode)` | Main frame finished loading. |
| `loadFailed(int errorCode, string errorText, url failedUrl)` | Main frame failed to load (Chromium `net::Error` code). |
| `newWindowRequested(url url, bool userGesture, bool background)` | `target=_blank`, `window.open()`, middle click, ... If nothing is connected, the URL opens in this view. |
| `closeRequested()` | The page called `window.close()`. |
| `consoleMessage(int level, string message, string source, int line)` | `console.*` output of the page (`level` is a `ConsoleLevel`). |
| `contextMenuRequested(real x, real y, url linkUrl, string selectedText, bool editable)` | Right click, in item coordinates. Chromium's own menu is never shown; draw your own (see `ContextMenu`). |
| `renderProcessTerminated(int status)` | The renderer crashed or was killed; `reload()` to recover. |
| `devToolsEvent(string method, var params)` | DevTools protocol events (enable the domain first, e.g. `devToolsMethod("Network.enable")`). |
| `findResult(int count, int activeMatch, bool finalUpdate)` | Result of `find()`; `activeMatch` is 1-based. |
| `javaScriptDialogRequested(CefJavaScriptDialog dialog)` | `alert`/`confirm`/`prompt`/`onbeforeunload`. Unhandled: dismissed. |
| `permissionRequested(CefPermissionRequest request)` | Camera, microphone, geolocation, notifications, ... Unhandled: denied. |
| `fileDialogRequested(CefFileDialogRequest request)` | `<input type=file>`, `showOpenFilePicker()`, ... Unhandled: canceled. |
| `downloadRequested(CefDownload download)` | A download starts. Unhandled: saved to the user's download directory. |

Request objects are owned by C++; QML may keep references while a request is
pending. Each must be answered once; further calls are ignored.

### `CefJavaScriptDialog`

| Member | Description |
|---|---|
| `type` | `CefJavaScriptDialog.Alert`, `Confirm`, `Prompt` or `BeforeUnload`. |
| `message`, `defaultText` (prompt), `origin` (url), `isReload` (beforeunload) | Read-only. |
| `handled` | Answered (or dismissed by Chromium). |
| `accept(string text = "")` | OK / Leave; `text` is the `prompt()` result. |
| `reject()` | Cancel / Stay. |
| signal `closed()` | Chromium dismissed the dialog itself (e.g. the page navigated): hide your UI. |

### `CefPermissionRequest`

| Member | Description |
|---|---|
| `origin` | url of the requesting page. |
| `permissions` | Human-readable names, e.g. `["camera", "microphone"]`. |
| `handled` | |
| `grant()`, `deny()` | |
| `dismiss()` | Close without deciding (the page may ask again later). |
| signal `closed()` | Chromium withdrew the request. |

### `CefFileDialogRequest`

| Member | Description |
|---|---|
| `mode` | `CefFileDialogRequest.Open`, `OpenMultiple`, `OpenFolder` or `Save`. |
| `title`, `defaultPath` | |
| `acceptFilters` | MIME types and/or extensions, e.g. `["image/*", ".pdf"]`. |
| `nameFilters` | The same as Qt file-dialog name filters, e.g. `["Files (*.png *.pdf)"]`. |
| `handled` | |
| `accept(list<string> files)` | Local paths or `file://` URLs (a single string works too). |
| `reject()` | Cancel. |

### `CefDownload`

| Member | Description |
|---|---|
| `id`, `url`, `suggestedFileName`, `mimeType` | Constant. |
| `state` | `CefDownload.Pending`, `InProgress`, `Paused`, `Complete`, `Canceled` or `Interrupted`. |
| `path`, `receivedBytes`, `totalBytes` (-1 if unknown), `progress` (0..1, -1 if unknown), `speed` (bytes/s) | Updated through `updated()`. |
| `accept(string path = "")` | Start saving. `path` may be a file, a directory, a `file://` URL or empty (download directory + suggested name). |
| `cancel()`, `pause()`, `resume()` | |
| `remove()` | Forget a finished download (removes it from `Cef.downloads`). |
| signals `updated()`, `finished()` | |

Downloads outlive the view that started them; all of them are listed in
`Cef.downloads`.

### `Cef` (singleton)

| Member | Description |
|---|---|
| `version` | CEF version, e.g. `"154.0.34"`. |
| `chromiumVersion` | e.g. `"154.0.8037.98"`. |
| `runtimeDir` | Directory of the loaded `libcef.so` (helper, resources, locales). |
| `downloads` | All `CefDownload`s of this process, oldest first (`downloadsChanged()`). |
| `urlFromUserInput(string text)` | What an address bar does with typed text: `"example.com"` → `https://example.com`, `"/tmp/x.html"` → file URL, `"localhost:8080"` → `http://localhost:8080`. Returns an invalid (empty) URL for text that is not an address (e.g. a search query). |
| `copyToClipboard(string text)` | |
| `environment(string name)` | Value of an environment variable (`""` if unset). |

### `HotReload` (Item)

Loads a QML file and reloads it whenever QML/JS files under its directory (or
`watchPaths`) change. The loaded item fills the `HotReload`. CEF is
initialized once per process and unaffected by reloads, so web views in the
reloaded content simply start again.

| Member | Description |
|---|---|
| `source` | url of the QML file to load (relative to the file declaring the `HotReload`). |
| `watch` | Reload on changes (default `true`). |
| `watchPaths` | Extra files/directories to watch (paths or `file:` URLs). |
| `delay` | Debounce between the last change and the reload, in ms. |
| `item` | The loaded item (read-only). |
| `errorString` | Load error, shown in place of the content (read-only). |
| `generation` | Increments on every (re)load (read-only). |
| `state` | Arbitrary map kept across reloads. |
| `reload()` | Reload on the next event loop iteration (safe to call from the loaded content). |
| signals `aboutToReload()` (save state here), `reloaded()`, `failed(string errorString)` | |

Inside the loaded content, the context property `hotReload` refers to the
`HotReload` object.

## `CefQml.Components`

`import CefQml.Components`: a pure-QML library of browser building blocks,
built only on the public `CefQml` API. Use them as they are, theme them
through `Style`, or copy one as the starting point for your own.

| Component | Purpose and key API |
|---|---|
| `Browser` | Complete tabbed browser: `TabStrip`, `NavigationBar`, `FindBar`, `WebTabs`, `StatusBubble`, `RequestOverlay`, `DownloadsBar`, `ContextMenu`, file dialogs and the usual keyboard shortcuts (Ctrl+T/W/L/F/R, Ctrl+Tab, Alt+Left/Right, Ctrl+±/0, Ctrl+1..9). Properties: `tabs` (the `WebTabs`), `currentView`, `title`, `initialUrls`, `openInitialTabs`, `homeUrl` (default: built-in new-tab page, `newTabHtml`), `searchUrl`, `keepOneTab`, `tabStrip`, `navigationBar`, `findBar`. Functions: `open(url, newTab)` (typed text becomes a URL or a search), `newTab()`, `isNewTabUrl(url)`. Signal: `lastTabClosed()` (when `keepOneTab` is false). |
| `WebTabs` | Non-visual tab manager: one `CefWebView` per tab, stacked, only the current one visible. `views`, `count`, `currentIndex`, `currentView`, `homeUrl`, `viewDelegate` (a `Component` deriving from `CefWebView`), `openPopupsInNewTabs`, `closeOnRequest`. `openTab(url, background, index)`, `closeTab(index)`, `moveTab(from, to)`, `closeAll()`, `indexOf(view)`, `urls()` / `restore(urls, current)` for sessions. Signals `tabOpened`, `tabClosed`, `lastTabClosed`, `sessionChanged`, `contextMenuRequested(view, ...)`; set `interceptJavaScriptDialogs` / `interceptPermissions` / `interceptFileDialogs` / `interceptDownloads` to receive every tab's requests as `javaScriptDialogRequested(view, dialog)`, `permissionRequested(view, request)`, `fileDialogRequested(view, request)`, `downloadRequested(view, download)`. |
| `TabStrip` | Horizontal tab bar for a `WebTabs` (`tabs`, required): click selects, middle click or × closes, + emits `newTabRequested()`. `maxTabWidth`, `minTabWidth`. |
| `NavigationBar` | Back / forward / reload-stop, an `AddressField` and a load-progress line for `view`. `addressField`, `searchUrl`; children are placed after the address field (e.g. a menu button). |
| `AddressField` | URL/search field bound to `view`: shows the page URL while not edited; Enter navigates, non-addresses are searched with `searchUrl` (`%s` = query). `text`, `input`, `isInternalUrl` (urls shown as an empty field), `urlFor(text)`, `focusAndSelect()`, signal `navigated(url)`. |
| `FindBar` | Find-in-page bar for `view`: Enter next, Shift+Enter previous, Escape closes. `text`, `matchCount`, `activeMatch`, `matchCase`, `open()`, `close()`, `findNext(forward)`, signal `closeRequested()`. |
| `RequestOverlay` | Shows JavaScript dialogs and permission prompts of a `WebTabs` (`tabs`, required) as an in-page card; requests of background tabs wait until their tab is shown. `rememberPermissions` (per origin and permission, this session). |
| `ContextMenu` | Right-click menu for a `WebTabs` (`tabs`, required), drawn inside the window: open/copy link, undo/redo/cut/copy/paste/select all in editable fields, copy selection, otherwise back/forward/reload. Signal `openLinkInNewTab(url)`; `show(view, x, y, linkUrl, selectedText, editable)`, `close()`. |
| `DownloadsBar` | Strip listing `Cef.downloads` with progress; click opens a finished file, ■ cancels, × and "Clear" remove finished entries. Hidden when empty. |
| `StatusBubble` | Bottom-left bubble showing `view.hoveredUrl`. |
| `IconButton` | Small flat button showing a text glyph: `text`, `toolTip`, `enabled`, `checked`, `textColor`, signal `clicked()`. |
| `Style` (singleton) | Shared look; all properties writable to theme everything at once: `background`, `surface`, `surfaceHover`, `surfaceActive`, `border`, `text`, `textDim`, `accent`, `danger` (colors), `radius`, `fontSize`, `barHeight`, `fontFamily`. |

`Browser` answers file dialogs with Qt's `FileDialog` when the
`QtQuick.Dialogs` module is installed (it is optional).

## Hot reload

`examples/browser/dev.qml` runs the reference browser under `HotReload`: edit
`examples/browser/BrowserApp.qml` (or any QML next to it), save, and the UI
reloads in place, keeping its tabs (`BrowserApp` saves them in
`hotReload.state` on `aboutToReload`).

```sh
QML_IMPORT_PATH=build /usr/lib/qt6/bin/qml examples/browser/dev.qml
# also live-edit the shared components:
CEFQML_COMPONENTS=$PWD/CefQml/Components QML_IMPORT_PATH=build /usr/lib/qt6/bin/qml examples/browser/dev.qml
```

The same pattern works for your own app:

```qml
Window {
    HotReload { anchors.fill: parent; source: "App.qml" }
}
```

## Remote control (Chrome DevTools Protocol)

Set `CEF_QML_REMOTE_DEBUGGING_PORT` to expose Chromium's remote-debugging
endpoint on 127.0.0.1 for any CefQml app; every `CefWebView` is a `page`
target:

```sh
CEF_QML_REMOTE_DEBUGGING_PORT=9222 QML_IMPORT_PATH=build /usr/lib/qt6/bin/qml examples/browser/main.qml &
curl -s http://127.0.0.1:9222/json/list      # one page target per view/tab
```

Connect any CDP client (Puppeteer, Playwright's `connectOverCDP`, or a raw
WebSocket as in `tests/cdp_remote.py`) to a target's `webSocketDebuggerUrl` and
use `Page.navigate`, `Runtime.evaluate`, ...; the QML side reflects the
changes as usual. Anyone on the machine can connect, so only enable it for
development or automation. Inside QML, `CefWebView.devToolsMethod()` gives the
same protocol without a port.

## Environment variables

| Variable | Effect |
|---|---|
| `CEF_QML_CACHE_DIR` | Profile directory (cookies, cache, local storage). Default: `<GenericDataLocation>/cef-qml/<application name>` (`~/.local/share/cef-qml/<app>`). If another live process holds it, a temporary profile is used instead. |
| `CEF_QML_REMOTE_DEBUGGING_PORT` | Enable the CDP endpoint on this port (see above). |
| `CEF_QML_FLAGS` | Extra Chromium switches, e.g. `"--enable-features=Foo --force-device-scale-factor=2"`. |
| `CEF_QML_OZONE_PLATFORM` | Chromium's Ozone platform. Default: `x11` under the Qt `xcb` platform, `headless` otherwise (including Wayland). |
| `CEF_QML_ENABLE_GPU_COMPOSITING` | Set to keep GPU compositing (disabled by default: frames are read back on the CPU anyway). |
| `CEF_QML_RUNTIME_DIR` | Directory holding `libcef.so`'s resources, `locales/` and `cef-qml-helper`. Default: the directory of the loaded `libcef.so`. |
| `CEF_QML_LOG_FILE` | Write CEF's log there. |
| `CEF_QML_VERBOSE` | Log at INFO level instead of ERROR. |
| `CEF_QML_ALLOW_MALLOC_REPLACEMENT` | Start even though the process replaced `malloc` (see below; expect crashes). |

Qt logging: the plugin logs under the category `cefqml`
(`QT_LOGGING_RULES="cefqml.info=true"`).

## Limitations

- **glibc malloc only.** `libcef.so` carries Chromium's allocator shim, which
  frees memory that glibc handed out. Processes that replace `malloc`
  (jemalloc, tcmalloc, mimalloc, ...) crash, so the plugin refuses to start
  CEF there. This is why **Quickshell is not supported** (it links jemalloc).
- **Off-screen rendering only.** Pages are rendered by Chromium into memory
  and drawn as a Qt Quick texture (CPU copy per frame); there are no native
  child windows. Chromium's own popups and menus (context menu, permission
  bubbles, file pickers, ...) do not exist: the host decides through the
  request signals.
- **Headless Ozone by default.** Off-screen browsers never create native
  surfaces, so Chromium runs with the `headless` Ozone platform (or `x11` on
  X11); its clipboard is bridged through Qt's clipboard.
- **One CEF per process**, initialized on first use, shut down when the Qt
  application exits. One browser process per profile directory.
- Linux x86_64 only. Tested with Qt 6.4.2 (Ubuntu 24.04), offscreen and
  Wayland (Weston) platforms. No sandbox (`no_sandbox`).

## Testing

```sh
meson test -C build --print-errorlogs      # offscreen + wayland + cdp-remote suites
tests/run.sh build offscreen               # all qmltestrunner suites, offscreen only
TEST_INPUT=tests/tst_browser.qml tests/run.sh build offscreen
```

The suites need `qmltestrunner` (`qt6-declarative-dev-tools`), `weston` for
the Wayland suite and the `qml` tool (`qml-qt6`) plus `python3` for
`cdp-remote`; missing tools skip the suite. Tests use `data:` URLs and need no
network. `tests/run.sh` also runs against an installed or extracted tree:
`tests/run.sh <prefix>/qml offscreen`. See
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the details and gotchas.

CI (`.github/workflows/ci.yml`) builds and runs `meson test` on Ubuntu 24.04
for every push and pull request to `main`. Pushing a `v*` tag runs
`.github/workflows/release.yml`: it builds the tarball with
`scripts/make-release.sh`, checks it with `scripts/verify-release.sh` (which
extracts it elsewhere and runs the offscreen and remote-control suites against
the extracted tree alone), and attaches it to a GitHub release.

## License

The cef-qml sources do not carry a license file yet. CEF is distributed under
a BSD license (`LICENSE.txt` of the CEF distribution); Chromium and its
third-party components come with their own licenses, listed in the CEF
distribution's `CREDITS.html`. Release tarballs include both under
`LICENSES/`.
