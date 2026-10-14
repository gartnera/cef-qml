#pragma once

#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>

#include <atomic>

class CefQmlClient;

// Process-wide CEF state.
//
// CEF can be initialized exactly once per process, on the main (GUI) thread,
// and must be shut down on that same thread before the process exits. We run
// CEF with `external_message_pump`, so the CEF UI thread *is* the Qt GUI thread
// and every CEF browser-process callback arrives on it. That keeps all QObject
// access single-threaded.
//
// Initialization is lazy (first CefWebView) and survives QML engine reloads
// (quickshell hot reload), since CefInitialize cannot be called twice.
class CefContext : public QObject {
  Q_OBJECT

 public:
  static CefContext* instance();

  // Initializes CEF on first call. Returns false if CEF failed to start.
  bool ensureInitialized();
  bool isInitialized() const { return m_state == State::Running; }

  // Thread-safe; called from CefBrowserProcessHandler::OnScheduleMessagePumpWork.
  void scheduleWork(qint64 delayMs);

  void registerClient(CefQmlClient* client);
  void unregisterClient(CefQmlClient* client);

  // Directory holding libcef.so, its resources and cef-qml-helper.
  QString runtimeDir() const { return m_runtimeDir; }

  // Chromium --ozone-platform value chosen for this process.
  QString ozonePlatform() const { return m_ozonePlatform; }

 private:
  enum class State { Uninitialized, Running, Failed, ShutDown };

  CefContext();

  void onScheduleWork(qint64 delayMs);
  void doWork();
  bool performWork();
  void shutdown();

  static QString locateRuntimeDir();
  static QString chooseCacheDir();

  State m_state = State::Uninitialized;
  std::atomic_bool m_acceptWork{false};
  QTimer m_timer;
  bool m_inWork = false;
  bool m_reentrancyDetected = false;
  QSet<CefQmlClient*> m_clients;
  QString m_runtimeDir;
  QString m_ozonePlatform;
};
