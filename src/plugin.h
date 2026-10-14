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
  // All downloads of this process (CefDownload objects), oldest first.
  Q_PROPERTY(QList<QObject*> downloads READ downloads NOTIFY downloadsChanged)

 public:
  explicit CefGlobal(QObject* parent = nullptr);

  QList<QObject*> downloads() const;

  QString version() const;
  QString chromiumVersion() const;
  QString runtimeDir() const;

  // What a browser address bar does with typed text: "example.com" ->
  // "https://example.com", "/tmp/x.html" -> file URL. Returns an invalid URL
  // for text that does not look like an address (e.g. a search query).
  Q_INVOKABLE QUrl urlFromUserInput(const QString& text) const;

  Q_INVOKABLE void copyToClipboard(const QString& text) const;

 Q_SIGNALS:
  void downloadsChanged();
};

class CefQmlPlugin : public QQmlExtensionPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

 public:
  void registerTypes(const char* uri) override;
};
