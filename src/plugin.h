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

 public:
  using QObject::QObject;

  QString version() const;
  QString chromiumVersion() const;
  QString runtimeDir() const;

  // What a browser address bar does with typed text: "example.com" ->
  // "https://example.com", "/tmp/x.html" -> file URL. Returns an invalid URL
  // for text that does not look like an address (e.g. a search query).
  Q_INVOKABLE QUrl urlFromUserInput(const QString& text) const;
};

class CefQmlPlugin : public QQmlExtensionPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

 public:
  void registerTypes(const char* uri) override;
};
