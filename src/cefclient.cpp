#include "cefclient.h"

#include "cefcontext.h"

#include <QGuiApplication>
#include <QQuickWindow>
#include <QScreen>

#include "include/cef_task.h"

namespace {

QString qstr(const CefString& s) {
  return QString::fromStdU16String(s.ToString16());
}

QRect qrect(const CefRect& r) {
  return QRect(r.x, r.y, r.width, r.height);
}

class CloseBrowserTask : public CefTask {
 public:
  explicit CloseBrowserTask(CefRefPtr<CefQmlClient> client) : m_client(std::move(client)) {}
  void Execute() override { m_client->closeBrowser(true); }

 private:
  CefRefPtr<CefQmlClient> m_client;
  IMPLEMENT_REFCOUNTING(CloseBrowserTask);
};

}  // namespace

CefQmlClient::CefQmlClient(CefWebView* view) : m_view(view) {
  CefContext::instance()->registerClient(this);
}

CefQmlClient::~CefQmlClient() {
  CefContext::instance()->unregisterClient(this);
}

void CefQmlClient::closeBrowser(bool force) {
  // After CefShutdown nothing may call into CEF (see CefContext::shutdown).
  if (!CefContext::instance()->isInitialized())
    return;
  if (!m_browser) {
    // CreateBrowser() is asynchronous: the browser does not exist yet, so
    // OnAfterCreated closes it. Stay registered meanwhile, so that
    // CefContext::shutdown() waits for it.
    m_closing = true;
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

// ---- CefDevToolsMessageObserver --------------------------------------------

// DevTools callbacks are delivered from the Qt event queue: handlers commonly
// send further DevTools messages or navigate, which must not happen while CEF
// is iterating its DevTools observers.
void CefQmlClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int messageId, bool success,
                                          const void* result, size_t resultSize) {
  if (!m_view)
    return;
  QByteArray json(static_cast<const char*>(result), qsizetype(resultSize));
  QMetaObject::invokeMethod(
      m_view.data(),
      [view = m_view, messageId, success, json] {
        if (view)
          view->cefDevToolsResult(messageId, success, json);
      },
      Qt::QueuedConnection);
}

void CefQmlClient::OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method,
                                   const void* params, size_t paramsSize) {
  if (!m_view)
    return;
  QByteArray json(static_cast<const char*>(params), qsizetype(paramsSize));
  QMetaObject::invokeMethod(
      m_view.data(),
      [view = m_view, m = qstr(method), json] {
        if (view)
          view->cefDevToolsEvent(m, json);
      },
      Qt::QueuedConnection);
}

// ---- CefDialogHandler ------------------------------------------------------

bool CefQmlClient::OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode,
                                const CefString& title, const CefString& defaultFilePath,
                                const std::vector<CefString>& acceptFilters,
                                const std::vector<CefString>& acceptExtensions,
                                const std::vector<CefString>&,
                                CefRefPtr<CefFileDialogCallback> callback) {
  if (!connected(&CefWebView::fileDialogRequested))
    return false;
  CefFileDialogRequest::Mode m = CefFileDialogRequest::Open;
  switch (mode) {
    case FILE_DIALOG_OPEN_MULTIPLE: m = CefFileDialogRequest::OpenMultiple; break;
    case FILE_DIALOG_OPEN_FOLDER: m = CefFileDialogRequest::OpenFolder; break;
    case FILE_DIALOG_SAVE: m = CefFileDialogRequest::Save; break;
    default: break;
  }
  QStringList filters, extensions;
  for (const auto& f : acceptFilters)
    filters << qstr(f);
  for (const auto& e : acceptExtensions)
    extensions << qstr(e);
  auto* req = new CefFileDialogRequest(m, qstr(title), qstr(defaultFilePath), filters,
                                       extensions, callback, m_view);
  Q_EMIT m_view->fileDialogRequested(req);
  return true;
}

// ---- CefDownloadHandler ----------------------------------------------------

bool CefQmlClient::OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                                    const CefString& suggestedName,
                                    CefRefPtr<CefBeforeDownloadCallback> callback) {
  // Downloads outlive tabs, so they belong to the process-wide context.
  auto* download = new CefDownload(item, qstr(suggestedName), callback,
                                   CefContext::instance());
  CefContext::instance()->addDownload(download);
  if (connected(&CefWebView::downloadRequested))
    Q_EMIT m_view->downloadRequested(download);
  else
    download->accept();
  return true;
}

void CefQmlClient::OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                                     CefRefPtr<CefDownloadItemCallback> callback) {
  if (CefDownload* d = CefDownload::find(item->GetId()))
    d->update(item, callback);
}

// ---- CefFindHandler --------------------------------------------------------

void CefQmlClient::OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&,
                                int activeMatchOrdinal, bool finalUpdate) {
  if (m_view)
    Q_EMIT m_view->findResult(count, activeMatchOrdinal, finalUpdate);
}

// ---- CefJSDialogHandler ----------------------------------------------------

bool CefQmlClient::OnJSDialog(CefRefPtr<CefBrowser>, const CefString& originUrl,
                              JSDialogType dialogType, const CefString& messageText,
                              const CefString& defaultPromptText,
                              CefRefPtr<CefJSDialogCallback> callback, bool&) {
  if (!connected(&CefWebView::javaScriptDialogRequested))
    return false;
  CefJavaScriptDialog::Type type = CefJavaScriptDialog::Alert;
  if (dialogType == JSDIALOGTYPE_CONFIRM)
    type = CefJavaScriptDialog::Confirm;
  else if (dialogType == JSDIALOGTYPE_PROMPT)
    type = CefJavaScriptDialog::Prompt;
  m_dialog = new CefJavaScriptDialog(type, qstr(messageText), qstr(defaultPromptText),
                                     QUrl(qstr(originUrl)), false, callback, m_view);
  Q_EMIT m_view->javaScriptDialogRequested(m_dialog);
  return true;
}

bool CefQmlClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString& messageText,
                                        bool isReload,
                                        CefRefPtr<CefJSDialogCallback> callback) {
  if (!connected(&CefWebView::javaScriptDialogRequested))
    return false;
  m_dialog = new CefJavaScriptDialog(CefJavaScriptDialog::BeforeUnload, qstr(messageText),
                                     QString(), m_view->url(), isReload, callback, m_view);
  Q_EMIT m_view->javaScriptDialogRequested(m_dialog);
  return true;
}

void CefQmlClient::OnResetDialogState(CefRefPtr<CefBrowser>) {
  if (m_dialog)
    m_dialog->cancelFromPage();
}

void CefQmlClient::OnDialogClosed(CefRefPtr<CefBrowser>) {
  m_dialog.clear();
}

// ---- CefPermissionHandler --------------------------------------------------

bool CefQmlClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& requestingOrigin,
    uint32_t requestedPermissions, CefRefPtr<CefMediaAccessCallback> callback) {
  if (!connected(&CefWebView::permissionRequested))
    return false;
  auto* req = new CefPermissionRequest(QUrl(qstr(requestingOrigin)), requestedPermissions,
                                       callback, m_view);
  Q_EMIT m_view->permissionRequested(req);
  return true;
}

bool CefQmlClient::OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t promptId,
                                          const CefString& requestingOrigin,
                                          uint32_t requestedPermissions,
                                          CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!connected(&CefWebView::permissionRequested))
    return false;
  auto* req = new CefPermissionRequest(QUrl(qstr(requestingOrigin)), requestedPermissions,
                                       promptId, callback, m_view);
  m_prompts.insert(promptId, req);
  Q_EMIT m_view->permissionRequested(req);
  return true;
}

void CefQmlClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t promptId,
                                             cef_permission_request_result_t) {
  if (auto req = m_prompts.take(promptId))
    req->cancelFromPage();
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
  if (m_view->cefConsoleMessage(qstr(message)))
    return true;
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
  if (connected(&CefWebView::newWindowRequested)) {
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
  // Released in OnBeforeClose (the registration references this client).
  m_devToolsRegistration = browser->GetHost()->AddDevToolsMessageObserver(this);
  if (m_view && !m_closing) {
    m_view->cefAfterCreated();
    return;
  }
  // The view went away (or shutdown began) while the browser was being
  // created. Closing right here would destroy the browser while CEF is still
  // inside AlloyBrowserHostImpl::CreateInternal, which keeps using it after
  // this callback (null deref); close it from a fresh UI-thread task instead.
  m_closing = true;
  CefPostTask(TID_UI, new CloseBrowserTask(this));
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
  m_devToolsRegistration = nullptr;
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

void CefQmlClient::OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                               TransitionType) {
  if (m_view && frame->IsMain())
    m_view->cefLoadStart(QUrl(qstr(frame->GetURL())));
}

void CefQmlClient::OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                             int httpStatusCode) {
  if (m_view && frame->IsMain())
    m_view->cefLoadEnd(QUrl(qstr(frame->GetURL())), httpStatusCode);
}

void CefQmlClient::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                               ErrorCode errorCode, const CefString& errorText,
                               const CefString& failedUrl) {
  if (m_view && frame->IsMain() && errorCode != ERR_ABORTED)
    m_view->cefLoadError(int(errorCode), qstr(errorText), QUrl(qstr(failedUrl)));
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
