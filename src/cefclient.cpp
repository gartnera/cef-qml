#include "cefclient.h"

#include "cefcontext.h"

#include <QGuiApplication>
#include <QQuickWindow>
#include <QScreen>

namespace {

QString qstr(const CefString& s) {
  return QString::fromStdU16String(s.ToString16());
}

QRect qrect(const CefRect& r) {
  return QRect(r.x, r.y, r.width, r.height);
}

}  // namespace

CefQmlClient::CefQmlClient(CefWebView* view) : m_view(view) {
  CefContext::instance()->registerClient(this);
}

CefQmlClient::~CefQmlClient() {
  CefContext::instance()->unregisterClient(this);
}

void CefQmlClient::closeBrowser(bool force) {
  if (!m_browser) {
    CefContext::instance()->unregisterClient(this);
    return;
  }
  if (m_closing && !force)
    return;
  m_closing = true;
  m_browser->GetHost()->CloseBrowser(force);
}

// ---- CefContextMenuHandler -------------------------------------------------

void CefQmlClient::OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                       CefRefPtr<CefContextMenuParams> params,
                                       CefRefPtr<CefMenuModel> model) {
  // Off-screen browsers cannot show Chromium's native menu; let QML draw one.
  model->Clear();
  if (!m_view)
    return;
  const qreal x = params->GetXCoord();
  const qreal y = params->GetYCoord();
  Q_EMIT m_view->contextMenuRequested(
      x, y, QUrl(qstr(params->GetLinkUrl())), qstr(params->GetSelectionText()),
      params->IsEditable());
}

// ---- CefDisplayHandler -----------------------------------------------------

void CefQmlClient::OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                   const CefString& url) {
  if (m_view && frame->IsMain())
    m_view->cefAddressChange(QUrl(qstr(url)));
}

void CefQmlClient::OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) {
  if (m_view)
    m_view->cefTitleChange(qstr(title));
}

void CefQmlClient::OnFaviconURLChange(CefRefPtr<CefBrowser>,
                                      const std::vector<CefString>& iconUrls) {
  if (m_view)
    m_view->cefIconChange(iconUrls.empty() ? QUrl() : QUrl(qstr(iconUrls.front())));
}

void CefQmlClient::OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool fullscreen) {
  if (m_view)
    m_view->cefFullscreen(fullscreen);
}

bool CefQmlClient::OnTooltip(CefRefPtr<CefBrowser>, CefString& text) {
  if (m_view)
    m_view->cefTooltip(qstr(text));
  return true;
}

void CefQmlClient::OnStatusMessage(CefRefPtr<CefBrowser>, const CefString& value) {
  if (m_view)
    m_view->cefStatusMessage(qstr(value));
}

bool CefQmlClient::OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                                    const CefString& message, const CefString& source,
                                    int line) {
  if (!m_view)
    return false;
  int l = CefWebView::Info;
  switch (level) {
    case LOGSEVERITY_VERBOSE:
      l = CefWebView::Debug;
      break;
    case LOGSEVERITY_WARNING:
      l = CefWebView::Warning;
      break;
    case LOGSEVERITY_ERROR:
    case LOGSEVERITY_FATAL:
      l = CefWebView::Error;
      break;
    default:
      break;
  }
  Q_EMIT m_view->consoleMessage(l, qstr(message), qstr(source), line);
  return true;  // don't also spam stderr
}

void CefQmlClient::OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) {
  if (m_view)
    m_view->cefLoadProgress(progress);
}

bool CefQmlClient::OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                                  cef_cursor_type_t type, const CefCursorInfo&) {
  if (m_view)
    m_view->cefCursor(int(type));
  return true;
}

// ---- CefLifeSpanHandler ----------------------------------------------------

bool CefQmlClient::handleNewWindow(const CefString& targetUrl,
                                   cef_window_open_disposition_t disposition,
                                   bool userGesture) {
  if (!m_view)
    return true;
  const QUrl url(qstr(targetUrl));
  if (m_view->cefWantsPopupSignal()) {
    const bool background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    Q_EMIT m_view->newWindowRequested(url, userGesture, background);
  } else if (m_browser) {
    m_browser->GetMainFrame()->LoadURL(targetUrl);
  }
  return true;  // never let CEF create its own window
}

bool CefQmlClient::OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                                 const CefString& targetUrl, const CefString&,
                                 cef_window_open_disposition_t targetDisposition,
                                 bool userGesture, const CefPopupFeatures&,
                                 CefWindowInfo&, CefRefPtr<CefClient>&,
                                 CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&,
                                 bool*) {
  return handleNewWindow(targetUrl, targetDisposition, userGesture);
}

void CefQmlClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  m_browser = browser;
  if (m_view)
    m_view->cefAfterCreated();
  else
    closeBrowser(true);
}

bool CefQmlClient::DoClose(CefRefPtr<CefBrowser>) {
  if (m_view && !m_closing) {
    // window.close() from script: let QML decide what to do with the view.
    Q_EMIT m_view->closeRequested();
    return true;  // cancel
  }
  return false;
}

void CefQmlClient::OnBeforeClose(CefRefPtr<CefBrowser>) {
  m_browser = nullptr;
  if (m_view)
    m_view->cefBeforeClose();
  CefContext::instance()->unregisterClient(this);
}

// ---- CefLoadHandler --------------------------------------------------------

void CefQmlClient::OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                                        bool canGoBack, bool canGoForward) {
  if (m_view)
    m_view->cefLoadingStateChange(isLoading, canGoBack, canGoForward);
}

void CefQmlClient::OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                             int httpStatusCode) {
  if (m_view && frame->IsMain())
    Q_EMIT m_view->loadFinished(QUrl(qstr(frame->GetURL())), httpStatusCode);
}

void CefQmlClient::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                               ErrorCode errorCode, const CefString& errorText,
                               const CefString& failedUrl) {
  if (m_view && frame->IsMain() && errorCode != ERR_ABORTED)
    Q_EMIT m_view->loadFailed(int(errorCode), qstr(errorText), QUrl(qstr(failedUrl)));
}

// ---- CefRenderHandler ------------------------------------------------------

bool CefQmlClient::GetRootScreenRect(CefRefPtr<CefBrowser>, CefRect& rect) {
  if (!m_view || !m_view->window())
    return false;
  const QRect g = m_view->window()->geometry();
  rect = CefRect(g.x(), g.y(), g.width(), g.height());
  return true;
}

void CefQmlClient::GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) {
  const QRect r = m_view ? m_view->cefViewRect() : QRect(0, 0, 800, 600);
  rect = CefRect(r.x(), r.y(), r.width(), r.height());
}

bool CefQmlClient::GetScreenPoint(CefRefPtr<CefBrowser>, int viewX, int viewY,
                                  int& screenX, int& screenY) {
  if (!m_view || !m_view->window())
    return false;
  const QPointF p = m_view->mapToGlobal(QPointF(viewX, viewY));
  screenX = int(p.x());
  screenY = int(p.y());
  return true;
}

bool CefQmlClient::GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) {
  QScreen* screen = nullptr;
  qreal dpr = 1.0;
  if (m_view) {
    dpr = m_view->devicePixelRatio();
    if (m_view->window())
      screen = m_view->window()->screen();
  }
  if (!screen)
    screen = QGuiApplication::primaryScreen();
  info.device_scale_factor = float(dpr);
  info.depth = 24;
  info.depth_per_component = 8;
  info.is_monochrome = false;
  if (screen) {
    const QRect g = screen->geometry();
    const QRect a = screen->availableGeometry();
    info.rect = CefRect(g.x(), g.y(), g.width(), g.height());
    info.available_rect = CefRect(a.x(), a.y(), a.width(), a.height());
  }
  return true;
}

void CefQmlClient::OnPopupShow(CefRefPtr<CefBrowser>, bool show) {
  if (m_view)
    m_view->cefPopupShow(show);
}

void CefQmlClient::OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) {
  if (m_view)
    m_view->cefPopupSize(qrect(rect));
}

void CefQmlClient::OnPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                           const RectList&, const void* buffer, int width,
                           int height) {
  if (m_view)
    m_view->cefPaint(type == PET_POPUP, buffer, width, height);
}

bool CefQmlClient::StartDragging(CefRefPtr<CefBrowser>, CefRefPtr<CefDragData>,
                                 DragOperationsMask, int, int) {
  // Drag and drop out of the page is not supported; abort so the page does
  // not wait for a drop that never comes.
  return false;
}

void CefQmlClient::OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>,
                                                const CefRange&,
                                                const RectList& characterBounds) {
  if (!m_view || characterBounds.empty())
    return;
  QRect bounds;
  for (const CefRect& r : characterBounds)
    bounds |= qrect(r);
  m_view->cefImeBounds(bounds);
}

void CefQmlClient::OnVirtualKeyboardRequested(CefRefPtr<CefBrowser>,
                                              TextInputMode inputMode) {
  if (m_view)
    m_view->cefTextInputMode(inputMode != CEF_TEXT_INPUT_MODE_NONE);
}

// ---- CefRequestHandler -----------------------------------------------------

bool CefQmlClient::OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                    const CefString& targetUrl,
                                    cef_window_open_disposition_t targetDisposition,
                                    bool userGesture) {
  // Ctrl/middle-click on links.
  if (targetDisposition == CEF_WOD_NEW_FOREGROUND_TAB ||
      targetDisposition == CEF_WOD_NEW_BACKGROUND_TAB ||
      targetDisposition == CEF_WOD_NEW_WINDOW ||
      targetDisposition == CEF_WOD_NEW_POPUP) {
    return handleNewWindow(targetUrl, targetDisposition, userGesture);
  }
  return false;
}

void CefQmlClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser>,
                                             TerminationStatus status, int,
                                             const CefString&) {
  if (m_view)
    Q_EMIT m_view->renderProcessTerminated(int(status));
}
