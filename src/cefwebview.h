#pragma once

#include <QColor>
#include <QHash>
#include <QImage>
#include <QJSValue>
#include <QJsonValue>
#include <QVariant>

#include <functional>
#include <QQuickItem>
#include <QRect>
#include <QUrl>

#include "include/cef_base.h"

#include "requests.h"

class CefQmlClient;
class CefBrowser;
class CefBrowserHost;

// A Chromium browser rendered off-screen (CEF OSR) into a Qt Quick texture.
//
//   import CefQml
//   CefWebView { anchors.fill: parent; url: "https://example.com" }
class CefWebView : public QQuickItem {
  Q_OBJECT

  Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)
  Q_PROPERTY(QString title READ title NOTIFY titleChanged)
  Q_PROPERTY(QUrl icon READ icon NOTIFY iconChanged)
  Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
  Q_PROPERTY(double loadProgress READ loadProgress NOTIFY loadProgressChanged)
  Q_PROPERTY(bool canGoBack READ canGoBack NOTIFY navigationStateChanged)
  Q_PROPERTY(bool canGoForward READ canGoForward NOTIFY navigationStateChanged)
  Q_PROPERTY(QString hoveredUrl READ hoveredUrl NOTIFY hoveredUrlChanged)
  Q_PROPERTY(QString tooltip READ tooltip NOTIFY tooltipChanged)
  Q_PROPERTY(double zoomFactor READ zoomFactor WRITE setZoomFactor NOTIFY zoomFactorChanged)
  Q_PROPERTY(bool audioMuted READ audioMuted WRITE setAudioMuted NOTIFY audioMutedChanged)
  Q_PROPERTY(bool fullscreen READ fullscreen NOTIFY fullscreenChanged)
  // Applied when the browser is created. Use "transparent" for see-through pages.
  Q_PROPERTY(QColor backgroundColor READ backgroundColor WRITE setBackgroundColor NOTIFY backgroundColorChanged)
  Q_PROPERTY(int frameRate READ frameRate WRITE setFrameRate NOTIFY frameRateChanged)
  // Set to false to keep the browser alive but stop it from rendering.
  Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
  // True once the underlying CEF browser exists.
  Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
  Q_PROPERTY(int frameCount READ frameCount NOTIFY frameSwapped)
  // JavaScript sources run in every document before the page's own scripts
  // (Page.addScriptToEvaluateOnNewDocument).
  Q_PROPERTY(QStringList userScripts READ userScripts WRITE setUserScripts NOTIFY userScriptsChanged)

 public:
  enum ConsoleLevel { Debug = 0, Info, Warning, Error };
  Q_ENUM(ConsoleLevel)

  explicit CefWebView(QQuickItem* parent = nullptr);
  ~CefWebView() override;

  QUrl url() const { return m_url; }
  void setUrl(const QUrl& url);
  QString title() const { return m_title; }
  QUrl icon() const { return m_icon; }
  bool loading() const { return m_loading; }
  double loadProgress() const { return m_loadProgress; }
  bool canGoBack() const { return m_canGoBack; }
  bool canGoForward() const { return m_canGoForward; }
  QString hoveredUrl() const { return m_hoveredUrl; }
  QString tooltip() const { return m_tooltip; }
  double zoomFactor() const { return m_zoomFactor; }
  void setZoomFactor(double factor);
  bool audioMuted() const { return m_audioMuted; }
  void setAudioMuted(bool muted);
  bool fullscreen() const { return m_fullscreen; }
  QStringList userScripts() const { return m_userScripts; }
  void setUserScripts(const QStringList& scripts);
  QColor backgroundColor() const { return m_backgroundColor; }
  void setBackgroundColor(const QColor& color);
  int frameRate() const { return m_frameRate; }
  void setFrameRate(int fps);
  bool active() const { return m_active; }
  void setActive(bool active);
  bool ready() const { return m_ready; }
  int frameCount() const { return m_frameCount; }

  Q_INVOKABLE void goBack();
  Q_INVOKABLE void goForward();
  Q_INVOKABLE void reload();
  Q_INVOKABLE void reloadIgnoringCache();
  Q_INVOKABLE void stop();
  // Fire-and-forget JavaScript in the main frame.
  Q_INVOKABLE void runJavaScript(const QString& script);
  // Evaluates `script` in the main frame and calls `callback(result, error)`.
  // Promises are awaited; the result must be JSON-serializable. On failure
  // `result` is undefined and `error` is a message.
  Q_INVOKABLE void evaluateJavaScript(const QString& script,
                                      const QJSValue& callback = QJSValue());
  // Calls any Chrome DevTools Protocol method, e.g.
  //   devToolsMethod("Page.captureScreenshot", {format: "png"}, (r, err) => ...)
  // Calls made before the browser exists are queued. Returns the message id.
  Q_INVOKABLE int devToolsMethod(const QString& method,
                                 const QVariantMap& params = QVariantMap(),
                                 const QJSValue& callback = QJSValue());
  Q_INVOKABLE void loadHtml(const QString& html);
  Q_INVOKABLE void find(const QString& text, bool forward = true, bool matchCase = false);
  Q_INVOKABLE void stopFinding(bool clearSelection = true);
  // Edit commands on the focused frame.
  Q_INVOKABLE void copy();
  Q_INVOKABLE void cut();
  Q_INVOKABLE void paste();
  Q_INVOKABLE void selectAll();
  Q_INVOKABLE void undo();
  Q_INVOKABLE void redo();

 Q_SIGNALS:
  void urlChanged();
  void titleChanged();
  void iconChanged();
  void loadingChanged();
  void loadProgressChanged();
  void navigationStateChanged();
  void hoveredUrlChanged();
  void tooltipChanged();
  void zoomFactorChanged();
  void audioMutedChanged();
  void fullscreenChanged();
  void backgroundColorChanged();
  void frameRateChanged();
  void activeChanged();
  void readyChanged();
  void frameSwapped();
  void userScriptsChanged();
  // DevTools protocol events. Enable a domain first, e.g.
  // devToolsMethod("Network.enable").
  void devToolsEvent(const QString& method, const QVariant& params);

  // A page asked for a new window/tab (target=_blank, window.open, middle
  // click, ...). If nothing is connected, the URL is opened in this view.
  void newWindowRequested(const QUrl& url, bool userGesture, bool background);
  // Main-frame load events. loadStarted: a new document committed (not for
  // same-document navigations). None are emitted for the internal
  // about:blank bootstrap page.
  void loadStarted(const QUrl& url);
  void loadFailed(int errorCode, const QString& errorText, const QUrl& failedUrl);
  void loadFinished(const QUrl& url, int httpStatusCode);
  void consoleMessage(int level, const QString& message, const QString& source, int line);
  // window.close() from the page.
  void closeRequested();
  // Right click. Coordinates are in item space.
  void contextMenuRequested(qreal x, qreal y, const QUrl& linkUrl,
                            const QString& selectedText, bool editable);
  void renderProcessTerminated(int status);

  // Decision requests. Connect a handler and answer the request object
  // (accept()/reject(), grant()/deny()). Unhandled: JavaScript dialogs are
  // dismissed, permissions denied, file dialogs canceled, and downloads saved
  // to the user's download directory.
  void javaScriptDialogRequested(CefJavaScriptDialog* dialog);
  void permissionRequested(CefPermissionRequest* request);
  void fileDialogRequested(CefFileDialogRequest* request);
  void downloadRequested(CefDownload* download);

  // Result of find(). activeMatch is 1-based.
  void findResult(int count, int activeMatch, bool finalUpdate);

 protected:
  void componentComplete() override;
  QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
  void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
  void itemChange(ItemChange change, const ItemChangeData& value) override;

  void mousePressEvent(QMouseEvent* event) override;
  void mouseReleaseEvent(QMouseEvent* event) override;
  void mouseDoubleClickEvent(QMouseEvent* event) override;
  void mouseMoveEvent(QMouseEvent* event) override;
  void mouseUngrabEvent() override;
  void hoverEnterEvent(QHoverEvent* event) override;
  void hoverMoveEvent(QHoverEvent* event) override;
  void hoverLeaveEvent(QHoverEvent* event) override;
  void wheelEvent(QWheelEvent* event) override;
  void keyPressEvent(QKeyEvent* event) override;
  void keyReleaseEvent(QKeyEvent* event) override;
  void inputMethodEvent(QInputMethodEvent* event) override;
  QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
  void focusInEvent(QFocusEvent* event) override;
  void focusOutEvent(QFocusEvent* event) override;

 private:
  friend class CefQmlClient;

  void createBrowser();
  CefRefPtr<CefBrowserHost> host() const;
  void sendMouseClick(QMouseEvent* event, bool up, int clickCount);
  QPoint toBrowser(QPointF pos) const;
  qreal devicePixelRatio() const;
  void loadInBrowser(const QUrl& url);
  bool isBootstrapLoad(const QUrl& url) const;
  void resetInitialHistory();

  // Called by CefQmlClient (always on the GUI thread).
  void cefAfterCreated();
  void cefBeforeClose();
  QRect cefViewRect() const;
  void cefPaint(bool popup, const void* buffer, int width, int height);
  void cefPopupShow(bool show);
  void cefPopupSize(const QRect& rect);
  void cefAddressChange(const QUrl& url);
  void cefLoadStart(const QUrl& url);
  void cefLoadEnd(const QUrl& url, int httpStatusCode);
  void cefLoadError(int errorCode, const QString& errorText, const QUrl& failedUrl);
  void cefTitleChange(const QString& title);
  void cefIconChange(const QUrl& icon);
  void cefLoadingStateChange(bool loading, bool canGoBack, bool canGoForward);
  void cefLoadProgress(double progress);
  void cefStatusMessage(const QString& message);
  void cefTooltip(const QString& text);
  void cefCursor(int cefCursorType);
  void cefFullscreen(bool fullscreen);
  void cefTextInputMode(bool editable);
  void cefImeBounds(const QRect& bounds);
  void cefDevToolsResult(int id, bool success, const QByteArray& json);
  void cefDevToolsEvent(const QString& method, const QByteArray& json);

  using DevToolsCallback = std::function<void(bool ok, const QJsonValue& result)>;
  int sendDevTools(const QString& method, const QVariantMap& params, DevToolsCallback cb);
  void flushDevToolsQueue();
  void applyUserScripts();
  void callJs(const QJSValue& callback, const QVariant& result, const QString& error);
  void pasteFromSystemClipboard();
  // True if the message was internal (clipboard bridge) and is consumed.
  bool cefConsoleMessage(const QString& message);

  CefRefPtr<CefQmlClient> m_client;

  struct PendingDevTools {
    int id;
    QByteArray message;
  };
  int m_nextDevToolsId = 1;
  QList<PendingDevTools> m_devToolsQueue;
  QHash<int, DevToolsCallback> m_devToolsCallbacks;
  QStringList m_userScripts;
  QStringList m_userScriptIds;
  QUrl m_deferredStartUrl;
  QUrl m_pendingLoad;
  bool m_internalScriptsInstalled = false;
  bool m_dropInitialHistoryEntry = false;
  bool m_bootstrapping = false;
  bool m_historyResetInFlight = false;

  QUrl m_url;
  QString m_pendingHtml;
  QString m_title;
  QUrl m_icon;
  bool m_loading = false;
  double m_loadProgress = 0;
  bool m_canGoBack = false;
  bool m_canGoForward = false;
  QString m_hoveredUrl;
  QString m_tooltip;
  double m_zoomFactor = 1.0;
  bool m_audioMuted = false;
  bool m_fullscreen = false;
  QColor m_backgroundColor = Qt::white;
  int m_frameRate = 60;
  bool m_active = true;
  bool m_ready = false;
  int m_frameCount = 0;
  bool m_editableFocused = false;
  QRect m_imeBounds;

  QImage m_view;
  QImage m_popup;
  bool m_popupVisible = false;
  QRect m_popupRect;          // clamped to the view, DIP
  QRect m_popupOriginalRect;  // as requested by Chromium, DIP
  bool m_viewDirty = false;
  bool m_popupDirty = false;
  int m_clickCount = 1;
  QString m_lastFind;
};
