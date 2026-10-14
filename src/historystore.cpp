#include "historystore.h"

#include "cefwebview.h"
#include "jsonstore.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QRegularExpression>
#include <QSaveFile>

#include <algorithm>
#include <vector>

Q_LOGGING_CATEGORY(lcHistory, "cefqml.history")

namespace {

constexpr qint64 kDay = 24LL * 60 * 60 * 1000;
// markTyped() applies to a navigation that starts within this time.
constexpr qint64 kTypedWindow = 30 * 1000;

qint64 now() {
  return QDateTime::currentMSecsSinceEpoch();
}

// A time given as ms since the epoch or a JS Date; -1 if neither.
qint64 toTime(const QVariant& v) {
  if (!v.isValid() || v.isNull())
    return -1;
  if (v.metaType() == QMetaType::fromType<QDateTime>())
    return v.toDateTime().toMSecsSinceEpoch();
  if (v.metaType() == QMetaType::fromType<QJSValue>())
    return toTime(v.value<QJSValue>().toVariant());
  bool ok = false;
  const double d = v.toDouble(&ok);
  return ok ? qint64(d) : -1;
}

QString stripFragment(const QString& url) {
  const int i = url.indexOf(QLatin1Char('#'));
  return i < 0 ? url : url.left(i);
}

// Strips "http(s)://" and "www." from lowercase address-bar text.
QString stripTyped(const QString& lower, int* stripped) {
  QString s = lower;
  int n = 0;
  for (const auto* p : {"https://", "http://"}) {
    const QLatin1String prefix(p);
    if (s.startsWith(prefix)) {
      s = s.mid(prefix.size());
      n += prefix.size();
      break;
    }
  }
  if (s.startsWith(QLatin1String("www."))) {
    s = s.mid(4);
    n += 4;
  }
  if (stripped)
    *stripped = n;
  return s;
}

// Whether `word` occurs in `hay` at a word start (start of string or after a
// non-alphanumeric character).
bool atWordStart(const QString& hay, const QString& word) {
  for (int i = hay.indexOf(word); i >= 0; i = hay.indexOf(word, i + 1)) {
    if (i == 0 || !hay.at(i - 1).isLetterOrNumber())
      return true;
  }
  return false;
}

}  // namespace

void HistoryStore::Entry::update() {
  const QString display = QUrl::fromPercentEncoding(url.toUtf8());
  lowerUrl = display.toLower();
  lowerTitle = title.toLower();
  host.clear();
  bare = lowerUrl;
  const int sep = bare.indexOf(QLatin1String("://"));
  if (sep > 0 && !bare.left(sep).contains(QLatin1Char('/'))) {
    bare = bare.mid(sep + 3);
    if (bare.startsWith(QLatin1String("www.")))
      bare = bare.mid(4);
    static const QRegularExpression end(QStringLiteral("[/?#]"));
    const int e = bare.indexOf(end);
    host = e < 0 ? bare : bare.left(e);
  }
}

void HistoryStore::Entry::updateDay() {
  day = QDateTime::fromMSecsSinceEpoch(last).toString(QStringLiteral("yyyy-MM-dd"));
}

// ---------------------------------------------------------------------------
// HistoryTracker: follows one CefWebView's navigations.
//
// loadStarted (a document committed) opens a pending visit, which is recorded
// at loadFinished — unless loadFailed reported the URL (an error page), in
// either order. Titles and favicons seen in between go with the visit; later
// ones update the entry. Same-document navigations with a new path/query
// (history.pushState) arrive as Page.navigatedWithinDocument and count as
// visits; fragment-only changes do not.
class HistoryTracker : public QObject {
 public:
  HistoryTracker(HistoryStore* store, CefWebView* view)
      : QObject(store), m_store(store), m_view(view) {
    m_conns << connect(view, &CefWebView::loadStarted, this,
                       [this](const QUrl& url) { started(url); });
    m_conns << connect(view, &CefWebView::loadFailed, this,
                       [this](int code, const QString&, const QUrl& url) { failed(code, url); });
    m_conns << connect(view, &CefWebView::loadFinished, this, [this] { commit(); });
    m_conns << connect(view, &CefWebView::titleChanged, this, [this] { titleChanged(); });
    m_conns << connect(view, &CefWebView::iconChanged, this, [this] { iconChanged(); });
    m_conns << connect(view, &CefWebView::devToolsEvent, this,
                       [this](const QString& method, const QVariant& params) {
                         devToolsEvent(method, params.toMap());
                       });
  }
  ~HistoryTracker() override {
    for (const auto& c : m_conns)
      disconnect(c);
  }

  void markTyped() { m_typedAt = now(); }

  void commit() {
    if (!m_pending.active)
      return;
    const Pending p = m_pending;
    m_pending = {};
    if (p.failed) {
      m_committed.clear();
      return;
    }
    m_committed = p.url;
    if (!recording())
      return;
    QVariantMap opts;
    // Only titles seen since loadStarted: before that, view->title() may
    // still be the previous document's.
    if (!p.title.isEmpty())
      opts.insert(QStringLiteral("title"), p.title);
    if (!p.icon.isEmpty())
      opts.insert(QStringLiteral("icon"), p.icon);
    if (p.typed)
      opts.insert(QStringLiteral("typed"), true);
    if (p.reload)
      opts.insert(QStringLiteral("reload"), true);
    m_store->recordVisit(p.url, opts);
  }

 private:
  struct Pending {
    QString url;
    QString title;
    QString icon;
    bool active = false;
    bool failed = false;
    bool typed = false;
    bool reload = false;
  };

  bool recording() const { return m_store->m_enabled && m_store->m_recording; }

  // CEF reports the URL as title for documents without one.
  QString cleanTitle(const QString& title) const {
    const QString t = title.trimmed();
    if (t.isEmpty() || !m_view)
      return {};
    const QUrl u = m_view->url();
    if (t == u.toString() || t == u.toString(QUrl::FullyEncoded) ||
        t == u.toString(QUrl::RemoveScheme).mid(2) ||
        t == QUrl::fromPercentEncoding(u.toString(QUrl::FullyEncoded).toUtf8()) ||
        (!m_pending.url.isEmpty() && t == m_pending.url) || t.startsWith(QLatin1String("data:")))
      return {};
    return t;
  }

  void started(const QUrl& url) {
    commit();
    const QString key = m_store->normalizeUrl(url);
    m_pending = {};
    m_pending.active = true;
    m_pending.url = key;
    m_pending.reload = key == m_committed;
    m_pending.typed = m_typedAt > 0 && now() - m_typedAt < kTypedWindow;
    m_typedAt = 0;
    if (!m_failedUrl.isEmpty() && key == m_failedUrl)
      m_pending.failed = true;
    m_failedUrl.clear();
  }

  void failed(int code, const QUrl& url) {
    if (code == -3)  // ERR_ABORTED: stopped or replaced, not an error page
      return;
    const QString key = m_store->normalizeUrl(url);
    if (m_pending.active && m_pending.url == key)
      m_pending.failed = true;
    else
      m_failedUrl = key;
  }

  void titleChanged() {
    if (!m_view)
      return;
    const QString t = cleanTitle(m_view->title());
    if (m_pending.active)
      m_pending.title = t;
    else if (!m_committed.isEmpty() && !t.isEmpty() && recording())
      m_store->setTitle(m_committed, t);
  }

  void iconChanged() {
    if (!m_view)
      return;
    const QString icon = m_view->icon().toString(QUrl::FullyEncoded);
    if (m_pending.active)
      m_pending.icon = icon;
    else if (!m_committed.isEmpty() && !icon.isEmpty() && recording())
      m_store->setIcon(m_committed, icon);
  }

  void devToolsEvent(const QString& method, const QVariantMap& params) {
    if (method == QLatin1String("Page.frameNavigated")) {
      const QVariantMap frame = params.value(QStringLiteral("frame")).toMap();
      if (frame.value(QStringLiteral("parentId")).toString().isEmpty())
        m_mainFrame = frame.value(QStringLiteral("id")).toString();
    } else if (method == QLatin1String("Page.navigatedWithinDocument")) {
      if (!m_mainFrame.isEmpty() &&
          params.value(QStringLiteral("frameId")).toString() != m_mainFrame)
        return;
      const QString key = m_store->normalizeUrl(params.value(QStringLiteral("url")).toString());
      const QString current = m_pending.active ? m_pending.url : m_committed;
      if (current.isEmpty() || stripFragment(key) == stripFragment(current)) {
        if (m_pending.active)
          m_pending.url = key;
        else
          m_committed = key;
        return;
      }
      commit();
      m_committed = key;
      if (recording()) {
        QVariantMap opts;
        if (m_view) {
          const QString t = cleanTitle(m_view->title());
          if (!t.isEmpty())
            opts.insert(QStringLiteral("title"), t);
        }
        m_store->recordVisit(key, opts);
      }
    }
  }

  HistoryStore* m_store;
  QPointer<CefWebView> m_view;
  QList<QMetaObject::Connection> m_conns;
  Pending m_pending;
  QString m_committed;
  QString m_failedUrl;
  QString m_mainFrame;
  qint64 m_typedAt = 0;
};

// ---------------------------------------------------------------------------

HistoryStore::HistoryStore(QObject* parent) : QAbstractListModel(parent) {
  m_ignoredSchemes = {QStringLiteral("about"),          QStringLiteral("chrome"),
                      QStringLiteral("chrome-error"),   QStringLiteral("chrome-extension"),
                      QStringLiteral("chrome-untrusted"), QStringLiteral("devtools"),
                      QStringLiteral("javascript"),     QStringLiteral("blob"),
                      QStringLiteral("view-source")};
  m_timer.setSingleShot(true);
  m_timer.setInterval(1000);
  connect(&m_timer, &QTimer::timeout, this, &HistoryStore::flush);
  if (auto* app = QCoreApplication::instance())
    connect(app, &QCoreApplication::aboutToQuit, this, [this] {
      for (auto* t : std::as_const(m_trackers))
        t->commit();
      flush();
    });
  auto countChange = [this] { Q_EMIT countChanged(); };
  connect(this, &QAbstractItemModel::rowsInserted, this, countChange);
  connect(this, &QAbstractItemModel::rowsRemoved, this, countChange);
  connect(this, &QAbstractItemModel::modelReset, this, countChange);
}

HistoryStore::~HistoryStore() {
  const auto trackers = m_trackers;
  m_trackers.clear();
  for (auto* t : trackers) {
    t->commit();
    delete t;
  }
  flush();
  qDeleteAll(m_list);
}

void HistoryStore::componentComplete() {
  m_complete = true;
  m_filePath = JsonStore::resolvePath(m_path);
  load();
}

void HistoryStore::ensureLoaded() {
  // Used from C++ / JS without QML's componentComplete.
  if (!m_complete) {
    m_complete = true;
    m_filePath = JsonStore::resolvePath(m_path);
    load();
  }
}

int HistoryStore::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : m_list.size();
}

QVariant HistoryStore::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() < 0 || index.row() >= m_list.size())
    return {};
  const Entry* e = m_list.at(index.row());
  switch (role) {
    case Qt::DisplayRole:
    case TitleRole:
      return e->title;
    case UrlRole:
      return e->url;
    case IconRole:
      return e->icon;
    case VisitCountRole:
      return e->visits;
    case TypedCountRole:
      return e->typed;
    case FirstVisitRole:
      return double(e->first);
    case LastVisitRole:
      return double(e->last);
    case DayRole:
      return e->day;
    case HostRole:
      return e->host;
  }
  return {};
}

QHash<int, QByteArray> HistoryStore::roleNames() const {
  return {{UrlRole, "url"},
          {TitleRole, "title"},
          {IconRole, "icon"},
          {VisitCountRole, "visitCount"},
          {TypedCountRole, "typedCount"},
          {FirstVisitRole, "firstVisit"},
          {LastVisitRole, "lastVisit"},
          {DayRole, "day"},
          {HostRole, "host"}};
}

void HistoryStore::setPath(const QString& path) {
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

void HistoryStore::setEnabled(bool on) {
  if (on == m_enabled)
    return;
  m_enabled = on;
  Q_EMIT enabledChanged();
}

void HistoryStore::setRecording(bool on) {
  if (on == m_recording)
    return;
  m_recording = on;
  Q_EMIT recordingChanged();
}

void HistoryStore::setMaxEntries(int n) {
  n = qMax(0, n);
  if (n == m_maxEntries)
    return;
  m_maxEntries = n;
  Q_EMIT maxEntriesChanged();
  if (m_loaded)
    prune();
}

void HistoryStore::setMaxAgeDays(int days) {
  days = qMax(0, days);
  if (days == m_maxAgeDays)
    return;
  m_maxAgeDays = days;
  Q_EMIT maxAgeDaysChanged();
  if (m_loaded)
    prune();
}

void HistoryStore::setMaxUrlLength(int n) {
  if (n == m_maxUrlLength)
    return;
  m_maxUrlLength = n;
  Q_EMIT maxUrlLengthChanged();
}

void HistoryStore::setIgnoredSchemes(const QStringList& schemes) {
  if (schemes == m_ignoredSchemes)
    return;
  m_ignoredSchemes = schemes;
  Q_EMIT ignoredSchemesChanged();
}

void HistoryStore::setIgnoreUrl(const QJSValue& fn) {
  m_ignoreUrl = fn;
  Q_EMIT ignoreUrlChanged();
}

void HistoryStore::setSaveDelay(int ms) {
  ms = qMax(0, ms);
  if (ms == m_timer.interval())
    return;
  m_timer.setInterval(ms);
  Q_EMIT saveDelayChanged();
}

void HistoryStore::setError(const QString& message) {
  if (!message.isEmpty())
    qCWarning(lcHistory).noquote() << message;
  if (message != m_error) {
    m_error = message;
    Q_EMIT errorStringChanged();
  }
}

QString HistoryStore::normalizeUrl(const QVariant& url) const {
  QVariant v = url;
  if (v.metaType() == QMetaType::fromType<QJSValue>())
    v = v.value<QJSValue>().toVariant();
  const QUrl u = v.metaType() == QMetaType::fromType<QUrl>() ? v.toUrl() : QUrl(v.toString().trimmed());
  return u.toString(QUrl::FullyEncoded);
}

bool HistoryStore::isRecordable(const QVariant& url) const {
  const QString key = normalizeUrl(url);
  if (key.isEmpty())
    return false;
  if (m_maxUrlLength > 0 && key.size() > m_maxUrlLength)
    return false;
  const QUrl u(key);
  if (!u.isValid() || u.scheme().isEmpty())
    return false;
  if (m_ignoredSchemes.contains(u.scheme(), Qt::CaseInsensitive))
    return false;
  if (m_ignoreUrl.isCallable()) {
    QJSValue fn = m_ignoreUrl;
    const QJSValue r = fn.call({QJSValue(key)});
    if (r.isError())
      qCWarning(lcHistory).noquote() << "ignoreUrl:" << r.toString();
    else if (r.toBool())
      return false;
  }
  return true;
}

int HistoryStore::rowOf(const Entry* e) const {
  return m_list.indexOf(const_cast<Entry*>(e));
}

void HistoryStore::reposition(Entry* e) {
  const int from = rowOf(e);
  if (from < 0)
    return;
  // Target index in the list without `e`: before the first older entry.
  int to = 0;
  for (int i = 0; i < m_list.size(); ++i) {
    if (i == from)
      continue;
    if (m_list.at(i)->last <= e->last)
      break;
    ++to;
  }
  if (to != from) {
    beginMoveRows({}, from, from, {}, to > from ? to + 1 : to);
    m_list.move(from, to);
    endMoveRows();
  }
  const QModelIndex idx = index(to);
  Q_EMIT dataChanged(idx, idx);
}

void HistoryStore::removeRow(int row) {
  beginRemoveRows({}, row, row);
  Entry* e = m_list.takeAt(row);
  m_index.remove(e->url);
  endRemoveRows();
  delete e;
}

void HistoryStore::prune() {
  int keep = m_list.size();
  if (m_maxEntries > 0)
    keep = qMin(keep, m_maxEntries);
  if (m_maxAgeDays > 0) {
    const qint64 limit = now() - m_maxAgeDays * kDay;
    while (keep > 0 && m_list.at(keep - 1)->last < limit)
      --keep;
  }
  if (keep >= m_list.size())
    return;
  beginRemoveRows({}, keep, m_list.size() - 1);
  while (m_list.size() > keep) {
    Entry* e = m_list.takeLast();
    m_index.remove(e->url);
    delete e;
  }
  endRemoveRows();
  markDirty();
}

bool HistoryStore::recordVisit(const QVariant& url, const QVariantMap& opts) {
  ensureLoaded();
  if (!m_enabled || !m_recording)
    return false;
  const QString key = normalizeUrl(url);
  if (!isRecordable(key))
    return false;
  qint64 time = toTime(opts.value(QStringLiteral("time")));
  if (time < 0)
    time = now();
  const bool typed = opts.value(QStringLiteral("typed")).toBool();
  const bool reload = opts.value(QStringLiteral("reload")).toBool();
  const QString title = opts.value(QStringLiteral("title")).toString().trimmed();
  QString icon = opts.value(QStringLiteral("icon")).toString();

  Entry* e = m_index.value(key);
  if (!e) {
    e = new Entry;
    e->url = key;
    e->title = title;
    e->icon = icon;
    e->visits = 1;
    e->typed = typed ? 1 : 0;
    e->first = e->last = time;
    e->update();
    e->updateDay();
    const auto it = std::partition_point(m_list.begin(), m_list.end(),
                                         [time](const Entry* x) { return x->last > time; });
    const int row = int(it - m_list.begin());
    beginInsertRows({}, row, row);
    m_list.insert(row, e);
    m_index.insert(key, e);
    endInsertRows();
  } else {
    if (!reload)
      ++e->visits;
    if (typed)
      ++e->typed;
    e->first = qMin(e->first, time);
    e->last = qMax(e->last, time);
    if (!title.isEmpty())
      e->title = title;
    if (!icon.isEmpty())
      e->icon = icon;
    e->update();
    e->updateDay();
    reposition(e);
  }
  markDirty();
  prune();
  Q_EMIT visited(key);
  return true;
}

void HistoryStore::setTitle(const QVariant& url, const QString& title) {
  ensureLoaded();
  Entry* e = m_index.value(normalizeUrl(url));
  const QString t = title.trimmed();
  if (!e || t.isEmpty() || t == e->title)
    return;
  e->title = t;
  e->update();
  const QModelIndex idx = index(rowOf(e));
  Q_EMIT dataChanged(idx, idx, {TitleRole, Qt::DisplayRole});
  markDirty();
}

void HistoryStore::setIcon(const QVariant& url, const QVariant& icon) {
  ensureLoaded();
  Entry* e = m_index.value(normalizeUrl(url));
  const QString i = icon.metaType() == QMetaType::fromType<QUrl>()
                        ? icon.toUrl().toString(QUrl::FullyEncoded)
                        : icon.toString();
  if (!e || i.isEmpty() || i == e->icon)
    return;
  e->icon = i;
  const QModelIndex idx = index(rowOf(e));
  Q_EMIT dataChanged(idx, idx, {IconRole});
  markDirty();
}

bool HistoryStore::contains(const QVariant& url) const {
  const_cast<HistoryStore*>(this)->ensureLoaded();
  return m_index.contains(normalizeUrl(url));
}

QVariantMap HistoryStore::toMap(const Entry* e) const {
  return {{QStringLiteral("url"), e->url},
          {QStringLiteral("title"), e->title},
          {QStringLiteral("icon"), e->icon},
          {QStringLiteral("visitCount"), e->visits},
          {QStringLiteral("typedCount"), e->typed},
          {QStringLiteral("firstVisit"), double(e->first)},
          {QStringLiteral("lastVisit"), double(e->last)},
          {QStringLiteral("day"), e->day},
          {QStringLiteral("host"), e->host}};
}

QVariant HistoryStore::entry(const QVariant& url) const {
  const_cast<HistoryStore*>(this)->ensureLoaded();
  const Entry* e = m_index.value(normalizeUrl(url));
  return e ? QVariant(toMap(e)) : QVariant();
}

QVariant HistoryStore::get(int row) const {
  if (row < 0 || row >= m_list.size())
    return {};
  return toMap(m_list.at(row));
}

bool HistoryStore::remove(const QVariant& url) {
  ensureLoaded();
  const Entry* e = m_index.value(normalizeUrl(url));
  if (!e)
    return false;
  removeRow(rowOf(e));
  markDirty();
  return true;
}

int HistoryStore::clear(const QVariant& since) {
  ensureLoaded();
  const qint64 t = toTime(since);
  int n = 0;
  if (t < 0) {
    n = m_list.size();
    beginResetModel();
    qDeleteAll(m_list);
    m_list.clear();
    m_index.clear();
    endResetModel();
  } else {
    while (n < m_list.size() && m_list.at(n)->last >= t)
      ++n;
    if (n > 0) {
      beginRemoveRows({}, 0, n - 1);
      for (int i = 0; i < n; ++i) {
        Entry* e = m_list.takeFirst();
        m_index.remove(e->url);
        delete e;
      }
      endRemoveRows();
    }
  }
  // Clearing history is a privacy action: write it out right away.
  m_dirty = true;
  flush();
  return n;
}

double HistoryStore::frecencyOf(const Entry* e, qint64 t) const {
  const double days = double(t - e->last) / kDay;
  const double weight = days < 4 ? 100 : days < 14 ? 70 : days < 31 ? 50 : days < 90 ? 30 : 10;
  return weight * (e->visits + 2.0 * e->typed);
}

double HistoryStore::frecency(const QVariant& url) const {
  const Entry* e = m_index.value(normalizeUrl(url));
  return e ? frecencyOf(e, now()) : 0;
}

bool HistoryStore::matches(int row, const QStringList& words) const {
  if (row < 0 || row >= m_list.size())
    return false;
  const Entry* e = m_list.at(row);
  for (const QString& w : words) {
    if (!e->lowerUrl.contains(w) && !e->lowerTitle.contains(w))
      return false;
  }
  return true;
}

QVariantList HistoryStore::search(const QString& text, int limit) const {
  const_cast<HistoryStore*>(this)->ensureLoaded();
  QVariantList out;
  if (!m_enabled || limit == 0)
    return out;
  const QString q = text.trimmed().toLower();
  const QStringList words = q.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
  const QString typed = stripTyped(q, nullptr);
  const qint64 t = now();

  std::vector<std::pair<double, const Entry*>> hits;
  hits.reserve(64);
  for (const Entry* e : m_list) {
    bool ok = true;
    for (const QString& w : words) {
      if (!e->lowerUrl.contains(w) && !e->lowerTitle.contains(w)) {
        ok = false;
        break;
      }
    }
    if (!ok)
      continue;
    double score = frecencyOf(e, t);
    if (!typed.isEmpty() && (e->host.startsWith(typed) || e->bare.startsWith(typed) ||
                             e->lowerUrl.startsWith(q)))
      score *= 4;
    for (const QString& w : words) {
      if (atWordStart(e->lowerTitle, w) || atWordStart(e->lowerUrl, w))
        score *= 1.5;
    }
    hits.emplace_back(score, e);
  }
  const size_t n = limit < 0 ? hits.size() : qMin(hits.size(), size_t(limit));
  std::partial_sort(hits.begin(), hits.begin() + n, hits.end(), [](const auto& a, const auto& b) {
    if (a.first != b.first)
      return a.first > b.first;
    return a.second->last > b.second->last;
  });
  for (size_t i = 0; i < n; ++i) {
    QVariantMap m = toMap(hits[i].second);
    m.insert(QStringLiteral("score"), hits[i].first);
    out.append(m);
  }
  return out;
}

QVariant HistoryStore::inlineCompletion(const QString& input) const {
  const_cast<HistoryStore*>(this)->ensureLoaded();
  if (!m_enabled || input.isEmpty() || input.contains(QRegularExpression(QStringLiteral("\\s"))))
    return {};
  const QString lower = input.toLower();
  const qint64 t = now();
  auto result = [&](const QString& completion, const QString& url) -> QVariant {
    if (completion.isEmpty())
      return {};
    return QVariantMap{{QStringLiteral("text"), input + completion},
                       {QStringLiteral("completion"), completion},
                       {QStringLiteral("url"), url}};
  };

  // Other schemes ("data:...", "file:///..."): complete the full URL.
  static const QRegularExpression scheme(QStringLiteral("^[a-z][a-z0-9+.-]*:(?!\\d)"));
  if (scheme.match(lower).hasMatch() && !lower.startsWith(QLatin1String("http://")) &&
      !lower.startsWith(QLatin1String("https://")) && !QStringLiteral("https://").startsWith(lower)) {
    const Entry* best = nullptr;
    double bestScore = 0;
    for (const Entry* e : m_list) {
      if (e->lowerUrl.size() > lower.size() && e->lowerUrl.startsWith(lower)) {
        const double s = frecencyOf(e, t);
        if (!best || s > bestScore) {
          best = e;
          bestScore = s;
        }
      }
    }
    if (!best)
      return {};
    const QString display = QUrl::fromPercentEncoding(best->url.toUtf8());
    return result(display.mid(input.size()), best->url);
  }

  int stripped = 0;
  const QString rest = stripTyped(lower, &stripped);
  if (rest.isEmpty())
    return {};

  if (!rest.contains(QLatin1Char('/'))) {
    // Complete to the host with the highest total frecency.
    QHash<QString, double> scores;
    QHash<QString, const Entry*> top;
    for (const Entry* e : m_list) {
      if (e->host.isEmpty() || !e->host.startsWith(rest))
        continue;
      const double s = frecencyOf(e, t);
      scores[e->host] += s;
      const Entry*& best = top[e->host];
      if (!best || s > frecencyOf(best, t))
        best = e;
    }
    QString host;
    double bestScore = -1;
    for (auto it = scores.cbegin(); it != scores.cend(); ++it) {
      if (it.value() > bestScore || (it.value() == bestScore && it.key().size() < host.size())) {
        host = it.key();
        bestScore = it.value();
      }
    }
    if (host.isEmpty())
      return {};
    QUrl u(top.value(host)->url);
    u.setPath(QStringLiteral("/"));
    u.setQuery(QString());
    u.setFragment(QString());
    u.setUserInfo(QString());
    return result(host.mid(rest.size()) + QLatin1Char('/'), u.toString(QUrl::FullyEncoded));
  }

  // Complete to a full URL (without scheme and "www.").
  const Entry* best = nullptr;
  double bestScore = 0;
  for (const Entry* e : m_list) {
    if (e->bare.size() > rest.size() && e->bare.startsWith(rest)) {
      const double s = frecencyOf(e, t);
      if (!best || s > bestScore) {
        best = e;
        bestScore = s;
      }
    }
  }
  if (!best)
    return {};
  // Keep the entry's case for the completed part.
  const QString display = QUrl::fromPercentEncoding(best->url.toUtf8());
  const int offset = display.size() - best->bare.size();
  return result(display.mid(offset + rest.size()), best->url);
}

void HistoryStore::attach(QObject* view) {
  auto* v = qobject_cast<CefWebView*>(view);
  if (!v || m_trackers.contains(v))
    return;
  ensureLoaded();
  m_trackers.insert(v, new HistoryTracker(this, v));
  connect(v, &QObject::destroyed, this, &HistoryStore::trackerGone);
}

void HistoryStore::detach(QObject* view) {
  if (HistoryTracker* t = m_trackers.take(view)) {
    disconnect(view, &QObject::destroyed, this, &HistoryStore::trackerGone);
    t->commit();
    delete t;
  }
}

bool HistoryStore::isAttached(QObject* view) const {
  return view && m_trackers.contains(view);
}

void HistoryStore::trackerGone(QObject* view) {
  if (HistoryTracker* t = m_trackers.take(view)) {
    t->commit();
    t->deleteLater();
  }
}

void HistoryStore::markTyped(QObject* view) {
  if (HistoryTracker* t = m_trackers.value(view))
    t->markTyped();
}

void HistoryStore::markDirty() {
  m_dirty = true;
  if (!m_filePath.isEmpty())
    m_timer.start();
}

void HistoryStore::flush() {
  m_timer.stop();
  if (m_dirty)
    save();
}

bool HistoryStore::load() {
  m_timer.stop();
  QList<Entry*> list;
  QString err;
  bool ok = true;
  if (!m_filePath.isEmpty()) {
    QFile f(m_filePath);
    if (f.exists()) {
      if (!f.open(QIODevice::ReadOnly)) {
        ok = false;
        err = QStringLiteral("HistoryStore: cannot read %1: %2").arg(m_filePath, f.errorString());
      } else {
        QJsonParseError pe;
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &pe);
        f.close();
        if (pe.error != QJsonParseError::NoError) {
          ok = false;
          const QString backup = m_filePath + QStringLiteral(".corrupt");
          QFile::remove(backup);
          QFile::copy(m_filePath, backup);
          err = QStringLiteral("HistoryStore: %1 is not valid JSON (%2 at offset %3); kept as %4")
                    .arg(m_filePath, pe.errorString())
                    .arg(pe.offset)
                    .arg(backup);
        } else {
          const QJsonArray entries =
              doc.isArray() ? doc.array() : doc.object().value(QLatin1String("entries")).toArray();
          QHash<QString, Entry*> seen;
          for (const QJsonValue& v : entries) {
            const QJsonObject o = v.toObject();
            const QString url = o.value(QLatin1String("url")).toString();
            if (url.isEmpty() || seen.contains(url))
              continue;
            auto* e = new Entry;
            e->url = url;
            e->title = o.value(QLatin1String("title")).toString();
            e->icon = o.value(QLatin1String("icon")).toString();
            e->visits = qMax(1, o.value(QLatin1String("visits")).toInt(1));
            e->typed = qMax(0, o.value(QLatin1String("typed")).toInt());
            e->last = qint64(o.value(QLatin1String("last")).toDouble());
            e->first = qint64(o.value(QLatin1String("first")).toDouble(double(e->last)));
            e->update();
            e->updateDay();
            seen.insert(url, e);
            list.append(e);
          }
          std::stable_sort(list.begin(), list.end(),
                           [](const Entry* a, const Entry* b) { return a->last > b->last; });
        }
      }
    }
  }
  beginResetModel();
  qDeleteAll(m_list);
  m_list = list;
  m_index.clear();
  for (Entry* e : std::as_const(m_list))
    m_index.insert(e->url, e);
  endResetModel();
  m_dirty = false;
  setError(err);
  prune();
  if (!m_loaded) {
    m_loaded = true;
    Q_EMIT loadedChanged();
  }
  return ok;
}

bool HistoryStore::reload() {
  ensureLoaded();
  return load();
}

bool HistoryStore::save() {
  m_timer.stop();
  if (m_filePath.isEmpty()) {
    m_dirty = false;
    return true;
  }
  QJsonArray entries;
  for (const Entry* e : std::as_const(m_list)) {
    QJsonObject o{{QLatin1String("url"), e->url},
                  {QLatin1String("visits"), e->visits},
                  {QLatin1String("first"), double(e->first)},
                  {QLatin1String("last"), double(e->last)}};
    if (!e->title.isEmpty())
      o.insert(QLatin1String("title"), e->title);
    if (!e->icon.isEmpty())
      o.insert(QLatin1String("icon"), e->icon);
    if (e->typed)
      o.insert(QLatin1String("typed"), e->typed);
    entries.append(o);
  }
  const QJsonObject root{{QLatin1String("version"), 1}, {QLatin1String("entries"), entries}};
  QDir().mkpath(QFileInfo(m_filePath).absolutePath());
  QSaveFile f(m_filePath);
  if (!f.open(QIODevice::WriteOnly) ||
      f.write(QJsonDocument(root).toJson(QJsonDocument::Compact)) < 0 || !f.commit()) {
    setError(QStringLiteral("HistoryStore: cannot write %1: %2").arg(m_filePath, f.errorString()));
    return false;
  }
  m_dirty = false;
  setError({});
  Q_EMIT saved();
  return true;
}

// ---------------------------------------------------------------------------

HistoryModel::HistoryModel(QObject* parent) : QSortFilterProxyModel(parent) {
  auto countChange = [this] { Q_EMIT countChanged(); };
  connect(this, &QAbstractItemModel::rowsInserted, this, countChange);
  connect(this, &QAbstractItemModel::rowsRemoved, this, countChange);
  connect(this, &QAbstractItemModel::modelReset, this, countChange);
  connect(this, &QAbstractItemModel::layoutChanged, this, countChange);
}

void HistoryModel::setStore(HistoryStore* store) {
  if (store == m_store)
    return;
  m_store = store;
  setSourceModel(store);
  Q_EMIT storeChanged();
  Q_EMIT countChanged();
}

void HistoryModel::setFilterText(const QString& text) {
  if (text == m_filterText)
    return;
  m_filterText = text;
  m_words = text.trimmed().toLower().split(QRegularExpression(QStringLiteral("\\s+")),
                                           Qt::SkipEmptyParts);
  invalidateFilter();
  Q_EMIT filterTextChanged();
  Q_EMIT countChanged();
}

bool HistoryModel::filterAcceptsRow(int sourceRow, const QModelIndex&) const {
  return m_words.isEmpty() || (m_store && m_store->matches(sourceRow, m_words));
}

QVariant HistoryModel::get(int row) const {
  if (!m_store || row < 0 || row >= rowCount())
    return {};
  return m_store->get(mapToSource(index(row, 0)).row());
}
