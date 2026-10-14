#pragma once

#include <QFileSystemWatcher>
#include <QPointer>
#include <QQuickItem>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

class QQmlComponent;
class QQmlContext;

// Loads a QML file and reloads it whenever QML/JS files under its directory
// (or `watchPaths`) change. Works with the stock `qml` tool or any Qt app:
//
//   Window { HotReload { anchors.fill: parent; source: "App.qml" } }
//
// The loaded item fills the HotReload. Inside it, `hotReload` refers to this
// object; `hotReload.state` survives reloads (e.g. to keep open tabs).
// CEF itself is initialized once per process and is unaffected by reloads.
class HotReload : public QQuickItem {
  Q_OBJECT
  Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
  Q_PROPERTY(bool watch READ watch WRITE setWatch NOTIFY watchChanged)
  // Extra files/directories to watch (local paths or file: URLs).
  Q_PROPERTY(QStringList watchPaths READ watchPaths WRITE setWatchPaths NOTIFY watchPathsChanged)
  // Debounce between the last change and the reload, in ms.
  Q_PROPERTY(int delay READ delay WRITE setDelay NOTIFY delayChanged)
  Q_PROPERTY(QQuickItem* item READ item NOTIFY itemChanged)
  Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)
  // Increments on every (re)load.
  Q_PROPERTY(int generation READ generation NOTIFY reloaded)
  // Arbitrary data kept across reloads.
  Q_PROPERTY(QVariantMap state READ state WRITE setState NOTIFY stateChanged)

 public:
  explicit HotReload(QQuickItem* parent = nullptr);
  ~HotReload() override;

  QUrl source() const { return m_source; }
  void setSource(const QUrl& source);
  bool watch() const { return m_watch; }
  void setWatch(bool watch);
  QStringList watchPaths() const { return m_watchPaths; }
  void setWatchPaths(const QStringList& paths);
  int delay() const { return m_debounce.interval(); }
  void setDelay(int ms);
  QQuickItem* item() const { return m_item; }
  QString errorString() const { return m_error; }
  int generation() const { return m_generation; }
  QVariantMap state() const { return m_state; }
  void setState(const QVariantMap& state);

  // Reloads on the next event loop iteration (safe to call from the
  // reloaded content itself).
  Q_INVOKABLE void reload();

 Q_SIGNALS:
  void sourceChanged();
  void watchChanged();
  void watchPathsChanged();
  void delayChanged();
  void itemChanged();
  void errorStringChanged();
  void stateChanged();
  // Emitted right before the current content is destroyed: save state here.
  void aboutToReload();
  void reloaded();
  void failed(const QString& errorString);

 protected:
  void componentComplete() override;
  void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;

 private:
  void doReload();
  void load();
  void unload();
  void showError(const QString& error);
  void rewatch();
  void layoutItem();

  QUrl m_source;
  bool m_watch = true;
  QStringList m_watchPaths;
  QPointer<QQuickItem> m_item;
  QQmlComponent* m_component = nullptr;
  QQmlContext* m_context = nullptr;
  QString m_error;
  int m_generation = 0;
  QVariantMap m_state;
  QFileSystemWatcher m_watcher;
  QTimer m_debounce;
  bool m_reloadQueued = false;
};
