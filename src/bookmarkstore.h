#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJSValue>
#include <QList>
#include <QPointer>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariant>

// Bookmarks: a tree of folders and bookmarks, persisted to a JSON file.
//
//   BookmarkStore { id: bookmarks }              // "bookmarks.json" under Cef.dataDir
//   bookmarks.toggle(view.url, view.title)       // star / unstar a page
//   BookmarksBar { store: bookmarks }            // or your own view:
//   Repeater { model: BookmarkModel { store: bookmarks; folder: bookmarks.barFolder } }
//
// Every node has an id (a string), title, dateAdded / dateModified (ms since
// the epoch), parent (the folder's id) and position (index in the folder);
// bookmarks also have url and icon. Two built-in folders, "bar" ("Bookmarks
// bar") and "other" ("Other bookmarks"), are children of the hidden root
// "root"; they cannot be removed, moved or renamed.
//
// Implemented in C++ rather than on top of JsonStore: isBookmarked(url) runs
// in bindings on every navigation of every tab, the address bar searches
// bookmarks on every keystroke, and bars / menus want per-folder models that
// update row by row (so a ListView keeps its delegates and scroll position).
// A URL hash, cached lowercase strings and an id -> node map give that
// cheaply, without converting the whole tree between QVariant and JavaScript
// on each change. The file is plain JSON, written atomically and debounced,
// like JsonStore's and HistoryStore's.
class BookmarkStore : public QObject, public QQmlParserStatus {
  Q_OBJECT
  Q_INTERFACES(QQmlParserStatus)
  // Relative paths resolve under Cef.dataDir; "" keeps bookmarks in memory.
  Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
  Q_PROPERTY(QString filePath READ filePath NOTIFY pathChanged)
  Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
  // Number of bookmarks / user folders (the built-in folders not counted).
  Q_PROPERTY(int count READ count NOTIFY changed)
  Q_PROPERTY(int folderCount READ folderCount NOTIFY changed)
  // Incremented on every change; use it to re-evaluate bindings that call
  // functions: `starred: (store.revision, store.isBookmarked(url))`.
  Q_PROPERTY(int revision READ revision NOTIFY changed)
  Q_PROPERTY(QString rootFolder READ rootFolder CONSTANT)
  Q_PROPERTY(QString barFolder READ barFolder CONSTANT)
  Q_PROPERTY(QString otherFolder READ otherFolder CONSTANT)
  // Where add() and toggle() put bookmarks without a `folder` option.
  Q_PROPERTY(QString defaultFolder READ defaultFolder WRITE setDefaultFolder NOTIFY defaultFolderChanged)
  Q_PROPERTY(int saveDelay READ saveDelay WRITE setSaveDelay NOTIFY saveDelayChanged)
  Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)

 public:
  struct Node {
    QString id;
    bool folder = false;
    QString title;
    QString url;
    QString icon;
    qint64 added = 0;
    qint64 modified = 0;
    Node* parent = nullptr;
    QList<Node*> children;
    // Derived, for search.
    QString lowerTitle;
    QString lowerUrl;
    QString host;
    QString bare;
    void update();
    ~Node() { qDeleteAll(children); }
  };

  explicit BookmarkStore(QObject* parent = nullptr);
  ~BookmarkStore() override;

  void classBegin() override {}
  void componentComplete() override;

  QString path() const { return m_path; }
  void setPath(const QString& path);
  QString filePath() const { return m_filePath; }
  bool loaded() const { return m_loaded; }
  int count() const { return m_urlCount; }
  int folderCount() const { return m_folderCount; }
  int revision() const { return m_revision; }
  QString rootFolder() const { return QStringLiteral("root"); }
  QString barFolder() const { return QStringLiteral("bar"); }
  QString otherFolder() const { return QStringLiteral("other"); }
  QString defaultFolder() const { return m_defaultFolder; }
  void setDefaultFolder(const QString& id);
  int saveDelay() const { return m_timer.interval(); }
  void setSaveDelay(int ms);
  QString errorString() const { return m_error; }

  // The canonical (encoded) string form of a URL, as stored.
  Q_INVOKABLE QString normalizeUrl(const QVariant& url) const;

  // Adds a bookmark; opts: { folder (id, default defaultFolder), index
  // (position, default end), icon, dateAdded (ms or Date) }. Returns the new
  // id, or "" if the URL or folder is invalid.
  Q_INVOKABLE QString add(const QVariant& url, const QString& title = {},
                          const QVariant& opts = {});
  // Adds a folder; opts: { folder (parent id, default defaultFolder), index }.
  Q_INVOKABLE QString addFolder(const QString& title, const QVariant& opts = {});
  // Removes a bookmark or a folder with everything in it.
  Q_INVOKABLE bool remove(const QString& id);
  // Changes { title, url, icon } of a node (url only for bookmarks).
  Q_INVOKABLE bool update(const QString& id, const QVariant& changes);
  // Moves a node into `folder` at `index` (its position afterwards; -1 or
  // out of range: the end). Folders cannot move into themselves.
  Q_INVOKABLE bool move(const QString& id, const QString& folder, int index = -1);
  Q_INVOKABLE bool isBookmarked(const QVariant& url) const;
  // All bookmarks of a URL (it can be in several folders), oldest first.
  Q_INVOKABLE QVariantList bookmarksFor(const QVariant& url) const;
  // Bookmarks the URL (see add(); opts as there) or, if it is bookmarked,
  // removes all its bookmarks. Returns whether it is bookmarked afterwards.
  Q_INVOKABLE bool toggle(const QVariant& url, const QString& title = {},
                          const QVariant& opts = {});
  // Sets the icon of every bookmark of a URL (e.g. from a view's favicon).
  Q_INVOKABLE void setIcon(const QVariant& url, const QVariant& icon);
  // Bookmarks whose title or URL contain every word of `text`, best first
  // (title / host prefix and word-start matches rank higher). An empty text
  // returns the newest bookmarks. `folder` limits the search to a subtree.
  Q_INVOKABLE QVariantList search(const QString& text, int limit = 10,
                                  const QString& folder = {}) const;
  // The node as an object { id, type ("folder" / "bookmark"), isFolder,
  // title, url, icon, dateAdded, dateModified, parent, position, childCount,
  // path (titles of the folders above it) }, or undefined.
  Q_INVOKABLE QVariant get(const QString& id) const;
  Q_INVOKABLE QVariantList children(const QString& folder) const;
  Q_INVOKABLE bool contains(const QString& id) const;
  Q_INVOKABLE bool isFolder(const QString& id) const;
  // Whether `ancestor` is `id` or one of the folders above it.
  Q_INVOKABLE bool isAncestor(const QString& ancestor, const QString& id) const;
  // Folders under `folder` (default: both built-in folders), depth first,
  // each with an extra `depth` (0 for the top level).
  Q_INVOKABLE QVariantList folders(const QString& folder = {}) const;
  // Bookmark URLs under a folder, depth first (for "open all in tabs").
  Q_INVOKABLE QStringList urls(const QString& folder) const;
  // Removes everything but the built-in folders.
  Q_INVOKABLE void clear();

  // Netscape bookmark file (the format browsers import and export).
  Q_INVOKABLE QString exportHtml(const QString& folder = {}) const;
  // JSON: { version, roots: [ { id, type, title, children: [...] } ] }.
  Q_INVOKABLE QString exportJson(const QString& folder = {}) const;
  // Imports a Netscape bookmark file; opts: { folder (put everything there;
  // by default the file's toolbar folder goes to the bookmarks bar and the
  // rest to "other"), replace (clear first) }. Bookmarks already in the
  // target folder (same URL) are skipped and folders with the same title
  // merged, so importing a file twice adds nothing. Returns { ok,
  // bookmarks, folders, skipped, error }.
  Q_INVOKABLE QVariantMap importHtml(const QString& html, const QVariant& opts = {});
  // Imports this store's JSON (a string or an object) or Chrome's
  // "Bookmarks" file; opts and result as for importHtml().
  Q_INVOKABLE QVariantMap importJson(const QVariant& json, const QVariant& opts = {});
  // Reads / writes a file (a path or file: URL); the format is JSON if the
  // file starts with "{", else HTML. exportFile's `format` is "html" or
  // "json" (default: from the extension).
  Q_INVOKABLE QVariantMap importFile(const QVariant& file, const QVariant& opts = {});
  Q_INVOKABLE bool exportFile(const QVariant& file, const QString& format = {},
                              const QString& folder = {});

  Q_INVOKABLE bool save();
  Q_INVOKABLE bool reload();

  // For BookmarkModel.
  Node* node(const QString& id) const;
  bool matches(const Node* n, const QStringList& words) const;
  QVariantMap toMap(const Node* n) const;

 Q_SIGNALS:
  void pathChanged();
  void loadedChanged();
  void defaultFolderChanged();
  void saveDelayChanged();
  void errorStringChanged();
  // Fine-grained notifications; changed() follows each operation (once for
  // bulk ones like import, clear and reload).
  void added(const QString& id);
  void removed(const QString& id, const QString& parentId, int index);
  void moved(const QString& id, const QString& oldParent, int oldIndex,
             const QString& newParent, int newIndex);
  void updated(const QString& id);
  void imported(int bookmarks, int folders);
  void changed();
  void saved();

 private:
  struct ImportStats {
    int bookmarks = 0;
    int folders = 0;
    int skipped = 0;
  };
  void resetTree();
  Node* newNode(bool folder, const QString& id = {});
  void index(Node* n);
  void unindex(Node* n);
  Node* targetFolder(const QVariantMap& opts, const QString& fallback) const;
  void insert(Node* parent, Node* n, int index);
  QString addNode(Node* parent, Node* n, int index);
  void commit();
  QVariantMap importInto(Node* tree, const QVariantMap& opts, bool hasRoots);
  void mergeInto(Node* target, Node* source, ImportStats* stats);
  void mergeChild(Node* target, Node* child, ImportStats* stats);
  Node* fromJson(const QVariantMap& o, int depth) const;
  QVariantMap toJson(const Node* n) const;
  void writeHtml(const Node* n, int depth, QString* out) const;
  void searchIn(const Node* n, const QStringList& words, const QString& text,
                QList<QPair<double, const Node*>>* out) const;
  bool load();
  void markDirty();
  void flush();
  void setError(const QString& message);
  void ensureLoaded() const;

  QString m_path = QStringLiteral("bookmarks.json");
  QString m_filePath;
  QString m_defaultFolder = QStringLiteral("bar");
  bool m_complete = false;
  bool m_loaded = false;
  bool m_dirty = false;
  int m_revision = 0;
  int m_urlCount = 0;
  int m_folderCount = 0;
  qint64 m_nextId = 1;
  QString m_error;
  QTimer m_timer;
  Node* m_root = nullptr;
  QHash<QString, Node*> m_ids;
  QMultiHash<QString, Node*> m_urls;
};

// The children of one folder of a BookmarkStore as a list model, updated row
// by row. Roles: nodeId (the node's id; `id` is reserved in QML), type,
// isFolder, title, url, icon, dateAdded, dateModified, parentId, position,
// childCount, depth, path. get(row) returns the node object (with `id`).
//
//   ListView { model: BookmarkModel { store: bookmarks; folder: "bar" } }
//
// recursive: the whole subtree, depth first (with `depth`) — e.g. a folder
// tree with foldersOnly. filterText: only bookmarks in the subtree matching
// every word (title or URL), as a flat list.
class BookmarkModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(BookmarkStore* store READ store WRITE setStore NOTIFY storeChanged)
  Q_PROPERTY(QString folder READ folder WRITE setFolder NOTIFY folderChanged)
  Q_PROPERTY(bool recursive READ recursive WRITE setRecursive NOTIFY recursiveChanged)
  Q_PROPERTY(bool foldersOnly READ foldersOnly WRITE setFoldersOnly NOTIFY foldersOnlyChanged)
  Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
  Q_PROPERTY(int count READ count NOTIFY countChanged)

 public:
  enum Roles {
    IdRole = Qt::UserRole + 1,
    TypeRole,
    IsFolderRole,
    TitleRole,
    UrlRole,
    IconRole,
    DateAddedRole,
    DateModifiedRole,
    ParentIdRole,
    PositionRole,
    ChildCountRole,
    DepthRole,
    PathRole,
  };

  explicit BookmarkModel(QObject* parent = nullptr);

  int rowCount(const QModelIndex& parent = {}) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  BookmarkStore* store() const { return m_store; }
  void setStore(BookmarkStore* store);
  QString folder() const { return m_folder; }
  void setFolder(const QString& folder);
  bool recursive() const { return m_recursive; }
  void setRecursive(bool on);
  bool foldersOnly() const { return m_foldersOnly; }
  void setFoldersOnly(bool on);
  QString filterText() const { return m_filterText; }
  void setFilterText(const QString& text);
  int count() const { return m_rows.size(); }

  Q_INVOKABLE QVariant get(int row) const;
  Q_INVOKABLE int indexOf(const QString& id) const;

 Q_SIGNALS:
  void storeChanged();
  void folderChanged();
  void recursiveChanged();
  void foldersOnlyChanged();
  void filterTextChanged();
  void countChanged();

 private:
  struct Row {
    QString id;
    int depth = 0;
    bool operator==(const Row& o) const { return id == o.id && depth == o.depth; }
  };
  QList<Row> collect() const;
  void collectInto(const BookmarkStore::Node* n, int depth, QList<Row>* out) const;
  void sync();

  QPointer<BookmarkStore> m_store;
  QMetaObject::Connection m_conn;
  QString m_folder = QStringLiteral("bar");
  bool m_recursive = false;
  bool m_foldersOnly = false;
  QString m_filterText;
  QStringList m_words;
  QList<Row> m_rows;
};
