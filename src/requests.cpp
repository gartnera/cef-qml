#include "requests.h"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QPointer>
#include <QStandardPaths>

namespace {

CefString cefstr(const QString& s) {
  return CefString(s.toStdU16String());
}

QStringList mediaPermissionNames(uint32_t mask) {
  QStringList names;
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) names << QStringLiteral("microphone");
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) names << QStringLiteral("camera");
  if (mask & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) names << QStringLiteral("desktop-audio");
  if (mask & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) names << QStringLiteral("desktop-video");
  return names;
}

QStringList promptPermissionNames(uint32_t mask) {
  static const std::pair<uint32_t, const char*> table[] = {
      {CEF_PERMISSION_TYPE_AR_SESSION, "ar-session"},
      {CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, "camera-pan-tilt-zoom"},
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, "camera"},
      {CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, "captured-surface-control"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, "clipboard"},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, "top-level-storage-access"},
      {CEF_PERMISSION_TYPE_DISK_QUOTA, "disk-quota"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, "local-fonts"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, "geolocation"},
      {CEF_PERMISSION_TYPE_HAND_TRACKING, "hand-tracking"},
      {CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, "identity-provider"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, "idle-detection"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, "microphone"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, "midi-sysex"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, "multiple-downloads"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, "notifications"},
      {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, "keyboard-lock"},
      {CEF_PERMISSION_TYPE_POINTER_LOCK, "pointer-lock"},
      {CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, "protected-media-identifier"},
      {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, "register-protocol-handler"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, "storage-access"},
      {CEF_PERMISSION_TYPE_VR_SESSION, "vr-session"},
      {CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, "web-app-installation"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, "window-management"},
      {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, "file-system-access"},
      {CEF_PERMISSION_TYPE_LOCAL_NETWORK, "local-network"},
      {CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, "loopback-network"},
  };
  QStringList names;
  uint32_t known = 0;
  for (const auto& [bit, name] : table) {
    known |= bit;
    if (mask & bit)
      names << QString::fromLatin1(name);
  }
  if (mask & ~known)
    names << QStringLiteral("other");
  return names;
}

QHash<uint32_t, QPointer<CefDownload>>& downloads() {
  static QHash<uint32_t, QPointer<CefDownload>> map;
  return map;
}

}  // namespace

// ---- CefJavaScriptDialog ---------------------------------------------------

CefJavaScriptDialog::CefJavaScriptDialog(Type type, QString message, QString defaultText,
                                         QUrl origin, bool isReload,
                                         CefRefPtr<CefJSDialogCallback> callback,
                                         QObject* parent)
    : QObject(parent),
      m_type(type),
      m_message(std::move(message)),
      m_defaultText(std::move(defaultText)),
      m_origin(std::move(origin)),
      m_isReload(isReload),
      m_callback(std::move(callback)) {}

CefJavaScriptDialog::~CefJavaScriptDialog() {
  // Never leave the renderer blocked on a dialog nobody can answer.
  if (m_callback)
    m_callback->Continue(false, CefString());
}

void CefJavaScriptDialog::finish(bool success, const QString& text) {
  if (!m_callback)
    return;
  auto cb = std::move(m_callback);
  m_callback = nullptr;
  cb->Continue(success, cefstr(text));
  Q_EMIT handledChanged();
  deleteLater();
}

void CefJavaScriptDialog::accept(const QString& text) {
  finish(true, text);
}

void CefJavaScriptDialog::reject() {
  finish(false, QString());
}

void CefJavaScriptDialog::cancelFromPage() {
  if (!m_callback)
    return;
  m_callback = nullptr;  // Chromium already dropped the dialog
  Q_EMIT handledChanged();
  Q_EMIT closed();
  deleteLater();
}

// ---- CefPermissionRequest --------------------------------------------------

CefPermissionRequest::CefPermissionRequest(QUrl origin, uint32_t mediaMask,
                                           CefRefPtr<CefMediaAccessCallback> callback,
                                           QObject* parent)
    : QObject(parent),
      m_origin(std::move(origin)),
      m_permissions(mediaPermissionNames(mediaMask)),
      m_mask(mediaMask),
      m_mediaCallback(std::move(callback)) {}

CefPermissionRequest::CefPermissionRequest(QUrl origin, uint32_t permissionMask,
                                           uint64_t promptId,
                                           CefRefPtr<CefPermissionPromptCallback> callback,
                                           QObject* parent)
    : QObject(parent),
      m_origin(std::move(origin)),
      m_permissions(promptPermissionNames(permissionMask)),
      m_mask(permissionMask),
      m_promptId(promptId),
      m_promptCallback(std::move(callback)) {}

CefPermissionRequest::~CefPermissionRequest() {
  if (m_mediaCallback)
    m_mediaCallback->Cancel();
  if (m_promptCallback)
    m_promptCallback->Continue(CEF_PERMISSION_RESULT_DISMISS);
}

void CefPermissionRequest::done() {
  m_mediaCallback = nullptr;
  m_promptCallback = nullptr;
  Q_EMIT handledChanged();
  deleteLater();
}

void CefPermissionRequest::grant() {
  if (handled())
    return;
  if (m_mediaCallback)
    m_mediaCallback->Continue(m_mask);
  else
    m_promptCallback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
  done();
}

void CefPermissionRequest::deny() {
  if (handled())
    return;
  if (m_mediaCallback)
    m_mediaCallback->Cancel();
  else
    m_promptCallback->Continue(CEF_PERMISSION_RESULT_DENY);
  done();
}

void CefPermissionRequest::dismiss() {
  if (handled())
    return;
  if (m_mediaCallback)
    m_mediaCallback->Cancel();
  else
    m_promptCallback->Continue(CEF_PERMISSION_RESULT_DISMISS);
  done();
}

void CefPermissionRequest::cancelFromPage() {
  if (handled())
    return;
  m_mediaCallback = nullptr;
  m_promptCallback = nullptr;
  Q_EMIT handledChanged();
  Q_EMIT closed();
  deleteLater();
}

// ---- CefFileDialogRequest --------------------------------------------------

CefFileDialogRequest::CefFileDialogRequest(Mode mode, QString title, QString defaultPath,
                                           QStringList acceptFilters, QStringList extensions,
                                           CefRefPtr<CefFileDialogCallback> callback,
                                           QObject* parent)
    : QObject(parent),
      m_mode(mode),
      m_title(std::move(title)),
      m_defaultPath(std::move(defaultPath)),
      m_acceptFilters(std::move(acceptFilters)),
      m_callback(std::move(callback)) {
  // CEF expands MIME filters ("image/*") into extensions for us when it can.
  QStringList globs;
  for (const QString& group : extensions) {
    for (const QString& ext : group.split(QLatin1Char(';'), Qt::SkipEmptyParts))
      globs << (ext.startsWith(QLatin1Char('.')) ? QStringLiteral("*") + ext : ext);
  }
  if (globs.isEmpty()) {
    for (const QString& f : std::as_const(m_acceptFilters)) {
      if (f.startsWith(QLatin1Char('.')))
        globs << QStringLiteral("*") + f;
    }
  }
  if (!globs.isEmpty())
    m_nameFilters << QStringLiteral("Accepted files (%1)").arg(globs.join(QLatin1Char(' ')));
  m_nameFilters << QStringLiteral("All files (*)");
}

CefFileDialogRequest::~CefFileDialogRequest() {
  if (m_callback)
    m_callback->Cancel();
}

void CefFileDialogRequest::accept(const QStringList& files) {
  if (!m_callback)
    return;
  std::vector<CefString> paths;
  for (QString s : files) {
    if (s.startsWith(QLatin1String("file:")))
      s = QUrl(s).toLocalFile();
    if (!s.isEmpty())
      paths.push_back(cefstr(s));
  }
  auto cb = std::move(m_callback);
  m_callback = nullptr;
  if (paths.empty())
    cb->Cancel();
  else
    cb->Continue(paths);
  Q_EMIT handledChanged();
  deleteLater();
}

void CefFileDialogRequest::reject() {
  if (!m_callback)
    return;
  auto cb = std::move(m_callback);
  m_callback = nullptr;
  cb->Cancel();
  Q_EMIT handledChanged();
  deleteLater();
}

// ---- CefDownload -----------------------------------------------------------

CefDownload::CefDownload(CefRefPtr<CefDownloadItem> item, QString suggestedName,
                         CefRefPtr<CefBeforeDownloadCallback> callback, QObject* parent)
    : QObject(parent),
      m_id(item->GetId()),
      m_url(QString::fromStdU16String(item->GetURL().ToString16())),
      m_suggestedFileName(std::move(suggestedName)),
      m_mimeType(QString::fromStdU16String(item->GetMimeType().ToString16())),
      m_total(item->GetTotalBytes()),
      m_beforeCallback(std::move(callback)) {
  downloads().insert(m_id, this);
}

CefDownload* CefDownload::find(uint32_t id) {
  return downloads().value(id);
}

double CefDownload::progress() const {
  if (m_state == Complete)
    return 1.0;
  if (m_total <= 0)
    return -1.0;
  return double(m_received) / double(m_total);
}

void CefDownload::accept(const QString& requested) {
  if (!m_beforeCallback)
    return;
  QString path = requested;
  if (path.startsWith(QLatin1String("file:")))
    path = QUrl(path).toLocalFile();
  QString name = m_suggestedFileName.isEmpty() ? QStringLiteral("download")
                                                : m_suggestedFileName;
  if (path.isEmpty()) {
    QString dir = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (dir.isEmpty())
      dir = QDir::homePath();
    path = dir + QLatin1Char('/') + name;
  } else if (path.endsWith(QLatin1Char('/')) || QFileInfo(path).isDir()) {
    path = QDir(path).filePath(name);
  }
  // Chromium interrupts downloads whose target path is not normalized.
  path = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
  QDir().mkpath(QFileInfo(path).absolutePath());

  // Don't overwrite: "file.txt" -> "file (1).txt".
  if (QFileInfo::exists(path)) {
    const QFileInfo fi(path);
    const QString base = fi.completeBaseName();
    const QString suffix = fi.suffix().isEmpty() ? QString() : QLatin1Char('.') + fi.suffix();
    for (int i = 1; QFileInfo::exists(path); ++i)
      path = fi.absolutePath() + QStringLiteral("/%1 (%2)%3").arg(base).arg(i).arg(suffix);
  }

  m_path = path;
  m_state = InProgress;
  auto cb = std::move(m_beforeCallback);
  m_beforeCallback = nullptr;
  cb->Continue(cefstr(path), false);
  Q_EMIT updated();
}

void CefDownload::cancel() {
  if (m_beforeCallback) {
    // Not started yet: dropping the callback cancels the download.
    m_beforeCallback = nullptr;
    m_state = Canceled;
    Q_EMIT updated();
    Q_EMIT finished();
    return;
  }
  m_cancelRequested = true;
  if (m_itemCallback)
    m_itemCallback->Cancel();
}

void CefDownload::pause() {
  if (m_itemCallback)
    m_itemCallback->Pause();
}

void CefDownload::resume() {
  if (m_itemCallback)
    m_itemCallback->Resume();
}

void CefDownload::releaseCallbacks() {
  m_beforeCallback = nullptr;
  m_itemCallback = nullptr;
  if (m_state == Pending || m_state == InProgress || m_state == Paused) {
    m_state = Interrupted;
    Q_EMIT updated();
    Q_EMIT finished();
  }
}

void CefDownload::remove() {
  if (m_state == InProgress || m_state == Paused || m_state == Pending)
    cancel();
  downloads().remove(m_id);
  deleteLater();
}

void CefDownload::update(CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) {
  if (m_state == Canceled && !m_beforeCallback && !m_itemCallback) {
    // Canceled before it started; make sure Chromium stops too.
    if (callback && item->IsInProgress())
      callback->Cancel();
    return;
  }
  m_itemCallback = callback;
  if (m_cancelRequested && item->IsInProgress()) {
    callback->Cancel();
    return;
  }

  const State before = m_state;
  m_received = item->GetReceivedBytes();
  m_total = item->GetTotalBytes();
  m_speed = item->GetCurrentSpeed();
  const QString full = QString::fromStdU16String(item->GetFullPath().ToString16());
  if (!full.isEmpty())
    m_path = full;

  if (item->IsComplete())
    m_state = Complete;
  else if (item->IsCanceled())
    m_state = Canceled;
  else if (item->IsInterrupted())
    m_state = Interrupted;
  else if (item->IsPaused())
    m_state = Paused;
  else if (item->IsInProgress())
    m_state = InProgress;

  Q_EMIT updated();
  const bool terminal = m_state == Complete || m_state == Canceled || m_state == Interrupted;
  if (terminal && before != m_state) {
    m_itemCallback = nullptr;
    Q_EMIT finished();
  }
}
