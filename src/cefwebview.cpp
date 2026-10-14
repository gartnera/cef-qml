#include "cefwebview.h"

#include "cefclient.h"
#include "cefcontext.h"
#include "keymap.h"

#include <QClipboard>
#include <QDateTime>
#include <QCursor>
#include <QGuiApplication>
#include <QInputMethod>
#include <QJSEngine>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlEngine>
#include <QQmlInfo>
#include <QTimer>
#include <QUuid>
#include <QLoggingCategory>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

#include <cmath>
#include <memory>
#include <utility>
#include <cstring>

#include "include/cef_browser.h"
#include "include/cef_navigation_entry.h"
#include "include/cef_ssl_status.h"
#include "include/cef_x509_certificate.h"

Q_DECLARE_LOGGING_CATEGORY(lcCef)

namespace {

// Prefix of console messages carrying clipboard text from the page; they
// are consumed by CefQmlClient::OnConsoleMessage and never reach QML.
constexpr char kClipboardMessagePrefix[] = "\x01" "cefqml:clipboard:";

// Installed in every document: reports copies to the host (Qt clipboard),
// since off-screen Chromium only has a process-private clipboard. Uses the
// original console.debug, captured before page scripts run.
constexpr char kClipboardScript[] = R"JS((() => {
  const log = console.debug.bind(console);
  const report = t => { if (typeof t === 'string' && t.length) log('\x01cefqml:clipboard:' + t); };
  const selected = () => {
    const el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') &&
        typeof el.selectionStart === 'number')
      return el.value.substring(el.selectionStart, el.selectionEnd);
    return String(getSelection());
  };
  for (const type of ['copy', 'cut']) {
    addEventListener(type, e => {
      report(e.defaultPrevented && e.clipboardData
             ? e.clipboardData.getData('text/plain') : selected());
    });
  }
  const cb = navigator.clipboard;
  if (cb) {
    const writeText = cb.writeText && cb.writeText.bind(cb);
    if (writeText) cb.writeText = t => { report(String(t)); return writeText(t).catch(() => {}); };
    const write = cb.write && cb.write.bind(cb);
    if (write) cb.write = async items => {
      for (const item of items || []) {
        if (item.types && item.types.includes('text/plain'))
          report(await (await item.getType('text/plain')).text());
      }
      return write(items).catch(() => {});
    };
  }
})();)JS";

// Console messages reporting whether the focused element is editable.
constexpr char kEditableMessagePrefix[] = "\x01" "cefqml:editable:";

// Installed in every document: reports focus changes to and from editable
// elements (CefWebView::editableFocused). Each frame reports its own
// transitions; a focus moving between frames blurs the old one first.
constexpr char kFocusScript[] = R"JS((() => {
  const log = console.debug.bind(console);
  const nonText = new Set(['button', 'checkbox', 'color', 'file', 'hidden', 'image',
                           'radio', 'range', 'reset', 'submit']);
  const editable = el => {
    if (!el || el.nodeType !== 1) return document.designMode === 'on';
    if (el.isContentEditable) return true;
    switch (el.localName) {
      case 'textarea': return !el.readOnly && !el.disabled;
      case 'input': return !nonText.has(el.type) && !el.readOnly && !el.disabled;
      case 'select': return !el.disabled;
    }
    return document.designMode === 'on';
  };
  let last = false;
  const report = on => {
    if (on === last) return;
    last = on;
    log('\x01cefqml:editable:' + (on ? '1' : '0'));
  };
  addEventListener('focusin', e => report(editable(e.composedPath()[0])), true);
  addEventListener('focusout', e => report(!!e.relatedTarget && editable(e.relatedTarget)), true);
})();)JS";

CefString cefstr(const QString& s) {
  return CefString(s.toStdU16String());
}

class TextureNode : public QSGSimpleTextureNode {
 public:
  TextureNode() { setFiltering(QSGTexture::Linear); }
  ~TextureNode() override { delete texture(); }

  void setImage(QQuickWindow* window, const QImage& image, bool opaque) {
    QQuickWindow::CreateTextureOptions opts;
    if (opaque)
      opts |= QQuickWindow::TextureIsOpaque;
    QSGTexture* old = texture();
    setTexture(window->createTextureFromImage(image, opts));
    delete old;
  }
};

class RootNode : public QSGNode {
 public:
  TextureNode* view = nullptr;
  TextureNode* popup = nullptr;
};

QString qstr(const CefString& s) {
  return QString::fromStdU16String(s.ToString16());
}

constexpr double kZoomBase = 1.2;  // Chromium: factor = 1.2 ^ level

Qt::CursorShape cursorShape(int type) {
  switch (type) {
    case CT_CROSS: return Qt::CrossCursor;
    case CT_HAND: return Qt::PointingHandCursor;
    case CT_IBEAM:
    case CT_VERTICALTEXT: return Qt::IBeamCursor;
    case CT_WAIT: return Qt::WaitCursor;
    case CT_HELP: return Qt::WhatsThisCursor;
    case CT_EASTRESIZE:
    case CT_WESTRESIZE:
    case CT_EASTWESTRESIZE:
    case CT_COLUMNRESIZE:
    case CT_EASTPANNING:
    case CT_WESTPANNING:
    case CT_MIDDLE_PANNING_HORIZONTAL: return Qt::SizeHorCursor;
    case CT_NORTHRESIZE:
    case CT_SOUTHRESIZE:
    case CT_NORTHSOUTHRESIZE:
    case CT_ROWRESIZE:
    case CT_NORTHPANNING:
    case CT_SOUTHPANNING:
    case CT_MIDDLE_PANNING_VERTICAL: return Qt::SizeVerCursor;
    case CT_NORTHEASTRESIZE:
    case CT_SOUTHWESTRESIZE:
    case CT_NORTHEASTSOUTHWESTRESIZE:
    case CT_NORTHEASTPANNING:
    case CT_SOUTHWESTPANNING: return Qt::SizeBDiagCursor;
    case CT_NORTHWESTRESIZE:
    case CT_SOUTHEASTRESIZE:
    case CT_NORTHWESTSOUTHEASTRESIZE:
    case CT_NORTHWESTPANNING:
    case CT_SOUTHEASTPANNING: return Qt::SizeFDiagCursor;
    case CT_MOVE:
    case CT_MIDDLEPANNING: return Qt::SizeAllCursor;
    case CT_PROGRESS: return Qt::BusyCursor;
    case CT_NODROP:
    case CT_NOTALLOWED:
    case CT_DND_NONE: return Qt::ForbiddenCursor;
    case CT_COPY:
    case CT_DND_COPY: return Qt::DragCopyCursor;
    case CT_ALIAS:
    case CT_DND_LINK: return Qt::DragLinkCursor;
    case CT_DND_MOVE: return Qt::DragMoveCursor;
    case CT_GRAB: return Qt::OpenHandCursor;
    case CT_GRABBING: return Qt::ClosedHandCursor;
    case CT_NONE: return Qt::BlankCursor;
    default: return Qt::ArrowCursor;
  }
}

class HistoryVisitor : public CefNavigationEntryVisitor {
 public:
  QVariantList entries;

  bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int, int) override {
    if (!entry || !entry->IsValid())
      return true;
    QVariantMap e{
        {QStringLiteral("url"), QUrl(QString::fromStdU16String(entry->GetURL().ToString16()))},
        {QStringLiteral("title"), QString::fromStdU16String(entry->GetTitle().ToString16())},
        {QStringLiteral("displayUrl"),
         QString::fromStdU16String(entry->GetDisplayURL().ToString16())},
        {QStringLiteral("httpStatusCode"), entry->GetHttpStatusCode()},
        {QStringLiteral("current"), current},
    };
    // CefBaseTime: microseconds since 1601-01-01 UTC; 0 when not completed.
    const int64_t us = entry->GetCompletionTime().val;
    if (us > 0) {
      constexpr int64_t kUnixEpochUs = INT64_C(11644473600000000);
      e.insert(QStringLiteral("time"),
               QDateTime::fromMSecsSinceEpoch((us - kUnixEpochUs) / 1000, Qt::UTC));
    }
    entries.append(e);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(HistoryVisitor);
};

// ---- DevTools frontend bridge (see "DevTools" below) ----

// Chromium's bundled DevTools frontend in "hosted" mode, told to connect
// over a WebSocket at ws://<ws>. kDevToolsShim hands that WebSocket to the
// bridge instead of the network.
constexpr char kDevToolsFrontendUrl[] =
    "devtools://devtools/bundled/devtools_app.html?ws=cefqml-devtools.invalid/page";
// Runtime.addBinding name in frontend views: frontend -> host messages.
constexpr char kDevToolsBinding[] = "cefqmlDevToolsSend";
// Installed in frontend views. Payloads to the host: "o" (a socket opens),
// "m<token> <message>", "c<token>" (the socket closes). The host answers
// through window.__cefqmlDevTools: open(token, rootSessionId),
// receive(token, [messages]) and close(token). The token is made by the
// host and only handed to the main frame, so other frames that see the
// binding cannot talk to the inspected page. Messages to the root session
// get its sessionId added here, and lose it again on the way back.
constexpr char kDevToolsShim[] = R"JS((() => {
  if (location.protocol !== 'devtools:' || window.__cefqmlDevTools) return;
  const send = window.cefqmlDevToolsSend;
  if (typeof send !== 'function') return;
  const NativeWebSocket = window.WebSocket;
  const prefix = 'ws://cefqml-devtools.invalid/';
  let socket = null;
  class BridgeSocket extends EventTarget {
    constructor(url) {
      super();
      Object.assign(this, {url, protocol: '', extensions: '', binaryType: 'blob',
                           bufferedAmount: 0, readyState: 0, onopen: null,
                           onmessage: null, onerror: null, onclose: null});
      this._token = '';
      this._root = '';
      this._suffix = '';
      if (socket) socket._closed(1000);
      socket = this;
      send('o');
    }
    _fire(event) {
      this.dispatchEvent(event);
      const handler = this['on' + event.type];
      if (typeof handler === 'function') handler.call(this, event);
    }
    _open(token, root) {
      this._token = token;
      this._root = root;
      this._suffix = ',"sessionId":"' + root + '"}';
      this.readyState = 1;
      this._fire(new Event('open'));
    }
    _message(data) {
      if (this.readyState !== 1) return;
      if (data.endsWith(this._suffix))
        data = data.slice(0, data.length - this._suffix.length) + '}';
      this._fire(new MessageEvent('message', {data}));
    }
    _closed(code) {
      if (this.readyState === 3) return;
      this.readyState = 3;
      if (socket === this) socket = null;
      this._fire(new CloseEvent('close', {code, wasClean: code === 1000}));
    }
    send(data) {
      if (this.readyState !== 1) return;
      const message = JSON.parse(data);
      if (!message.sessionId) message.sessionId = this._root;
      send('m' + this._token + ' ' + JSON.stringify(message));
    }
    close() {
      if (this.readyState >= 2) return;
      if (this._token) send('c' + this._token);
      this._closed(1000);
    }
  }
  for (const [k, v] of Object.entries({CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3}))
    BridgeSocket[k] = BridgeSocket.prototype[k] = v;
  window.WebSocket = new Proxy(NativeWebSocket, {
    construct(target, args, newTarget) {
      return String(args[0]).startsWith(prefix) ? new BridgeSocket(String(args[0]))
                                                : Reflect.construct(target, args, newTarget);
    }
  });
  Object.defineProperty(window, '__cefqmlDevTools', {value: Object.freeze({
    open(token, root) {
      if (!socket) return;
      if (socket.readyState === 0) socket._open(token, root);
      else socket._closed(1006);  // superseded: the frontend offers to reconnect
    },
    receive(token, messages) {
      if (socket && socket._token === token)
        for (const m of messages) socket._message(m);
    },
    close(token) {
      if (socket && socket._token === token) socket._closed(1006);
    },
  })});
})();)JS";

// `data` (UTF-8) as a JavaScript string literal.
QByteArray jsStringLiteral(const QByteArray& data) {
  QByteArray out;
  out.reserve(data.size() + 16);
  out += '"';
  for (const char c : data) {
    const auto u = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (u < 0x20) {
      static const char hex[] = "0123456789abcdef";
      out += "\\u00";
      out += hex[u >> 4];
      out += hex[u & 0xf];
    } else {
      out += c;
    }
  }
  out += '"';
  return out;
}

bool isProtocolToken(const QString& s) {
  if (s.isEmpty() || s.size() > 128)
    return false;
  for (const QChar c : s) {
    if (!(c.isLetterOrNumber() && c.unicode() < 128) && c != QLatin1Char('-') &&
        c != QLatin1Char('_'))
      return false;
  }
  return true;
}

}  // namespace

CefWebView::CefWebView(QQuickItem* parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
  setFlag(ItemIsFocusScope, true);
  setActiveFocusOnTab(true);
  setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton |
                          Qt::BackButton | Qt::ForwardButton);
  setAcceptHoverEvents(true);
}

CefWebView::~CefWebView() {
  dropDevTools();              // as the inspected view
  detachFromDevToolsTarget();  // as a frontend
  if (m_client) {
    m_client->detachView();
    m_client->closeBrowser(true);
  }
}

// ---- lifecycle -------------------------------------------------------------

void CefWebView::componentComplete() {
  QQuickItem::componentComplete();
  if (!m_discarded)
    createBrowser();
}

void CefWebView::setDiscarded(bool discarded) {
  if (discarded == m_discarded)
    return;
  m_discarded = discarded;
  if (discarded)
    releaseBrowser();
  else if (isComponentComplete())
    createBrowser();
  Q_EMIT discardedChanged();
}

// Closes the browser but keeps the view's identity (url, title, icon, zoom,
// mute, user scripts). DevTools calls and pending requests belonged to the
// old browser and are dropped, as when a browser closes on its own.
void CefWebView::releaseBrowser() {
  dropDevTools();
  devToolsFrontendLost();
  if (m_client) {
    m_client->detachView();
    m_client->closeBrowser(true);
    m_client = nullptr;
  }
  for (auto* r : findChildren<CefJavaScriptDialog*>(Qt::FindDirectChildrenOnly))
    delete r;
  for (auto* r : findChildren<CefPermissionRequest*>(Qt::FindDirectChildrenOnly))
    delete r;
  for (auto* r : findChildren<CefFileDialogRequest*>(Qt::FindDirectChildrenOnly))
    delete r;
  m_devToolsCallbacks.clear();
  m_devToolsQueue.clear();
  m_userScriptIds.clear();
  m_internalScriptsInstalled = false;
  m_deferredStartUrl.clear();
  m_pendingLoad.clear();
  m_bootstrapping = false;
  m_dropInitialHistoryEntry = false;
  m_historyResetInFlight = false;
  m_imeEnabled = false;
  setFlag(ItemAcceptsInputMethod, false);
  setEditableFocused(false);

  m_view = QImage();
  m_popup = QImage();
  m_popupVisible = false;
  m_popupRect = m_popupOriginalRect = QRect();
  update();

  if (m_loading) {
    m_loading = false;
    Q_EMIT loadingChanged();
  }
  if (m_loadProgress != 0) {
    m_loadProgress = 0;
    Q_EMIT loadProgressChanged();
  }
  if (m_canGoBack || m_canGoForward) {
    m_canGoBack = m_canGoForward = false;
    Q_EMIT navigationStateChanged();
  }
  cefStatusMessage(QString());
  cefTooltip(QString());
  cefFullscreen(false);
  if (m_ready) {
    m_ready = false;
    Q_EMIT readyChanged();
  }
}

void CefWebView::createBrowser() {
  if (m_client || !CefContext::instance()->ensureInitialized())
    return;

  m_client = new CefQmlClient(this);

  CefWindowInfo windowInfo;
  windowInfo.SetAsWindowless(0);

  CefBrowserSettings settings;
  settings.windowless_frame_rate = m_frameRate;
  settings.background_color =
      CefColorSetARGB(m_backgroundColor.alpha(), m_backgroundColor.red(),
                      m_backgroundColor.green(), m_backgroundColor.blue());

  QUrl start = m_url;
  if (!m_pendingHtml.isEmpty()) {
    start = QUrl(QStringLiteral("data:text/html;charset=utf-8;base64,") +
                 QString::fromLatin1(m_pendingHtml.toUtf8().toBase64()));
    m_pendingHtml.clear();
  }
  if (start.isEmpty())
    start = QUrl(QStringLiteral("about:blank"));
  // Scripts (ours and userScripts) are registered over DevTools once the
  // browser exists; hold the real first navigation until then so they apply
  // to it too.
  // Scripts only apply to documents created after they are registered, and
  // registering needs a live document; so start on about:blank, register,
  // then navigate (the about:blank entry is dropped from history after).
  m_deferredStartUrl = start;
  m_bootstrapping = true;
  start = QUrl(QStringLiteral("about:blank"));

  if (!CefBrowserHost::CreateBrowser(windowInfo, m_client, cefstr(start.toString()),
                                     settings, nullptr, nullptr)) {
    qCWarning(lcCef) << "CefBrowserHost::CreateBrowser failed";
    // No browser will ever close for this client; don't make shutdown wait.
    CefContext::instance()->unregisterClient(m_client.get());
    m_client->detachView();
    m_client = nullptr;
  }
}

// ---- DevTools ----------------------------------------------------------------
//
// A frontend view (devToolsFor set) is an ordinary browser showing Chromium's
// bundled DevTools frontend. CefBrowserHost::ShowDevTools cannot be used: in
// CEF 154 DevTools are always a Chrome-style native window (windowless
// rendering is not supported for them). Instead the frontend is bridged to
// the inspected browser in-process:
//
//   frontend page  --binding "m..."-->  frontend view  --SendDevToolsMessage-->
//   inspected browser, child session S (Target.attachToTarget to itself,
//   flatten)  --OnDevToolsMessage, ,"sessionId":"S..."}-->  inspected view
//   --ExecuteJavaScript __cefqmlDevTools.receive-->  frontend page
//
// The frontend owns session S and the child sessions it attaches from there;
// the view's own DevTools traffic (devToolsMethod, user scripts) stays on the
// browser's root session. Detaching S on close resets everything the
// frontend changed (breakpoints, pauses, overlays, enabled domains).

void CefWebView::setDevToolsFor(CefWebView* view) {
  if (view == this) {
    qmlWarning(this) << "a CefWebView cannot inspect itself";
    return;
  }
  if (view == m_devToolsFor)
    return;
  // The browser shows the previous target's frontend (or a page); a frontend
  // gets a browser of its own, set up for the bridge from the start.
  releaseBrowser();
  detachFromDevToolsTarget();
  if (view) {
    m_devToolsFor = view;
    m_devToolsTargetReady = connect(view, &CefWebView::readyChanged, this, [this] {
      if (m_devToolsFor && m_devToolsFor->m_ready && m_devToolsConnectPending)
        m_devToolsFor->devToolsConnect();
    });
    if (view->m_devToolsView)
      view->dropDevTools();  // the newest frontend wins
    view->setDevToolsView(this);
  }
  const QUrl url = view ? QUrl(QString::fromLatin1(kDevToolsFrontendUrl)) : QUrl();
  if (url != m_url) {
    m_url = url;
    Q_EMIT urlChanged();
  }
  Q_EMIT devToolsForChanged();
  if (view && isComponentComplete() && !m_discarded)
    createBrowser();
}

void CefWebView::detachFromDevToolsTarget() {
  disconnect(m_devToolsTargetReady);
  devToolsFrontendLost();
  CefWebView* target = m_devToolsFor;
  m_devToolsFor = nullptr;
  if (target && target->m_devToolsView == this) {
    target->devToolsDisconnect();
    target->setDevToolsView(nullptr);
  }
}

// The frontend document's connection is gone (browser released or closed,
// renderer crashed, view detached); a new document connects again.
void CefWebView::devToolsFrontendLost() {
  m_devToolsConnectPending = false;
  m_devToolsOutbox.clear();
  if (!m_devToolsToken.isEmpty()) {
    m_devToolsToken.clear();
    if (m_devToolsFor && m_devToolsFor->m_devToolsView == this)
      m_devToolsFor->devToolsDisconnect();
  }
  setDevToolsConnected(false);
}

void CefWebView::setDevToolsView(CefWebView* view) {
  if (m_devToolsView == view)
    return;
  m_devToolsView = view;
  m_inspectNode = 0;
  Q_EMIT devToolsChanged();
}

void CefWebView::setDevToolsConnected(bool connected) {
  if (m_devToolsConnected == connected)
    return;
  m_devToolsConnected = connected;
  Q_EMIT devToolsConnectedChanged();
}

// Inspected side: the DevTools of this view close (closeDevTools(), another
// frontend taking over, or this view's browser going away).
void CefWebView::dropDevTools() {
  CefWebView* frontend = m_devToolsView;
  if (!frontend)
    return;
  frontend->setDevToolsFor(nullptr);
  if (!CefContext::instance()->isShuttingDown())
    Q_EMIT frontend->closeRequested();
}

void CefWebView::closeDevTools() {
  dropDevTools();
}

// Frontend side: a message from the frontend page (see kDevToolsShim).
void CefWebView::devToolsBindingCalled(const QString& payload) {
  CefWebView* target = m_devToolsFor;
  if (!target || target->m_devToolsView != this || payload.isEmpty() ||
      m_url.scheme() != QLatin1String("devtools"))
    return;
  const QChar op = payload.at(0);
  if (op == QLatin1Char('o')) {
    // A (new) frontend document connects; the previous connection is dropped.
    devToolsFrontendLost();
    m_devToolsToken = QString::fromLatin1(QUuid::createUuid().toRfc4122().toHex());
    m_devToolsConnectPending = true;
    target->devToolsConnect();
    return;
  }
  const qsizetype space = payload.indexOf(QLatin1Char(' '));
  const QString token = payload.mid(1, space < 0 ? -1 : space - 1);
  if (m_devToolsToken.isEmpty() || token != m_devToolsToken)
    return;
  if (op == QLatin1Char('m') && space > 0 && m_devToolsConnected)
    target->devToolsFromFrontend(payload.mid(space + 1).toUtf8());
  else if (op == QLatin1Char('c'))
    devToolsFrontendLost();
}

// Inspected side: opens the frontend's session once both ends are ready.
void CefWebView::devToolsConnect() {
  CefWebView* frontend = m_devToolsView;
  if (!frontend || !frontend->m_devToolsConnectPending || !m_ready)
    return;  // again on readyChanged
  frontend->m_devToolsConnectPending = false;
  devToolsDisconnect();
  const int generation = m_devToolsGeneration;
  const QString token = frontend->m_devToolsToken;
  auto current = [this, generation, token] {
    return generation == m_devToolsGeneration && m_devToolsView &&
           m_devToolsView->m_devToolsToken == token;
  };
  sendDevTools(QStringLiteral("Target.getTargetInfo"), {},
               [this, current](bool ok, const QJsonValue& r) {
    if (!current())
      return;
    const QString targetId =
        r[QLatin1String("targetInfo")][QLatin1String("targetId")].toString();
    if (!ok || targetId.isEmpty()) {
      qCWarning(lcCef) << "DevTools: Target.getTargetInfo failed" << r;
      return;
    }
    sendDevTools(QStringLiteral("Target.attachToTarget"),
                 {{QStringLiteral("targetId"), targetId}, {QStringLiteral("flatten"), true}},
                 [this, current](bool ok, const QJsonValue& r) {
      const QString session = r[QLatin1String("sessionId")].toString();
      if (!current()) {
        if (ok && !session.isEmpty())
          sendDevTools(QStringLiteral("Target.detachFromTarget"),
                       {{QStringLiteral("sessionId"), session}}, nullptr);
        return;
      }
      if (!ok || !isProtocolToken(session)) {
        qCWarning(lcCef) << "DevTools: Target.attachToTarget failed" << r;
        return;
      }
      m_devToolsSession = session;
      m_devToolsSessions = {session};
      CefWebView* frontend = m_devToolsView;
      frontend->runFrontendScript(
          QStringLiteral("window.__cefqmlDevTools && __cefqmlDevTools.open('%1', '%2')")
              .arg(frontend->m_devToolsToken, session));
      frontend->setDevToolsConnected(true);
    });
  });
}

// Inspected side: ends the frontend's session.
void CefWebView::devToolsDisconnect() {
  ++m_devToolsGeneration;
  if (!m_devToolsSession.isEmpty() && m_ready && !CefContext::instance()->isShuttingDown())
    sendDevTools(QStringLiteral("Target.detachFromTarget"),
                 {{QStringLiteral("sessionId"), m_devToolsSession}}, nullptr);
  m_devToolsSession.clear();
  m_devToolsSessions.clear();
  m_devToolsOverlayEnableId = -1;
  m_devToolsOverlayReady = false;
}

// Inspected side: a protocol message from the frontend, for its sessions only.
void CefWebView::devToolsFromFrontend(const QByteArray& message) {
  if (m_devToolsSession.isEmpty())
    return;
  const QJsonObject msg = QJsonDocument::fromJson(message).object();
  const QString session = msg.value(QLatin1String("sessionId")).toString();
  if (!m_devToolsSessions.contains(session))
    return;  // never the view's own root session
  if (session == m_devToolsSession &&
      msg.value(QLatin1String("method")).toString() == QLatin1String("Overlay.enable"))
    m_devToolsOverlayEnableId = msg.value(QLatin1String("id")).toInt(-1);
  if (auto h = host())
    h->SendDevToolsMessage(message.constData(), size_t(message.size()));
}

// Inspected side: a protocol message of a child session (from CefQmlClient).
void CefWebView::cefDevToolsSessionMessage(const QString& session, const QByteArray& message) {
  CefWebView* frontend = m_devToolsView;
  if (!frontend || !m_devToolsSessions.contains(session))
    return;
  static const QByteArray attached = QByteArrayLiteral("{\"method\":\"Target.attachedToTarget\"");
  static const QByteArray detached = QByteArrayLiteral("{\"method\":\"Target.detachedFromTarget\"");
  if (message.startsWith(attached) || message.startsWith(detached)) {
    const QString child = QJsonDocument::fromJson(message)
                              .object()[QLatin1String("params")][QLatin1String("sessionId")]
                              .toString();
    if (message.startsWith(attached))
      m_devToolsSessions.insert(child);
    else if (child != m_devToolsSession)
      m_devToolsSessions.remove(child);
  }
  frontend->devToolsQueueToFrontend(message);
  if (session == m_devToolsSession && m_devToolsOverlayEnableId >= 0 &&
      message.startsWith("{\"id\":" + QByteArray::number(m_devToolsOverlayEnableId) + ',')) {
    // The frontend's overlay (and with it Elements) can now take
    // Overlay.inspectNodeRequested.
    m_devToolsOverlayEnableId = -1;
    m_devToolsOverlayReady = true;
    devToolsDeliverInspect();
  }
}

void CefWebView::inspectElementAt(qreal x, qreal y) {
  if (!m_ready || m_bootstrapping)
    return;
  // DOM.getNodeForLocation takes document coordinates in CSS pixels.
  sendDevTools(QStringLiteral("Page.getLayoutMetrics"), {},
               [this, x, y](bool ok, const QJsonValue& r) {
    if (!ok)
      return;
    const QJsonValue vp = r[QLatin1String("cssVisualViewport")];
    const double zoom = m_zoomFactor > 0 ? m_zoomFactor : 1.0;
    const QVariantMap params{
        {QStringLiteral("x"), int(std::floor(x / zoom + vp[QLatin1String("pageX")].toDouble()))},
        {QStringLiteral("y"), int(std::floor(y / zoom + vp[QLatin1String("pageY")].toDouble()))},
        {QStringLiteral("includeUserAgentShadowDOM"), false},
        {QStringLiteral("ignorePointerEventsNone"), true}};
    sendDevTools(QStringLiteral("DOM.getNodeForLocation"), params,
                 [this](bool ok, const QJsonValue& r) {
      const int node = r[QLatin1String("backendNodeId")].toInt();
      if (!ok || !node || !m_devToolsView)
        return;
      m_inspectNode = node;
      devToolsDeliverInspect();
    });
  });
}

// What Chromium's own "Inspect" does: the backend reports the node to the
// frontend's overlay, which reveals it in the Elements panel.
void CefWebView::devToolsDeliverInspect() {
  if (!m_inspectNode || !m_devToolsOverlayReady || !m_devToolsView ||
      m_devToolsSession.isEmpty())
    return;
  const QByteArray event =
      "{\"method\":\"Overlay.inspectNodeRequested\",\"params\":{\"backendNodeId\":" +
      QByteArray::number(std::exchange(m_inspectNode, 0)) + "},\"sessionId\":\"" +
      m_devToolsSession.toLatin1() + "\"}";
  m_devToolsView->devToolsQueueToFrontend(event);
}

// Frontend side: messages are batched per event loop pass.
void CefWebView::devToolsQueueToFrontend(const QByteArray& message) {
  if (m_devToolsToken.isEmpty())
    return;
  m_devToolsOutbox.append(message);
  if (m_devToolsFlushScheduled)
    return;
  m_devToolsFlushScheduled = true;
  QMetaObject::invokeMethod(this, &CefWebView::devToolsFlushToFrontend, Qt::QueuedConnection);
}

void CefWebView::devToolsFlushToFrontend() {
  m_devToolsFlushScheduled = false;
  if (m_devToolsOutbox.isEmpty() || m_devToolsToken.isEmpty())
    return;
  const auto messages = std::exchange(m_devToolsOutbox, {});
  QByteArray js = "window.__cefqmlDevTools && __cefqmlDevTools.receive('" +
                  m_devToolsToken.toLatin1() + "', [";
  for (qsizetype i = 0; i < messages.size(); ++i) {
    if (i)
      js += ',';
    js += jsStringLiteral(messages[i]);
  }
  js += "])";
  runFrontendScript(QString::fromUtf8(js));
}

void CefWebView::runFrontendScript(const QString& script) {
  if (m_client && m_client->browser())
    m_client->browser()->GetMainFrame()->ExecuteJavaScript(cefstr(script), CefString(), 0);
}

bool CefWebView::cefAllowNavigation(const QUrl& url) const {
  // A frontend view only ever shows DevTools: its binding talks to the
  // inspected page.
  if (!m_devToolsFor)
    return true;
  return url.scheme() == QLatin1String("devtools") || url == QUrl(QStringLiteral("about:blank"));
}

CefRefPtr<CefBrowserHost> CefWebView::host() const {
  if (!m_client || !m_client->browser())
    return nullptr;
  return m_client->browser()->GetHost();
}

void CefWebView::cefAfterCreated() {
  auto h = host();
  if (!h)
    return;
  if (!qFuzzyCompare(m_zoomFactor, 1.0))
    applyZoom();
  if (m_audioMuted)
    h->SetAudioMuted(true);
  h->WasHidden(!isVisible() || !m_active);
  if (hasActiveFocus())
    h->SetFocus(true);
  h->WasResized();
  m_ready = true;
  if (m_pendingLoad.isValid())
    loadInBrowser(std::exchange(m_pendingLoad, QUrl()));
  flushDevToolsQueue();
  applyUserScripts();
  Q_EMIT readyChanged();
}

void CefWebView::cefBeforeClose() {
  // Answer anything still pending: requests hold CEF callbacks, which must
  // not outlive the browser (or CefShutdown).
  for (auto* r : findChildren<CefJavaScriptDialog*>(Qt::FindDirectChildrenOnly))
    delete r;
  for (auto* r : findChildren<CefPermissionRequest*>(Qt::FindDirectChildrenOnly))
    delete r;
  for (auto* r : findChildren<CefFileDialogRequest*>(Qt::FindDirectChildrenOnly))
    delete r;
  dropDevTools();
  devToolsFrontendLost();
  m_client = nullptr;
  m_devToolsCallbacks.clear();
  m_devToolsQueue.clear();
  if (m_ready) {
    m_ready = false;
    Q_EMIT readyChanged();
  }
}

qreal CefWebView::devicePixelRatio() const {
  if (window())
    return window()->effectiveDevicePixelRatio();
  return qApp->devicePixelRatio();
}

QRect CefWebView::cefViewRect() const {
  return QRect(0, 0, std::max(1, int(std::ceil(width()))),
               std::max(1, int(std::ceil(height()))));
}

void CefWebView::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) {
  QQuickItem::geometryChange(newGeometry, oldGeometry);
  if (newGeometry.size() != oldGeometry.size()) {
    if (auto h = host())
      h->WasResized();
  }
}

void CefWebView::itemChange(ItemChange change, const ItemChangeData& value) {
  QQuickItem::itemChange(change, value);
  auto h = host();
  if (!h)
    return;
  switch (change) {
    case ItemVisibleHasChanged:
      h->WasHidden(!value.boolValue || !m_active);
      if (value.boolValue && m_active)
        applyZoom();
      break;
    case ItemSceneChange:
    case ItemDevicePixelRatioHasChanged:
      h->NotifyScreenInfoChanged();
      h->WasResized();
      break;
    default:
      break;
  }
}

// ---- rendering -------------------------------------------------------------

void CefWebView::cefPaint(bool popup, const void* buffer, int width, int height) {
  QImage& img = popup ? m_popup : m_view;
  // CEF delivers premultiplied BGRA, i.e. 0xAARRGGBB words on little endian.
  if (img.width() != width || img.height() != height)
    img = QImage(width, height, QImage::Format_ARGB32_Premultiplied);
  std::memcpy(img.bits(), buffer, size_t(width) * size_t(height) * 4);
  if (popup) {
    m_popupDirty = true;
  } else {
    m_viewDirty = true;
    m_frameCount++;
    Q_EMIT frameSwapped();
  }
  update();
}

void CefWebView::cefPopupShow(bool show) {
  m_popupVisible = show;
  if (!show) {
    m_popup = QImage();
    m_popupRect = m_popupOriginalRect = QRect();
    m_popupDirty = true;
    update();
  }
}

void CefWebView::cefPopupSize(const QRect& rect) {
  // Same clamping as cefclient: keep <select> popups inside the view.
  m_popupOriginalRect = rect;
  QRect r = rect;
  const QRect view = cefViewRect();
  r.moveLeft(std::max(0, r.x()));
  r.moveTop(std::max(0, r.y()));
  if (r.right() >= view.width())
    r.moveLeft(view.width() - r.width());
  if (r.bottom() >= view.height())
    r.moveTop(view.height() - r.height());
  r.moveLeft(std::max(0, r.x()));
  r.moveTop(std::max(0, r.y()));
  m_popupRect = r;
  update();
}

QSGNode* CefWebView::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
  auto* root = static_cast<RootNode*>(old);
  if (m_view.isNull()) {
    delete root;  // discarded: show nothing rather than a stale frame
    return nullptr;
  }
  if (!root)
    root = new RootNode;

  const qreal dpr = devicePixelRatio();
  const bool opaque = m_backgroundColor.alpha() == 255;

  if (!root->view) {
    root->view = new TextureNode;
    root->appendChildNode(root->view);
    m_viewDirty = true;
  }
  if (m_viewDirty) {
    root->view->setImage(window(), m_view, opaque);
    m_viewDirty = false;
  }
  root->view->setRect(0, 0, m_view.width() / dpr, m_view.height() / dpr);

  const bool showPopup = m_popupVisible && !m_popup.isNull() && !m_popupRect.isEmpty();
  if (showPopup) {
    if (!root->popup) {
      root->popup = new TextureNode;
      root->appendChildNode(root->popup);
      m_popupDirty = true;
    }
    if (m_popupDirty) {
      root->popup->setImage(window(), m_popup, opaque);
      m_popupDirty = false;
    }
    root->popup->setRect(m_popupRect);
  } else if (root->popup) {
    root->removeChildNode(root->popup);
    delete root->popup;
    root->popup = nullptr;
  }
  return root;
}

// ---- properties ------------------------------------------------------------

void CefWebView::loadInBrowser(const QUrl& url) {
  if (m_bootstrapping) {
    // Still on the about:blank bootstrap page: this becomes the first page.
    m_deferredStartUrl = url;
    return;
  }
  if (m_historyResetInFlight) {
    // Page.resetNavigationHistory would cancel it; load once it is done.
    m_pendingLoad = url;
    return;
  }
  if (m_client && m_client->browser())
    m_client->browser()->GetMainFrame()->LoadURL(cefstr(url.toString()));
}

void CefWebView::setUrl(const QUrl& url) {
  if (url == m_url)
    return;
  m_url = url;
  Q_EMIT urlChanged();
  if (m_client && !m_ready) {
    // Creation in flight: navigate once the browser exists.
    if (m_deferredStartUrl.isValid())
      m_deferredStartUrl = url;
    else
      m_pendingLoad = url;
    return;
  }
  loadInBrowser(url);  // before creation the URL is used as the start page
}

void CefWebView::loadHtml(const QString& html) {
  if (!m_client) {
    m_pendingHtml = html;
    return;
  }
  loadInBrowser(QUrl(QStringLiteral("data:text/html;charset=utf-8;base64,") +
                     QString::fromLatin1(html.toUtf8().toBase64())));
}

void CefWebView::setZoomFactor(double factor) {
  factor = std::clamp(factor, 0.25, 5.0);
  if (qFuzzyCompare(factor, m_zoomFactor))
    return;
  m_zoomFactor = factor;
  applyZoom();
  Q_EMIT zoomFactorChanged();
}

// Chromium keeps one zoom level per host (HostZoomMap, regardless of scheme
// and port) and applies it when a document commits; another view zooming the
// same host changes this one too. The view's own zoomFactor wins: it is
// re-applied when a document starts loading in a shown view and when the
// view is shown. Two views of one host shown at the same time still share
// the zoom of the one that applied it last.
void CefWebView::applyZoom() {
  if (auto h = host())
    h->SetZoomLevel(std::log(m_zoomFactor) / std::log(kZoomBase));
}

void CefWebView::setAudioMuted(bool muted) {
  if (muted == m_audioMuted)
    return;
  m_audioMuted = muted;
  if (auto h = host())
    h->SetAudioMuted(muted);
  Q_EMIT audioMutedChanged();
}

void CefWebView::setBackgroundColor(const QColor& color) {
  if (color == m_backgroundColor)
    return;
  if (m_client)
    qCWarning(lcCef) << "backgroundColor only applies before the browser is created";
  m_backgroundColor = color;
  Q_EMIT backgroundColorChanged();
}

void CefWebView::setFrameRate(int fps) {
  fps = std::clamp(fps, 1, 240);
  if (fps == m_frameRate)
    return;
  m_frameRate = fps;
  if (auto h = host())
    h->SetWindowlessFrameRate(fps);
  Q_EMIT frameRateChanged();
}

void CefWebView::setActive(bool active) {
  if (active == m_active)
    return;
  m_active = active;
  if (auto h = host()) {
    h->WasHidden(!isVisible() || !active);
    if (active && isVisible())
      applyZoom();
  }
  Q_EMIT activeChanged();
}

void CefWebView::goBack() {
  if (m_client && m_client->browser())
    m_client->browser()->GoBack();
}

void CefWebView::goForward() {
  if (m_client && m_client->browser())
    m_client->browser()->GoForward();
}

void CefWebView::reload() {
  if (m_discarded) {
    setDiscarded(false);
    return;
  }
  if (m_client && m_client->browser())
    m_client->browser()->Reload();
}

void CefWebView::reloadIgnoringCache() {
  if (m_discarded) {
    setDiscarded(false);
    return;
  }
  if (m_client && m_client->browser())
    m_client->browser()->ReloadIgnoreCache();
}

QVariantList CefWebView::navigationHistory() const {
  auto h = host();
  if (!h || m_bootstrapping)
    return {};
  CefRefPtr<HistoryVisitor> visitor = new HistoryVisitor;
  h->GetNavigationEntries(visitor, false);  // visits synchronously
  QVariantList entries = std::move(visitor->entries);
  // The about:blank bootstrap entry, until it is reset away.
  if (m_dropInitialHistoryEntry && entries.size() > 1 &&
      entries.first().toMap().value(QStringLiteral("url")).toUrl() ==
          QUrl(QStringLiteral("about:blank")))
    entries.removeFirst();
  return entries;
}

bool CefWebView::goToHistoryEntry(int index) {
  const QVariantList entries = navigationHistory();
  if (index < 0 || index >= entries.size())
    return false;
  const int count = int(entries.size());
  // DevTools lists the same entries (possibly with the bootstrap one in
  // front): match from the end.
  sendDevTools(QStringLiteral("Page.getNavigationHistory"), {},
               [this, index, count](bool ok, const QJsonValue& r) {
                 if (!ok)
                   return;
                 const QJsonObject obj = r.toObject();
                 const QJsonArray all = obj.value(QStringLiteral("entries")).toArray();
                 const int i = int(all.size()) - count + index;
                 if (i < 0 || i >= all.size() ||
                     i == obj.value(QStringLiteral("currentIndex")).toInt(-1))
                   return;
                 sendDevTools(QStringLiteral("Page.navigateToHistoryEntry"),
                              {{QStringLiteral("entryId"),
                                all.at(i).toObject().value(QStringLiteral("id")).toInt()}},
                              nullptr);
               });
  return true;
}

void CefWebView::stop() {
  if (m_client && m_client->browser())
    m_client->browser()->StopLoad();
}

void CefWebView::runJavaScript(const QString& script) {
  if (m_client && m_client->browser()) {
    auto frame = m_client->browser()->GetMainFrame();
    frame->ExecuteJavaScript(cefstr(script), frame->GetURL(), 0);
  }
}

// ---- DevTools / scripting --------------------------------------------------

int CefWebView::sendDevTools(const QString& method, const QVariantMap& params,
                             DevToolsCallback cb) {
  const int id = m_nextDevToolsId++;
  QJsonObject msg{{QStringLiteral("id"), id}, {QStringLiteral("method"), method}};
  if (!params.isEmpty())
    msg.insert(QStringLiteral("params"), QJsonObject::fromVariantMap(params));
  const QByteArray json = QJsonDocument(msg).toJson(QJsonDocument::Compact);
  if (cb)
    m_devToolsCallbacks.insert(id, std::move(cb));

  if (!m_ready) {
    m_devToolsQueue.append({id, json});
    return id;
  }
  auto h = host();
  if (!h || !h->SendDevToolsMessage(json.constData(), size_t(json.size()))) {
    if (auto failed = m_devToolsCallbacks.take(id))
      failed(false, QJsonObject{{QStringLiteral("message"), QStringLiteral("browser closed")}});
  }
  return id;
}

void CefWebView::flushDevToolsQueue() {
  const auto queue = std::exchange(m_devToolsQueue, {});
  auto h = host();
  for (const auto& p : queue) {
    if (!h || !h->SendDevToolsMessage(p.message.constData(), size_t(p.message.size()))) {
      if (auto failed = m_devToolsCallbacks.take(p.id))
        failed(false, QJsonObject{{QStringLiteral("message"), QStringLiteral("browser closed")}});
    }
  }
}

void CefWebView::cefDevToolsResult(int id, bool success, const QByteArray& json) {
  auto cb = m_devToolsCallbacks.take(id);
  if (!cb)
    return;
  const QJsonDocument doc = QJsonDocument::fromJson(json);
  cb(success, doc.isObject() ? QJsonValue(doc.object()) : QJsonValue(doc.array()));
}

void CefWebView::cefDevToolsEvent(const QString& method, const QByteArray& json) {
  if (m_devToolsFor && method == QLatin1String("Runtime.bindingCalled")) {
    const QJsonObject params = QJsonDocument::fromJson(json).object();
    if (params.value(QLatin1String("name")).toString() == QLatin1String(kDevToolsBinding)) {
      devToolsBindingCalled(params.value(QLatin1String("payload")).toString());
      return;
    }
  }
  static const QMetaMethod sig = QMetaMethod::fromSignal(&CefWebView::devToolsEvent);
  if (isSignalConnected(sig))
    Q_EMIT devToolsEvent(method, QJsonDocument::fromJson(json).toVariant());
}

bool CefWebView::cefConsoleMessage(const QString& message) {
  if (!message.startsWith(QChar(1)))
    return false;
  static const QString clipboard = QString::fromLatin1(kClipboardMessagePrefix);
  static const QString editable = QString::fromLatin1(kEditableMessagePrefix);
  if (message.startsWith(clipboard)) {
    QGuiApplication::clipboard()->setText(message.mid(clipboard.size()));
    return true;
  }
  if (message.startsWith(editable)) {
    setEditableFocused(message.mid(editable.size()) == QLatin1String("1"));
    return true;
  }
  return false;
}

void CefWebView::setEditableFocused(bool focused) {
  if (focused == m_editableFocused)
    return;
  m_editableFocused = focused;
  Q_EMIT editableFocusedChanged();
}

void CefWebView::pasteFromSystemClipboard() {
  const QString text = QGuiApplication::clipboard()->text();
  if (text.isEmpty()) {
    if (m_client && m_client->browser())
      if (auto f = m_client->browser()->GetFocusedFrame())
        f->Paste();
    return;
  }
  // Give the page a real paste event first; insert the text if it does not
  // handle it.
  const QString literal = QString::fromUtf8(
      QJsonDocument(QJsonArray{text}).toJson(QJsonDocument::Compact));
  runJavaScript(QStringLiteral(
      "(t => { t = t[0]; const el = document.activeElement || document.body;"
      " let dt = null; try { dt = new DataTransfer(); dt.setData('text/plain', t); } catch (e) {}"
      " const ev = new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true});"
      " if (el.dispatchEvent(ev)) document.execCommand('insertText', false, t); })(%1)")
                    .arg(literal));
}

void CefWebView::callJs(const QJSValue& callback, const QVariant& result,
                        const QString& error) {
  if (!callback.isCallable())
    return;
  QJSEngine* engine = qjsEngine(this);
  if (!engine)
    return;
  const QJSValue undefined(QJSValue::UndefinedValue);
  QJSValue fn = callback;
  const QJSValue ret = fn.call({result.isValid() ? engine->toScriptValue(result) : undefined,
                               error.isEmpty() ? undefined : QJSValue(error)});
  if (ret.isError())
    qCWarning(lcCef) << "callback threw:" << ret.toString();
}

int CefWebView::devToolsMethod(const QString& method, const QVariantMap& params,
                               const QJSValue& callback) {
  DevToolsCallback cb;
  if (callback.isCallable()) {
    cb = [this, callback](bool ok, const QJsonValue& result) {
      if (ok)
        callJs(callback, result.toVariant(), QString());
      else
        callJs(callback, QVariant(),
               result.toObject().value(QStringLiteral("message")).toString(
                   QStringLiteral("DevTools call failed")));
    };
  }
  return sendDevTools(method, params, std::move(cb));
}

void CefWebView::evaluateJavaScript(const QString& script, const QJSValue& callback) {
  const QVariantMap params{
      {QStringLiteral("expression"), script},
      {QStringLiteral("returnByValue"), true},
      {QStringLiteral("awaitPromise"), true},
      {QStringLiteral("userGesture"), true},
  };
  sendDevTools(QStringLiteral("Runtime.evaluate"), params,
               [this, callback](bool ok, const QJsonValue& result) {
                 const QJsonObject obj = result.toObject();
                 if (!ok) {
                   callJs(callback, QVariant(),
                          obj.value(QStringLiteral("message")).toString(
                              QStringLiteral("evaluation failed")));
                   return;
                 }
                 if (obj.contains(QStringLiteral("exceptionDetails"))) {
                   const QJsonObject ex = obj.value(QStringLiteral("exceptionDetails")).toObject();
                   QString msg = ex.value(QStringLiteral("exception"))
                                     .toObject()
                                     .value(QStringLiteral("description"))
                                     .toString();
                   if (msg.isEmpty())
                     msg = ex.value(QStringLiteral("text")).toString();
                   callJs(callback, QVariant(), msg);
                   return;
                 }
                 const QJsonObject r = obj.value(QStringLiteral("result")).toObject();
                 QVariant value;
                 if (r.contains(QStringLiteral("value")))
                   value = r.value(QStringLiteral("value")).toVariant();
                 if (!value.isValid() && r.value(QStringLiteral("type")).toString() != QLatin1String("undefined"))
                   value = QVariant::fromValue(nullptr);
                 callJs(callback, value, QString());
               });
}

void CefWebView::setUserScripts(const QStringList& scripts) {
  if (scripts == m_userScripts)
    return;
  m_userScripts = scripts;
  if (m_ready)
    applyUserScripts();
  Q_EMIT userScriptsChanged();
}

void CefWebView::applyUserScripts() {
  for (const QString& id : std::as_const(m_userScriptIds)) {
    sendDevTools(QStringLiteral("Page.removeScriptToEvaluateOnNewDocument"),
                 {{QStringLiteral("identifier"), id}}, nullptr);
  }
  m_userScriptIds.clear();

  // Scripts only take effect while the Page domain is enabled.
  if (!m_internalScriptsInstalled) {
    m_internalScriptsInstalled = true;
    sendDevTools(QStringLiteral("Page.enable"), {}, nullptr);
    sendDevTools(QStringLiteral("Page.addScriptToEvaluateOnNewDocument"),
                 {{QStringLiteral("source"), QString::fromUtf8(kClipboardScript)}}, nullptr);
    sendDevTools(QStringLiteral("Page.addScriptToEvaluateOnNewDocument"),
                 {{QStringLiteral("source"), QString::fromUtf8(kFocusScript)}}, nullptr);
    if (m_devToolsFor) {
      // Bindings only reach new documents (here: the frontend, in its own
      // process) while the Runtime domain is enabled.
      sendDevTools(QStringLiteral("Runtime.enable"), {}, nullptr);
      sendDevTools(QStringLiteral("Runtime.addBinding"),
                   {{QStringLiteral("name"), QString::fromLatin1(kDevToolsBinding)}}, nullptr);
      sendDevTools(QStringLiteral("Page.addScriptToEvaluateOnNewDocument"),
                   {{QStringLiteral("source"), QString::fromUtf8(kDevToolsShim)}}, nullptr);
    }
  }
  for (const QString& source : std::as_const(m_userScripts)) {
    sendDevTools(QStringLiteral("Page.addScriptToEvaluateOnNewDocument"),
                 {{QStringLiteral("source"), source}},
                 [this](bool ok, const QJsonValue& r) {
                   if (ok)
                     m_userScriptIds << r.toObject().value(QStringLiteral("identifier")).toString();
                   else
                     qCWarning(lcCef) << "failed to install user script" << r;
                 });
  }

  if (!m_deferredStartUrl.isValid())
    return;
  // Replies come back in order: once this one arrives, everything above is
  // registered and the real first page can load.
  sendDevTools(QStringLiteral("Page.enable"), {}, [this](bool, const QJsonValue&) {
    if (!m_deferredStartUrl.isValid())
      return;
    m_dropInitialHistoryEntry = true;
    m_bootstrapping = false;
    loadInBrowser(std::exchange(m_deferredStartUrl, QUrl()));
  });
}

void CefWebView::find(const QString& text, bool forward, bool matchCase) {
  auto h = host();
  if (!h)
    return;
  if (text.isEmpty()) {
    stopFinding(true);
    return;
  }
  const bool findNext = text == m_lastFind;
  m_lastFind = text;
  h->Find(cefstr(text), forward, matchCase, findNext);
}

void CefWebView::stopFinding(bool clearSelection) {
  m_lastFind.clear();
  if (auto h = host())
    h->StopFinding(clearSelection);
}

#define CEF_QML_EDIT_COMMAND(name, cefName)                         \
  void CefWebView::name() {                                         \
    if (m_client && m_client->browser())                            \
      if (auto f = m_client->browser()->GetFocusedFrame())          \
        f->cefName();                                               \
  }
CEF_QML_EDIT_COMMAND(copy, Copy)
CEF_QML_EDIT_COMMAND(cut, Cut)
CEF_QML_EDIT_COMMAND(selectAll, SelectAll)
CEF_QML_EDIT_COMMAND(undo, Undo)
CEF_QML_EDIT_COMMAND(redo, Redo)
#undef CEF_QML_EDIT_COMMAND

// ---- CEF -> QML state ------------------------------------------------------

// Load events of the about:blank bootstrap page are internal. Its late
// events can still arrive after bootstrapping ended, until the first real
// page starts loading (m_dropInitialHistoryEntry is still set then).
bool CefWebView::isBootstrapLoad(const QUrl& url) const {
  return m_bootstrapping ||
         (m_dropInitialHistoryEntry && url == QUrl(QStringLiteral("about:blank")));
}

void CefWebView::cefLoadEnd(const QUrl& url, int httpStatusCode) {
  updateSecurity();
  if (!isBootstrapLoad(url))
    Q_EMIT loadFinished(url, httpStatusCode);
}

void CefWebView::cefBeforeBrowse(const QUrl& url, bool userGesture, bool isRedirect) {
  if (m_bootstrapping && url == QUrl(QStringLiteral("about:blank")))
    return;
  Q_EMIT navigationRequested(url, userGesture, isRedirect);
}

void CefWebView::updateSecurity() {
  bool secure = false;
  QVariantMap cert;
  CefRefPtr<CefNavigationEntry> entry;
  if (auto h = host())
    entry = h->GetVisibleNavigationEntry();
  CefRefPtr<CefSSLStatus> ssl = entry ? entry->GetSSLStatus() : nullptr;
  if (ssl && ssl->IsSecureConnection()) {
    static const std::pair<int, const char*> kErrors[] = {
        {CERT_STATUS_COMMON_NAME_INVALID, "common-name-invalid"},
        {CERT_STATUS_DATE_INVALID, "date-invalid"},
        {CERT_STATUS_AUTHORITY_INVALID, "authority-invalid"},
        {CERT_STATUS_REVOKED, "revoked"},
        {CERT_STATUS_INVALID, "invalid"},
        {CERT_STATUS_WEAK_SIGNATURE_ALGORITHM, "weak-signature-algorithm"},
        {CERT_STATUS_NON_UNIQUE_NAME, "non-unique-name"},
        {CERT_STATUS_WEAK_KEY, "weak-key"},
        {CERT_STATUS_PINNED_KEY_MISSING, "pinned-key-missing"},
        {CERT_STATUS_NAME_CONSTRAINT_VIOLATION, "name-constraint-violation"},
        {CERT_STATUS_VALIDITY_TOO_LONG, "validity-too-long"},
        {CERT_STATUS_CT_COMPLIANCE_FAILED, "ct-compliance-failed"},
    };
    const int status = ssl->GetCertStatus();
    QStringList errors;
    for (const auto& [bit, name] : kErrors) {
      if (status & bit)
        errors << QString::fromLatin1(name);
    }
    const bool mixed = ssl->GetContentStatus() != SSL_CONTENT_NORMAL_CONTENT;
    cert.insert(QStringLiteral("errors"), errors);
    cert.insert(QStringLiteral("mixedContent"), mixed);
    static const std::pair<cef_ssl_version_t, const char*> kVersions[] = {
        {SSL_CONNECTION_VERSION_TLS1, "TLS 1.0"},   {SSL_CONNECTION_VERSION_TLS1_1, "TLS 1.1"},
        {SSL_CONNECTION_VERSION_TLS1_2, "TLS 1.2"}, {SSL_CONNECTION_VERSION_TLS1_3, "TLS 1.3"},
        {SSL_CONNECTION_VERSION_QUIC, "QUIC"},
    };
    for (const auto& [v, name] : kVersions) {
      if (ssl->GetSSLVersion() == v)
        cert.insert(QStringLiteral("protocol"), QString::fromLatin1(name));
    }
    if (auto x509 = ssl->GetX509Certificate()) {
      auto principal = [](CefRefPtr<CefX509CertPrincipal> p) {
        if (!p)
          return QString();
        const QString cn = qstr(p->GetCommonName());
        return cn.isEmpty() ? qstr(p->GetDisplayName()) : cn;
      };
      cert.insert(QStringLiteral("subject"), principal(x509->GetSubject()));
      cert.insert(QStringLiteral("issuer"), principal(x509->GetIssuer()));
      if (auto subject = x509->GetSubject()) {
        std::vector<CefString> orgs;
        subject->GetOrganizationNames(orgs);
        if (!orgs.empty())
          cert.insert(QStringLiteral("organization"), qstr(orgs.front()));
      }
      auto date = [](const CefBaseTime& t) {
        // CefBaseTime: microseconds since 1601-01-01 UTC.
        constexpr qint64 kEpochDeltaUs = 11644473600LL * 1000000LL;
        return QDateTime::fromMSecsSinceEpoch((t.val - kEpochDeltaUs) / 1000, Qt::UTC);
      };
      cert.insert(QStringLiteral("validFrom"), date(x509->GetValidStart()));
      cert.insert(QStringLiteral("validTo"), date(x509->GetValidExpiry()));
    }
    const QString scheme = m_url.scheme();
    secure = errors.isEmpty() && !mixed &&
             (scheme == QLatin1String("https") || scheme == QLatin1String("wss"));
  }
  if (secure == m_secure && cert == m_certificate)
    return;
  m_secure = secure;
  m_certificate = cert;
  Q_EMIT securityChanged();
}

void CefWebView::cefLoadError(int errorCode, const QString& errorText, const QUrl& failedUrl) {
  if (!m_bootstrapping)
    Q_EMIT loadFailed(errorCode, errorText, failedUrl);
}

void CefWebView::cefLoadStart(const QUrl& url) {
  const bool internal = isBootstrapLoad(url);
  resetInitialHistory();
  // A hidden view re-applies its zoom when shown: applying it now would
  // also change the visible view of the same host.
  if (isVisible() && m_active)
    applyZoom();
  updateSecurity();
  // The new document reports its own focus; the old one may not have blurred.
  setEditableFocused(false);
  // After the history bookkeeping, so that a handler may navigate right away.
  if (!internal)
    Q_EMIT loadStarted(url);
}

void CefWebView::resetInitialHistory() {
  if (!m_dropInitialHistoryEntry || m_bootstrapping)
    return;
  // The first real page has committed: forget the about:blank bootstrap
  // entry so it cannot be navigated back to.
  m_dropInitialHistoryEntry = false;
  m_historyResetInFlight = true;
  sendDevTools(QStringLiteral("Page.resetNavigationHistory"), {},
               [this](bool, const QJsonValue&) {
                 m_historyResetInFlight = false;
                                if (m_pendingLoad.isValid())
                   loadInBrowser(std::exchange(m_pendingLoad, QUrl()));
                 if (m_client && m_client->browser()) {
                   auto b = m_client->browser();
                   cefLoadingStateChange(m_loading, b->CanGoBack(), b->CanGoForward());
                 }
               });
}

void CefWebView::cefAddressChange(const QUrl& url) {
  if (m_bootstrapping)
    return;
  if (url == m_url)
    return;
  m_url = url;
  Q_EMIT urlChanged();
}

void CefWebView::setTitle(const QString& title) {
  if (title == m_title)
    return;
  m_title = title;
  Q_EMIT titleChanged();
}

void CefWebView::setIcon(const QUrl& icon) {
  if (icon == m_icon)
    return;
  m_icon = icon;
  Q_EMIT iconChanged();
}

void CefWebView::cefTitleChange(const QString& title) {
  if (m_bootstrapping)
    return;
  if (title == m_title)
    return;
  m_title = title;
  Q_EMIT titleChanged();
}

void CefWebView::cefIconChange(const QUrl& icon) {
  if (m_bootstrapping || icon == m_icon)
    return;
  m_icon = icon;
  Q_EMIT iconChanged();
}

void CefWebView::cefLoadingStateChange(bool loading, bool canGoBack, bool canGoForward) {
  if (m_bootstrapping)
    return;  // about:blank bootstrap page, see createBrowser()
  if (m_dropInitialHistoryEntry)
    canGoBack = false;
  if (loading != m_loading) {
    m_loading = loading;
    if (!loading)
      updateSecurity();
    Q_EMIT loadingChanged();
  }
  if (canGoBack != m_canGoBack || canGoForward != m_canGoForward) {
    m_canGoBack = canGoBack;
    m_canGoForward = canGoForward;
    Q_EMIT navigationStateChanged();
  }
}

void CefWebView::cefLoadProgress(double progress) {
  if (qFuzzyCompare(progress, m_loadProgress))
    return;
  m_loadProgress = progress;
  Q_EMIT loadProgressChanged();
}

void CefWebView::cefStatusMessage(const QString& message) {
  if (message == m_hoveredUrl)
    return;
  m_hoveredUrl = message;
  Q_EMIT hoveredUrlChanged();
}

void CefWebView::cefTooltip(const QString& text) {
  if (text == m_tooltip)
    return;
  m_tooltip = text;
  Q_EMIT tooltipChanged();
}

void CefWebView::cefCursor(int type) {
  setCursor(QCursor(cursorShape(type)));
}

void CefWebView::cefFullscreen(bool fullscreen) {
  if (fullscreen == m_fullscreen)
    return;
  m_fullscreen = fullscreen;
  Q_EMIT fullscreenChanged();
}

void CefWebView::cefTextInputMode(bool editable) {
  if (editable == m_imeEnabled)
    return;
  m_imeEnabled = editable;
  setFlag(ItemAcceptsInputMethod, editable);
  if (hasActiveFocus())
    QGuiApplication::inputMethod()->update(Qt::ImEnabled | Qt::ImHints);
}

void CefWebView::cefImeBounds(const QRect& bounds) {
  m_imeBounds = bounds;
  if (hasActiveFocus())
    QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
}

// ---- input -----------------------------------------------------------------

QPoint CefWebView::toBrowser(QPointF pos) const {
  QPoint p(int(std::floor(pos.x())), int(std::floor(pos.y())));
  if (m_popupVisible && m_popupRect.contains(p))
    p += m_popupOriginalRect.topLeft() - m_popupRect.topLeft();
  return p;
}

void CefWebView::forwardMouseButton(QMouseEvent* event, bool up, int clickCount) {
  auto h = host();
  if (!h)
    return;
  CefBrowserHost::MouseButtonType type;
  switch (event->button()) {
    case Qt::LeftButton: type = MBT_LEFT; break;
    case Qt::MiddleButton: type = MBT_MIDDLE; break;
    case Qt::RightButton: type = MBT_RIGHT; break;
    default: return;
  }
  CefMouseEvent ev;
  const QPoint p = toBrowser(event->position());
  ev.x = p.x();
  ev.y = p.y();
  // On release the button is no longer in buttons(); Chromium still expects
  // the flag for the button being released.
  ev.modifiers = cefModifiers(event->modifiers(), event->buttons() | event->button());
  h->SendMouseClickEvent(ev, type, up, clickCount);
}

void CefWebView::mousePressEvent(QMouseEvent* event) {
  if (event->button() == Qt::BackButton) {
    goBack();
    event->accept();
    return;
  }
  if (event->button() == Qt::ForwardButton) {
    goForward();
    event->accept();
    return;
  }
  if (!hasActiveFocus())
    forceActiveFocus(Qt::MouseFocusReason);
  m_clickCount = 1;
  forwardMouseButton(event, false, m_clickCount);
  event->accept();
}

void CefWebView::mouseDoubleClickEvent(QMouseEvent* event) {
  m_clickCount = 2;
  forwardMouseButton(event, false, m_clickCount);
  event->accept();
}

void CefWebView::mouseReleaseEvent(QMouseEvent* event) {
  forwardMouseButton(event, true, m_clickCount);
  event->accept();
}

void CefWebView::mouseMoveEvent(QMouseEvent* event) {
  if (auto h = host()) {
    CefMouseEvent ev;
    const QPoint p = toBrowser(event->position());
    ev.x = p.x();
    ev.y = p.y();
    ev.modifiers = cefModifiers(event->modifiers(), event->buttons());
    h->SendMouseMoveEvent(ev, false);
  }
  event->accept();
}

void CefWebView::mouseUngrabEvent() {
  if (auto h = host())
    h->SendCaptureLostEvent();
}

void CefWebView::hoverEnterEvent(QHoverEvent* event) {
  hoverMoveEvent(event);
}

void CefWebView::hoverMoveEvent(QHoverEvent* event) {
  if (auto h = host()) {
    CefMouseEvent ev;
    const QPoint p = toBrowser(event->position());
    ev.x = p.x();
    ev.y = p.y();
    ev.modifiers = cefModifiers(event->modifiers(), Qt::NoButton);
    h->SendMouseMoveEvent(ev, false);
  }
  event->accept();
}

void CefWebView::hoverLeaveEvent(QHoverEvent* event) {
  if (auto h = host()) {
    CefMouseEvent ev;
    const QPoint p = toBrowser(event->position());
    ev.x = p.x();
    ev.y = p.y();
    ev.modifiers = cefModifiers(event->modifiers(), Qt::NoButton);
    h->SendMouseMoveEvent(ev, true);
  }
  event->accept();
}

void CefWebView::wheelEvent(QWheelEvent* event) {
  auto h = host();
  if (!h) {
    event->ignore();
    return;
  }
  CefMouseEvent ev;
  const QPoint p = toBrowser(event->position());
  ev.x = p.x();
  ev.y = p.y();
  ev.modifiers = cefModifiers(event->modifiers(), event->buttons());
  // angleDelta is 120 per notch, which is also what Chromium expects from a
  // wheel (WHEEL_DELTA); touchpads report pixel deltas.
  QPoint delta = event->pixelDelta();
  if (delta.isNull())
    delta = event->angleDelta();
  else
    ev.modifiers |= EVENTFLAG_PRECISION_SCROLLING_DELTA;
  h->SendMouseWheelEvent(ev, delta.x(), delta.y());
  event->accept();
}

void CefWebView::paste() {
  pasteFromSystemClipboard();
}

void CefWebView::sendMouseMove(qreal x, qreal y, int modifiers) {
  auto h = host();
  if (!h)
    return;
  CefMouseEvent ev;
  const QPoint p = toBrowser(QPointF(x, y));
  ev.x = p.x();
  ev.y = p.y();
  ev.modifiers = cefModifiers(Qt::KeyboardModifiers(modifiers), Qt::NoButton);
  h->SendMouseMoveEvent(ev, false);
}

void CefWebView::sendMouseClick(qreal x, qreal y, int button, int modifiers, int clickCount) {
  auto h = host();
  if (!h)
    return;
  CefBrowserHost::MouseButtonType type;
  switch (button) {
    case Qt::LeftButton: type = MBT_LEFT; break;
    case Qt::MiddleButton: type = MBT_MIDDLE; break;
    case Qt::RightButton: type = MBT_RIGHT; break;
    default:
      qCWarning(lcCef) << "sendMouseClick: unsupported button" << button;
      return;
  }
  if (!hasActiveFocus())
    forceActiveFocus(Qt::MouseFocusReason);
  sendMouseMove(x, y, modifiers);
  CefMouseEvent ev;
  const QPoint p = toBrowser(QPointF(x, y));
  ev.x = p.x();
  ev.y = p.y();
  const auto mods = Qt::KeyboardModifiers(modifiers);
  for (int i = 1; i <= std::max(1, clickCount); ++i) {
    ev.modifiers = cefModifiers(mods, Qt::MouseButton(button));
    h->SendMouseClickEvent(ev, type, false, i);
    h->SendMouseClickEvent(ev, type, true, i);
  }
}

void CefWebView::sendMouseWheel(qreal x, qreal y, int deltaX, int deltaY, int modifiers,
                                bool pixels) {
  auto h = host();
  if (!h)
    return;
  CefMouseEvent ev;
  const QPoint p = toBrowser(QPointF(x, y));
  ev.x = p.x();
  ev.y = p.y();
  ev.modifiers = cefModifiers(Qt::KeyboardModifiers(modifiers), Qt::NoButton);
  if (pixels)
    ev.modifiers |= EVENTFLAG_PRECISION_SCROLLING_DELTA;
  h->SendMouseWheelEvent(ev, deltaX, deltaY);
}

void CefWebView::sendKey(int key, int modifiers, const QString& text) {
  const auto mods = Qt::KeyboardModifiers(modifiers);
  QString t = text;
  if (t.isNull() && key >= Qt::Key_Space && key <= Qt::Key_AsciiTilde &&
      !(mods & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))) {
    const QChar c(key);
    t = (mods & Qt::ShiftModifier) ? QString(c.toUpper()) : QString(c.toLower());
  }
  // Through the same path as real key events (paste handling, char events).
  QKeyEvent press(QEvent::KeyPress, key, mods, t);
  keyPressEvent(&press);
  QKeyEvent release(QEvent::KeyRelease, key, mods, t);
  keyReleaseEvent(&release);
}

void CefWebView::keyPressEvent(QKeyEvent* event) {
  auto h = host();
  if (!h) {
    event->ignore();
    return;
  }
  if (event->matches(QKeySequence::Paste) ||
      (event->key() == Qt::Key_V &&
       event->modifiers() == (Qt::ControlModifier | Qt::ShiftModifier))) {
    pasteFromSystemClipboard();
    event->accept();
    return;
  }
  CefKeyEvent ev;
  ev.windows_key_code = qtKeyToWindowsKeyCode(event->key(), event->modifiers());
  ev.native_key_code = int(event->nativeScanCode());
  ev.modifiers = cefModifiers(event->modifiers(), Qt::NoButton);
  if (event->isAutoRepeat())
    ev.modifiers |= EVENTFLAG_IS_REPEAT;

  const QString text = event->text();
  const char16_t ch = text.isEmpty() ? 0 : char16_t(text.at(0).unicode());
  ev.character = ch;
  ev.unmodified_character = ch;
  ev.type = KEYEVENT_RAWKEYDOWN;
  h->SendKeyEvent(ev);

  // Ctrl+<key> produces control characters in Qt; Chromium handles those
  // shortcuts from the RAWKEYDOWN alone. AltGr (Ctrl+Alt) still types.
  const auto mods = event->modifiers();
  const bool ctrlShortcut = (mods & Qt::ControlModifier) && !(mods & Qt::AltModifier);
  if (!text.isEmpty() && !ctrlShortcut) {
    ev.type = KEYEVENT_CHAR;
    for (QChar c : text) {
      ev.character = char16_t(c.unicode());
      ev.unmodified_character = ev.character;
      h->SendKeyEvent(ev);
    }
  }
  event->accept();
}

void CefWebView::keyReleaseEvent(QKeyEvent* event) {
  auto h = host();
  if (!h) {
    event->ignore();
    return;
  }
  CefKeyEvent ev;
  ev.type = KEYEVENT_KEYUP;
  ev.windows_key_code = qtKeyToWindowsKeyCode(event->key(), event->modifiers());
  ev.native_key_code = int(event->nativeScanCode());
  ev.modifiers = cefModifiers(event->modifiers(), Qt::NoButton);
  const QString text = event->text();
  ev.character = text.isEmpty() ? 0 : char16_t(text.at(0).unicode());
  ev.unmodified_character = ev.character;
  h->SendKeyEvent(ev);
  event->accept();
}

void CefWebView::inputMethodEvent(QInputMethodEvent* event) {
  auto h = host();
  if (!h) {
    event->ignore();
    return;
  }
  if (!event->commitString().isEmpty()) {
    h->ImeCommitText(cefstr(event->commitString()), CefRange::InvalidRange(), 0);
  } else if (!event->preeditString().isEmpty()) {
    int cursor = int(event->preeditString().size());
    for (const auto& a : event->attributes()) {
      if (a.type == QInputMethodEvent::Cursor)
        cursor = a.start;
    }
    h->ImeSetComposition(cefstr(event->preeditString()), {},
                         CefRange::InvalidRange(), CefRange(uint32_t(cursor), uint32_t(cursor)));
  } else {
    h->ImeCancelComposition();
  }
  event->accept();
}

QVariant CefWebView::inputMethodQuery(Qt::InputMethodQuery query) const {
  switch (query) {
    case Qt::ImEnabled:
      return m_imeEnabled;
    case Qt::ImCursorRectangle:
      return QRectF(m_imeBounds);
    case Qt::ImHints:
      return int(Qt::ImhNone);
    default:
      return QQuickItem::inputMethodQuery(query);
  }
}

void CefWebView::focusInEvent(QFocusEvent* event) {
  QQuickItem::focusInEvent(event);
  if (auto h = host())
    h->SetFocus(true);
}

void CefWebView::focusOutEvent(QFocusEvent* event) {
  QQuickItem::focusOutEvent(event);
  if (auto h = host())
    h->SetFocus(false);
}
