#include "appindex.h"
#include "match.h"

#include <KApplicationTrader>
#include <KJsonUtils>
#include <KPluginMetaData>
#include <KSycoca>

#include <QSet>

AppIndex::AppIndex(QObject *parent)
    : QObject(parent)
{
    rebuild();
    connect(KSycoca::self(), &KSycoca::databaseChanged, this, &AppIndex::rebuild);
}

void AppIndex::rebuild()
{
    m_apps.clear();
    m_settings.clear();

    const KService::List services = KApplicationTrader::query([](const KService::Ptr &s) {
        return !s->noDisplay();
    });
    for (const KService::Ptr &s : services) {
        Result r{Result::App, s->name(), s->genericName().isEmpty() ? s->comment() : s->genericName(), s->icon(), s->storageId()};
        const QString extra = s->genericName() + QLatin1Char(' ') + s->keywords().join(QLatin1Char(' ')) + QLatin1Char(' ')
            + s->untranslatedGenericName() + QLatin1Char(' ') + s->desktopEntryName();
        m_apps.append({r, extra});
    }

    QSet<QString> seen;
    const auto addModules = [&](const QString &ns, const QString &launcher) {
        for (const KPluginMetaData &md : KPluginMetaData::findPlugins(ns)) {
            if (seen.contains(md.pluginId())) {
                continue;
            }
            seen.insert(md.pluginId());
            const QJsonObject raw = md.rawData();
            const QString keywords = KJsonUtils::readTranslatedString(raw, QStringLiteral("X-KDE-Keywords"));
            const QString englishKeywords = raw.value(QStringLiteral("X-KDE-Keywords")).toString();
            Result r{Result::Setting, md.name(), md.description(), md.iconName(), launcher + QLatin1Char(' ') + md.pluginId()};
            m_settings.append({r, md.description() + QLatin1Char(' ') + keywords + QLatin1Char(' ') + englishKeywords});
        }
    };
    addModules(QStringLiteral("plasma/kcms/systemsettings"), QStringLiteral("systemsettings"));
    addModules(QStringLiteral("plasma/kcms/systemsettings_qwidgets"), QStringLiteral("systemsettings"));
    addModules(QStringLiteral("plasma/kcms/kinfocenter"), QStringLiteral("kinfocenter"));
}

QList<Result> AppIndex::search(const QString &query, int maxApps, int maxSettings) const
{
    const QString q = query.trimmed().toLower();
    const QStringList qw = Match::words(q);

    const auto run = [&](const QList<Entry> &entries, int limit) {
        QList<Result> out;
        for (const Entry &e : entries) {
            const int s = Match::score(q, qw, e.result.title, e.keywords);
            if (s > 0) {
                Result r = e.result;
                r.score = s;
                out.append(r);
            }
        }
        std::stable_sort(out.begin(), out.end(), [](const Result &a, const Result &b) {
            return a.score != b.score ? a.score > b.score : a.title.size() < b.title.size();
        });
        if (out.size() > limit) {
            out.resize(limit);
        }
        return out;
    };

    return run(m_apps, maxApps) + run(m_settings, maxSettings);
}
