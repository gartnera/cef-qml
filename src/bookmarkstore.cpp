#include "bookmarkstore.h"

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
#include <QUrl>

#include <algorithm>
#include <functional>

Q_LOGGING_CATEGORY(lcBookmarks, "cefqml.bookmarks")

namespace {

using Node = BookmarkStore::Node;

const QString kRoot = QStringLiteral("root");
const QString kBar = QStringLiteral("bar");
const QString kOther = QStringLiteral("other");
// Chrome stores times as microseconds since 1601-01-01.
constexpr qint64 kWindowsEpochOffsetMs = 11644473600000LL;
constexpr int kMaxDepth = 64;

qint64 now() {
  return QDateTime::currentMSecsSinceEpoch();
}

QVariant plain(const QVariant& v) {
  if (v.metaType() == QMetaType::fromType<QJSValue>())
    return v.value<QJSValue>().toVariant();
  return v;
}

QVariantMap toOpts(const QVariant& v) {
  return plain(v).toMap();
}

// A time given as ms since the epoch or a JS Date; -1 if neither.
qint64 toTime(const QVariant& value) {
  const QVariant v = plain(value);
  if (!v.isValid() || v.isNull())
    return -1;
  if (v.metaType() == QMetaType::fromType<QDateTime>())
    return v.toDateTime().toMSecsSinceEpoch();
  bool ok = false;
  const double d = v.toDouble(&ok);
  return ok ? qint64(d) : -1;
}

QString iconString(const QVariant& value) {
  const QVariant v = plain(value);
  if (v.metaType() == QMetaType::fromType<QUrl>())
    return v.toUrl().toString(QUrl::FullyEncoded);
  return v.toString();
}

bool isBuiltin(const Node* n) {
  return n->id == kRoot || n->id == kBar || n->id == kOther;
}

int positionOf(const Node* n) {
  return n->parent ? n->parent->children.indexOf(const_cast<Node*>(n)) : 0;
}

// Whether `word` occurs in `hay` at a word start.
bool atWordStart(const QString& hay, const QString& word) {
  for (int i = hay.indexOf(word); i >= 0; i = hay.indexOf(word, i + 1)) {
    if (i == 0 || !hay.at(i - 1).isLetterOrNumber())
      return true;
  }
  return false;
}

QStringList splitWords(const QString& text) {
  static const QRegularExpression ws(QStringLiteral("\\s+"));
  return text.trimmed().toLower().split(ws, Qt::SkipEmptyParts);
}

QString escapeHtml(const QString& s) {
  QString r;
  r.reserve(s.size());
  for (const QChar c : s) {
    switch (c.unicode()) {
      case '&': r += QLatin1String("&amp;"); break;
      case '<': r += QLatin1String("&lt;"); break;
      case '>': r += QLatin1String("&gt;"); break;
      case '"': r += QLatin1String("&quot;"); break;
      default: r += c;
    }
  }
  return r;
}

QString unescapeHtml(const QString& s) {
  if (!s.contains(QLatin1Char('&')))
    return s;
  static const QRegularExpression entity(QStringLiteral("&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"));
  static const QHash<QString, QString> named{
      {QStringLiteral("amp"), QStringLiteral("&")},  {QStringLiteral("lt"), QStringLiteral("<")},
      {QStringLiteral("gt"), QStringLiteral(">")},   {QStringLiteral("quot"), QStringLiteral("\"")},
      {QStringLiteral("apos"), QStringLiteral("'")}, {QStringLiteral("nbsp"), QString(QChar(0xa0))}};
  QString out;
  int last = 0;
  auto it = entity.globalMatch(s);
  while (it.hasNext()) {
    const auto m = it.next();
    out += QStringView(s).mid(last, m.capturedStart() - last);
    const QString name = m.captured(1);
    QString rep;
    if (name.startsWith(QLatin1Char('#'))) {
      bool ok = false;
      const uint code = name.at(1).toLower() == QLatin1Char('x') ? name.mid(2).toUInt(&ok, 16)
                                                                 : name.mid(1).toUInt(&ok, 10);
      if (ok && code > 0 && code <= 0x10ffff) {
        const char32_t c = code;
        rep = QString::fromUcs4(&c, 1);
      }
    } else {
      rep = named.value(name.toLower());
    }
    out += rep.isNull() ? m.captured(0) : rep;
    last = m.capturedEnd();
  }
  out += QStringView(s).mid(last);
  return out;
}

QHash<QString, QString> parseAttributes(const QString& s) {
  static const QRegularExpression attr(QStringLiteral(
      "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*(?:=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?"));
  QHash<QString, QString> out;
  auto it = attr.globalMatch(s);
  while (it.hasNext()) {
    const auto m = it.next();
    QString v = m.captured(2);
    if (m.capturedStart(3) >= 0)
      v = m.captured(3);
    else if (m.capturedStart(4) >= 0)
      v = m.captured(4);
    out.insert(m.captured(1).toUpper(), unescapeHtml(v));
  }
  return out;
}

qint64 secondsToMs(const QString& s) {
  bool ok = false;
  const qint64 v = s.trimmed().toLongLong(&ok);
  return ok && v > 0 ? v * 1000 : 0;
}

QString pathOf(const QVariant& file) {
  const QVariant v = plain(file);
  QUrl url = v.metaType() == QMetaType::fromType<QUrl>() ? v.toUrl() : QUrl();
  QString s = url.isValid() ? QString() : v.toString();
  if (url.isEmpty() && s.startsWith(QLatin1String("file:")))
    url = QUrl(s);
  if (url.isLocalFile())
    return url.toLocalFile();
  if (s.startsWith(QLatin1Char('~')))
    s.replace(0, 1, QDir::homePath());
  return JsonStore::resolvePath(s);
}

}  // namespace

void BookmarkStore::Node::update() {
  lowerTitle = title.toLower();
  const QString display = QUrl::fromPercentEncoding(url.toUtf8());
  lowerUrl = display.toLower();
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

// ---------------------------------------------------------------------------

BookmarkStore::BookmarkStore(QObject* parent) : QObject(parent) {
  m_timer.setSingleShot(true);
  m_timer.setInterval(500);
  connect(&m_timer, &QTimer::timeout, this, &BookmarkStore::flush);
  if (auto* app = QCoreApplication::instance())
    connect(app, &QCoreApplication::aboutToQuit, this, &BookmarkStore::flush);
  resetTree();
}

BookmarkStore::~BookmarkStore() {
  flush();
  delete m_root;
}

void BookmarkStore::componentComplete() {
  m_complete = true;
  m_filePath = JsonStore::resolvePath(m_path);
  load();
}

void BookmarkStore::ensureLoaded() const {
  auto* self = const_cast<BookmarkStore*>(this);
  if (!self->m_complete) {
    self->m_complete = true;
    self->m_filePath = JsonStore::resolvePath(m_path);
    self->load();
  }
}

void BookmarkStore::setPath(const QString& path) {
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

void BookmarkStore::setDefaultFolder(const QString& id) {
  if (id == m_defaultFolder)
    return;
  m_defaultFolder = id;
  Q_EMIT defaultFolderChanged();
}

void BookmarkStore::setSaveDelay(int ms) {
  ms = qMax(0, ms);
  if (ms == m_timer.interval())
    return;
  m_timer.setInterval(ms);
  Q_EMIT saveDelayChanged();
}

void BookmarkStore::setError(const QString& message) {
  if (!message.isEmpty())
    qCWarning(lcBookmarks).noquote() << message;
  if (message != m_error) {
    m_error = message;
    Q_EMIT errorStringChanged();
  }
}

QString BookmarkStore::normalizeUrl(const QVariant& url) const {
  const QVariant v = plain(url);
  QUrl u = v.metaType() == QMetaType::fromType<QUrl>() ? v.toUrl() : QUrl(v.toString().trimmed());
  // "https://example.com" and "https://example.com/" are the same page;
  // views report the latter.
  if (!u.host().isEmpty() && u.path().isEmpty()) {
    static const QStringList hier{QStringLiteral("http"), QStringLiteral("https"),
                                  QStringLiteral("ftp"), QStringLiteral("ws"),
                                  QStringLiteral("wss")};
    if (hier.contains(u.scheme().toLower()))
      u.setPath(QStringLiteral("/"));
  }
  return u.toString(QUrl::FullyEncoded);
}

// ---------------------------------------------------------------------------
// Tree bookkeeping

void BookmarkStore::resetTree() {
  delete m_root;
  m_ids.clear();
  m_urls.clear();
  m_urlCount = 0;
  m_folderCount = 0;
  m_root = new Node;
  m_root->id = kRoot;
  m_root->folder = true;
  const qint64 t = now();
  for (const auto& [id, title] : {std::pair{kBar, QStringLiteral("Bookmarks bar")},
                                  std::pair{kOther, QStringLiteral("Other bookmarks")}}) {
    auto* n = new Node;
    n->id = id;
    n->folder = true;
    n->title = title;
    n->added = n->modified = t;
    n->parent = m_root;
    n->update();
    m_root->children.append(n);
  }
  index(m_root);
}

BookmarkStore::Node* BookmarkStore::newNode(bool folder, const QString& id) {
  auto* n = new Node;
  n->folder = folder;
  n->id = id;
  n->added = n->modified = now();
  return n;
}

// Indexes a subtree, giving nodes without a (unique) id a new one.
void BookmarkStore::index(Node* n) {
  if (n->id.isEmpty() || m_ids.contains(n->id)) {
    do
      n->id = QString::number(m_nextId++);
    while (m_ids.contains(n->id));
  } else {
    bool numeric = false;
    const qint64 v = n->id.toLongLong(&numeric);
    if (numeric && v >= m_nextId)
      m_nextId = v + 1;
  }
  m_ids.insert(n->id, n);
  if (n->folder) {
    if (!isBuiltin(n))
      ++m_folderCount;
  } else {
    m_urls.insert(n->url, n);
    ++m_urlCount;
  }
  for (Node* c : std::as_const(n->children)) {
    c->parent = n;
    index(c);
  }
}

void BookmarkStore::unindex(Node* n) {
  for (Node* c : std::as_const(n->children))
    unindex(c);
  m_ids.remove(n->id);
  if (n->folder) {
    if (!isBuiltin(n))
      --m_folderCount;
  } else {
    m_urls.remove(n->url, n);
    --m_urlCount;
  }
}

BookmarkStore::Node* BookmarkStore::node(const QString& id) const {
  ensureLoaded();
  return m_ids.value(id);
}

BookmarkStore::Node* BookmarkStore::targetFolder(const QVariantMap& opts,
                                                 const QString& fallback) const {
  const QVariant f = opts.value(QStringLiteral("folder"));
  QString id = f.isValid() && !f.isNull() ? f.toString() : fallback;
  if (id.isEmpty())
    id = kBar;
  Node* n = node(id);
  if (!n || !n->folder || n == m_root)
    return nullptr;
  return n;
}

void BookmarkStore::insert(Node* parent, Node* n, int index) {
  if (index < 0 || index > parent->children.size())
    index = parent->children.size();
  n->parent = parent;
  parent->children.insert(index, n);
  n->update();
  this->index(n);
}

QString BookmarkStore::addNode(Node* parent, Node* n, int index) {
  insert(parent, n, index);
  const QString id = n->id;
  Q_EMIT added(id);
  commit();
  return id;
}

void BookmarkStore::commit() {
  ++m_revision;
  markDirty();
  Q_EMIT changed();
}

// ---------------------------------------------------------------------------
// Editing

QString BookmarkStore::add(const QVariant& url, const QString& title, const QVariant& options) {
  ensureLoaded();
  const QVariantMap opts = toOpts(options);
  const QString key = normalizeUrl(url);
  const QUrl u(key);
  if (key.isEmpty() || !u.isValid() || u.scheme().isEmpty())
    return {};
  Node* parent = targetFolder(opts, m_defaultFolder);
  if (!parent)
    return {};
  Node* n = newNode(false);
  n->url = key;
  n->title = title.trimmed();
  n->icon = iconString(opts.value(QStringLiteral("icon")));
  const qint64 t = toTime(opts.value(QStringLiteral("dateAdded")));
  if (t >= 0)
    n->added = n->modified = t;
  return addNode(parent, n, opts.value(QStringLiteral("index"), -1).toInt());
}

QString BookmarkStore::addFolder(const QString& title, const QVariant& options) {
  ensureLoaded();
  const QVariantMap opts = toOpts(options);
  Node* parent = targetFolder(opts, m_defaultFolder);
  if (!parent)
    return {};
  Node* n = newNode(true);
  n->title = title.trimmed().isEmpty() ? QStringLiteral("New folder") : title.trimmed();
  return addNode(parent, n, opts.value(QStringLiteral("index"), -1).toInt());
}

bool BookmarkStore::remove(const QString& id) {
  Node* n = node(id);
  if (!n || isBuiltin(n))
    return false;
  Node* parent = n->parent;
  const int pos = parent->children.indexOf(n);
  parent->children.removeAt(pos);
  unindex(n);
  delete n;
  Q_EMIT removed(id, parent->id, pos);
  commit();
  return true;
}

bool BookmarkStore::update(const QString& id, const QVariant& changes) {
  Node* n = node(id);
  if (!n || n == m_root)
    return false;
  const QVariantMap c = toOpts(changes);
  bool dirty = false;
  if (c.contains(QStringLiteral("title")) && !isBuiltin(n)) {
    QString t = c.value(QStringLiteral("title")).toString().trimmed();
    if (n->folder && t.isEmpty())
      t = n->title;
    if (t != n->title) {
      n->title = t;
      dirty = true;
    }
  }
  if (c.contains(QStringLiteral("url")) && !n->folder) {
    const QString key = normalizeUrl(c.value(QStringLiteral("url")));
    const QUrl u(key);
    if (key.isEmpty() || !u.isValid() || u.scheme().isEmpty())
      return false;
    if (key != n->url) {
      m_urls.remove(n->url, n);
      n->url = key;
      m_urls.insert(key, n);
      dirty = true;
    }
  }
  if (c.contains(QStringLiteral("icon")) && !n->folder) {
    const QString i = iconString(c.value(QStringLiteral("icon")));
    if (i != n->icon) {
      n->icon = i;
      dirty = true;
    }
  }
  if (dirty) {
    n->modified = now();
    n->update();
    Q_EMIT updated(id);
    commit();
  }
  return true;
}

bool BookmarkStore::move(const QString& id, const QString& folder, int index) {
  Node* n = node(id);
  Node* target = node(folder);
  if (!n || isBuiltin(n) || !target || !target->folder || target == m_root)
    return false;
  if (isAncestor(id, folder))
    return false;
  Node* from = n->parent;
  const int oldIndex = from->children.indexOf(n);
  from->children.removeAt(oldIndex);
  if (index < 0 || index > target->children.size())
    index = target->children.size();
  target->children.insert(index, n);
  n->parent = target;
  if (from == target && index == oldIndex)
    return true;
  Q_EMIT moved(id, from->id, oldIndex, target->id, index);
  commit();
  return true;
}

bool BookmarkStore::isBookmarked(const QVariant& url) const {
  ensureLoaded();
  const QString key = normalizeUrl(url);
  return !key.isEmpty() && m_urls.contains(key);
}

QVariantList BookmarkStore::bookmarksFor(const QVariant& url) const {
  ensureLoaded();
  QList<Node*> nodes = m_urls.values(normalizeUrl(url));
  std::sort(nodes.begin(), nodes.end(), [](const Node* a, const Node* b) {
    return a->added != b->added ? a->added < b->added : a->id.toLongLong() < b->id.toLongLong();
  });
  QVariantList out;
  for (const Node* n : std::as_const(nodes))
    out.append(toMap(n));
  return out;
}

bool BookmarkStore::toggle(const QVariant& url, const QString& title, const QVariant& opts) {
  ensureLoaded();
  const QString key = normalizeUrl(url);
  if (key.isEmpty())
    return false;
  const QList<Node*> nodes = m_urls.values(key);
  if (nodes.isEmpty())
    return !add(key, title, opts).isEmpty();
  for (Node* n : nodes) {
    Node* parent = n->parent;
    const int pos = parent->children.indexOf(n);
    const QString id = n->id;
    parent->children.removeAt(pos);
    unindex(n);
    delete n;
    Q_EMIT removed(id, parent->id, pos);
  }
  commit();
  return false;
}

void BookmarkStore::setIcon(const QVariant& url, const QVariant& icon) {
  ensureLoaded();
  const QString i = iconString(icon);
  if (i.isEmpty())
    return;
  bool any = false;
  const QList<Node*> nodes = m_urls.values(normalizeUrl(url));
  for (Node* n : nodes) {
    if (n->icon == i)
      continue;
    n->icon = i;
    any = true;
    Q_EMIT updated(n->id);
  }
  if (any)
    commit();
}

void BookmarkStore::clear() {
  ensureLoaded();
  bool any = false;
  for (const QString& id : {kBar, kOther}) {
    Node* f = m_ids.value(id);
    for (Node* c : std::as_const(f->children)) {
      unindex(c);
      delete c;
      any = true;
    }
    f->children.clear();
  }
  if (any)
    commit();
}

// ---------------------------------------------------------------------------
// Queries

QVariantMap BookmarkStore::toMap(const Node* n) const {
  QStringList path;
  for (const Node* p = n->parent; p && p != m_root; p = p->parent)
    path.prepend(p->title);
  return {{QStringLiteral("id"), n->id},
          {QStringLiteral("type"), n->folder ? QStringLiteral("folder") : QStringLiteral("bookmark")},
          {QStringLiteral("isFolder"), n->folder},
          {QStringLiteral("title"), n->title},
          {QStringLiteral("url"), n->url},
          {QStringLiteral("icon"), n->icon},
          {QStringLiteral("dateAdded"), double(n->added)},
          {QStringLiteral("dateModified"), double(n->modified)},
          {QStringLiteral("parent"), n->parent ? n->parent->id : QString()},
          {QStringLiteral("position"), positionOf(n)},
          {QStringLiteral("childCount"), int(n->children.size())},
          {QStringLiteral("path"), path}};
}

QVariant BookmarkStore::get(const QString& id) const {
  const Node* n = node(id);
  return n ? QVariant(toMap(n)) : QVariant();
}

QVariantList BookmarkStore::children(const QString& folder) const {
  QVariantList out;
  if (const Node* f = node(folder)) {
    for (const Node* c : f->children)
      out.append(toMap(c));
  }
  return out;
}

bool BookmarkStore::contains(const QString& id) const {
  return node(id) != nullptr;
}

bool BookmarkStore::isFolder(const QString& id) const {
  const Node* n = node(id);
  return n && n->folder;
}

bool BookmarkStore::isAncestor(const QString& ancestor, const QString& id) const {
  for (const Node* n = node(id); n; n = n->parent) {
    if (n->id == ancestor)
      return true;
  }
  return false;
}

QVariantList BookmarkStore::folders(const QString& folder) const {
  QVariantList out;
  const Node* start = folder.isEmpty() ? (ensureLoaded(), m_root) : node(folder);
  if (!start)
    return out;
  std::function<void(const Node*, int)> walk = [&](const Node* f, int depth) {
    for (const Node* c : f->children) {
      if (!c->folder)
        continue;
      QVariantMap m = toMap(c);
      m.insert(QStringLiteral("depth"), depth);
      out.append(m);
      walk(c, depth + 1);
    }
  };
  walk(start, 0);
  return out;
}

QStringList BookmarkStore::urls(const QString& folder) const {
  QStringList out;
  std::function<void(const Node*)> walk = [&](const Node* f) {
    for (const Node* c : f->children) {
      if (c->folder)
        walk(c);
      else
        out.append(c->url);
    }
  };
  if (const Node* f = node(folder))
    walk(f);
  return out;
}

bool BookmarkStore::matches(const Node* n, const QStringList& words) const {
  for (const QString& w : words) {
    if (!n->lowerTitle.contains(w) && !n->lowerUrl.contains(w))
      return false;
  }
  return true;
}

void BookmarkStore::searchIn(const Node* f, const QStringList& words, const QString& text,
                             QList<QPair<double, const Node*>>* out) const {
  for (const Node* n : f->children) {
    if (n->folder) {
      searchIn(n, words, text, out);
      continue;
    }
    if (!matches(n, words))
      continue;
    double score = 1;
    for (const QString& w : words) {
      if (n->lowerTitle.startsWith(w))
        score += 4;
      else if (atWordStart(n->lowerTitle, w))
        score += 3;
      else if (n->lowerTitle.contains(w))
        score += 1;
      if (n->host.startsWith(w) || n->bare.startsWith(w))
        score += 4;
      else if (atWordStart(n->bare, w))
        score += 2;
      else if (n->lowerUrl.contains(w))
        score += 0.5;
    }
    if (!text.isEmpty() && (n->lowerTitle == text || n->bare == text || n->host == text))
      score += 5;
    out->append({score, n});
  }
}

QVariantList BookmarkStore::search(const QString& text, int limit, const QString& folder) const {
  ensureLoaded();
  const Node* start = folder.isEmpty() ? m_root : node(folder);
  if (!start)
    return {};
  const QStringList words = splitWords(text);
  const QString lower = text.trimmed().toLower();
  QList<QPair<double, const Node*>> hits;
  searchIn(start, words, lower, &hits);
  std::stable_sort(hits.begin(), hits.end(), [](const auto& a, const auto& b) {
    if (a.first != b.first)
      return a.first > b.first;
    if (a.second->added != b.second->added)
      return a.second->added > b.second->added;
    return a.second->id.toLongLong() > b.second->id.toLongLong();
  });
  QVariantList out;
  for (const auto& [score, n] : std::as_const(hits)) {
    if (limit > 0 && out.size() >= limit)
      break;
    QVariantMap m = toMap(n);
    m.insert(QStringLiteral("score"), score);
    out.append(m);
  }
  return out;
}

// ---------------------------------------------------------------------------
// JSON

QVariantMap BookmarkStore::toJson(const Node* n) const {
  QVariantMap o{{QStringLiteral("id"), n->id},
                {QStringLiteral("type"), n->folder ? QStringLiteral("folder") : QStringLiteral("bookmark")},
                {QStringLiteral("title"), n->title},
                {QStringLiteral("dateAdded"), double(n->added)}};
  if (n->folder) {
    o.insert(QStringLiteral("dateModified"), double(n->modified));
    QVariantList children;
    for (const Node* c : n->children)
      children.append(toJson(c));
    o.insert(QStringLiteral("children"), children);
  } else {
    o.insert(QStringLiteral("url"), n->url);
    if (!n->icon.isEmpty())
      o.insert(QStringLiteral("icon"), n->icon);
    if (n->modified != n->added)
      o.insert(QStringLiteral("dateModified"), double(n->modified));
  }
  return o;
}

// A detached subtree from this store's JSON or Chrome's (ids kept as given;
// index() replaces duplicates). nullptr for invalid nodes.
BookmarkStore::Node* BookmarkStore::fromJson(const QVariantMap& o, int depth) const {
  if (depth > kMaxDepth)
    return nullptr;
  const QString type = o.value(QStringLiteral("type")).toString();
  const bool folder = type == QLatin1String("folder") || (type.isEmpty() && o.contains(QStringLiteral("children")));
  auto* n = new Node;
  n->folder = folder;
  n->id = o.value(QStringLiteral("id")).toString();
  n->title = o.value(o.contains(QStringLiteral("title")) ? QStringLiteral("title") : QStringLiteral("name"))
                 .toString();
  const QVariant added = o.value(QStringLiteral("dateAdded"));
  if (added.isValid()) {
    n->added = toTime(added);
    n->modified = toTime(o.value(QStringLiteral("dateModified"), added));
  } else if (o.contains(QStringLiteral("date_added"))) {  // Chrome
    const auto chrome = [](const QVariant& v) {
      const qint64 us = v.toString().toLongLong();
      return us > 0 ? us / 1000 - kWindowsEpochOffsetMs : 0;
    };
    n->added = chrome(o.value(QStringLiteral("date_added")));
    n->modified = o.contains(QStringLiteral("date_modified"))
                      ? chrome(o.value(QStringLiteral("date_modified")))
                      : n->added;
  }
  if (n->added <= 0)
    n->added = now();
  if (n->modified <= 0)
    n->modified = n->added;
  if (folder) {
    const QVariantList children = o.value(QStringLiteral("children")).toList();
    for (const QVariant& c : children) {
      if (Node* child = fromJson(c.toMap(), depth + 1)) {
        child->parent = n;
        n->children.append(child);
      }
    }
  } else {
    n->url = normalizeUrl(o.value(QStringLiteral("url")));
    n->icon = o.value(QStringLiteral("icon")).toString();
    if (n->url.isEmpty()) {
      delete n;
      return nullptr;
    }
  }
  n->update();
  return n;
}

QString BookmarkStore::exportJson(const QString& folder) const {
  ensureLoaded();
  QVariantList roots;
  if (folder.isEmpty()) {
    for (const Node* r : std::as_const(m_root->children))
      roots.append(toJson(r));
  } else if (const Node* f = node(folder); f && f->folder) {
    if (f == m_root) {
      for (const Node* r : std::as_const(m_root->children))
        roots.append(toJson(r));
    } else {
      roots.append(toJson(f));
    }
  }
  const QVariantMap doc{{QStringLiteral("version"), 1}, {QStringLiteral("roots"), roots}};
  return QString::fromUtf8(QJsonDocument::fromVariant(doc).toJson(QJsonDocument::Indented));
}

QVariantMap BookmarkStore::importJson(const QVariant& json, const QVariant& opts) {
  ensureLoaded();
  QVariant v = plain(json);
  if (v.metaType() == QMetaType::fromType<QString>() ||
      v.metaType() == QMetaType::fromType<QByteArray>()) {
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(v.toString().toUtf8(), &pe);
    if (pe.error != QJsonParseError::NoError) {
      return {{QStringLiteral("ok"), false},
              {QStringLiteral("bookmarks"), 0},
              {QStringLiteral("folders"), 0},
              {QStringLiteral("skipped"), 0},
              {QStringLiteral("error"), QStringLiteral("invalid JSON: %1").arg(pe.errorString())}};
    }
    v = doc.toVariant();
  }
  auto* tree = new Node;
  tree->folder = true;
  const auto adopt = [tree](Node* n, const QString& special) {
    if (!n)
      return;
    n->id = special;
    n->parent = tree;
    tree->children.append(n);
  };
  bool hasRoots = false;
  if (v.metaType() == QMetaType::fromType<QVariantList>()) {
    for (const QVariant& c : v.toList())
      adopt(fromJson(c.toMap(), 1), {});
  } else {
    const QVariantMap o = v.toMap();
    const QVariant roots = o.value(QStringLiteral("roots"));
    if (roots.metaType() == QMetaType::fromType<QVariantList>()) {  // ours
      hasRoots = true;
      for (const QVariant& r : roots.toList()) {
        const QVariantMap rm = r.toMap();
        const QString id = rm.value(QStringLiteral("id")).toString();
        Node* n = fromJson(rm, 1);
        if (n && !n->folder) {
          adopt(n, {});
          continue;
        }
        adopt(n, id == kBar || id == kOther ? id : QString());
      }
    } else if (roots.canConvert<QVariantMap>() && !roots.toMap().isEmpty()) {  // Chrome
      hasRoots = true;
      const QVariantMap rm = roots.toMap();
      for (const auto& [key, special] :
           {std::pair{QStringLiteral("bookmark_bar"), kBar}, std::pair{QStringLiteral("other"), kOther},
            std::pair{QStringLiteral("synced"), kOther}}) {
        if (rm.contains(key))
          adopt(fromJson(rm.value(key).toMap(), 1), special);
      }
    } else if (!o.isEmpty()) {
      adopt(fromJson(o, 1), {});
    }
  }
  if (!hasRoots && tree->children.isEmpty()) {
    delete tree;
    return {{QStringLiteral("ok"), false},
            {QStringLiteral("bookmarks"), 0},
            {QStringLiteral("folders"), 0},
            {QStringLiteral("skipped"), 0},
            {QStringLiteral("error"), QStringLiteral("no bookmarks found")}};
  }
  return importInto(tree, toOpts(opts), hasRoots);
}

// ---------------------------------------------------------------------------
// Netscape bookmark HTML

void BookmarkStore::writeHtml(const Node* f, int depth, QString* out) const {
  const QString indent(depth * 4, QLatin1Char(' '));
  for (const Node* n : f->children) {
    if (n->folder) {
      *out += indent + QStringLiteral("<DT><H3 ADD_DATE=\"%1\" LAST_MODIFIED=\"%2\"")
                           .arg(n->added / 1000)
                           .arg(n->modified / 1000);
      if (n->id == kBar)
        *out += QLatin1String(" PERSONAL_TOOLBAR_FOLDER=\"true\"");
      *out += QStringLiteral(">%1</H3>\n").arg(escapeHtml(n->title));
      *out += indent + QStringLiteral("<DL><p>\n");
      writeHtml(n, depth + 1, out);
      *out += indent + QStringLiteral("</DL><p>\n");
    } else {
      *out += indent + QStringLiteral("<DT><A HREF=\"%1\" ADD_DATE=\"%2\"")
                           .arg(escapeHtml(n->url))
                           .arg(n->added / 1000);
      if (n->modified != n->added)
        *out += QStringLiteral(" LAST_MODIFIED=\"%1\"").arg(n->modified / 1000);
      if (!n->icon.isEmpty()) {
        const bool data = n->icon.startsWith(QLatin1String("data:"));
        *out += QStringLiteral(" %1=\"%2\"")
                    .arg(data ? QStringLiteral("ICON") : QStringLiteral("ICON_URI"),
                         escapeHtml(n->icon));
      }
      *out += QStringLiteral(">%1</A>\n").arg(escapeHtml(n->title));
    }
  }
}

QString BookmarkStore::exportHtml(const QString& folder) const {
  ensureLoaded();
  QString out = QStringLiteral(
      "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
      "<!-- This is an automatically generated file.\n"
      "     It will be read and overwritten.\n"
      "     DO NOT EDIT! -->\n"
      "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
      "<TITLE>Bookmarks</TITLE>\n"
      "<H1>Bookmarks</H1>\n"
      "<DL><p>\n");
  const Node* f = folder.isEmpty() ? m_root : node(folder);
  if (f == m_root) {
    // Like Chrome: the bar as a toolbar folder, then the other bookmarks at
    // the top level (where importers put loose bookmarks).
    Node bar;
    bar.folder = true;
    bar.children = {m_ids.value(kBar)};
    writeHtml(&bar, 1, &out);
    writeHtml(m_ids.value(kOther), 1, &out);
    bar.children.clear();
  } else if (f && f->folder) {
    writeHtml(f, 1, &out);
  }
  out += QStringLiteral("</DL><p>\n");
  return out;
}

QVariantMap BookmarkStore::importHtml(const QString& html, const QVariant& opts) {
  ensureLoaded();
  static const QRegularExpression tag(QStringLiteral("<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"));
  auto* tree = new Node;
  tree->folder = true;
  QList<Node*> stack;
  Node* current = tree;
  Node* pending = nullptr;  // an <H3> folder whose <DL> comes next
  bool sawList = false;
  int pos = 0;
  while (true) {
    const auto m = tag.match(html, pos);
    if (!m.hasMatch())
      break;
    pos = m.capturedEnd();
    const bool closing = !m.captured(1).isEmpty();
    const QString name = m.captured(2).toUpper();
    // Text up to the closing tag of <H3> / <A>.
    const auto textUntil = [&](const QString& close) {
      const int end = html.indexOf(close, pos, Qt::CaseInsensitive);
      const int stop = end < 0 ? html.indexOf(QLatin1Char('<'), pos) : end;
      const QString text = html.mid(pos, stop < 0 ? -1 : stop - pos);
      pos = end < 0 ? (stop < 0 ? html.size() : stop) : end + close.size();
      static const QRegularExpression ws(QStringLiteral("\\s+"));
      return unescapeHtml(text).replace(ws, QStringLiteral(" ")).trimmed();
    };
    if (name == QLatin1String("DL")) {
      sawList = true;
      if (closing) {
        if (!stack.isEmpty())
          current = stack.takeLast();
      } else {
        stack.append(current);
        if (pending && stack.size() <= kMaxDepth)
          current = pending;
        pending = nullptr;
      }
    } else if (closing) {
      continue;
    } else if (name == QLatin1String("H3")) {
      const auto attrs = parseAttributes(m.captured(3));
      auto* f = new Node;
      f->folder = true;
      f->added = secondsToMs(attrs.value(QStringLiteral("ADD_DATE")));
      f->modified = secondsToMs(attrs.value(QStringLiteral("LAST_MODIFIED")));
      if (!f->added)
        f->added = now();
      if (!f->modified)
        f->modified = f->added;
      f->title = textUntil(QStringLiteral("</H3>"));
      if (current == tree) {
        if (attrs.contains(QStringLiteral("PERSONAL_TOOLBAR_FOLDER")))
          f->id = kBar;
        else if (attrs.contains(QStringLiteral("UNFILED_BOOKMARKS_FOLDER")))
          f->id = kOther;
      }
      f->parent = current;
      current->children.append(f);
      pending = f;
    } else if (name == QLatin1String("A")) {
      pending = nullptr;
      const auto attrs = parseAttributes(m.captured(3));
      const QString title = textUntil(QStringLiteral("</A>"));
      const QString href = attrs.value(QStringLiteral("HREF")).trimmed();
      if (href.isEmpty())
        continue;
      auto* b = new Node;
      b->url = normalizeUrl(href);
      b->title = title;
      b->icon = attrs.value(QStringLiteral("ICON"));
      if (b->icon.isEmpty())
        b->icon = attrs.value(QStringLiteral("ICON_URI"));
      b->added = secondsToMs(attrs.value(QStringLiteral("ADD_DATE")));
      if (!b->added)
        b->added = now();
      b->modified = secondsToMs(attrs.value(QStringLiteral("LAST_MODIFIED")));
      if (!b->modified)
        b->modified = b->added;
      b->update();
      b->parent = current;
      current->children.append(b);
    }
  }
  if (!sawList) {
    delete tree;
    return {{QStringLiteral("ok"), false},
            {QStringLiteral("bookmarks"), 0},
            {QStringLiteral("folders"), 0},
            {QStringLiteral("skipped"), 0},
            {QStringLiteral("error"), QStringLiteral("not a bookmark file")}};
  }
  return importInto(tree, toOpts(opts), true);
}

// Merges a detached tree (top-level folders with id "bar" / "other" stand for
// the built-in ones) into the store and takes ownership of it.
QVariantMap BookmarkStore::importInto(Node* tree, const QVariantMap& opts, bool) {
  if (opts.value(QStringLiteral("replace")).toBool()) {
    for (const QString& id : {kBar, kOther}) {
      Node* f = m_ids.value(id);
      for (Node* c : std::as_const(f->children)) {
        unindex(c);
        delete c;
      }
      f->children.clear();
    }
  }
  ImportStats stats;
  QString error;
  if (opts.contains(QStringLiteral("folder"))) {
    Node* target = targetFolder(opts, {});
    if (!target) {
      error = QStringLiteral("no such folder: %1").arg(opts.value(QStringLiteral("folder")).toString());
    } else {
      for (Node* c : std::as_const(tree->children))
        c->id.clear();
      mergeInto(target, tree, &stats);
    }
  } else {
    // In file order: loose top-level items go to "other".
    for (Node* c : std::as_const(tree->children)) {
      if (c->id == kBar || c->id == kOther)
        mergeInto(m_ids.value(c->id), c, &stats);
      else
        mergeChild(m_ids.value(kOther), c, &stats);
    }
  }
  delete tree;
  ++m_revision;
  markDirty();
  if (error.isEmpty())
    Q_EMIT imported(stats.bookmarks, stats.folders);
  Q_EMIT changed();
  return {{QStringLiteral("ok"), error.isEmpty()},
          {QStringLiteral("bookmarks"), stats.bookmarks},
          {QStringLiteral("folders"), stats.folders},
          {QStringLiteral("skipped"), stats.skipped},
          {QStringLiteral("error"), error}};
}

void BookmarkStore::mergeInto(Node* target, Node* source, ImportStats* stats) {
  for (Node* c : std::as_const(source->children))
    mergeChild(target, c, stats);
}

void BookmarkStore::mergeChild(Node* target, Node* c, ImportStats* stats) {
  if (c->folder) {
    Node* existing = nullptr;
    for (Node* t : std::as_const(target->children)) {
      if (t->folder && t->title == c->title) {
        existing = t;
        break;
      }
    }
    if (!existing) {
      existing = newNode(true);
      existing->title = c->title.isEmpty() ? QStringLiteral("New folder") : c->title;
      existing->added = c->added;
      existing->modified = c->modified;
      insert(target, existing, -1);
      ++stats->folders;
    }
    mergeInto(existing, c, stats);
    return;
  }
  const QUrl u(c->url);
  if (c->url.isEmpty() || !u.isValid() || u.scheme().isEmpty() ||
      u.scheme() == QLatin1String("place") || u.scheme() == QLatin1String("javascript")) {
    ++stats->skipped;
    return;
  }
  bool dup = false;
  for (const Node* t : std::as_const(target->children)) {
    if (!t->folder && t->url == c->url) {
      dup = true;
      break;
    }
  }
  if (dup) {
    ++stats->skipped;
    return;
  }
  Node* b = newNode(false);
  b->url = c->url;
  b->title = c->title;
  b->icon = c->icon;
  b->added = c->added;
  b->modified = c->modified;
  insert(target, b, -1);
  ++stats->bookmarks;
}

// ---------------------------------------------------------------------------
// Files

QVariantMap BookmarkStore::importFile(const QVariant& file, const QVariant& opts) {
  const QString path = pathOf(file);
  QFile f(path);
  if (!f.open(QIODevice::ReadOnly)) {
    return {{QStringLiteral("ok"), false},
            {QStringLiteral("bookmarks"), 0},
            {QStringLiteral("folders"), 0},
            {QStringLiteral("skipped"), 0},
            {QStringLiteral("error"), QStringLiteral("cannot read %1: %2").arg(path, f.errorString())}};
  }
  const QString text = QString::fromUtf8(f.readAll());
  const QString start = text.left(64).trimmed();
  if (start.startsWith(QLatin1Char('{')) || start.startsWith(QLatin1Char('[')))
    return importJson(text, opts);
  return importHtml(text, opts);
}

bool BookmarkStore::exportFile(const QVariant& file, const QString& format, const QString& folder) {
  const QString path = pathOf(file);
  const bool json = format.isEmpty() ? path.endsWith(QLatin1String(".json"), Qt::CaseInsensitive)
                                     : format.compare(QLatin1String("json"), Qt::CaseInsensitive) == 0;
  const QString text = json ? exportJson(folder) : exportHtml(folder);
  QDir().mkpath(QFileInfo(path).absolutePath());
  QSaveFile f(path);
  if (path.isEmpty() || !f.open(QIODevice::WriteOnly) || f.write(text.toUtf8()) < 0 || !f.commit()) {
    setError(QStringLiteral("BookmarkStore: cannot write %1: %2").arg(path, f.errorString()));
    return false;
  }
  return true;
}

void BookmarkStore::markDirty() {
  m_dirty = true;
  if (!m_filePath.isEmpty())
    m_timer.start();
}

void BookmarkStore::flush() {
  m_timer.stop();
  if (m_dirty)
    save();
}

bool BookmarkStore::load() {
  m_timer.stop();
  QString err;
  bool ok = true;
  QVariantMap doc;
  if (!m_filePath.isEmpty()) {
    QFile f(m_filePath);
    if (f.exists()) {
      if (!f.open(QIODevice::ReadOnly)) {
        ok = false;
        err = QStringLiteral("BookmarkStore: cannot read %1: %2").arg(m_filePath, f.errorString());
      } else {
        QJsonParseError pe;
        const QJsonDocument d = QJsonDocument::fromJson(f.readAll(), &pe);
        f.close();
        if (pe.error != QJsonParseError::NoError || !d.isObject()) {
          ok = false;
          const QString backup = m_filePath + QStringLiteral(".corrupt");
          QFile::remove(backup);
          QFile::copy(m_filePath, backup);
          err = QStringLiteral("BookmarkStore: %1 is not valid JSON (%2 at offset %3); kept as %4")
                    .arg(m_filePath, pe.errorString())
                    .arg(pe.offset)
                    .arg(backup);
        } else {
          doc = d.object().toVariantMap();
        }
      }
    }
  }
  m_nextId = 1;
  resetTree();
  const qint64 next = qint64(doc.value(QStringLiteral("nextId")).toDouble());
  if (next > m_nextId)
    m_nextId = next;
  for (const QVariant& r : doc.value(QStringLiteral("roots")).toList()) {
    const QVariantMap rm = r.toMap();
    const QString id = rm.value(QStringLiteral("id")).toString();
    Node* builtin = (id == kBar || id == kOther) ? m_ids.value(id) : nullptr;
    Node* parsed = fromJson(rm, 1);
    if (!parsed)
      continue;
    Node* target = builtin ? builtin : m_ids.value(kOther);
    if (builtin) {
      builtin->added = parsed->added;
      builtin->modified = parsed->modified;
      // Keep the stored titles of the built-in folders? They are fixed.
      for (Node* c : std::as_const(parsed->children)) {
        c->parent = target;
        target->children.append(c);
        index(c);
      }
      parsed->children.clear();
      delete parsed;
    } else {
      parsed->parent = target;
      target->children.append(parsed);
      index(parsed);
    }
  }
  m_dirty = false;
  setError(err);
  ++m_revision;
  if (!m_loaded) {
    m_loaded = true;
    Q_EMIT loadedChanged();
  }
  Q_EMIT changed();
  return ok;
}

bool BookmarkStore::reload() {
  ensureLoaded();
  return load();
}

bool BookmarkStore::save() {
  m_timer.stop();
  if (m_filePath.isEmpty()) {
    m_dirty = false;
    return true;
  }
  QVariantList roots;
  for (const Node* r : std::as_const(m_root->children))
    roots.append(toJson(r));
  const QVariantMap root{{QStringLiteral("version"), 1},
                         {QStringLiteral("nextId"), double(m_nextId)},
                         {QStringLiteral("roots"), roots}};
  QDir().mkpath(QFileInfo(m_filePath).absolutePath());
  QSaveFile f(m_filePath);
  if (!f.open(QIODevice::WriteOnly) ||
      f.write(QJsonDocument::fromVariant(root).toJson(QJsonDocument::Compact)) < 0 || !f.commit()) {
    setError(QStringLiteral("BookmarkStore: cannot write %1: %2").arg(m_filePath, f.errorString()));
    return false;
  }
  m_dirty = false;
  setError({});
  Q_EMIT saved();
  return true;
}

// ---------------------------------------------------------------------------

BookmarkModel::BookmarkModel(QObject* parent) : QAbstractListModel(parent) {
  auto countChange = [this] { Q_EMIT countChanged(); };
  connect(this, &QAbstractItemModel::rowsInserted, this, countChange);
  connect(this, &QAbstractItemModel::rowsRemoved, this, countChange);
  connect(this, &QAbstractItemModel::modelReset, this, countChange);
}

int BookmarkModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : m_rows.size();
}

QVariant BookmarkModel::data(const QModelIndex& index, int role) const {
  if (!m_store || !index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
    return {};
  const Row& row = m_rows.at(index.row());
  const BookmarkStore::Node* n = m_store->node(row.id);
  if (!n)
    return {};
  switch (role) {
    case Qt::DisplayRole:
    case TitleRole:
      return n->title;
    case IdRole:
      return n->id;
    case TypeRole:
      return n->folder ? QStringLiteral("folder") : QStringLiteral("bookmark");
    case IsFolderRole:
      return n->folder;
    case UrlRole:
      return n->url;
    case IconRole:
      return n->icon;
    case DateAddedRole:
      return double(n->added);
    case DateModifiedRole:
      return double(n->modified);
    case ParentIdRole:
      return n->parent ? n->parent->id : QString();
    case PositionRole:
      return positionOf(n);
    case ChildCountRole:
      return int(n->children.size());
    case DepthRole:
      return row.depth;
    case PathRole: {
      QStringList path;
      for (const Node* p = n->parent; p && p->parent; p = p->parent)
        path.prepend(p->title);
      return path;
    }
  }
  return {};
}

QHash<int, QByteArray> BookmarkModel::roleNames() const {
  return {{IdRole, "id"},
          {TypeRole, "type"},
          {IsFolderRole, "isFolder"},
          {TitleRole, "title"},
          {UrlRole, "url"},
          {IconRole, "icon"},
          {DateAddedRole, "dateAdded"},
          {DateModifiedRole, "dateModified"},
          {ParentIdRole, "parentId"},
          {PositionRole, "position"},
          {ChildCountRole, "childCount"},
          {DepthRole, "depth"},
          {PathRole, "path"}};
}

void BookmarkModel::setStore(BookmarkStore* store) {
  if (store == m_store)
    return;
  disconnect(m_conn);
  m_store = store;
  if (store)
    m_conn = connect(store, &BookmarkStore::changed, this, &BookmarkModel::sync);
  sync();
  Q_EMIT storeChanged();
}

void BookmarkModel::setFolder(const QString& folder) {
  if (folder == m_folder)
    return;
  m_folder = folder;
  sync();
  Q_EMIT folderChanged();
}

void BookmarkModel::setRecursive(bool on) {
  if (on == m_recursive)
    return;
  m_recursive = on;
  sync();
  Q_EMIT recursiveChanged();
}

void BookmarkModel::setFoldersOnly(bool on) {
  if (on == m_foldersOnly)
    return;
  m_foldersOnly = on;
  sync();
  Q_EMIT foldersOnlyChanged();
}

void BookmarkModel::setFilterText(const QString& text) {
  if (text == m_filterText)
    return;
  m_filterText = text;
  m_words = splitWords(text);
  sync();
  Q_EMIT filterTextChanged();
}

void BookmarkModel::collectInto(const BookmarkStore::Node* f, int depth, QList<Row>* out) const {
  if (depth > kMaxDepth)
    return;
  for (const BookmarkStore::Node* c : f->children) {
    if (!m_words.isEmpty()) {
      if (c->folder)
        collectInto(c, depth, out);
      else if (m_store->matches(c, m_words))
        out->append({c->id, 0});
      continue;
    }
    if (m_foldersOnly && !c->folder)
      continue;
    out->append({c->id, depth});
    if (m_recursive && c->folder)
      collectInto(c, depth + 1, out);
  }
}

QList<BookmarkModel::Row> BookmarkModel::collect() const {
  QList<Row> rows;
  if (!m_store)
    return rows;
  const BookmarkStore::Node* f = m_store->node(m_folder);
  if (f && f->folder)
    collectInto(f, 0, &rows);
  return rows;
}

void BookmarkModel::sync() {
  const QList<Row> next = collect();
  const QList<Row>& prev = m_rows;
  const int n = prev.size();
  const int m = next.size();
  int first = 0;
  while (first < qMin(n, m) && prev.at(first) == next.at(first))
    ++first;
  bool done = false;
  if (first == n && first == m) {
    done = true;
  } else if (m == n + 1 && std::equal(prev.begin() + first, prev.end(), next.begin() + first + 1)) {
    beginInsertRows({}, first, first);
    m_rows = next;
    endInsertRows();
    done = true;
  } else if (m == n - 1 && std::equal(next.begin() + first, next.end(), prev.begin() + first + 1)) {
    beginRemoveRows({}, first, first);
    m_rows = next;
    endRemoveRows();
    done = true;
  } else if (m == n) {
    int last = n - 1;
    while (last > first && prev.at(last) == next.at(last))
      --last;
    // One row moved from `last` up to `first`, or from `first` down to `last`.
    if (next.at(first) == prev.at(last) &&
        std::equal(prev.begin() + first, prev.begin() + last, next.begin() + first + 1)) {
      beginMoveRows({}, last, last, {}, first);
      m_rows = next;
      endMoveRows();
      done = true;
    } else if (next.at(last) == prev.at(first) &&
               std::equal(prev.begin() + first + 1, prev.begin() + last + 1, next.begin() + first)) {
      beginMoveRows({}, first, first, {}, last + 1);
      m_rows = next;
      endMoveRows();
      done = true;
    }
  }
  if (!done) {
    beginResetModel();
    m_rows = next;
    endResetModel();
    return;
  }
  // Titles, positions, child counts... may have changed anywhere.
  if (!m_rows.isEmpty())
    Q_EMIT dataChanged(index(0), index(m_rows.size() - 1));
}

QVariant BookmarkModel::get(int row) const {
  if (!m_store || row < 0 || row >= m_rows.size())
    return {};
  const BookmarkStore::Node* n = m_store->node(m_rows.at(row).id);
  if (!n)
    return {};
  QVariantMap map = m_store->toMap(n);
  map.insert(QStringLiteral("depth"), m_rows.at(row).depth);
  return map;
}

int BookmarkModel::indexOf(const QString& id) const {
  for (int i = 0; i < m_rows.size(); ++i) {
    if (m_rows.at(i).id == id)
      return i;
  }
  return -1;
}
