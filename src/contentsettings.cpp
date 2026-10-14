#include "contentsettings.h"

#include "cefcontext.h"

#include "include/cef_request_context.h"

#include <utility>

namespace {

struct TypeName {
  const char* name;
  cef_content_setting_types_t type;
};

constexpr TypeName kTypes[] = {
    {"javascript", CEF_CONTENT_SETTING_TYPE_JAVASCRIPT},
    {"images", CEF_CONTENT_SETTING_TYPE_IMAGES},
    {"popups", CEF_CONTENT_SETTING_TYPE_POPUPS},
    {"cookies", CEF_CONTENT_SETTING_TYPE_COOKIES},
    {"sound", CEF_CONTENT_SETTING_TYPE_SOUND},
    {"notifications", CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
    {"geolocation", CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
    {"camera", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA},
    {"microphone", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
    {"clipboard", CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
    // CEF_CONTENT_SETTING_TYPE_MIDI is not registered in this Chromium (any
    // access CHECK-fails): plain MIDI is granted, sysex asks.
    {"midi-sysex", CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
    {"local-fonts", CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS},
    {"idle-detection", CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION},
    {"window-management", CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT},
    {"pointer-lock", CEF_CONTENT_SETTING_TYPE_POINTER_LOCK},
    {"keyboard-lock", CEF_CONTENT_SETTING_TYPE_KEYBOARD_LOCK},
    {"multiple-downloads", CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS},
    {"sensors", CEF_CONTENT_SETTING_TYPE_SENSORS},
    {"register-protocol-handler", CEF_CONTENT_SETTING_TYPE_PROTOCOL_HANDLERS},
};

constexpr std::pair<const char*, cef_content_setting_values_t> kValues[] = {
    {"default", CEF_CONTENT_SETTING_VALUE_DEFAULT},
    {"allow", CEF_CONTENT_SETTING_VALUE_ALLOW},
    {"block", CEF_CONTENT_SETTING_VALUE_BLOCK},
    {"ask", CEF_CONTENT_SETTING_VALUE_ASK},
    {"session-only", CEF_CONTENT_SETTING_VALUE_SESSION_ONLY},
};

bool typeOf(const QString& name, cef_content_setting_types_t* out) {
  for (const auto& t : kTypes) {
    if (name == QLatin1String(t.name)) {
      *out = t.type;
      return true;
    }
  }
  return false;
}

CefString cefUrl(const QUrl& url) {
  return url.isEmpty() ? CefString() : CefString(url.toString(QUrl::FullyEncoded).toStdString());
}

CefRefPtr<CefRequestContext> context() {
  if (!CefContext::instance()->ensureInitialized())
    return nullptr;
  return CefRequestContext::GetGlobalContext();
}

}  // namespace

namespace ContentSettings {

QStringList types() {
  QStringList list;
  for (const auto& t : kTypes)
    list << QString::fromLatin1(t.name);
  return list;
}

bool isType(const QString& type) {
  cef_content_setting_types_t t;
  return typeOf(type, &t);
}

bool set(const QUrl& url, const QString& type, const QString& value) {
  cef_content_setting_types_t t;
  if (!typeOf(type, &t))
    return false;
  for (const auto& [name, v] : kValues) {
    if (value != QLatin1String(name))
      continue;
    auto ctx = context();
    if (!ctx)
      return false;
    const CefString u = cefUrl(url);
    const cef_content_setting_values_t current = ctx->GetContentSetting(u, u, t);
    // GetContentSetting reports the effective value, not whether an
    // exception exists: a site at the profile default has none to remove
    // (an exception equal to the default is harmless). Skipping no-op writes
    // matters: callers sync every type on every navigation.
    if (v == CEF_CONTENT_SETTING_VALUE_DEFAULT && !url.isEmpty()
            ? current == ctx->GetContentSetting(CefString(), CefString(), t)
            : current == v)
      return true;
    ctx->SetContentSetting(u, u, t, v);
    return true;
  }
  return false;
}

QString get(const QUrl& url, const QString& type) {
  cef_content_setting_types_t t;
  if (!typeOf(type, &t))
    return {};
  auto ctx = context();
  if (!ctx)
    return {};
  const CefString u = cefUrl(url);
  const cef_content_setting_values_t v = ctx->GetContentSetting(u, u, t);
  for (const auto& [name, value] : kValues) {
    if (v == value)
      return QString::fromLatin1(name);
  }
  return {};
}

}  // namespace ContentSettings
