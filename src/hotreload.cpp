#include "hotreload.h"

#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>

namespace {

QString toLocalPath(const QString& pathOrUrl) {
  const QUrl url(pathOrUrl);
  if (url.isLocalFile())
    return url.toLocalFile();
  return pathOrUrl;
}

bool isSourceFile(const QString& name) {
  return name.endsWith(QLatin1String(".qml")) || name.endsWith(QLatin1String(".js")) ||
         name.endsWith(QLatin1String(".mjs")) || name == QLatin1String("qmldir");
}

// Shown while the source has errors; reloads again on the next save.
constexpr char kErrorQml[] = R"QML(
import QtQuick
Rectangle {
  property string message
  color: "#2a1d1f"
  Text {
    anchors.fill: parent; anchors.margins: 16
    text: "HotReload: failed to load\n\n" + parent.message
    color: "#ffb4ab"; font.family: "monospace"; font.pixelSize: 13
    wrapMode: Text.Wrap
  }
}
)QML";

}  // namespace

HotReload::HotReload(QQuickItem* parent) : QQuickItem(parent) {
  m_debounce.setSingleShot(true);
  m_debounce.setInterval(150);
  connect(&m_debounce, &QTimer::timeout, this, &HotReload::reload);
  connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_debounce,
          qOverload<>(&QTimer::start));
  connect(&m_watcher, &QFileSystemWatcher::fileChanged, &m_debounce,
          qOverload<>(&QTimer::start));
}

HotReload::~HotReload() {
  unload();
}

void HotReload::setSource(const QUrl& source) {
  if (source == m_source)
    return;
  m_source = source;
  Q_EMIT sourceChanged();
  if (isComponentComplete())
    reload();
}

void HotReload::setWatch(bool watch) {
  if (watch == m_watch)
    return;
  m_watch = watch;
  rewatch();
  Q_EMIT watchChanged();
}

void HotReload::setWatchPaths(const QStringList& paths) {
  if (paths == m_watchPaths)
    return;
  m_watchPaths = paths;
  rewatch();
  Q_EMIT watchPathsChanged();
}

void HotReload::setDelay(int ms) {
  if (ms == m_debounce.interval())
    return;
  m_debounce.setInterval(ms);
  Q_EMIT delayChanged();
}

void HotReload::setState(const QVariantMap& state) {
  if (state == m_state)
    return;
  m_state = state;
  Q_EMIT stateChanged();
}

void HotReload::componentComplete() {
  QQuickItem::componentComplete();
  load();
  rewatch();
}

void HotReload::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) {
  QQuickItem::geometryChange(newGeometry, oldGeometry);
  layoutItem();
}

void HotReload::layoutItem() {
  if (m_item) {
    m_item->setPosition(QPointF(0, 0));
    m_item->setSize(size());
  }
}

void HotReload::reload() {
  if (m_reloadQueued)
    return;
  m_reloadQueued = true;
  QMetaObject::invokeMethod(this, &HotReload::doReload, Qt::QueuedConnection);
}

void HotReload::doReload() {
  m_reloadQueued = false;
  Q_EMIT aboutToReload();
  unload();
  // Drop compiled components nobody uses anymore (the old tree is gone), so
  // edited files are read again. Unlike clearComponentCache() this leaves the
  // document hosting this item intact.
  if (QQmlEngine* engine = qmlEngine(this)) {
    // JS wrappers of the destroyed objects keep their compilation units
    // referenced until collected.
    engine->collectGarbage();
    engine->trimComponentCache();
  }
  load();
  rewatch();
}

void HotReload::unload() {
  if (m_item) {
    m_item->setParentItem(nullptr);
    delete m_item.data();
  }
  delete m_component;
  m_component = nullptr;
  delete m_context;
  m_context = nullptr;
}

void HotReload::showError(const QString& error) {
  m_error = error;
  Q_EMIT errorStringChanged();
  Q_EMIT failed(error);
  qWarning().noquote() << "HotReload:" << error;

  QQmlEngine* engine = qmlEngine(this);
  m_component = new QQmlComponent(engine, this);
  m_component->setData(kErrorQml, QUrl(QStringLiteral("hotreload-error.qml")));
  m_context = new QQmlContext(qmlContext(this), this);
  QObject* obj = m_component->create(m_context);
  if (auto* item = qobject_cast<QQuickItem*>(obj)) {
    item->setProperty("message", error);
    item->setParentItem(this);
    m_item = item;
    layoutItem();
  } else {
    delete obj;
  }
  Q_EMIT itemChanged();
}

void HotReload::load() {
  QQmlEngine* engine = qmlEngine(this);
  if (!engine || m_source.isEmpty())
    return;

  const QUrl url = qmlContext(this) ? qmlContext(this)->resolvedUrl(m_source) : m_source;
  m_component = new QQmlComponent(engine, url, QQmlComponent::PreferSynchronous, this);
  if (m_component->isLoading()) {
    showError(QStringLiteral("%1 must be a local file").arg(url.toString()));
    return;
  }
  if (m_component->isError()) {
    const QString err = m_component->errorString();
    delete m_component;
    m_component = nullptr;
    showError(err.trimmed());
    return;
  }

  m_context = new QQmlContext(qmlContext(this), this);
  m_context->setContextProperty(QStringLiteral("hotReload"), this);
  QObject* obj = m_component->beginCreate(m_context);
  auto* item = qobject_cast<QQuickItem*>(obj);
  if (!item) {
    if (obj) {
      m_component->completeCreate();
      delete obj;
    }
    const QString err = obj ? QStringLiteral("root object must be an Item")
                            : m_component->errorString().trimmed();
    delete m_component;
    m_component = nullptr;
    showError(err);
    return;
  }
  item->setParentItem(this);
  m_item = item;
  layoutItem();
  m_component->completeCreate();

  if (!m_error.isEmpty()) {
    m_error.clear();
    Q_EMIT errorStringChanged();
  }
  ++m_generation;
  Q_EMIT itemChanged();
  Q_EMIT reloaded();
}

void HotReload::rewatch() {
  const QStringList old = m_watcher.files() + m_watcher.directories();
  if (!old.isEmpty())
    m_watcher.removePaths(old);
  if (!m_watch || !isComponentComplete())
    return;

  QStringList roots;
  const QUrl url = qmlContext(this) ? qmlContext(this)->resolvedUrl(m_source) : m_source;
  if (url.isLocalFile())
    roots << QFileInfo(url.toLocalFile()).absolutePath();
  for (const QString& p : std::as_const(m_watchPaths))
    roots << toLocalPath(p);

  QStringList paths;
  for (const QString& root : std::as_const(roots)) {
    const QFileInfo info(root);
    if (info.isFile()) {
      paths << info.absoluteFilePath();
      continue;
    }
    if (!info.isDir())
      continue;
    paths << info.absoluteFilePath();
    QDirIterator it(root, QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot,
                    QDirIterator::Subdirectories);
    while (it.hasNext() && paths.size() < 2000) {
      const QFileInfo f(it.next());
      if (f.fileName().startsWith(QLatin1Char('.')))
        continue;
      if (f.isDir() || isSourceFile(f.fileName()))
        paths << f.absoluteFilePath();
    }
  }
  paths.removeDuplicates();
  if (!paths.isEmpty())
    m_watcher.addPaths(paths);
}
