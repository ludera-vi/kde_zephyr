#pragma once

#include "appindex.h"
#include "filesearch.h"
#include "resultsmodel.h"

#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>

class Controller : public QObject
{
    Q_OBJECT
    Q_PROPERTY(ResultsModel *results READ results CONSTANT)
    Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
    Q_PROPERTY(bool wholeSystem READ wholeSystem WRITE setWholeSystem NOTIFY optionsChanged)
    Q_PROPERTY(bool hidden READ hidden WRITE setHidden NOTIFY optionsChanged)
    Q_PROPERTY(bool content READ content WRITE setContent NOTIFY optionsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

public:
    explicit Controller(QObject *parent = nullptr);

    void setWindow(QQuickWindow *window);

    ResultsModel *results() { return &m_model; }
    QString query() const { return m_query; }
    void setQuery(const QString &query);
    bool wholeSystem() const { return m_wholeSystem; }
    bool hidden() const { return m_hidden; }
    bool content() const { return m_content; }
    void setWholeSystem(bool on);
    void setHidden(bool on);
    void setContent(bool on);
    bool busy() const { return m_busy; }

    Q_INVOKABLE void toggle();
    Q_INVOKABLE void show();
    Q_INVOKABLE void hide();
    void showWithQuery(const QString &query);
    // Opens the result; with `reveal` opens its containing folder instead.
    Q_INVOKABLE void activate(int row, bool reveal);
    Q_INVOKABLE void setBlurRect(qreal x, qreal y, qreal w, qreal h, qreal radius);

Q_SIGNALS:
    void queryChanged();
    void optionsChanged();
    void busyChanged();
    void shown();

private:
    void runSearch();
    void setBusy(bool busy);
    void commit();

    ResultsModel m_model;
    AppIndex m_apps;
    FileSearch m_files;
    QPointer<QQuickWindow> m_window;
    QTimer m_debounce;
    QString m_query;
    QList<Result> m_appResults;
    QList<Result> m_fileResults;
    QTimer m_commit;
    bool m_wholeSystem = false;
    bool m_hidden = false;
    bool m_content = false;
    bool m_busy = false;
};
