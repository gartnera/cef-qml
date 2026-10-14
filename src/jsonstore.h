#pragma once

#include <QObject>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariant>

// A JSON document persisted to a file, for app state such as userscripts,
// history or bookmarks:
//
//   JsonStore {
//       id: prefs
//       path: "prefs.json"            // relative: under Cef.dataDir
//       data: ({ theme: "dark" })     // default while the file does not exist
//   }
//   ... prefs.set("theme", "light")   // saved shortly afterwards
//
// The file is read when the component completes (and on reload() or a path
// change). Assigning `data` (or set()/remove()) after that marks the store
// dirty; with `autoSave` it is written `saveDelay` ms after the last change,
// and pending changes are always flushed on destruction and at application
// quit. Writes are atomic (QSaveFile): a crash leaves the old or the new file,
// never a truncated one. A file that cannot be parsed is kept as
// "<file>.corrupt", reported through errorString/error(), and the store
// continues with its default data.
//
// `data` is a plain value: mutating it in place (`store.data.x = 1`) changes
// a copy and is not seen; assign a new value or use set()/remove().
class JsonStore : public QObject, public QQmlParserStatus {
  Q_OBJECT
  Q_INTERFACES(QQmlParserStatus)
  // Relative paths resolve under Cef.dataDir; absolute paths and file: URLs
  // are used as is. Empty: in-memory only.
  Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
  // The absolute file path in use ("" without a path).
  Q_PROPERTY(QString filePath READ filePath NOTIFY pathChanged)
  Q_PROPERTY(QVariant data READ data WRITE setData NOTIFY dataChanged)
  // True once the file was read (or found missing / unreadable).
  Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
  // True while there are changes not yet written.
  Q_PROPERTY(bool dirty READ dirty NOTIFY dirtyChanged)
  Q_PROPERTY(bool autoSave READ autoSave WRITE setAutoSave NOTIFY autoSaveChanged)
  Q_PROPERTY(int saveDelay READ saveDelay WRITE setSaveDelay NOTIFY saveDelayChanged)
  // Last load/save error ("" after a successful load or save).
  Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)

 public:
  explicit JsonStore(QObject* parent = nullptr);
  ~JsonStore() override;

  void classBegin() override {}
  void componentComplete() override;

  QString path() const { return m_path; }
  void setPath(const QString& path);
  QString filePath() const { return m_filePath; }
  QVariant data() const { return m_data; }
  void setData(const QVariant& data);
  bool loaded() const { return m_loaded; }
  bool dirty() const { return m_dirty; }
  bool autoSave() const { return m_autoSave; }
  void setAutoSave(bool on);
  int saveDelay() const { return m_timer.interval(); }
  void setSaveDelay(int ms);
  QString errorString() const { return m_error; }

  // Writes now (if there is a path). Returns false on error.
  Q_INVOKABLE bool save();
  // Discards unsaved changes and reads the file again. Returns false if the
  // file exists but could not be read or parsed.
  Q_INVOKABLE bool reload();

  // Object helpers (`data` must be an object or unset).
  Q_INVOKABLE QVariant get(const QString& key, const QVariant& defaultValue = {}) const;
  Q_INVOKABLE void set(const QString& key, const QVariant& value);
  Q_INVOKABLE void remove(const QString& key);
  Q_INVOKABLE QStringList keys() const;

 Q_SIGNALS:
  void pathChanged();
  void dataChanged();
  void loadedChanged();
  void dirtyChanged();
  void autoSaveChanged();
  void saveDelayChanged();
  void errorStringChanged();
  void saved();
  void error(const QString& message);

 private:
  QString resolve(const QString& path) const;
  bool load();
  void markDirty();
  void setDirty(bool dirty);
  void setError(const QString& message);
  void flush();

  QString m_path;
  QString m_filePath;
  QVariant m_data;
  bool m_complete = false;
  bool m_loaded = false;
  bool m_dirty = false;
  bool m_autoSave = true;
  QString m_error;
  QTimer m_timer;
};
