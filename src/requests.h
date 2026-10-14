#pragma once

#include <QObject>
#include <QStringList>
#include <QUrl>

#include "include/cef_dialog_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_permission_handler.h"

// Objects handed to QML when a page needs a decision. Each must be answered
// exactly once; further calls are ignored. They are owned by C++ (parented to
// the view or, for downloads, to the process-wide context), so QML may keep
// references while the request is pending.

// alert() / confirm() / prompt() / onbeforeunload.
class CefJavaScriptDialog : public QObject {
  Q_OBJECT
  Q_PROPERTY(Type type READ type CONSTANT)
  Q_PROPERTY(QString message READ message CONSTANT)
  Q_PROPERTY(QString defaultText READ defaultText CONSTANT)
  Q_PROPERTY(QUrl origin READ origin CONSTANT)
  Q_PROPERTY(bool isReload READ isReload CONSTANT)
  Q_PROPERTY(bool handled READ handled NOTIFY handledChanged)

 public:
  enum Type { Alert, Confirm, Prompt, BeforeUnload };
  Q_ENUM(Type)

  CefJavaScriptDialog(Type type, QString message, QString defaultText, QUrl origin,
                      bool isReload, CefRefPtr<CefJSDialogCallback> callback,
                      QObject* parent);
  ~CefJavaScriptDialog() override;

  Type type() const { return m_type; }
  QString message() const { return m_message; }
  QString defaultText() const { return m_defaultText; }
  QUrl origin() const { return m_origin; }
  bool isReload() const { return m_isReload; }
  bool handled() const { return !m_callback; }

  // OK / Leave. `text` is the prompt() result.
  Q_INVOKABLE void accept(const QString& text = QString());
  // Cancel / Stay.
  Q_INVOKABLE void reject();

  // The page navigated away or the dialog was dismissed by Chromium.
  void cancelFromPage();

 Q_SIGNALS:
  void handledChanged();
  // Emitted when Chromium dismissed the dialog itself; hide any UI.
  void closed();

 private:
  void finish(bool success, const QString& text);

  Type m_type;
  QString m_message;
  QString m_defaultText;
  QUrl m_origin;
  bool m_isReload;
  CefRefPtr<CefJSDialogCallback> m_callback;
};

// Camera / microphone / geolocation / notifications / ... prompts.
class CefPermissionRequest : public QObject {
  Q_OBJECT
  Q_PROPERTY(QUrl origin READ origin CONSTANT)
  // Human-readable names, e.g. ["camera", "microphone"].
  Q_PROPERTY(QStringList permissions READ permissions CONSTANT)
  Q_PROPERTY(bool handled READ handled NOTIFY handledChanged)

 public:
  // Media (getUserMedia) request.
  CefPermissionRequest(QUrl origin, uint32_t mediaMask,
                       CefRefPtr<CefMediaAccessCallback> callback, QObject* parent);
  // Generic permission prompt.
  CefPermissionRequest(QUrl origin, uint32_t permissionMask, uint64_t promptId,
                       CefRefPtr<CefPermissionPromptCallback> callback,
                       QObject* parent);
  ~CefPermissionRequest() override;

  QUrl origin() const { return m_origin; }
  QStringList permissions() const { return m_permissions; }
  bool handled() const { return !m_mediaCallback && !m_promptCallback; }
  uint64_t promptId() const { return m_promptId; }

  Q_INVOKABLE void grant();
  Q_INVOKABLE void deny();
  // Close without deciding (the page may ask again later).
  Q_INVOKABLE void dismiss();

  void cancelFromPage();

 Q_SIGNALS:
  void handledChanged();
  void closed();

 private:
  void done();

  QUrl m_origin;
  QStringList m_permissions;
  uint32_t m_mask = 0;
  uint64_t m_promptId = 0;
  CefRefPtr<CefMediaAccessCallback> m_mediaCallback;
  CefRefPtr<CefPermissionPromptCallback> m_promptCallback;
};

// <input type=file>, showOpenFilePicker(), ...
class CefFileDialogRequest : public QObject {
  Q_OBJECT
  Q_PROPERTY(Mode mode READ mode CONSTANT)
  Q_PROPERTY(QString title READ title CONSTANT)
  Q_PROPERTY(QString defaultPath READ defaultPath CONSTANT)
  // MIME types and/or extensions, e.g. ["image/*", ".pdf"].
  Q_PROPERTY(QStringList acceptFilters READ acceptFilters CONSTANT)
  // The same filters as file-dialog name filters, e.g. ["Files (*.png *.pdf)"].
  Q_PROPERTY(QStringList nameFilters READ nameFilters CONSTANT)
  Q_PROPERTY(bool handled READ handled NOTIFY handledChanged)

 public:
  enum Mode { Open, OpenMultiple, OpenFolder, Save };
  Q_ENUM(Mode)

  CefFileDialogRequest(Mode mode, QString title, QString defaultPath,
                       QStringList acceptFilters, QStringList extensions,
                       CefRefPtr<CefFileDialogCallback> callback, QObject* parent);
  ~CefFileDialogRequest() override;

  Mode mode() const { return m_mode; }
  QString title() const { return m_title; }
  QString defaultPath() const { return m_defaultPath; }
  QStringList acceptFilters() const { return m_acceptFilters; }
  QStringList nameFilters() const { return m_nameFilters; }
  bool handled() const { return !m_callback; }

  // Local paths or file:// URLs; a single string works too.
  Q_INVOKABLE void accept(const QStringList& files);
  Q_INVOKABLE void reject();

 Q_SIGNALS:
  void handledChanged();

 private:
  Mode m_mode;
  QString m_title;
  QString m_defaultPath;
  QStringList m_acceptFilters;
  QStringList m_nameFilters;
  CefRefPtr<CefFileDialogCallback> m_callback;
};

// A download. Created when a download starts and updated until it finishes.
class CefDownload : public QObject {
  Q_OBJECT
  Q_PROPERTY(int id READ id CONSTANT)
  Q_PROPERTY(QUrl url READ url CONSTANT)
  Q_PROPERTY(QString suggestedFileName READ suggestedFileName CONSTANT)
  Q_PROPERTY(QString mimeType READ mimeType CONSTANT)
  Q_PROPERTY(State state READ state NOTIFY updated)
  Q_PROPERTY(QString path READ path NOTIFY updated)
  Q_PROPERTY(qint64 receivedBytes READ receivedBytes NOTIFY updated)
  // -1 when unknown.
  Q_PROPERTY(qint64 totalBytes READ totalBytes NOTIFY updated)
  // 0..1, or -1 when unknown.
  Q_PROPERTY(double progress READ progress NOTIFY updated)
  // Bytes per second.
  Q_PROPERTY(qint64 speed READ speed NOTIFY updated)

 public:
  enum State { Pending, InProgress, Paused, Complete, Canceled, Interrupted };
  Q_ENUM(State)

  CefDownload(CefRefPtr<CefDownloadItem> item, QString suggestedName,
              CefRefPtr<CefBeforeDownloadCallback> callback, QObject* parent);

  int id() const { return int(m_id); }
  QUrl url() const { return m_url; }
  QString suggestedFileName() const { return m_suggestedFileName; }
  QString mimeType() const { return m_mimeType; }
  State state() const { return m_state; }
  QString path() const { return m_path; }
  qint64 receivedBytes() const { return m_received; }
  qint64 totalBytes() const { return m_total; }
  double progress() const;
  qint64 speed() const { return m_speed; }

  // Start saving. `path` may be a file path, a directory, a file:// URL or
  // empty (the user's download directory + suggested name).
  Q_INVOKABLE void accept(const QString& path = QString());
  Q_INVOKABLE void cancel();
  Q_INVOKABLE void pause();
  Q_INVOKABLE void resume();
  // Forget a finished download (removes it from Cef.downloads).
  Q_INVOKABLE void remove();

  void update(CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback);

  static CefDownload* find(uint32_t id);

 Q_SIGNALS:
  void updated();
  void finished();

 private:
  uint32_t m_id;
  QUrl m_url;
  QString m_suggestedFileName;
  QString m_mimeType;
  State m_state = Pending;
  QString m_path;
  qint64 m_received = 0;
  qint64 m_total = -1;
  qint64 m_speed = 0;
  bool m_cancelRequested = false;
  CefRefPtr<CefBeforeDownloadCallback> m_beforeCallback;
  CefRefPtr<CefDownloadItemCallback> m_itemCallback;
};
