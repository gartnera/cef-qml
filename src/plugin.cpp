#include "plugin.h"

#include "bookmarkstore.h"
#include "cefcontext.h"
#include "cefwebview.h"
#include "historystore.h"
#include "hotreload.h"
#include "jsonstore.h"
#include "requests.h"

#include <QClipboard>
#include <QDir>
#include <QGuiApplication>
#include <QFileInfo>
#include <QQmlEngine>
#include <QRegularExpression>

#include "include/cef_version_info.h"

CefGlobal::CefGlobal(QObject* parent) : QObject(parent) {
  connect(CefContext::instance(), &CefContext::downloadsChanged, this,
          &CefGlobal::downloadsChanged);
}

QList<QObject*> CefGlobal::downloads() const {
  QList<QObject*> list;
  for (CefDownload* d : CefContext::instance()->downloads())
    list.append(d);
  return list;
}

QString CefGlobal::version() const {
  return QStringLiteral("%1.%2.%3")
      .arg(cef_version_info(0))
      .arg(cef_version_info(1))
      .arg(cef_version_info(2));
}

QString CefGlobal::chromiumVersion() const {
  return QStringLiteral("%1.%2.%3.%4")
      .arg(cef_version_info(4))
      .arg(cef_version_info(5))
      .arg(cef_version_info(6))
      .arg(cef_version_info(7));
}

QString CefGlobal::runtimeDir() const {
  return CefContext::instance()->runtimeDir();
}

QString CefGlobal::profileDir() const {
  return CefContext::instance()->profileDir();
}

QString CefGlobal::dataDir() const {
  return CefContext::instance()->dataDir();
}

QUrl CefGlobal::urlFromUserInput(const QString& input) const {
  const QString text = input.trimmed();
  if (text.isEmpty())
    return {};

  // Explicit schemes ("https:", "about:", "data:", "chrome:", ...), but not
  // "localhost:8080", which is host:port.
  static const QRegularExpression scheme(
      QStringLiteral("^[a-zA-Z][a-zA-Z0-9+.-]*:(.?)"));
  const auto sm = scheme.match(text);
  if (sm.hasMatch() && !text.contains(QLatin1Char(' ')) &&
      !(sm.captured(1).size() == 1 && sm.captured(1).at(0).isDigit())) {
    return QUrl(text);
  }

  if (text.startsWith(QLatin1Char('/')) || text.startsWith(QLatin1Char('~'))) {
    QString path = text;
    if (path.startsWith(QLatin1Char('~')))
      path.replace(0, 1, QDir::homePath());
    return QUrl::fromLocalFile(path);
  }

  if (text.contains(QLatin1Char(' ')))
    return {};

  // host[:port][/path] — needs a dot, a port, or to be localhost.
  static const QRegularExpression hostLike(QStringLiteral(
      "^(localhost|[^/?#:]+\\.[^/?#:]+|\\[[0-9a-fA-F:]+\\])(:\\d+)?([/?#].*)?$"));
  const auto m = hostLike.match(text);
  if (!m.hasMatch())
    return {};
  const bool local = m.captured(1) == QLatin1String("localhost") ||
                     QRegularExpression(QStringLiteral("^[0-9.]+$")).match(m.captured(1)).hasMatch();
  return QUrl((local ? QStringLiteral("http://") : QStringLiteral("https://")) + text);
}

void CefGlobal::copyToClipboard(const QString& text) const {
  QGuiApplication::clipboard()->setText(text);
}

QString CefGlobal::environment(const QString& name) const {
  return qEnvironmentVariable(name.toLocal8Bit().constData());
}

void CefQmlPlugin::registerTypes(const char* uri) {
  qmlRegisterType<CefWebView>(uri, 1, 0, "CefWebView");
  qmlRegisterType<HotReload>(uri, 1, 0, "HotReload");
  qmlRegisterType<JsonStore>(uri, 1, 0, "JsonStore");
  qmlRegisterType<HistoryStore>(uri, 1, 0, "HistoryStore");
  qmlRegisterType<HistoryModel>(uri, 1, 0, "HistoryModel");
  qmlRegisterType<BookmarkStore>(uri, 1, 0, "BookmarkStore");
  qmlRegisterType<BookmarkModel>(uri, 1, 0, "BookmarkModel");
  const QString why = QStringLiteral("created by CefWebView");
  qmlRegisterUncreatableType<CefJavaScriptDialog>(uri, 1, 0, "CefJavaScriptDialog", why);
  qmlRegisterUncreatableType<CefPermissionRequest>(uri, 1, 0, "CefPermissionRequest", why);
  qmlRegisterUncreatableType<CefFileDialogRequest>(uri, 1, 0, "CefFileDialogRequest", why);
  qmlRegisterUncreatableType<CefDownload>(uri, 1, 0, "CefDownload", why);
  qmlRegisterSingletonType<CefGlobal>(uri, 1, 0, "Cef",
                                      [](QQmlEngine*, QJSEngine*) -> QObject* {
                                        return new CefGlobal;
                                      });
}
