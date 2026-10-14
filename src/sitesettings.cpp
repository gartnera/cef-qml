#include "sitesettings.h"

#include "contentsettings.h"
#include "jsonstore.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QSaveFile>

#include <algorithm>

Q_LOGGING_CATEGORY(lcSiteSettings, "cefqml.sitesettings")

namespace {

const QString kDefaultScope = QStringLiteral("*");
const QString kPatternPrefix = QStringLiteral("[*.]");

// Every name CefPermissionRequest.permissions can hold, plus "sensors".
const QSet<QString>& permissionNames() {
  static const QSet<QString> names = {
      QStringLiteral("camera"),
      QStringLiteral("microphone"),
      QStringLiteral("desktop-audio"),
      QStringLiteral("desktop-video"),
      QStringLiteral("geolocation"),
      QStringLiteral("notifications"),
      QStringLiteral("clipboard"),
      QStringLiteral("midi-sysex"),
      QStringLiteral("local-fonts"),
      QStringLiteral("idle-detection"),
      QStringLiteral("window-management"),
      QStringLiteral("pointer-lock"),
      QStringLiteral("keyboard-lock"),
      QStringLiteral("storage-access"),
      QStringLiteral("top-level-storage-access"),
      QStringLiteral("multiple-downloads"),
      QStringLiteral("register-protocol-handler"),
      QStringLiteral("protected-media-identifier"),
      QStringLiteral("ar-session"),
      QStringLiteral("vr-session"),
      QStringLiteral("hand-tracking"),
      QStringLiteral("camera-pan-tilt-zoom"),
      QStringLiteral("captured-surface-control"),
      QStringLiteral("disk-quota"),
      QStringLiteral("identity-provider"),
      QStringLiteral("web-app-installation"),
      QStringLiteral("file-system-access"),
      QStringLiteral("local-network"),
      QStringLiteral("loopback-network"),
      QStringLiteral("sensors"),
  };
  return names;
}

bool isSwitchKey(const QString& key) {
  return key == QLatin1String("javascript") || key == QLatin1String("images") ||
         key == QLatin1String("popups");
}

// Keys mirrored into Chromium's content settings.
const QStringList& contentKeys() {
  static const QStringList keys = [] {
    QStringList list;
    for (const QString& t : ContentSettings::types()) {
      if (t != QLatin1String("cookies") && t != QLatin1String("sound"))
        list << t;
    }
    return list;
  }();
  return keys;
}

QVariant plain(const QVariant& v) {
  if (v.metaType() == QMetaType::fromType<QJSValue>())
    return v.value<QJSValue>().toVariant();
  return v;
}

QUrl toUrl(const QVariant& v) {
  const QVariant p = plain(v);
  if (p.metaType() == QMetaType::fromType<QUrl>())
    return p.toUrl();
  return QUrl(p.toString().trimmed());
}

bool validHostLabel(const QString& host) {
  if (host.isEmpty())
    return false;
  for (const QChar c : host) {
    if (c.isSpace() || QStringLiteral("/:?#@*[]\\").contains(c))
      return false;
  }
  return true;
}

QString aceHost(QString host) {
  host = host.toLower();
  while (host.endsWith(QLatin1Char('.')))
    host.chop(1);
  if (!validHostLabel(host))
    return {};
  return QString::fromLatin1(QUrl::toAce(host));
}

}  // namespace

SiteSettings::SiteSettings(QObject* parent) : QAbstractListModel(parent) {
  m_timer.setSingleShot(true);
  m_timer.setInterval(500);
  connect(&m_timer, &QTimer::timeout, this, &SiteSettings::flush);
  if (auto* app = QCoreApplication::instance())
    connect(app, &QCoreApplication::aboutToQuit, this, &SiteSettings::flush);
  auto countChange = [this] { Q_EMIT countChanged(); };
  connect(this, &QAbstractItemModel::rowsInserted, this, countChange);
  connect(this, &QAbstractItemModel::rowsRemoved, this, countChange);
  connect(this, &QAbstractItemModel::modelReset, this, countChange);
}

SiteSettings::~SiteSettings() {
  flush();
}

void SiteSettings::componentComplete() {
  m_complete = true;
  m_filePath = JsonStore::resolvePath(m_path);
  load();
}

void SiteSettings::ensureLoaded() {
  if (!m_complete) {
    m_complete = true;
    m_filePath = JsonStore::resolvePath(m_path);
    load();
  }
}

// ---- model -----------------------------------------------------------------

int SiteSettings::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : m_scopes.size();
}

QVariant SiteSettings::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() < 0 || index.row() >= m_scopes.size())
    return {};
  const Scope& s = m_scopes.at(index.row());
  switch (role) {
    case Qt::DisplayRole:
    case NameRole:
      return s.name;
    case ScopeRole:
      return s.key;
    case KindRole:
      return s.kind;
    case SettingsRole:
      return s.values;
    case KeysRole:
      return QStringList(s.values.keys());
  }
  return {};
}

QHash<int, QByteArray> SiteSettings::roleNames() const {
  return {{ScopeRole, "scope"},
          {NameRole, "name"},
          {KindRole, "kind"},
          {SettingsRole, "settings"},
          {KeysRole, "keys"}};
}

QVariant SiteSettings::get(int row) const {
  if (row < 0 || row >= m_scopes.size())
    return {};
  const Scope& s = m_scopes.at(row);
  return QVariantMap{{QStringLiteral("scope"), s.key},
                     {QStringLiteral("name"), s.name},
                     {QStringLiteral("kind"), s.kind},
                     {QStringLiteral("settings"), s.values},
                     {QStringLiteral("keys"), QStringList(s.values.keys())}};
}

int SiteSettings::rowOf(const QString& scope) const {
  for (int i = 0; i < m_scopes.size(); ++i) {
    if (m_scopes.at(i).key == scope)
      return i;
  }
  return -1;
}

namespace {
int kindRank(const QString& kind) {
  if (kind == QLatin1String("default")) return 0;
  if (kind == QLatin1String("pattern")) return 1;
  if (kind == QLatin1String("host")) return 2;
  return 3;
}
}  // namespace

int SiteSettings::insertionRow(const Scope& s) const {
  auto less = [](const Scope& a, const Scope& b) {
    const int ra = a.kind == QLatin1String("default") ? 0 : 1;
    const int rb = b.kind == QLatin1String("default") ? 0 : 1;
    if (ra != rb)
      return ra < rb;
    const int c = a.name.compare(b.name, Qt::CaseInsensitive);
    if (c != 0)
      return c < 0;
    if (kindRank(a.kind) != kindRank(b.kind))
      return kindRank(a.kind) < kindRank(b.kind);
    return a.key < b.key;
  };
  return int(std::lower_bound(m_scopes.begin(), m_scopes.end(), s, less) - m_scopes.begin());
}

// ---- properties ------------------------------------------------------------

void SiteSettings::setPath(const QString& path) {
  if (path == m_path)
    return;
  if (m_complete)
    flush();
  m_path = path;
  if (m_complete) {
    m_filePath = JsonStore::resolvePath(path);
    load();
  }
  Q_EMIT pathChanged();
}

void SiteSettings::setContentSettings(bool on) {
  if (on == m_contentSettings)
    return;
  m_contentSettings = on;
  if (on && m_loaded) {
    for (const QString& k : contentKeys())
      pushDefault(k);
    for (const QString& origin : std::as_const(m_applied))
      pushOrigin(origin);
  }
  Q_EMIT contentSettingsChanged();
}

void SiteSettings::setSaveDelay(int ms) {
  ms = qMax(0, ms);
  if (ms == m_timer.interval())
    return;
  m_timer.setInterval(ms);
  Q_EMIT saveDelayChanged();
}

void SiteSettings::setError(const QString& message) {
  if (!message.isEmpty())
    qCWarning(lcSiteSettings).noquote() << message;
  if (message != m_error) {
    m_error = message;
    Q_EMIT errorStringChanged();
  }
}

// ---- scopes ----------------------------------------------------------------

QString SiteSettings::originOf(const QVariant& value) const {
  const QUrl url = toUrl(value);
  const QString scheme = url.scheme().toLower();
  if (scheme == QLatin1String("blob") || scheme == QLatin1String("filesystem"))
    return originOf(QUrl(url.path()));
  if (scheme == QLatin1String("file"))
    return QStringLiteral("file://");
  const QString host = url.host(QUrl::FullyEncoded).toLower();
  if (scheme.isEmpty() || host.isEmpty())
    return {};
  int port = url.port();
  if ((port == 80 && (scheme == QLatin1String("http") || scheme == QLatin1String("ws"))) ||
      (port == 443 && (scheme == QLatin1String("https") || scheme == QLatin1String("wss"))) ||
      (port == 21 && scheme == QLatin1String("ftp")))
    port = -1;
  QUrl o;
  o.setScheme(scheme);
  o.setHost(host);
  if (port >= 0)
    o.setPort(port);
  return o.toString(QUrl::FullyEncoded);
}

QString SiteSettings::normalizeScope(const QVariant& value) const {
  const QVariant p = plain(value);
  const QString s = p.metaType() == QMetaType::fromType<QUrl>()
                        ? p.toUrl().toString()
                        : p.toString().trimmed();
  if (s == kDefaultScope)
    return s;
  if (s.startsWith(kPatternPrefix)) {
    const QString host = aceHost(s.mid(kPatternPrefix.size()));
    return host.isEmpty() ? QString() : kPatternPrefix + host;
  }
  if (s.contains(QLatin1String("://")) || s.startsWith(QLatin1String("file:")))
    return originOf(QUrl(s));
  return aceHost(s);
}

QString SiteSettings::scopeKind(const QString& scope) const {
  if (scope == kDefaultScope)
    return QStringLiteral("default");
  if (scope.startsWith(kPatternPrefix))
    return QStringLiteral("pattern");
  if (scope.contains(QLatin1String("://")))
    return QStringLiteral("origin");
  return QStringLiteral("host");
}

QString SiteSettings::scopeName(const QString& scope) const {
  if (scope == kDefaultScope)
    return scope;
  if (scope.startsWith(kPatternPrefix))
    return QUrl::fromAce(scope.mid(kPatternPrefix.size()).toLatin1());
  if (scope.contains(QLatin1String("://"))) {
    const QUrl u(scope);
    if (u.scheme() == QLatin1String("file"))
      return QStringLiteral("file");
    return u.host(QUrl::PrettyDecoded);
  }
  return QUrl::fromAce(scope.toLatin1());
}

// ---- values ----------------------------------------------------------------

bool SiteSettings::isPermission(const QString& key) const {
  return permissionNames().contains(key);
}

QVariant SiteSettings::defaultValue(const QString& key) const {
  if (key == QLatin1String("zoom"))
    return 1.0;
  if (key == QLatin1String("popups"))
    return QStringLiteral("block");
  if (isSwitchKey(key))
    return QStringLiteral("allow");
  if (isPermission(key))
    return QStringLiteral("ask");
  return {};
}

QVariant SiteSettings::get(const QVariant& scope, const QString& key) const {
  const int row = rowOf(normalizeScope(scope));
  return row < 0 ? QVariant() : m_scopes.at(row).values.value(key);
}

QVariantMap SiteSettings::settings(const QVariant& scope) const {
  const int row = rowOf(normalizeScope(scope));
  return row < 0 ? QVariantMap() : m_scopes.at(row).values;
}

bool SiteSettings::contains(const QVariant& scope) const {
  return rowOf(normalizeScope(scope)) >= 0;
}

QStringList SiteSettings::origins() const {
  QStringList list;
  for (const Scope& s : m_scopes)
    list << s.key;
  return list;
}

bool SiteSettings::set(const QVariant& scopeValue, const QString& key, const QVariant& rawValue) {
  ensureLoaded();
  const QString scope = normalizeScope(scopeValue);
  if (scope.isEmpty() || key.isEmpty()) {
    qCWarning(lcSiteSettings) << "SiteSettings.set: invalid scope" << scopeValue << "or key" << key;
    return false;
  }
  QVariant value = plain(rawValue);
  if (!value.isValid() || value.isNull())
    return reset(scope, key);

  if (key == QLatin1String("zoom")) {
    bool ok = false;
    const double z = value.toDouble(&ok);
    if (!ok || !(z > 0)) {
      qCWarning(lcSiteSettings) << "SiteSettings.set: invalid zoom" << value;
      return false;
    }
    value = std::clamp(z, 0.25, 5.0);
  } else if (isSwitchKey(key) || isPermission(key)) {
    const QString v = value.toString();
    const bool ok = v == QLatin1String("allow") || v == QLatin1String("block") ||
                    (isPermission(key) && v == QLatin1String("ask"));
    if (!ok) {
      qCWarning(lcSiteSettings) << "SiteSettings.set: invalid value" << value << "for" << key;
      return false;
    }
    value = v;
  }

  int row = rowOf(scope);
  if (row >= 0) {
    Scope& s = m_scopes[row];
    if (s.values.value(key) == value)
      return true;
    s.values.insert(key, value);
    const QModelIndex idx = index(row);
    Q_EMIT dataChanged(idx, idx, {SettingsRole, KeysRole});
  } else {
    Scope s{scope, scopeName(scope), scopeKind(scope), {{key, value}}};
    row = insertionRow(s);
    beginInsertRows({}, row, row);
    m_scopes.insert(row, s);
    endInsertRows();
  }
  markDirty();
  notifyChanged(scope, key);
  return true;
}

bool SiteSettings::reset(const QVariant& scopeValue, const QString& key) {
  ensureLoaded();
  const QString scope = normalizeScope(scopeValue);
  const int row = rowOf(scope);
  if (row < 0)
    return scope.isEmpty() ? false : true;
  Scope& s = m_scopes[row];
  if (!key.isEmpty()) {
    if (!s.values.contains(key))
      return true;
    s.values.remove(key);
  }
  if (key.isEmpty() || s.values.isEmpty()) {
    beginRemoveRows({}, row, row);
    m_scopes.removeAt(row);
    endRemoveRows();
  } else {
    const QModelIndex idx = index(row);
    Q_EMIT dataChanged(idx, idx, {SettingsRole, KeysRole});
  }
  markDirty();
  notifyChanged(scope, key);
  return true;
}

void SiteSettings::clear() {
  ensureLoaded();
  if (m_scopes.isEmpty())
    return;
  const QStringList defaults =
      rowOf(kDefaultScope) >= 0 ? QStringList(m_scopes.at(rowOf(kDefaultScope)).values.keys())
                                : QStringList();
  beginResetModel();
  m_scopes.clear();
  endResetModel();
  markDirty();
  if (m_contentSettings) {
    for (const QString& k : defaults)
      pushDefault(k);
  }
  notifyChanged(QString(), QString());
}

QVariant SiteSettings::lookup(const QVariant& urlValue, const QString& key, QString* from,
                              bool withDefault) const {
  const QUrl url = toUrl(urlValue);
  const QString origin = originOf(url);
  auto valueIn = [&](const QString& scope, QVariant* out) {
    const int row = rowOf(scope);
    if (row < 0)
      return false;
    const auto it = m_scopes.at(row).values.constFind(key);
    if (it == m_scopes.at(row).values.cend())
      return false;
    *out = *it;
    if (from)
      *from = scope;
    return true;
  };
  QVariant v;
  if (!origin.isEmpty()) {
    if (valueIn(origin, &v))
      return v;
    const QString host = origin.startsWith(QLatin1String("file:"))
                             ? QString()
                             : url.host(QUrl::FullyEncoded).toLower();
    if (!host.isEmpty()) {
      if (valueIn(host, &v))
        return v;
      // Patterns: the longest matching domain wins.
      int best = -1;
      int bestLen = -1;
      for (int i = 0; i < m_scopes.size(); ++i) {
        const Scope& s = m_scopes.at(i);
        if (s.kind != QLatin1String("pattern") || !s.values.contains(key))
          continue;
        const QString domain = s.key.mid(kPatternPrefix.size());
        if ((host == domain || host.endsWith(QLatin1Char('.') + domain)) &&
            domain.size() > bestLen) {
          best = i;
          bestLen = domain.size();
        }
      }
      if (best >= 0) {
        if (from)
          *from = m_scopes.at(best).key;
        return m_scopes.at(best).values.value(key);
      }
    }
  }
  if (withDefault && valueIn(kDefaultScope, &v))
    return v;
  if (from)
    from->clear();
  return {};
}

QVariant SiteSettings::effective(const QVariant& url, const QString& key) const {
  const QVariant v = lookup(url, key, nullptr, true);
  return v.isValid() ? v : defaultValue(key);
}

QString SiteSettings::scopeFor(const QVariant& url, const QString& key) const {
  QString from;
  lookup(url, key, &from, true);
  return from;
}

QString SiteSettings::decide(const QVariant& url, const QStringList& permissions) const {
  if (permissions.isEmpty())
    return QStringLiteral("ask");
  bool all = true;
  for (const QString& p : permissions) {
    const QString v = effective(url, p).toString();
    if (v == QLatin1String("block"))
      return v;
    if (v != QLatin1String("allow"))
      all = false;
  }
  return all ? QStringLiteral("allow") : QStringLiteral("ask");
}

// ---- Chromium content settings ---------------------------------------------

void SiteSettings::apply(const QVariant& url) {
  if (!m_contentSettings)
    return;
  ensureLoaded();
  const QString origin = originOf(url);
  if (!origin.startsWith(QLatin1String("http://")) && !origin.startsWith(QLatin1String("https://")))
    return;
  m_applied.insert(origin);
  pushOrigin(origin);
}

// The origin's own exception: from its origin, host or pattern scope; the
// "*" scope is Chromium's default (pushDefault), so it is left out here.
void SiteSettings::pushOrigin(const QString& origin) {
  const QUrl url(origin + QLatin1Char('/'));
  for (const QString& key : contentKeys()) {
    const QVariant v = lookup(url, key, nullptr, false);
    ContentSettings::set(url, key, v.isValid() ? v.toString() : QStringLiteral("default"));
  }
}

void SiteSettings::pushDefault(const QString& key) {
  if (!contentKeys().contains(key))
    return;
  const int row = rowOf(kDefaultScope);
  const QVariant v = row < 0 ? QVariant() : m_scopes.at(row).values.value(key);
  ContentSettings::set(QUrl(), key, v.isValid() ? v.toString() : QStringLiteral("default"));
}

void SiteSettings::notifyChanged(const QString& scope, const QString& key) {
  ++m_revision;
  if (m_contentSettings && (key.isEmpty() || contentKeys().contains(key))) {
    if (scope == kDefaultScope) {
      if (key.isEmpty()) {
        for (const QString& k : contentKeys())
          pushDefault(k);
      } else {
        pushDefault(key);
      }
    } else {
      if (scope.startsWith(QLatin1String("http://")) || scope.startsWith(QLatin1String("https://")))
        m_applied.insert(scope);
      for (const QString& origin : std::as_const(m_applied))
        pushOrigin(origin);
    }
  }
  Q_EMIT revisionChanged();
  Q_EMIT changed(scope, key);
}

// ---- persistence -----------------------------------------------------------

void SiteSettings::markDirty() {
  m_dirty = true;
  if (!m_filePath.isEmpty())
    m_timer.start();
}

void SiteSettings::flush() {
  m_timer.stop();
  if (m_dirty)
    save();
}

bool SiteSettings::load() {
  m_timer.stop();
  QList<Scope> scopes;
  QString err;
  bool ok = true;
  if (!m_filePath.isEmpty()) {
    QFile f(m_filePath);
    if (f.exists()) {
      if (!f.open(QIODevice::ReadOnly)) {
        ok = false;
        err = QStringLiteral("SiteSettings: cannot read %1: %2").arg(m_filePath, f.errorString());
      } else {
        QJsonParseError pe;
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &pe);
        f.close();
        if (pe.error != QJsonParseError::NoError) {
          ok = false;
          const QString backup = m_filePath + QStringLiteral(".corrupt");
          QFile::remove(backup);
          QFile::copy(m_filePath, backup);
          err = QStringLiteral("SiteSettings: %1 is not valid JSON (%2 at offset %3); kept as %4")
                    .arg(m_filePath, pe.errorString())
                    .arg(pe.offset)
                    .arg(backup);
        } else {
          const QJsonObject sites = doc.object().value(QLatin1String("sites")).toObject();
          for (auto it = sites.begin(); it != sites.end(); ++it) {
            const QString scope = normalizeScope(it.key());
            const QVariantMap values = it.value().toObject().toVariantMap();
            if (scope.isEmpty() || values.isEmpty())
              continue;
            Scope s{scope, scopeName(scope), scopeKind(scope), values};
            scopes.append(s);
          }
        }
      }
    }
  }
  beginResetModel();
  m_scopes.clear();
  for (const Scope& s : std::as_const(scopes))
    m_scopes.insert(insertionRow(s), s);
  endResetModel();
  m_dirty = false;
  setError(err);
  if (!m_loaded) {
    m_loaded = true;
    Q_EMIT loadedChanged();
  }
  if (m_contentSettings) {
    // Every default, not only the stored ones: Chromium keeps its content
    // settings in the profile, so defaults from an earlier run whose scope
    // is gone (file deleted or edited) would otherwise stay in force.
    for (const QString& k : contentKeys())
      pushDefault(k);
    for (const QString& origin : std::as_const(m_applied))
      pushOrigin(origin);
  }
  ++m_revision;
  Q_EMIT revisionChanged();
  Q_EMIT changed(QString(), QString());
  return ok;
}

bool SiteSettings::reload() {
  ensureLoaded();
  return load();
}

bool SiteSettings::save() {
  m_timer.stop();
  if (m_filePath.isEmpty()) {
    m_dirty = false;
    return true;
  }
  QJsonObject sites;
  for (const Scope& s : std::as_const(m_scopes))
    sites.insert(s.key, QJsonObject::fromVariantMap(s.values));
  const QJsonObject root{{QLatin1String("version"), 1}, {QLatin1String("sites"), sites}};
  QDir().mkpath(QFileInfo(m_filePath).absolutePath());
  QSaveFile f(m_filePath);
  if (!f.open(QIODevice::WriteOnly) ||
      f.write(QJsonDocument(root).toJson(QJsonDocument::Indented)) < 0 || !f.commit()) {
    setError(QStringLiteral("SiteSettings: cannot write %1: %2").arg(m_filePath, f.errorString()));
    return false;
  }
  m_dirty = false;
  setError({});
  Q_EMIT saved();
  return true;
}

// ---------------------------------------------------------------------------

SiteSettingsModel::SiteSettingsModel(QObject* parent) : QSortFilterProxyModel(parent) {
  auto countChange = [this] { Q_EMIT countChanged(); };
  connect(this, &QAbstractItemModel::rowsInserted, this, countChange);
  connect(this, &QAbstractItemModel::rowsRemoved, this, countChange);
  connect(this, &QAbstractItemModel::modelReset, this, countChange);
  connect(this, &QAbstractItemModel::layoutChanged, this, countChange);
}

void SiteSettingsModel::setStore(SiteSettings* store) {
  if (store == m_store)
    return;
  m_store = store;
  setSourceModel(store);
  Q_EMIT storeChanged();
  Q_EMIT countChanged();
}

void SiteSettingsModel::setFilterText(const QString& text) {
  if (text == m_filterText)
    return;
  m_filterText = text;
  invalidateFilter();
  Q_EMIT filterTextChanged();
  Q_EMIT countChanged();
}

QVariant SiteSettingsModel::get(int row) const {
  if (!m_store || row < 0 || row >= rowCount())
    return {};
  return m_store->get(mapToSource(index(row, 0)).row());
}

bool SiteSettingsModel::filterAcceptsRow(int sourceRow, const QModelIndex&) const {
  if (!m_store)
    return false;
  const QStringList words = m_filterText.split(QLatin1Char(' '), Qt::SkipEmptyParts);
  if (words.isEmpty())
    return true;
  const QModelIndex idx = m_store->index(sourceRow);
  const QString hay = (idx.data(SiteSettings::ScopeRole).toString() + QLatin1Char(' ') +
                       idx.data(SiteSettings::NameRole).toString() + QLatin1Char(' ') +
                       idx.data(SiteSettings::KeysRole).toStringList().join(QLatin1Char(' ')))
                          .toLower();
  for (const QString& w : words) {
    if (!hay.contains(w.toLower()))
      return false;
  }
  return true;
}
