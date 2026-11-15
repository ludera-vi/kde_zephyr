#pragma once

#include "resultsmodel.h"

#include <QObject>

// In-memory index of installed applications and System Settings modules.
// Built once at startup and rebuilt when the KService database changes.
class AppIndex : public QObject
{
    Q_OBJECT

public:
    explicit AppIndex(QObject *parent = nullptr);

    QList<Result> search(const QString &query, int maxApps, int maxSettings) const;

private:
    struct Entry {
        Result result;
        QString keywords; // extra searchable text
    };

    void rebuild();

    QList<Entry> m_apps;
    QList<Entry> m_settings;
};
