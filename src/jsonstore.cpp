#include "jsonstore.h"

#include "cefcontext.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QUrl>

Q_LOGGING_CATEGORY(lcJsonStore, "cefqml.jsonstore")

namespace {

// Values assigned from QML can arrive as QJSValue (or contain them); make
// them plain variants so comparisons and JSON conversion work.
QVariant normalized(const QVariant& v) {
  if (v.metaType() == QMetaType::fromType<QJSValue>())
    return normalized(v.value<QJSValue>().toVariant());
  if (v.metaType() == QMetaType::fromType<QVariantMap>()) {
    QVariantMap m = v.toMap();
    for (auto it = m.begin(); it != m.end(); ++it)
      *it = normalized(*it);
    return m;
  }
  if (v.metaType() == QMetaType::fromType<QVariantList>()) {
    QVariantList l = v.toList();
    for (auto& e : l)
      e = normalized(e);
    return l;
  }
  return v;
}

}  // namespace

JsonStore::JsonStore(QObject* parent) : QObject(parent) {
  m_timer.setSingleShot(true);
  m_timer.setInterval(500);
  connect(&m_timer, &QTimer::timeout, this, &JsonStore::flush);
  // Destructors of QML objects do not always run at exit (e.g. a store in a
  // singleton or the root window of `qml`); aboutToQuit does.
  if (auto* app = QCoreApplication::instance())
    connect(app, &QCoreApplication::aboutToQuit, this, &JsonStore::flush);
}

JsonStore::~JsonStore() {
  flush();
}

void JsonStore::componentComplete() {
  m_complete = true;
  load();
}

QString JsonStore::resolvePath(const QString& path) {
  if (path.isEmpty())
    return {};
  QString p = path;
  if (p.startsWith(QLatin1String("file:")))
    p = QUrl(p).toLocalFile();
  if (QDir::isRelativePath(p))
    p = CefContext::instance()->dataDir() + QLatin1Char('/') + p;
  return QDir::cleanPath(p);
}

void JsonStore::setPath(const QString& path) {
  if (path == m_path)
    return;
  if (m_complete)
    flush();  // pending changes belong to the old file
  m_path = path;
  m_filePath = resolvePath(path);
  Q_EMIT pathChanged();
  if (m_complete)
    load();
}

void JsonStore::setData(const QVariant& data) {
  const QVariant v = normalized(data);
  if (v == m_data && v.metaType() == m_data.metaType())
    return;
  m_data = v;
  Q_EMIT dataChanged();
  // Before the first load this is the QML-assigned default, not a change.
  if (m_loaded)
    markDirty();
}

void JsonStore::setAutoSave(bool on) {
  if (on == m_autoSave)
    return;
  m_autoSave = on;
  Q_EMIT autoSaveChanged();
  if (on && m_dirty)
    m_timer.start();
  else if (!on)
    m_timer.stop();
}

void JsonStore::setSaveDelay(int ms) {
  ms = qMax(0, ms);
  if (ms == m_timer.interval())
    return;
  m_timer.setInterval(ms);
  Q_EMIT saveDelayChanged();
}

void JsonStore::markDirty() {
  setDirty(true);
  if (m_autoSave)
    m_timer.start();
}

void JsonStore::setDirty(bool dirty) {
  if (dirty == m_dirty)
    return;
  m_dirty = dirty;
  Q_EMIT dirtyChanged();
}

void JsonStore::setError(const QString& message) {
  if (!message.isEmpty())
    qCWarning(lcJsonStore).noquote() << message;
  if (message != m_error) {
    m_error = message;
    Q_EMIT errorStringChanged();
  }
  if (!message.isEmpty())
    Q_EMIT error(message);
}

void JsonStore::flush() {
  m_timer.stop();
  if (m_dirty)
    save();
}

bool JsonStore::load() {
  m_timer.stop();
  bool ok = true;
  QString err;
  if (!m_filePath.isEmpty()) {
    QFile f(m_filePath);
    if (f.exists()) {
      if (!f.open(QIODevice::ReadOnly)) {
        ok = false;
        err = QStringLiteral("JsonStore: cannot read %1: %2").arg(m_filePath, f.errorString());
      } else {
        QJsonParseError pe;
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &pe);
        f.close();
        if (pe.error != QJsonParseError::NoError) {
          ok = false;
          // Keep the unparsable file for inspection; the next save replaces it.
          const QString backup = m_filePath + QStringLiteral(".corrupt");
          QFile::remove(backup);
          QFile::copy(m_filePath, backup);
          err = QStringLiteral("JsonStore: %1 is not valid JSON (%2 at offset %3); kept as %4")
                    .arg(m_filePath, pe.errorString())
                    .arg(pe.offset)
                    .arg(backup);
        } else {
          m_data = doc.isArray() ? QVariant(doc.array().toVariantList())
                                 : QVariant(doc.object().toVariantMap());
          Q_EMIT dataChanged();
        }
      }
    }
  }
  setDirty(false);
  setError(err);
  if (!m_loaded) {
    m_loaded = true;
    Q_EMIT loadedChanged();
  }
  return ok;
}

bool JsonStore::reload() {
  return load();
}

bool JsonStore::save() {
  m_timer.stop();
  if (m_filePath.isEmpty()) {
    setDirty(false);
    return true;
  }
  QJsonDocument doc;
  if (m_data.metaType() == QMetaType::fromType<QVariantList>() ||
      m_data.metaType() == QMetaType::fromType<QStringList>()) {
    doc = QJsonDocument(QJsonArray::fromVariantList(m_data.toList()));
  } else if (!m_data.isValid() || m_data.isNull() ||
             m_data.metaType() == QMetaType::fromType<QVariantMap>()) {
    doc = QJsonDocument(QJsonObject::fromVariantMap(m_data.toMap()));
  } else {
    setError(QStringLiteral("JsonStore: data must be an object or an array (%1)")
                 .arg(m_filePath));
    return false;
  }

  QDir().mkpath(QFileInfo(m_filePath).absolutePath());
  QSaveFile f(m_filePath);
  if (!f.open(QIODevice::WriteOnly) || f.write(doc.toJson(QJsonDocument::Indented)) < 0 ||
      !f.commit()) {
    setError(QStringLiteral("JsonStore: cannot write %1: %2").arg(m_filePath, f.errorString()));
    return false;
  }
  setDirty(false);
  setError({});
  Q_EMIT saved();
  return true;
}

QVariant JsonStore::get(const QString& key, const QVariant& defaultValue) const {
  const QVariantMap m = m_data.toMap();
  auto it = m.constFind(key);
  return it == m.constEnd() ? defaultValue : *it;
}

void JsonStore::set(const QString& key, const QVariant& value) {
  QVariantMap m = m_data.toMap();
  const QVariant v = normalized(value);
  auto it = m.constFind(key);
  if (it != m.constEnd() && *it == v && it->metaType() == v.metaType())
    return;
  m.insert(key, v);
  setData(m);
}

void JsonStore::remove(const QString& key) {
  QVariantMap m = m_data.toMap();
  if (m.remove(key))
    setData(m);
}

QStringList JsonStore::keys() const {
  return m_data.toMap().keys();
}
