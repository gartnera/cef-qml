#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QQmlParserStatus>
#include <QSet>
#include <QSortFilterProxyModel>
#include <QTimer>
#include <QUrl>
#include <QVariant>

// Per-site settings: a value per key for each site scope, persisted to a
// JSON file under Cef.dataDir.
//
//   SiteSettings { id: sites }               // "site-settings.json"
//   WebTabs { siteSettings: sites }           // enforces them in every tab
//   sites.set("https://example.com", "camera", "allow")
//   sites.set("[*.]example.org", "javascript", "block")
//   sites.set("*", "zoom", 1.25)              // default for all sites
//   sites.effective("https://a.example.org/x", "javascript")  // "block"
//
// Scopes, most specific first:
//   "https://example.com:8443"  an origin (scheme, host and port; default
//                               ports are dropped, any URL is reduced to it)
//   "example.com"               that host, any scheme and port
//   "[*.]example.com"           the host and all its subdomains (the longest
//                               matching domain wins)
//   "*"                         the default for every site
// A lookup goes through the scopes in that order per key, so an origin that
// only stores "zoom" still gets "javascript" from a matching pattern.
//
// Keys and values (other keys may hold any JSON value, e.g. app settings):
//   "zoom"                       zoom factor (0.25 .. 5)
//   "javascript", "images"       "allow" | "block" (Chromium content settings)
//   "popups"                     "allow" | "block": popups opened without a
//                                user gesture (Chromium's popup blocker)
//   permission names             "allow" | "block" | "ask", as in
//                                CefPermissionRequest.permissions: "camera",
//                                "microphone", "geolocation", "notifications",
//                                "clipboard", "midi-sysex", ...
//
// The store is a list model of its scopes (sorted by host, "*" first) with
// the roles scope, name (host for display), kind ("origin", "host",
// "pattern" or "default"), settings (object) and keys.
//
// Implemented in C++ rather than on top of JsonStore: lookups (pattern
// matching) run synchronously for every navigation and permission request,
// and enforcement writes Chromium's content settings through
// CefRequestContext, which is only reachable from C++.
class SiteSettings : public QAbstractListModel, public QQmlParserStatus {
  Q_OBJECT
  Q_INTERFACES(QQmlParserStatus)
  // Relative paths resolve under Cef.dataDir; "" keeps the settings in memory.
  Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
  Q_PROPERTY(QString filePath READ filePath NOTIFY pathChanged)
  Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
  Q_PROPERTY(int count READ count NOTIFY countChanged)
  // Incremented on every change; bind to it to re-evaluate lookups.
  Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
  // Push "javascript", "images", "popups" and permission decisions into
  // Chromium's content settings (apply()). Without it the store only
  // answers lookups and WebTabs still auto-answers permission requests.
  Q_PROPERTY(bool contentSettings READ contentSettings WRITE setContentSettings NOTIFY contentSettingsChanged)
  Q_PROPERTY(int saveDelay READ saveDelay WRITE setSaveDelay NOTIFY saveDelayChanged)
  Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)

 public:
  enum Roles { ScopeRole = Qt::UserRole + 1, NameRole, KindRole, SettingsRole, KeysRole };

  explicit SiteSettings(QObject* parent = nullptr);
  ~SiteSettings() override;

  void classBegin() override {}
  void componentComplete() override;

  int rowCount(const QModelIndex& parent = {}) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  QString path() const { return m_path; }
  void setPath(const QString& path);
  QString filePath() const { return m_filePath; }
  bool loaded() const { return m_loaded; }
  int count() const { return m_scopes.size(); }
  int revision() const { return m_revision; }
  bool contentSettings() const { return m_contentSettings; }
  void setContentSettings(bool on);
  int saveDelay() const { return m_timer.interval(); }
  void setSaveDelay(int ms);
  QString errorString() const { return m_error; }

  // "scheme://host[:port]" of a URL (string or url); "" for URLs without an
  // origin of their own (data:, about:, javascript:, ...); "file://" for
  // file URLs.
  Q_INVOKABLE QString originOf(const QVariant& url) const;
  // The canonical form of a scope ("" if it is not one): see above.
  Q_INVOKABLE QString normalizeScope(const QVariant& scope) const;

  // The value stored for exactly this scope, or undefined.
  Q_INVOKABLE QVariant get(const QVariant& scope, const QString& key) const;
  // All values of a scope, as an object ({} if none).
  Q_INVOKABLE QVariantMap settings(const QVariant& scope) const;
  // Stores a value; undefined or null removes it. Returns false for an
  // invalid scope or a value a built-in key does not accept.
  Q_INVOKABLE bool set(const QVariant& scope, const QString& key, const QVariant& value);
  // Removes one key of a scope, or the whole scope without `key`.
  Q_INVOKABLE bool reset(const QVariant& scope, const QString& key = QString());
  // Removes everything.
  Q_INVOKABLE void clear();
  // Every scope with settings, in model order.
  Q_INVOKABLE QStringList origins() const;
  Q_INVOKABLE bool contains(const QVariant& scope) const;
  Q_INVOKABLE QVariant get(int row) const;

  // The value that applies to `url`: from the most specific scope that has
  // the key, else the built-in default (zoom 1, javascript/images "allow",
  // popups "block", permissions "ask"; undefined for other keys).
  Q_INVOKABLE QVariant effective(const QVariant& url, const QString& key) const;
  // The scope that decides `key` for `url` ("" when the built-in default
  // applies).
  Q_INVOKABLE QString scopeFor(const QVariant& url, const QString& key) const;
  Q_INVOKABLE QVariant defaultValue(const QString& key) const;
  // Decision for a permission request: "block" if any permission is
  // blocked, "allow" if all are allowed, else "ask".
  Q_INVOKABLE QString decide(const QVariant& url, const QStringList& permissions) const;
  // Whether `key` is a permission (answered with allow / block / ask).
  Q_INVOKABLE bool isPermission(const QString& key) const;

  // Writes the content settings that apply to the origin of `url` into
  // Chromium (see contentSettings). Call it before the page loads:
  // WebTabs does so from CefWebView.navigationRequested. Later changes to
  // the store are pushed again for every origin applied this way.
  Q_INVOKABLE void apply(const QVariant& url);

  Q_INVOKABLE bool save();
  Q_INVOKABLE bool reload();

 Q_SIGNALS:
  void pathChanged();
  void loadedChanged();
  void countChanged();
  void revisionChanged();
  void contentSettingsChanged();
  void saveDelayChanged();
  void errorStringChanged();
  // A value changed. `key` is "" when a whole scope was reset; `scope` is
  // "" when everything changed (clear, reload).
  void changed(const QString& scope, const QString& key);
  void saved();

 private:
  struct Scope {
    QString key;
    QString name;  // display: host or pattern domain
    QString kind;
    QVariantMap values;
  };

  QVariant lookup(const QVariant& url, const QString& key, QString* from, bool withDefault) const;
  QString scopeKind(const QString& scope) const;
  QString scopeName(const QString& scope) const;
  int rowOf(const QString& scope) const;
  int insertionRow(const Scope& s) const;
  void notifyChanged(const QString& scope, const QString& key);
  void pushOrigin(const QString& origin);
  void pushDefault(const QString& key);
  void ensureLoaded();
  bool load();
  void markDirty();
  void flush();
  void setError(const QString& message);

  QString m_path = QStringLiteral("site-settings.json");
  QString m_filePath;
  bool m_complete = false;
  bool m_loaded = false;
  bool m_dirty = false;
  bool m_contentSettings = true;
  int m_revision = 0;
  QString m_error;
  QTimer m_timer;
  QList<Scope> m_scopes;      // model order
  QSet<QString> m_applied;    // origins pushed to Chromium by apply()
};

// SiteSettings filtered by text (matched against the scope and its keys),
// for site settings pages:
//   ListView { model: SiteSettingsModel { store: sites; filterText: search.text } }
class SiteSettingsModel : public QSortFilterProxyModel {
  Q_OBJECT
  Q_PROPERTY(SiteSettings* store READ store WRITE setStore NOTIFY storeChanged)
  Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
  Q_PROPERTY(int count READ count NOTIFY countChanged)

 public:
  explicit SiteSettingsModel(QObject* parent = nullptr);

  SiteSettings* store() const { return m_store; }
  void setStore(SiteSettings* store);
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
  SiteSettings* m_store = nullptr;
  QString m_filterText;
};
