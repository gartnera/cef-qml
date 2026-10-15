#include "servowebview.h"

#include <QCoreApplication>
#include <QCursor>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QKeyEvent>
#include <QOpenGLContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSurface>

#include <utility>

namespace {

// Servo renders with its own (EGL) GL context, made current on this
// thread. With Qt Quick's basic render loop, Qt's context lives on this
// thread too: release it around every call into Servo (EGL and GLX cannot
// both be current on a thread under libglvnd) and make it current again
// afterwards, so Qt never renders into Servo's context.
class QtGlGuard {
 public:
  QtGlGuard() : m_ctx(QOpenGLContext::currentContext()) {
    if (m_ctx) {
      m_surface = m_ctx->surface();
      m_ctx->doneCurrent();
    }
  }
  ~QtGlGuard() {
    if (m_ctx && m_surface)
      m_ctx->makeCurrent(m_surface);
  }
  QtGlGuard(const QtGlGuard&) = delete;
  QtGlGuard& operator=(const QtGlGuard&) = delete;

 private:
  QOpenGLContext* m_ctx;
  QSurface* m_surface = nullptr;
};

QByteArray env(const char* name) {
  return qEnvironmentVariable(name).toUtf8();
}

int domButton(Qt::MouseButton b) {
  switch (b) {
    case Qt::LeftButton: return 0;
    case Qt::MiddleButton: return 1;
    case Qt::RightButton: return 2;
    case Qt::BackButton: return 3;
    case Qt::ForwardButton: return 4;
    default: return -1;
  }
}

uint32_t servoModifiers(Qt::KeyboardModifiers m) {
  uint32_t r = 0;
  if (m & Qt::ShiftModifier) r |= SERVO_QML_MOD_SHIFT;
  if (m & Qt::ControlModifier) r |= SERVO_QML_MOD_CONTROL;
  if (m & Qt::AltModifier) r |= SERVO_QML_MOD_ALT;
  if (m & Qt::MetaModifier) r |= SERVO_QML_MOD_META;
  return r;
}

struct NamedKey {
  int qt;
  const char* key;
  const char* code;
};

// Non-printable keys: DOM `key` and `code` values.
constexpr NamedKey kNamedKeys[] = {
    {Qt::Key_Return, "Enter", "Enter"},
    {Qt::Key_Enter, "Enter", "NumpadEnter"},
    {Qt::Key_Backspace, "Backspace", "Backspace"},
    {Qt::Key_Tab, "Tab", "Tab"},
    {Qt::Key_Backtab, "Tab", "Tab"},
    {Qt::Key_Escape, "Escape", "Escape"},
    {Qt::Key_Delete, "Delete", "Delete"},
    {Qt::Key_Insert, "Insert", "Insert"},
    {Qt::Key_Home, "Home", "Home"},
    {Qt::Key_End, "End", "End"},
    {Qt::Key_PageUp, "PageUp", "PageUp"},
    {Qt::Key_PageDown, "PageDown", "PageDown"},
    {Qt::Key_Left, "ArrowLeft", "ArrowLeft"},
    {Qt::Key_Right, "ArrowRight", "ArrowRight"},
    {Qt::Key_Up, "ArrowUp", "ArrowUp"},
    {Qt::Key_Down, "ArrowDown", "ArrowDown"},
    {Qt::Key_Shift, "Shift", "ShiftLeft"},
    {Qt::Key_Control, "Control", "ControlLeft"},
    {Qt::Key_Alt, "Alt", "AltLeft"},
    {Qt::Key_AltGr, "AltGraph", "AltRight"},
    {Qt::Key_Meta, "Meta", "MetaLeft"},
    {Qt::Key_Super_L, "Meta", "MetaLeft"},
    {Qt::Key_Super_R, "Meta", "MetaRight"},
    {Qt::Key_CapsLock, "CapsLock", "CapsLock"},
    {Qt::Key_NumLock, "NumLock", "NumLock"},
    {Qt::Key_ScrollLock, "ScrollLock", "ScrollLock"},
    {Qt::Key_Menu, "ContextMenu", "ContextMenu"},
    {Qt::Key_Print, "PrintScreen", "PrintScreen"},
    {Qt::Key_Pause, "Pause", "Pause"},
};

// `code` (physical key) for printable keys, from the Qt key on a US layout.
QByteArray printableCode(int key) {
  if (key >= Qt::Key_A && key <= Qt::Key_Z)
    return "Key" + QByteArray(1, char('A' + key - Qt::Key_A));
  if (key >= Qt::Key_0 && key <= Qt::Key_9)
    return "Digit" + QByteArray(1, char('0' + key - Qt::Key_0));
  switch (key) {
    case Qt::Key_Space: return "Space";
    case Qt::Key_Minus: case Qt::Key_Underscore: return "Minus";
    case Qt::Key_Equal: case Qt::Key_Plus: return "Equal";
    case Qt::Key_BracketLeft: case Qt::Key_BraceLeft: return "BracketLeft";
    case Qt::Key_BracketRight: case Qt::Key_BraceRight: return "BracketRight";
    case Qt::Key_Backslash: case Qt::Key_Bar: return "Backslash";
    case Qt::Key_Semicolon: case Qt::Key_Colon: return "Semicolon";
    case Qt::Key_Apostrophe: case Qt::Key_QuoteDbl: return "Quote";
    case Qt::Key_QuoteLeft: case Qt::Key_AsciiTilde: return "Backquote";
    case Qt::Key_Comma: case Qt::Key_Less: return "Comma";
    case Qt::Key_Period: case Qt::Key_Greater: return "Period";
    case Qt::Key_Slash: case Qt::Key_Question: return "Slash";
    default: return "Unidentified";
  }
}

Qt::CursorShape cursorShape(int servoCursor) {
  // servo::Cursor, in declaration order.
  static constexpr Qt::CursorShape kShapes[] = {
      Qt::BlankCursor,     // None
      Qt::ArrowCursor,     // Default
      Qt::PointingHandCursor,  // Pointer
      Qt::ArrowCursor,     // ContextMenu
      Qt::WhatsThisCursor, // Help
      Qt::BusyCursor,      // Progress
      Qt::WaitCursor,      // Wait
      Qt::CrossCursor,     // Cell
      Qt::CrossCursor,     // Crosshair
      Qt::IBeamCursor,     // Text
      Qt::IBeamCursor,     // VerticalText
      Qt::DragLinkCursor,  // Alias
      Qt::DragCopyCursor,  // Copy
      Qt::SizeAllCursor,   // Move
      Qt::ForbiddenCursor, // NoDrop
      Qt::ForbiddenCursor, // NotAllowed
      Qt::OpenHandCursor,  // Grab
      Qt::ClosedHandCursor,  // Grabbing
      Qt::SizeHorCursor,   // EResize
      Qt::SizeVerCursor,   // NResize
      Qt::SizeBDiagCursor, // NeResize
      Qt::SizeFDiagCursor, // NwResize
      Qt::SizeVerCursor,   // SResize
      Qt::SizeFDiagCursor, // SeResize
      Qt::SizeBDiagCursor, // SwResize
      Qt::SizeHorCursor,   // WResize
      Qt::SizeHorCursor,   // EwResize
      Qt::SizeVerCursor,   // NsResize
      Qt::SizeBDiagCursor, // NeswResize
      Qt::SizeFDiagCursor, // NwseResize
      Qt::SplitHCursor,    // ColResize
      Qt::SplitVCursor,    // RowResize
      Qt::SizeAllCursor,   // AllScroll
      Qt::ArrowCursor,     // ZoomIn
      Qt::ArrowCursor,     // ZoomOut
  };
  if (servoCursor < 0 || servoCursor >= int(std::size(kShapes)))
    return Qt::ArrowCursor;
  return kShapes[servoCursor];
}

ServoWebView* self(void* user) {
  return static_cast<ServoWebView*>(user);
}

}  // namespace

// --- ServoEngine -------------------------------------------------------

namespace {
// Never deleted: Servo's threads may still call wake() while the process
// exits.
ServoEngine* g_engine = nullptr;
}  // namespace

ServoEngine* ServoEngine::instance() {
  if (!g_engine) {
    g_engine = new ServoEngine;
    if (!g_engine->start())
      g_engine->m_shutDown = true;
  }
  return running();
}

ServoEngine* ServoEngine::running() {
  return g_engine && !g_engine->m_shutDown ? g_engine : nullptr;
}

bool ServoEngine::start() {
  if (!QCoreApplication::instance())
    return false;
  const QByteArray configDir = env("SERVO_QML_PROFILE_DIR");
  const QByteArray certs = env("SERVO_QML_CERTIFICATE_PATH");
  if (!configDir.isEmpty())
    QDir().mkpath(QString::fromUtf8(configDir));
  ServoQmlConfig config{};
  config.wake = &ServoEngine::wake;
  config.user = this;
  config.config_dir = configDir.isEmpty() ? nullptr : configDir.constData();
  config.certificate_path = certs.isEmpty() ? nullptr : certs.constData();
  bool ok;
  {
    QtGlGuard guard;
    ok = servo_qml_init(&config);
  }
  if (!ok) {
    qWarning("ServoWebView: Servo failed to start");
    return false;
  }
  // Shut down while the event loop and the scene still exist; the post
  // routine covers applications that never emit aboutToQuit.
  connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, this,
          &ServoEngine::shutdown);
  qAddPostRoutine([] {
    if (auto* e = ServoEngine::running())
      e->shutdown();
  });
  return true;
}

void ServoEngine::wake(void* user) {
  static_cast<ServoEngine*>(user)->spinSoon();
}

void ServoEngine::spinSoon() {
  if (!m_spinPending.exchange(true))
    QMetaObject::invokeMethod(this, &ServoEngine::spin, Qt::QueuedConnection);
}

void ServoEngine::spin() {
  m_spinPending = false;
  if (m_shutDown)
    return;
  QtGlGuard guard;
  servo_qml_spin();
}

void ServoEngine::attach(ServoWebView* view) {
  if (!m_views.contains(view))
    m_views.append(view);
}

void ServoEngine::detach(ServoWebView* view) {
  m_views.removeAll(view);
}

void ServoEngine::shutdown() {
  if (m_shutDown)
    return;
  m_shutDown = true;
  const auto views = m_views;
  m_views.clear();
  for (ServoWebView* v : views)
    v->releaseServoView();
  QtGlGuard guard;
  servo_qml_shutdown();
}

// --- ServoWebView --------------------------------------------------------

const ServoQmlViewCallbacks ServoWebView::s_callbacks = {
    &ServoWebView::onFrame,     &ServoWebView::onUrl,       &ServoWebView::onTitle,
    &ServoWebView::onStatusText, &ServoWebView::onLoadStatus, &ServoWebView::onHistory,
    &ServoWebView::onCursor,    &ServoWebView::onConsole,   &ServoWebView::onNewWindow,
    &ServoWebView::onCrashed,
};

ServoWebView::ServoWebView(QQuickItem* parent) : QQuickItem(parent) {
  setFlag(ItemHasContents);
  setFlag(ItemIsFocusScope);
  setAcceptedMouseButtons(Qt::AllButtons);
  setAcceptHoverEvents(true);
}

ServoWebView::~ServoWebView() {
  releaseServoView();
}

void ServoWebView::releaseServoView() {
  if (auto* engine = ServoEngine::running())
    engine->detach(this);
  if (!m_view)
    return;
  ServoQmlView* view = std::exchange(m_view, nullptr);
  {
    QtGlGuard guard;
    servo_qml_view_free(view);
  }
  m_released = true;
  if (auto* engine = ServoEngine::running())
    engine->spinSoon();  // drops the view
}

qreal ServoWebView::dpr() const {
  return window() ? window()->effectiveDevicePixelRatio() : 1.0;
}

void ServoWebView::componentComplete() {
  QQuickItem::componentComplete();
  ensureView();
}

void ServoWebView::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) {
  QQuickItem::geometryChange(newGeometry, oldGeometry);
  if (m_view)
    syncSize();
  else
    ensureView();
}

void ServoWebView::itemChange(ItemChange change, const ItemChangeData& value) {
  QQuickItem::itemChange(change, value);
  switch (change) {
    case ItemSceneChange:
    case ItemDevicePixelRatioHasChanged:
      if (m_view)
        syncSize();
      else
        ensureView();
      break;
    case ItemVisibleHasChanged:
      if (m_view) {
        QtGlGuard guard;
        servo_qml_view_set_visible(m_view, value.boolValue);
      }
      break;
    default:
      break;
  }
}

void ServoWebView::ensureView() {
  if (m_view || m_released || !isComponentComplete() || !window())
    return;
  const QSize size = (QSizeF(width(), height()) * dpr()).toSize();
  if (size.isEmpty())
    return;
  ServoEngine* engine = ServoEngine::instance();
  if (!engine)
    return;
  const QByteArray url = m_url.isEmpty() ? QByteArray() : m_url.toEncoded();
  {
    QtGlGuard guard;
    m_view = servo_qml_view_new(size.width(), size.height(), float(dpr()),
                                url.isEmpty() ? nullptr : url.constData(), &s_callbacks, this);
  }
  if (!m_view) {
    qWarning("ServoWebView: could not create a Servo view");
    return;
  }
  engine->attach(this);
  m_viewSize = size;
  m_viewScale = dpr();
  if (!qFuzzyCompare(m_zoomFactor, 1.0)) {
    QtGlGuard guard;
    servo_qml_view_set_zoom(m_view, float(m_zoomFactor));
  }
  if (hasActiveFocus()) {
    QtGlGuard guard;
    servo_qml_view_set_focused(m_view, true);
  }
  engine->spinSoon();
  Q_EMIT readyChanged();
}

void ServoWebView::syncSize() {
  const qreal scale = dpr();
  const QSize size = (QSizeF(width(), height()) * scale).toSize();
  if (size.isEmpty())
    return;
  QtGlGuard guard;
  if (!qFuzzyCompare(scale, m_viewScale)) {
    m_viewScale = scale;
    servo_qml_view_set_scale(m_view, float(scale));
  }
  if (size != m_viewSize) {
    m_viewSize = size;
    servo_qml_view_resize(m_view, size.width(), size.height());
  }
}

void ServoWebView::setUrl(const QUrl& url) {
  if (url == m_url)
    return;
  m_url = url;
  if (m_view)
    load(url);
  Q_EMIT urlChanged();
}

void ServoWebView::load(const QUrl& url) {
  if (!m_viewStarted) {
    m_loadPending = true;
    return;
  }
  const QByteArray u = url.toEncoded();
  QtGlGuard guard;
  servo_qml_view_load(m_view, u.constData());
}

void ServoWebView::setZoomFactor(double zoom) {
  if (zoom <= 0 || qFuzzyCompare(zoom, m_zoomFactor))
    return;
  m_zoomFactor = zoom;
  if (m_view) {
    QtGlGuard guard;
    servo_qml_view_set_zoom(m_view, float(zoom));
  }
  Q_EMIT zoomFactorChanged();
}

void ServoWebView::goBack() {
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_go_back(m_view);
}

void ServoWebView::goForward() {
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_go_forward(m_view);
}

void ServoWebView::reload() {
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_reload(m_view);
}

void ServoWebView::loadHtml(const QString& html) {
  setUrl(QUrl(QStringLiteral("data:text/html;charset=utf-8,") +
              QString::fromLatin1(html.toUtf8().toPercentEncoding())));
}

void ServoWebView::runJavaScript(const QString& script) {
  evaluateJavaScript(script);
}

namespace {
struct JsCall {
  QPointer<ServoWebView> view;
  QJSValue callback;
};
}  // namespace

void ServoWebView::evaluateJavaScript(const QString& script, const QJSValue& callback) {
  auto* call = new JsCall{this, callback};
  auto done = [](void* user, const char* json, const char* error) {
    std::unique_ptr<JsCall> call(static_cast<JsCall*>(user));
    if (!call->view || !call->callback.isCallable())
      return;
    QQmlEngine* engine = qmlEngine(call->view);
    if (!engine)
      return;
    QJSValue result;
    QJSValue err;
    if (json) {
      // Wrapped in an array so scalars parse too.
      const QJsonDocument doc =
          QJsonDocument::fromJson("[" + QByteArray(json) + "]");
      result = engine->toScriptValue(doc.array().at(0).toVariant());
    } else {
      err = QJSValue(QString::fromUtf8(error ? error : "evaluation failed"));
    }
    call->callback.call({result, err});
  };
  const QByteArray s = script.toUtf8();
  if (!m_view) {
    done(call, nullptr, "view not ready");
    return;
  }
  QtGlGuard guard;
  servo_qml_view_evaluate_javascript(m_view, s.constData(), done, call);
}

// --- Frames and page state ---------------------------------------------

void ServoWebView::onFrame(void* user, const uint8_t* rgba, uint32_t w, uint32_t h) {
  ServoWebView* v = self(user);
  v->m_frame = QImage(rgba, int(w), int(h), int(w) * 4, QImage::Format_RGBA8888).copy();
  v->m_frameDirty = true;
  v->m_frameCount++;
  v->update();
  Q_EMIT v->frameSwapped();
}

void ServoWebView::onUrl(void* user, const char* url) {
  ServoWebView* v = self(user);
  v->m_viewStarted = true;
  if (std::exchange(v->m_loadPending, false)) {
    v->m_skipBlank = true;
    v->load(v->m_url);  // the URL set while the view was starting
    return;
  }
  const QUrl u(QString::fromUtf8(url));
  if (v->m_skipBlank) {
    if (u == QUrl(QStringLiteral("about:blank")))
      return;
    v->m_skipBlank = false;
  }
  if (u != v->m_url) {
    v->m_url = u;
    Q_EMIT v->urlChanged();
  }
}

void ServoWebView::onTitle(void* user, const char* title) {
  ServoWebView* v = self(user);
  if (v->m_skipBlank)
    return;
  const QString t = QString::fromUtf8(title);
  if (t != v->m_title) {
    v->m_title = t;
    Q_EMIT v->titleChanged();
  }
}

void ServoWebView::onStatusText(void* user, const char* text) {
  ServoWebView* v = self(user);
  const QString t = QString::fromUtf8(text);
  if (t != v->m_hoveredUrl) {
    v->m_hoveredUrl = t;
    Q_EMIT v->hoveredUrlChanged();
  }
}

void ServoWebView::onLoadStatus(void* user, int status) {
  ServoWebView* v = self(user);
  if (!v->m_skipBlank && !v->m_loadPending)
    v->setLoadStatus(status);
}

void ServoWebView::setLoadStatus(int status) {
  const bool loading = status != SERVO_QML_LOAD_COMPLETE;
  const double progress = status == SERVO_QML_LOAD_STARTED       ? 0.1
                          : status == SERVO_QML_LOAD_HEAD_PARSED ? 0.5
                                                                 : 1.0;
  if (progress != m_loadProgress) {
    m_loadProgress = progress;
    Q_EMIT loadProgressChanged();
  }
  if (loading != m_loading) {
    m_loading = loading;
    Q_EMIT loadingChanged();
  }
  if (status == SERVO_QML_LOAD_COMPLETE)
    Q_EMIT loadFinished(m_url);
}

void ServoWebView::onHistory(void* user, bool back, bool forward) {
  ServoWebView* v = self(user);
  if (back == v->m_canGoBack && forward == v->m_canGoForward)
    return;
  v->m_canGoBack = back;
  v->m_canGoForward = forward;
  Q_EMIT v->navigationStateChanged();
}

void ServoWebView::onCursor(void* user, int cursor) {
  self(user)->setCursor(QCursor(cursorShape(cursor)));
}

void ServoWebView::onConsole(void* user, int level, const char* message) {
  Q_EMIT self(user)->consoleMessage(level, QString::fromUtf8(message));
}

void ServoWebView::onNewWindow(void* user, const char* url) {
  Q_EMIT self(user)->newWindowRequested(QUrl(QString::fromUtf8(url)));
}

void ServoWebView::onCrashed(void* user, const char* reason) {
  Q_EMIT self(user)->crashed(QString::fromUtf8(reason));
}

QSGNode* ServoWebView::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
  auto* node = static_cast<QSGSimpleTextureNode*>(old);
  if (m_frame.isNull()) {
    delete node;
    return nullptr;
  }
  if (!node) {
    node = new QSGSimpleTextureNode;
    node->setOwnsTexture(true);
    node->setFiltering(QSGTexture::Linear);
    m_frameDirty = true;
  }
  if (m_frameDirty) {
    node->setTexture(
        window()->createTextureFromImage(m_frame, QQuickWindow::TextureIsOpaque));
    m_frameDirty = false;
  }
  // The frame keeps its device-pixel size while a resize is in flight.
  const qreal scale = m_viewScale > 0 ? m_viewScale : dpr();
  node->setRect(0, 0, m_frame.width() / scale, m_frame.height() / scale);
  return node;
}

// --- Input -----------------------------------------------------------------

void ServoWebView::mouseMove(QPointF pos) {
  if (!m_view) return;
  const QPointF p = pos * dpr();
  QtGlGuard guard;
  servo_qml_view_mouse_move(m_view, float(p.x()), float(p.y()));
}

void ServoWebView::mouseButton(bool down, Qt::MouseButton button, QPointF pos) {
  const int b = domButton(button);
  if (!m_view || b < 0) return;
  const QPointF p = pos * dpr();
  QtGlGuard guard;
  servo_qml_view_mouse_move(m_view, float(p.x()), float(p.y()));
  servo_qml_view_mouse_button(m_view, down, b, float(p.x()), float(p.y()));
}

void ServoWebView::wheel(QPointF pos, QPoint angle, QPoint pixels) {
  if (!m_view) return;
  const QPointF p = pos * dpr();
  QtGlGuard guard;
  // Servo's WheelDelta has Qt's sign convention (positive y scrolls up).
  // Notches are sent the way servoshell sends winit line deltas.
  if (!pixels.isNull())
    servo_qml_view_wheel(m_view, pixels.x() * dpr(), pixels.y() * dpr(),
                         SERVO_QML_WHEEL_PIXEL, float(p.x()), float(p.y()));
  else
    servo_qml_view_wheel(m_view, angle.x() / 120.0 * 76, angle.y() / 120.0 * 76,
                         SERVO_QML_WHEEL_LINE, float(p.x()), float(p.y()));
}

void ServoWebView::mousePressEvent(QMouseEvent* e) {
  forceActiveFocus(Qt::MouseFocusReason);
  mouseButton(true, e->button(), e->position());
  e->accept();
}

void ServoWebView::mouseReleaseEvent(QMouseEvent* e) {
  mouseButton(false, e->button(), e->position());
  e->accept();
}

void ServoWebView::mouseMoveEvent(QMouseEvent* e) {
  mouseMove(e->position());
  e->accept();
}

void ServoWebView::hoverMoveEvent(QHoverEvent* e) {
  mouseMove(e->position());
}

void ServoWebView::hoverLeaveEvent(QHoverEvent*) {
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_mouse_leave(m_view);
}

void ServoWebView::wheelEvent(QWheelEvent* e) {
  wheel(e->position(), e->angleDelta(), e->pixelDelta());
  e->accept();
}

void ServoWebView::sendKeyEvent(bool down, int key, Qt::KeyboardModifiers mods,
                                const QString& text, bool repeat) {
  if (!m_view) return;
  QByteArray domKey;
  QByteArray domCode;
  for (const NamedKey& k : kNamedKeys) {
    if (k.qt == key) {
      domKey = k.key;
      domCode = k.code;
      break;
    }
  }
  if (key >= Qt::Key_F1 && key <= Qt::Key_F24)
    domKey = domCode = "F" + QByteArray::number(key - Qt::Key_F1 + 1);
  if (domKey.isEmpty()) {
    // Printable: the character, which with Ctrl/Alt Qt may not report as
    // text (Ctrl+A gives "\x01").
    QString ch = text;
    if (ch.isEmpty() || !ch.at(0).isPrint()) {
      if (key >= Qt::Key_Space && key <= Qt::Key_AsciiTilde) {
        ch = QChar(key);
        ch = (mods & Qt::ShiftModifier) ? ch.toUpper() : ch.toLower();
      } else {
        ch.clear();
      }
    }
    domKey = ch.isEmpty() ? QByteArray("Unidentified") : ch.toUtf8();
    domCode = printableCode(key);
  }
  const int location = (mods & Qt::KeypadModifier) ? 3 : 0;
  QtGlGuard guard;
  servo_qml_view_key(m_view, down, domKey.constData(), domCode.constData(), location,
                     servoModifiers(mods), repeat);
}

void ServoWebView::keyPressEvent(QKeyEvent* e) {
  sendKeyEvent(true, e->key(), e->modifiers(), e->text(), e->isAutoRepeat());
  e->accept();
}

void ServoWebView::keyReleaseEvent(QKeyEvent* e) {
  sendKeyEvent(false, e->key(), e->modifiers(), e->text(), e->isAutoRepeat());
  e->accept();
}

void ServoWebView::focusInEvent(QFocusEvent* e) {
  QQuickItem::focusInEvent(e);
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_set_focused(m_view, true);
}

void ServoWebView::focusOutEvent(QFocusEvent* e) {
  QQuickItem::focusOutEvent(e);
  if (!m_view) return;
  QtGlGuard guard;
  servo_qml_view_set_focused(m_view, false);
}

void ServoWebView::sendMouseClick(qreal x, qreal y, int button, int, int clickCount) {
  forceActiveFocus(Qt::MouseFocusReason);
  for (int i = 0; i < std::max(1, clickCount); i++) {
    mouseButton(true, Qt::MouseButton(button), {x, y});
    mouseButton(false, Qt::MouseButton(button), {x, y});
  }
}

void ServoWebView::sendMouseMove(qreal x, qreal y, int) {
  mouseMove({x, y});
}

void ServoWebView::sendMouseWheel(qreal x, qreal y, int deltaX, int deltaY, int, bool pixels) {
  if (pixels)
    wheel({x, y}, {}, {deltaX, deltaY});
  else
    wheel({x, y}, {deltaX, deltaY}, {});
}

void ServoWebView::sendKey(int key, int modifiers, const QString& text) {
  const auto mods = Qt::KeyboardModifiers(modifiers);
  sendKeyEvent(true, key, mods, text, false);
  sendKeyEvent(false, key, mods, text, false);
}
