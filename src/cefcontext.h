#pragma once

#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>

#include <atomic>

struct sigaction;

class CefQmlClient;
class CefDownload;

// Process-wide CEF state.
//
// CEF can be initialized exactly once per process, on the main (GUI) thread,
// and must be shut down on that same thread before the process exits. We run
// CEF with `external_message_pump`, so the CEF UI thread *is* the Qt GUI thread
// and every CEF browser-process callback arrives on it. That keeps all QObject
// access single-threaded.
//
// Initialization is lazy (first CefWebView) and survives QML engine reloads
// (e.g. live-reloading QML), since CefInitialize cannot be called twice.
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
  QString runtimeDir() {
    if (m_runtimeDir.isEmpty())
      m_runtimeDir = locateRuntimeDir();
    return m_runtimeDir;
  }

  // Every download started in this process, oldest first.
  QList<CefDownload*> downloads() const { return m_downloads; }
  void addDownload(CefDownload* download);

  // Chromium profile directory of this process (root_cache_path): the
  // configured one (CEF_QML_CACHE_DIR or <GenericDataLocation>/cef-qml/<app>),
  // or a throwaway one when another live process holds it. Chosen once, on
  // first use, so reading it before CEF starts gives the same answer.
  QString profileDir();
  // Directory for the app's own persistent data (JsonStore), kept apart from
  // Chromium's files: "<configured profile>/cefqml". Always derived from the
  // *configured* profile, so a second instance that had to fall back to a
  // throwaway Chromium profile still sees the same app data.
  QString dataDir();

  // Chromium --ozone-platform value chosen for this process.
  QString ozonePlatform() const { return m_ozonePlatform; }

 Q_SIGNALS:
  void downloadsChanged();

 private:
  enum class State { Uninitialized, Running, Failed, ShutDown };

  CefContext();

  void onScheduleWork(qint64 delayMs);
  void doWork();
  bool performWork();
  void shutdown();
  void installQuitSignalHandlers(const struct sigaction* hostActions);

  static QString locateRuntimeDir();
  static QString configuredCacheDir();
  static QString chooseCacheDir();

  State m_state = State::Uninitialized;
  std::atomic_bool m_acceptWork{false};
  QTimer m_timer;
  bool m_inWork = false;
  bool m_reentrancyDetected = false;
  QSet<CefQmlClient*> m_clients;
  QList<CefDownload*> m_downloads;
  QString m_runtimeDir;
  QString m_profileDir;
  QString m_ozonePlatform;
};
