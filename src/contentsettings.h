#pragma once

#include <QString>
#include <QStringList>
#include <QUrl>

// Chromium content settings of the global request context (the profile all
// CefWebViews share), by name. Names follow CefPermissionRequest.permissions
// where both exist: "javascript", "images", "popups", "cookies", "sound",
// "notifications", "geolocation", "camera", "microphone", "clipboard",
// "midi", "midi-sysex", "local-fonts", "idle-detection", "window-management",
// "pointer-lock", "keyboard-lock", "multiple-downloads", "sensors",
// "register-protocol-handler". Values: "allow", "block", "ask",
// "session-only" (cookies) and "default" (no exception: Chromium's default).
//
// Exceptions are set for the origin of `url` (Chromium's default scope for
// these types); an empty url addresses the profile-wide default. Must be
// called on the GUI thread (the CEF UI thread); initializes CEF if needed.
namespace ContentSettings {

QStringList types();
bool isType(const QString& type);
// Returns false for an unknown type or value, or if CEF is not running.
bool set(const QUrl& url, const QString& type, const QString& value);
// "allow", "block", "ask", "session-only", "default"; "" on error.
QString get(const QUrl& url, const QString& type);

}  // namespace ContentSettings
