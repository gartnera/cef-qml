#pragma once

#include <QImage>
#include <QJSValue>
#include <QPointer>
#include <QQuickItem>
#include <QUrl>

#include <atomic>

#include "servo_qml.h"

class ServoWebView;

// Process-wide Servo instance (libservo_qml). Servo is started by the first
// ServoWebView and runs on the GUI thread; its event loop is spun whenever
// Servo asks for it (the wake callback), and it shuts down when the
// application quits. Servo can only be started once per process.
class ServoEngine : public QObject {
  Q_OBJECT

 public:
  // Starts Servo on first use. nullptr once shut down, or when Servo
  // failed to start.
  static ServoEngine* instance();
  // The engine if it is running; never starts it.
  static ServoEngine* running();

  void attach(ServoWebView* view);
  void detach(ServoWebView* view);
  void spinSoon();

 private:
  ServoEngine() = default;
  bool start();
  void spin();
  void shutdown();
  static void wake(void* user);

  QList<ServoWebView*> m_views;
  std::atomic<bool> m_spinPending{false};
  bool m_shutDown = false;
};

// A web view backed by Servo (https://servo.org), rendered off-screen into
// the Qt Quick scene. The API is a subset of CefWebView's, with the same
// names, so simple QML works with either engine.
class ServoWebView : public QQuickItem {
  Q_OBJECT
  Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)
  Q_PROPERTY(QString title READ title NOTIFY titleChanged)
  Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
  // 0.1 when a load starts, 0.5 once <head> is parsed, 1 when complete.
  Q_PROPERTY(double loadProgress READ loadProgress NOTIFY loadProgressChanged)
  Q_PROPERTY(bool canGoBack READ canGoBack NOTIFY navigationStateChanged)
  Q_PROPERTY(bool canGoForward READ canGoForward NOTIFY navigationStateChanged)
  // Link under the pointer ("" when none).
  Q_PROPERTY(QString hoveredUrl READ hoveredUrl NOTIFY hoveredUrlChanged)
  Q_PROPERTY(double zoomFactor READ zoomFactor WRITE setZoomFactor NOTIFY zoomFactorChanged)
  // True once Servo is running and the view exists (it needs a window and
  // a non-empty size).
  Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
  // Frames received from Servo so far.
  Q_PROPERTY(int frameCount READ frameCount NOTIFY frameSwapped)
  // Engine name, for UI that shows which engine a view uses.
  Q_PROPERTY(QString engine READ engine CONSTANT)

 public:
  explicit ServoWebView(QQuickItem* parent = nullptr);
  ~ServoWebView() override;

  QUrl url() const { return m_url; }
  void setUrl(const QUrl& url);
  QString title() const { return m_title; }
  bool loading() const { return m_loading; }
  double loadProgress() const { return m_loadProgress; }
  bool canGoBack() const { return m_canGoBack; }
  bool canGoForward() const { return m_canGoForward; }
  QString hoveredUrl() const { return m_hoveredUrl; }
  double zoomFactor() const { return m_zoomFactor; }
  void setZoomFactor(double zoom);
  bool ready() const { return m_view != nullptr; }
  int frameCount() const { return m_frameCount; }
  QString engine() const { return QStringLiteral("servo"); }

  Q_INVOKABLE void goBack();
  Q_INVOKABLE void goForward();
  Q_INVOKABLE void reload();
  // Loads `html` as a data: URL.
  Q_INVOKABLE void loadHtml(const QString& html);
  // Fire-and-forget JavaScript in the page.
  Q_INVOKABLE void runJavaScript(const QString& script);
  // Evaluates `script` and calls `callback(result, error)`. The result is
  // converted to JSON-like values; DOM nodes become descriptive strings.
  Q_INVOKABLE void evaluateJavaScript(const QString& script,
                                      const QJSValue& callback = QJSValue());

  // Real input events, as if the user did them; coordinates are in item
  // space. Same signatures as CefWebView's.
  Q_INVOKABLE void sendMouseClick(qreal x, qreal y, int button = Qt::LeftButton,
                                  int modifiers = 0, int clickCount = 1);
  Q_INVOKABLE void sendMouseMove(qreal x, qreal y, int modifiers = 0);
  // Wheel deltas as QWheelEvent::angleDelta (120 per notch), or pixels
  // when `pixels` is true.
  Q_INVOKABLE void sendMouseWheel(qreal x, qreal y, int deltaX, int deltaY,
                                  int modifiers = 0, bool pixels = false);
  // Presses and releases `key` (a Qt.Key). `text` defaults to the key's
  // character for printable keys.
  Q_INVOKABLE void sendKey(int key, int modifiers = 0, const QString& text = QString());

  // Called by ServoEngine when Servo shuts down.
  void releaseServoView();

 Q_SIGNALS:
  void urlChanged();
  void titleChanged();
  void loadingChanged();
  void loadProgressChanged();
  // The document and its subresources have loaded.
  void loadFinished(const QUrl& url);
  void navigationStateChanged();
  void hoveredUrlChanged();
  void zoomFactorChanged();
  void readyChanged();
  void frameSwapped();
  // `level`: 0 log, 1 debug, 2 info, 3 warn, 4 error, 5 trace.
  void consoleMessage(int level, const QString& message);
  // The page asked for a new window (target=_blank, window.open); Servo was
  // told no. Load `url` here or in another view.
  void newWindowRequested(const QUrl& url);
  void crashed(const QString& reason);

 protected:
  void componentComplete() override;
  void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
  void itemChange(ItemChange change, const ItemChangeData& value) override;
  QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;

  void mousePressEvent(QMouseEvent* e) override;
  void mouseReleaseEvent(QMouseEvent* e) override;
  void mouseMoveEvent(QMouseEvent* e) override;
  void hoverMoveEvent(QHoverEvent* e) override;
  void hoverLeaveEvent(QHoverEvent* e) override;
  void wheelEvent(QWheelEvent* e) override;
  void keyPressEvent(QKeyEvent* e) override;
  void keyReleaseEvent(QKeyEvent* e) override;
  void focusInEvent(QFocusEvent* e) override;
  void focusOutEvent(QFocusEvent* e) override;

 private:
  void ensureView();
  void syncSize();
  qreal dpr() const;
  void sendKeyEvent(bool down, int key, Qt::KeyboardModifiers mods, const QString& text,
                    bool repeat);
  void mouseButton(bool down, Qt::MouseButton button, QPointF pos);
  void mouseMove(QPointF pos);
  void wheel(QPointF pos, QPoint angle, QPoint pixels);
  void setLoadStatus(int status);
  void load(const QUrl& url);

  static const ServoQmlViewCallbacks s_callbacks;
  static void onFrame(void* user, const uint8_t* rgba, uint32_t w, uint32_t h);
  static void onUrl(void* user, const char* url);
  static void onTitle(void* user, const char* title);
  static void onStatusText(void* user, const char* text);
  static void onLoadStatus(void* user, int status);
  static void onHistory(void* user, bool back, bool forward);
  static void onCursor(void* user, int cursor);
  static void onConsole(void* user, int level, const char* message);
  static void onNewWindow(void* user, const char* url);
  static void onCrashed(void* user, const char* reason);

  ServoQmlView* m_view = nullptr;
  bool m_released = false;  // Servo shut down under us
  // Servo drops loads for a view it has not finished creating; until the
  // view reports its first URL, a new `url` waits here.
  bool m_viewStarted = false;
  bool m_loadPending = false;
  // Set once that waiting load is sent: the initial about:blank may still
  // report its title and load status; they are ignored until Servo reports
  // another URL.
  bool m_skipBlank = false;
  QUrl m_url;
  QString m_title;
  bool m_loading = false;
  double m_loadProgress = 0;
  bool m_canGoBack = false;
  bool m_canGoForward = false;
  QString m_hoveredUrl;
  double m_zoomFactor = 1.0;
  int m_frameCount = 0;
  QSize m_viewSize;  // device pixels last given to Servo
  qreal m_viewScale = 0;

  QImage m_frame;
  bool m_frameDirty = false;
};
