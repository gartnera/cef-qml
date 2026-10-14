#pragma once

#include <QObject>
#include <QQmlExtensionPlugin>
#include <QUrl>

// `Cef` singleton: process-wide information and helpers.
class CefGlobal : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString version READ version CONSTANT)
  Q_PROPERTY(QString chromiumVersion READ chromiumVersion CONSTANT)
  Q_PROPERTY(QString runtimeDir READ runtimeDir CONSTANT)
  // Chromium profile directory in use (cookies, cache, local storage).
  Q_PROPERTY(QString profileDir READ profileDir CONSTANT)
  // Directory for the app's own data (JsonStore files): "<profile>/cefqml".
  Q_PROPERTY(QString dataDir READ dataDir CONSTANT)
  // True when another process holds the configured profile and this one runs
  // on a throwaway Chromium profile (dataDir is still the shared one).
  Q_PROPERTY(bool temporaryProfile READ temporaryProfile CONSTANT)
  // All downloads of this process (CefDownload objects), oldest first.
  Q_PROPERTY(QList<QObject*> downloads READ downloads NOTIFY downloadsChanged)
  // Names accepted by setContentSetting() / contentSetting().
  Q_PROPERTY(QStringList contentSettingTypes READ contentSettingTypes CONSTANT)

 public:
  explicit CefGlobal(QObject* parent = nullptr);

  QList<QObject*> downloads() const;
  QStringList contentSettingTypes() const;

  QString version() const;
  QString chromiumVersion() const;
  QString runtimeDir() const;
  QString profileDir() const;
  QString dataDir() const;
  bool temporaryProfile() const;

  // What a browser address bar does with typed text: "example.com" ->
  // "https://example.com", "/tmp/x.html" -> file URL. Returns an invalid URL
  // for text that does not look like an address (e.g. a search query).
  Q_INVOKABLE QUrl urlFromUserInput(const QString& text) const;

  Q_INVOKABLE void copyToClipboard(const QString& text) const;

  // Chromium's own content settings (profile-wide, persisted by Chromium):
  // the exception for the origin of `url`, or the default when `url` is
  // empty. `type` is one of contentSettingTypes ("javascript", "images",
  // "popups", "notifications", "geolocation", "camera", ...); `value` is
  // "allow", "block", "ask", "session-only" (cookies) or "default" (remove
  // the exception). JavaScript and images apply to documents loaded after
  // the change. Returns false for an unknown type or value.
  //   Cef.setContentSetting("https://example.com", "javascript", "block")
  Q_INVOKABLE bool setContentSetting(const QUrl& url, const QString& type,
                                     const QString& value) const;
  // The effective value for `url` ("allow", "block", "ask", ...).
  Q_INVOKABLE QString contentSetting(const QUrl& url, const QString& type) const;

  // Value of an environment variable ("" if unset); handy for dev setups.
  Q_INVOKABLE QString environment(const QString& name) const;

 Q_SIGNALS:
  void downloadsChanged();
};

class CefQmlPlugin : public QQmlExtensionPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

 public:
  void registerTypes(const char* uri) override;
};
