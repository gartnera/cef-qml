#include "cefwebview.h"

#include "cefclient.h"
#include "cefcontext.h"
#include "keymap.h"

#include <QClipboard>
#include <QCursor>
#include <QGuiApplication>
#include <QInputMethod>
#include <QJSEngine>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlEngine>
#include <QLoggingCategory>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

#include <cmath>
#include <memory>
#include <utility>
#include <cstring>

#include "include/cef_browser.h"

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
  if (m_client) {
    m_client->detachView();
    m_client->closeBrowser(true);
  }
}

// ---- lifecycle -------------------------------------------------------------

void CefWebView::componentComplete() {
  QQuickItem::componentComplete();
  createBrowser();
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
  }
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
    h->SetZoomLevel(std::log(m_zoomFactor) / std::log(kZoomBase));
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
  if (m_view.isNull())
    return root;
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
  if (auto h = host())
    h->SetZoomLevel(std::log(factor) / std::log(kZoomBase));
  Q_EMIT zoomFactorChanged();
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
  if (auto h = host())
    h->WasHidden(!isVisible() || !active);
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
  if (m_client && m_client->browser())
    m_client->browser()->Reload();
}

void CefWebView::reloadIgnoringCache() {
  if (m_client && m_client->browser())
    m_client->browser()->ReloadIgnoreCache();
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
  static const QMetaMethod sig = QMetaMethod::fromSignal(&CefWebView::devToolsEvent);
  if (isSignalConnected(sig))
    Q_EMIT devToolsEvent(method, QJsonDocument::fromJson(json).toVariant());
}

bool CefWebView::cefConsoleMessage(const QString& message) {
  static const QString prefix = QString::fromLatin1(kClipboardMessagePrefix);
  if (!message.startsWith(prefix))
    return false;
  QGuiApplication::clipboard()->setText(message.mid(prefix.size()));
  return true;
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

void CefWebView::cefLoadStart() {
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

void CefWebView::cefTitleChange(const QString& title) {
  if (m_bootstrapping)
    return;
  if (title == m_title)
    return;
  m_title = title;
  Q_EMIT titleChanged();
}

void CefWebView::cefIconChange(const QUrl& icon) {
  if (icon == m_icon)
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
  if (editable == m_editableFocused)
    return;
  m_editableFocused = editable;
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

void CefWebView::sendMouseClick(QMouseEvent* event, bool up, int clickCount) {
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
  sendMouseClick(event, false, m_clickCount);
  event->accept();
}

void CefWebView::mouseDoubleClickEvent(QMouseEvent* event) {
  m_clickCount = 2;
  sendMouseClick(event, false, m_clickCount);
  event->accept();
}

void CefWebView::mouseReleaseEvent(QMouseEvent* event) {
  sendMouseClick(event, true, m_clickCount);
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
      return m_editableFocused;
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
