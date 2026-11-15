#pragma once

#include <QAbstractListModel>
#include <QList>

struct Result {
    enum Kind { App, Setting, Folder, File, TextMatch };

    Kind kind;
    QString title;
    QString subtitle;
    QString icon;
    QString target; // desktop entry id, KCM id or absolute path
    int line = 0; // for TextMatch
    int score = 0;
    QString detail = {}; // location shown at the right of the title
};

class ResultsModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
    enum Roles { TitleRole = Qt::UserRole + 1, SubtitleRole, IconRole, SectionRole, KindRole, DetailRole };

    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setResults(QList<Result> results);
    const Result *at(int row) const;

Q_SIGNALS:
    void countChanged();

private:
    QList<Result> m_results;
};
