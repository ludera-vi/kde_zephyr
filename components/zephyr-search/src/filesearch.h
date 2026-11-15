#pragma once

#include "resultsmodel.h"

#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QTimer>

// Runs external search tools and streams ranked results:
//   names -> fd (live filesystem walk)
//   text  -> ripgrep
// The default scope is the home folder plus every connected disk.
class FileSearch : public QObject
{
    Q_OBJECT

public:
    struct Options {
        bool wholeSystem = false;
        bool hidden = false;
        bool content = false;
    };

    explicit FileSearch(QObject *parent = nullptr);

    void start(const QString &query, Options options);
    void cancel();

Q_SIGNALS:
    void resultsReady(const QList<Result> &results, bool finished);

private:
    void launch(QStringList roots);
    void readOutput();
    void publish(bool finished);

    QPointer<QProcess> m_process;
    QByteArray m_buffer;
    QString m_query;
    QStringList m_queryWords;
    QStringList m_userRoots;
    QString m_program;
    QStringList m_baseArgs;
    QStringList m_pendingRoots; // searched once m_userRoots are exhausted
    bool m_scanningSystem = false;
    Options m_options;
    QList<Result> m_candidates;
    int m_lines = 0;
    QTimer m_publishTimer;
};
