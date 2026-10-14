#include "plugin.h"

#include "cefcontext.h"
#include "cefwebview.h"

#include <QDir>
#include <QFileInfo>
#include <QQmlEngine>
#include <QRegularExpression>

#include "include/cef_version_info.h"

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

void CefQmlPlugin::registerTypes(const char* uri) {
  qmlRegisterType<CefWebView>(uri, 1, 0, "CefWebView");
  qmlRegisterSingletonType<CefGlobal>(uri, 1, 0, "Cef",
                                      [](QQmlEngine*, QJSEngine*) -> QObject* {
                                        return new CefGlobal;
                                      });
}
