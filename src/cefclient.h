#pragma once

#include <QHash>
#include <QPointer>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_registration.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"

#include "cefwebview.h"

// One per CefWebView. Owns the CefBrowser reference and forwards CEF
// callbacks (all delivered on the GUI thread, see CefContext) to the view.
// The view may be destroyed before the browser finishes closing, so it is
// held through a QPointer.
class CefQmlClient : public CefClient,
                     public CefContextMenuHandler,
                     public CefDevToolsMessageObserver,
                     public CefDialogHandler,
                     public CefDisplayHandler,
                     public CefDownloadHandler,
                     public CefFindHandler,
                     public CefJSDialogHandler,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefPermissionHandler,
                     public CefRenderHandler,
                     public CefRequestHandler {
 public:
  explicit CefQmlClient(CefWebView* view);
  ~CefQmlClient() override;

  CefRefPtr<CefBrowser> browser() const { return m_browser; }
  void detachView() { m_view.clear(); }
  void closeBrowser(bool force);

  // CefClient
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefContextMenuHandler
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;

  // CefDevToolsMessageObserver
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message,
                         size_t messageSize) override;
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int messageId, bool success,
                              const void* result, size_t resultSize) override;
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
                       const void* params, size_t paramsSize) override;

  // CefDialogHandler
  bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode,
                    const CefString& title, const CefString& defaultFilePath,
                    const std::vector<CefString>& acceptFilters,
                    const std::vector<CefString>& acceptExtensions,
                    const std::vector<CefString>& acceptDescriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override;

  // CefDownloadHandler
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggestedName,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

  // CefFindHandler
  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                    const CefRect& selectionRect, int activeMatchOrdinal,
                    bool finalUpdate) override;

  // CefJSDialogHandler
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& originUrl,
                  JSDialogType dialogType, const CefString& messageText,
                  const CefString& defaultPromptText,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppressMessage) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& messageText, bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;
  void OnDialogClosed(CefRefPtr<CefBrowser> browser) override;

  // CefPermissionHandler
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      const CefString& requestingOrigin, uint32_t requestedPermissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptId,
                              const CefString& requestingOrigin,
                              uint32_t requestedPermissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptId,
                                 cef_permission_request_result_t result) override;

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& iconUrls) override;
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override;
  bool OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) override;
  void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) override;
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override;
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& customCursorInfo) override;

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                     int popupId, const CefString& targetUrl,
                     const CefString& targetFrameName,
                     cef_window_open_disposition_t targetDisposition, bool userGesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo, CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extraInfo,
                     bool* noJavascriptAccess) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                            bool canGoBack, bool canGoForward) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   TransitionType transitionType) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode, const CefString& errorText,
                   const CefString& failedUrl) override;

  // CefRenderHandler
  bool GetRootScreenRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenPoint(CefRefPtr<CefBrowser> browser, int viewX, int viewY,
                      int& screenX, int& screenY) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
               const RectList& dirtyRects, const void* buffer, int width,
               int height) override;
  bool StartDragging(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefDragData> dragData,
                     DragOperationsMask allowedOps, int x, int y) override;
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser> browser,
                                    const CefRange& selectedRange,
                                    const RectList& characterBounds) override;
  void OnVirtualKeyboardRequested(CefRefPtr<CefBrowser> browser,
                                  TextInputMode inputMode) override;

  // CefRequestHandler
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool userGesture,
                      bool isRedirect) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString& targetUrl,
                        cef_window_open_disposition_t targetDisposition,
                        bool userGesture) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int errorCode,
                                 const CefString& errorString) override;

 private:
  bool handleNewWindow(const CefString& targetUrl,
                       cef_window_open_disposition_t disposition, bool userGesture);

  template <typename Func>
  bool connected(Func signal) const {
    return m_view && m_view->isSignalConnected(QMetaMethod::fromSignal(signal));
  }

  QPointer<CefWebView> m_view;
  QPointer<CefJavaScriptDialog> m_dialog;
  QHash<uint64_t, QPointer<CefPermissionRequest>> m_prompts;
  CefRefPtr<CefBrowser> m_browser;
  CefRefPtr<CefRegistration> m_devToolsRegistration;
  bool m_closing = false;

  IMPLEMENT_REFCOUNTING(CefQmlClient);
};
