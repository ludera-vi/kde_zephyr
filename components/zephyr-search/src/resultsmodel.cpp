#include "resultsmodel.h"

static QString sectionName(Result::Kind kind)
{
    switch (kind) {
    case Result::App:
        return QStringLiteral("Приложения");
    case Result::Setting:
        return QStringLiteral("Настройки");
    case Result::Folder:
        return QStringLiteral("Папки");
    case Result::File:
        return QStringLiteral("Файлы");
    case Result::TextMatch:
        return QStringLiteral("Найдено в тексте");
    }
    return {};
}

int ResultsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_results.size();
}

QVariant ResultsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_results.size()) {
        return {};
    }
    const Result &r = m_results.at(index.row());
    switch (role) {
    case TitleRole:
        return r.title;
    case SubtitleRole:
        return r.subtitle;
    case IconRole:
        return r.icon;
    case SectionRole:
        return sectionName(r.kind);
    case KindRole:
        return int(r.kind);
    case DetailRole:
        return r.detail;
    }
    return {};
}

QHash<int, QByteArray> ResultsModel::roleNames() const
{
    return {
        {TitleRole, "title"},
        {SubtitleRole, "subtitle"},
        {IconRole, "iconName"},
        {SectionRole, "section"},
        {KindRole, "kind"},
        {DetailRole, "detail"},
    };
}

void ResultsModel::setResults(QList<Result> results)
{
    const auto same = [](const Result &a, const Result &b) {
        return a.kind == b.kind && a.target == b.target && a.line == b.line && a.title == b.title && a.subtitle == b.subtitle;
    };
    if (std::equal(m_results.cbegin(), m_results.cend(), results.cbegin(), results.cend(), same)) {
        return;
    }
    const int oldCount = m_results.size();
    beginResetModel();
    m_results = std::move(results);
    endResetModel();
    if (oldCount != m_results.size()) {
        Q_EMIT countChanged();
    }
}

const Result *ResultsModel::at(int row) const
{
    return row >= 0 && row < m_results.size() ? &m_results.at(row) : nullptr;
}
