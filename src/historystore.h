#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJSValue>
#include <QPointer>
#include <QQmlParserStatus>
#include <QSortFilterProxyModel>
#include <QTimer>
#include <QUrl>
#include <QVariant>

class CefWebView;
class HistoryTracker;

// Browsing history: one entry per URL with title, favicon, visit and typed
// counts and first/last visit times, persisted to a JSON file.
//
//   HistoryStore { id: history }            // "history.json" under Cef.dataDir
//   WebTabs { historyStore: history }        // records every tab's visits
//   ... history.search("news", 8)            // frecency-ranked matches
//
// The store is a list model (newest visit first) with the roles url, title,
// icon, visitCount, typedCount, firstVisit, lastVisit (ms since the epoch)
// and day ("yyyy-MM-dd", local time, for ListView sections).
//
// Implemented in C++ rather than on top of JsonStore: history grows to tens
// of thousands of entries and is searched on every keystroke in the address
// bar; a hash + sorted list with cached lowercase strings keeps lookups O(1),
// search a single linear pass, and avoids converting the whole data set
// between QVariant and JavaScript on every change. The file format is plain
// JSON (written atomically, debounced) like JsonStore's.
class HistoryStore : public QAbstractListModel, public QQmlParserStatus {
  Q_OBJECT
  Q_INTERFACES(QQmlParserStatus)
  // Relative paths resolve under Cef.dataDir; "" keeps history in memory.
  Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
  Q_PROPERTY(QString filePath READ filePath NOTIFY pathChanged)
  Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
  Q_PROPERTY(int count READ count NOTIFY countChanged)
  // false: nothing is recorded and search()/inlineCompletion() return
  // nothing (the stored entries are kept).
  Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
  // false ("private mode"): attached views record nothing, but searching
  // existing history still works.
  Q_PROPERTY(bool recording READ recording WRITE setRecording NOTIFY recordingChanged)
  // Pruning: the oldest entries beyond maxEntries, and entries not visited
  // for maxAgeDays, are dropped (0 disables either limit).
  Q_PROPERTY(int maxEntries READ maxEntries WRITE setMaxEntries NOTIFY maxEntriesChanged)
  Q_PROPERTY(int maxAgeDays READ maxAgeDays WRITE setMaxAgeDays NOTIFY maxAgeDaysChanged)
  // URLs longer than this are not recorded (e.g. big data: URLs).
  Q_PROPERTY(int maxUrlLength READ maxUrlLength WRITE setMaxUrlLength NOTIFY maxUrlLengthChanged)
  // URL schemes that are never recorded.
  Q_PROPERTY(QStringList ignoredSchemes READ ignoredSchemes WRITE setIgnoredSchemes NOTIFY ignoredSchemesChanged)
  // function(url) -> true to not record a URL (e.g. the new-tab page).
  Q_PROPERTY(QJSValue ignoreUrl READ ignoreUrl WRITE setIgnoreUrl NOTIFY ignoreUrlChanged)
  Q_PROPERTY(int saveDelay READ saveDelay WRITE setSaveDelay NOTIFY saveDelayChanged)
  Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)

 public:
  enum Roles {
    UrlRole = Qt::UserRole + 1,
    TitleRole,
    IconRole,
    VisitCountRole,
    TypedCountRole,
    FirstVisitRole,
    LastVisitRole,
    DayRole,
    HostRole,
  };

  struct Entry {
    QString url;
    QString title;
    QString icon;
    int visits = 0;
    int typed = 0;
    qint64 first = 0;
    qint64 last = 0;
    // Derived, for search / completion.
    QString day;
    QString host;       // lowercase, without "www."
    QString bare;       // display URL, lowercase, without scheme and "www."
    QString lowerUrl;   // display URL, lowercase
    QString lowerTitle;
    void update();
    void updateDay();
  };

  explicit HistoryStore(QObject* parent = nullptr);
  ~HistoryStore() override;

  void classBegin() override {}
  void componentComplete() override;

  int rowCount(const QModelIndex& parent = {}) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  QString path() const { return m_path; }
  void setPath(const QString& path);
  QString filePath() const { return m_filePath; }
  bool loaded() const { return m_loaded; }
  int count() const { return m_list.size(); }
  bool enabled() const { return m_enabled; }
  void setEnabled(bool on);
  bool recording() const { return m_recording; }
  void setRecording(bool on);
  int maxEntries() const { return m_maxEntries; }
  void setMaxEntries(int n);
  int maxAgeDays() const { return m_maxAgeDays; }
  void setMaxAgeDays(int days);
  int maxUrlLength() const { return m_maxUrlLength; }
  void setMaxUrlLength(int n);
  QStringList ignoredSchemes() const { return m_ignoredSchemes; }
  void setIgnoredSchemes(const QStringList& schemes);
  QJSValue ignoreUrl() const { return m_ignoreUrl; }
  void setIgnoreUrl(const QJSValue& fn);
  int saveDelay() const { return m_timer.interval(); }
  void setSaveDelay(int ms);
  QString errorString() const { return m_error; }

  // The canonical (encoded) string form used as key for a URL or string.
  Q_INVOKABLE QString normalizeUrl(const QVariant& url) const;
  // Whether a URL would be recorded (scheme, length, ignoreUrl).
  Q_INVOKABLE bool isRecordable(const QVariant& url) const;

  // Records a visit. opts: { title, icon, typed (bool), time (ms or Date),
  // reload (bool: only refresh the time) }. Returns false if ignored.
  Q_INVOKABLE bool recordVisit(const QVariant& url, const QVariantMap& opts = {});
  Q_INVOKABLE void setTitle(const QVariant& url, const QString& title);
  Q_INVOKABLE void setIcon(const QVariant& url, const QVariant& icon);
  Q_INVOKABLE bool contains(const QVariant& url) const;
  // The entry as an object, or undefined.
  Q_INVOKABLE QVariant entry(const QVariant& url) const;
  Q_INVOKABLE QVariant get(int row) const;
  Q_INVOKABLE bool remove(const QVariant& url);
  // Removes entries last visited at or after `since` (ms or Date); all
  // entries without an argument. Returns the number removed.
  Q_INVOKABLE int clear(const QVariant& since = {});

  // Entries whose URL or title contain every word of `text`, best first:
  // frecency (visits + 2 x typed, weighted by recency), boosted when the
  // text is a prefix of the host / URL or matches at word starts. An empty
  // text returns the most frecent entries. Each result has the entry fields
  // plus `score`.
  Q_INVOKABLE QVariantList search(const QString& text, int limit = 10) const;
  // Inline autocompletion for address-bar text: { text, url } where `text`
  // starts with `input` (case kept) and completes to the best host
  // ("exa" -> "example.com/") or, once the input contains a "/", to a full
  // URL. undefined when there is nothing to complete.
  Q_INVOKABLE QVariant inlineCompletion(const QString& input) const;
  // Frecency of a URL (0 if unknown).
  Q_INVOKABLE double frecency(const QVariant& url) const;

  // Track a CefWebView's navigations.
  Q_INVOKABLE void attach(QObject* view);
  Q_INVOKABLE void detach(QObject* view);
  Q_INVOKABLE bool isAttached(QObject* view) const;
  // The view's next navigation was typed by the user (address bar).
  Q_INVOKABLE void markTyped(QObject* view);

  Q_INVOKABLE bool save();
  Q_INVOKABLE bool reload();

  // For HistoryModel.
  bool matches(int row, const QStringList& words) const;

 Q_SIGNALS:
  void pathChanged();
  void loadedChanged();
  void countChanged();
  void enabledChanged();
  void recordingChanged();
  void maxEntriesChanged();
  void maxAgeDaysChanged();
  void maxUrlLengthChanged();
  void ignoredSchemesChanged();
  void ignoreUrlChanged();
  void saveDelayChanged();
  void errorStringChanged();
  void visited(const QString& url);
  void saved();

 private:
  friend class HistoryTracker;
  double frecencyOf(const Entry* e, qint64 now) const;
  QVariantMap toMap(const Entry* e) const;
  int rowOf(const Entry* e) const;
  void reposition(Entry* e);
  void removeRow(int row);
  void prune();
  bool load();
  void markDirty();
  void flush();
  void setError(const QString& message);
  void ensureLoaded();
  void trackerGone(QObject* view);

  QString m_path = QStringLiteral("history.json");
  QString m_filePath;
  bool m_complete = false;
  bool m_loaded = false;
  bool m_dirty = false;
  bool m_enabled = true;
  bool m_recording = true;
  int m_maxEntries = 20000;
  int m_maxAgeDays = 90;
  int m_maxUrlLength = 4096;
  QStringList m_ignoredSchemes;
  QJSValue m_ignoreUrl;
  QString m_error;
  QTimer m_timer;
  QList<Entry*> m_list;  // newest first
  QHash<QString, Entry*> m_index;
  QHash<QObject*, HistoryTracker*> m_trackers;
};

// HistoryStore filtered by text (every word must occur in URL or title), in
// the store's order (newest first). For history pages:
//
//   ListView {
//       model: HistoryModel { store: history; filterText: search.text }
//       section.property: "day"
//   }
class HistoryModel : public QSortFilterProxyModel {
  Q_OBJECT
  Q_PROPERTY(HistoryStore* store READ store WRITE setStore NOTIFY storeChanged)
  Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
  Q_PROPERTY(int count READ count NOTIFY countChanged)

 public:
  explicit HistoryModel(QObject* parent = nullptr);

  HistoryStore* store() const { return m_store; }
  void setStore(HistoryStore* store);
  QString filterText() const { return m_filterText; }
  void setFilterText(const QString& text);
  int count() const { return rowCount(); }

  Q_INVOKABLE QVariant get(int row) const;

 Q_SIGNALS:
  void storeChanged();
  void filterTextChanged();
  void countChanged();

 protected:
  bool filterAcceptsRow(int sourceRow, const QModelIndex& sourceParent) const override;

 private:
  QPointer<HistoryStore> m_store;
  QString m_filterText;
  QStringList m_words;
};
