#include "servoplugin.h"

#include <QtQml>

#include "servowebview.h"

void ServoQmlPlugin::registerTypes(const char* uri) {
  qmlRegisterType<ServoWebView>(uri, 1, 0, "ServoWebView");
}
