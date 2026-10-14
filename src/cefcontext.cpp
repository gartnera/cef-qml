#include "cefcontext.h"

#include "cefclient.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QProcess>
#include <QStandardPaths>
#include <QThread>
#include <QElapsedTimer>

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

#include <climits>

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_version_info.h"

Q_LOGGING_CATEGORY(lcCef, "cefqml")

namespace {

// Matches cefclient's MainMessageLoopExternalPump: never sleep longer than
// this between CefDoMessageLoopWork() calls.
constexpr qint64 kMaxTimerDelayMs = 1000 / 30;
constexpr qint64 kTimerDelayPlaceholder = INT_MAX;

QString envString(const char* name) {
  return qEnvironmentVariable(name);
}

class CefQmlApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit CefQmlApp(QString ozonePlatform)
      : m_ozonePlatform(std::move(ozonePlatform)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& processType,
      CefRefPtr<CefCommandLine> commandLine) override {
    if (!processType.empty())
      return;

    commandLine->AppendSwitchWithValue("ozone-platform",
                                       m_ozonePlatform.toStdString());

    // We read frames back through CefRenderHandler::OnPaint, so GPU
    // compositing only adds a GPU->CPU copy (OBS does the same).
    if (!qEnvironmentVariableIsSet("CEF_QML_ENABLE_GPU_COMPOSITING"))
      commandLine->AppendSwitch("disable-gpu-compositing");

    // Embedded browsers should not nag about restoring sessions, etc.
    commandLine->AppendSwitch("hide-crash-restore-bubble");
    commandLine->AppendSwitch("disable-session-crashed-bubble");

    // Arbitrary extra Chromium switches, e.g.
    // CEF_QML_FLAGS="--enable-features=Foo --force-device-scale-factor=2"
    const QStringList extra = QProcess::splitCommand(envString("CEF_QML_FLAGS"));
    for (const QString& arg : extra) {
      QString sw = arg;
      while (sw.startsWith(QLatin1Char('-')))
        sw.remove(0, 1);
      if (sw.isEmpty())
        continue;
      const int eq = sw.indexOf(QLatin1Char('='));
      if (eq < 0) {
        commandLine->AppendSwitch(sw.toStdString());
      } else {
        commandLine->AppendSwitchWithValue(sw.left(eq).toStdString(),
                                           sw.mid(eq + 1).toStdString());
      }
    }
  }

  void OnScheduleMessagePumpWork(int64_t delayMs) override {
    CefContext::instance()->scheduleWork(delayMs);
  }

 private:
  QString m_ozonePlatform;
  IMPLEMENT_REFCOUNTING(CefQmlApp);
};

}  // namespace

CefContext* CefContext::instance() {
  // Intentionally leaked: it must outlive every QML engine and CEF itself.
  static CefContext* ctx = new CefContext();
  return ctx;
}

CefContext::CefContext() {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &CefContext::doWork);
}

QString CefContext::locateRuntimeDir() {
  const QString env = envString("CEF_QML_RUNTIME_DIR");
  if (!env.isEmpty())
    return QDir(env).absolutePath();

  // libcef.so was found through the plugin's RPATH; everything else ships
  // next to it.
  Dl_info info{};
  if (dladdr(reinterpret_cast<void*>(&cef_version_info), &info) &&
      info.dli_fname) {
    return QFileInfo(QString::fromLocal8Bit(info.dli_fname)).absolutePath();
  }
  return {};
}

QString CefContext::chooseCacheDir() {
  QString dir = envString("CEF_QML_CACHE_DIR");
  if (dir.isEmpty()) {
    QString app = QCoreApplication::applicationName();
    if (app.isEmpty())
      app = QStringLiteral("default");
    dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) +
          QStringLiteral("/cef-qml/") + app;
  }

  // Chromium allows one browser process per profile directory. If another
  // live process holds it (e.g. a second quickshell instance), fall back to a
  // private throwaway profile instead of failing to start.
  // The lock is a dangling symlink whose target is "<hostname>-<pid>".
  const QByteArray lockPath = QFile::encodeName(dir + QStringLiteral("/SingletonLock"));
  char target[512] = {};
  const ssize_t len = readlink(lockPath.constData(), target, sizeof(target) - 1);
  if (len > 0) {
    const QString name = QString::fromLocal8Bit(target, int(len));
    const int dash = name.lastIndexOf(QLatin1Char('-'));
    bool ok = false;
    const pid_t pid = dash >= 0 ? name.mid(dash + 1).toInt(&ok) : 0;
    char host[256] = {};
    gethostname(host, sizeof(host) - 1);
    if (ok && pid != getpid() && name.left(dash) == QString::fromLocal8Bit(host) &&
        kill(pid, 0) == 0) {
      QString base = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
      if (base.isEmpty())
        base = QDir::tempPath();
      const QString fallback =
          base + QStringLiteral("/cef-qml-%1").arg(QCoreApplication::applicationPid());
      qCWarning(lcCef) << "profile" << dir << "is in use by pid" << pid
                       << "- using temporary profile" << fallback;
      dir = fallback;
    }
  }
  QDir().mkpath(dir);
  return dir;
}

bool CefContext::ensureInitialized() {
  if (m_state == State::Running)
    return true;
  if (m_state != State::Uninitialized)
    return false;

  Q_ASSERT(QThread::currentThread() == QCoreApplication::instance()->thread());
  m_state = State::Failed;

  m_runtimeDir = locateRuntimeDir();
  const QString helper = m_runtimeDir + QStringLiteral("/cef-qml-helper");
  if (!QFileInfo(helper).isExecutable()) {
    qCCritical(lcCef) << "CEF helper not found at" << helper
                      << "(set CEF_QML_RUNTIME_DIR)";
    return false;
  }

  m_ozonePlatform = envString("CEF_QML_OZONE_PLATFORM");
  if (m_ozonePlatform.isEmpty()) {
    const QString qpa = QGuiApplication::platformName();
    if (qpa.startsWith(QLatin1String("wayland")))
      m_ozonePlatform = QStringLiteral("wayland");
    else if (qpa == QLatin1String("xcb"))
      m_ozonePlatform = QStringLiteral("x11");
    else
      m_ozonePlatform = QStringLiteral("headless");
  }

  // Do not hand the host's argv to Chromium: quickshell's own flags would be
  // parsed as Chromium switches.
  static char arg0[] = "cef-qml";
  static char* argv[] = {arg0, nullptr};
  CefMainArgs mainArgs(1, argv);

  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  settings.multi_threaded_message_loop = false;
  settings.windowless_rendering_enabled = true;
  // Leave the host's crash/signal handlers alone.
  settings.disable_signal_handlers = true;
  settings.persist_session_cookies = true;
  CefString(&settings.browser_subprocess_path) = helper.toStdString();
  CefString(&settings.resources_dir_path) = m_runtimeDir.toStdString();
  CefString(&settings.locales_dir_path) =
      (m_runtimeDir + QStringLiteral("/locales")).toStdString();

  const QString cacheDir = chooseCacheDir();
  CefString(&settings.root_cache_path) = cacheDir.toStdString();
  CefString(&settings.cache_path) = cacheDir.toStdString();

  const QString logFile = envString("CEF_QML_LOG_FILE");
  if (!logFile.isEmpty())
    CefString(&settings.log_file) = logFile.toStdString();
  settings.log_severity = qEnvironmentVariableIsSet("CEF_QML_VERBOSE")
                              ? LOGSEVERITY_INFO
                              : LOGSEVERITY_ERROR;

  bool portOk = false;
  const int port = qEnvironmentVariableIntValue("CEF_QML_REMOTE_DEBUGGING_PORT", &portOk);
  if (portOk && port > 0)
    settings.remote_debugging_port = port;

  qCInfo(lcCef) << "initializing CEF" << cef_version_info(0) << "runtime"
                << m_runtimeDir << "ozone" << m_ozonePlatform << "profile" << cacheDir;

  m_acceptWork = true;
  CefRefPtr<CefQmlApp> app(new CefQmlApp(m_ozonePlatform));
  if (!CefInitialize(mainArgs, settings, app, nullptr)) {
    m_acceptWork = false;
    qCCritical(lcCef) << "CefInitialize failed, exit code" << CefGetExitCode();
    return false;
  }

  m_state = State::Running;
  connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, this,
          &CefContext::shutdown);
  scheduleWork(0);
  return true;
}

void CefContext::scheduleWork(qint64 delayMs) {
  if (!m_acceptWork)
    return;
  QMetaObject::invokeMethod(
      this, [this, delayMs] { onScheduleWork(delayMs); }, Qt::QueuedConnection);
}

void CefContext::onScheduleWork(qint64 delayMs) {
  if (m_state != State::Running)
    return;
  if (delayMs == kTimerDelayPlaceholder && m_timer.isActive())
    return;  // keep the sooner timer
  m_timer.stop();
  if (delayMs <= 0)
    doWork();
  else
    m_timer.start(int(std::min(delayMs, kMaxTimerDelayMs)));
}

bool CefContext::performWork() {
  if (m_inWork) {
    // CefDoMessageLoopWork must not be re-entered; run again afterwards.
    m_reentrancyDetected = true;
    return false;
  }
  m_reentrancyDetected = false;
  m_inWork = true;
  CefDoMessageLoopWork();
  m_inWork = false;
  return m_reentrancyDetected;
}

void CefContext::doWork() {
  if (m_state != State::Running)
    return;
  const bool reentrant = performWork();
  if (reentrant)
    scheduleWork(0);
  else if (!m_timer.isActive())
    scheduleWork(kTimerDelayPlaceholder);
}

void CefContext::registerClient(CefQmlClient* client) {
  m_clients.insert(client);
}

void CefContext::unregisterClient(CefQmlClient* client) {
  m_clients.remove(client);
}

void CefContext::shutdown() {
  if (m_state != State::Running)
    return;

  // Every browser must be closed (OnBeforeClose) before CefShutdown().
  const auto clients = m_clients;
  for (CefQmlClient* c : clients)
    c->closeBrowser(true);

  QElapsedTimer t;
  t.start();
  while (!m_clients.isEmpty() && t.elapsed() < 3000) {
    performWork();
    QThread::msleep(5);
  }
  if (!m_clients.isEmpty())
    qCWarning(lcCef) << m_clients.size() << "browser(s) did not close before shutdown";

  m_timer.stop();
  m_state = State::ShutDown;
  m_acceptWork = false;
  CefShutdown();
}
