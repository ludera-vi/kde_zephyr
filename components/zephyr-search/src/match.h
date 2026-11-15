#pragma once

#include <QString>
#include <QStringList>

#include <algorithm>

namespace Match
{

// Splits a lowercased query into words.
inline QStringList words(const QString &query)
{
    return query.split(QLatin1Char(' '), Qt::SkipEmptyParts);
}

// True if some word of `haystack` starts with `word`, tolerating a changed
// ending of up to two letters (so "комбинация" still finds "Комбинации").
inline bool wordMatches(const QString &word, const QString &haystack)
{
    if (haystack.contains(word)) {
        return true;
    }
    // Only Russian words change their endings; for Latin names this just adds noise.
    const bool cyrillic = std::any_of(word.cbegin(), word.cend(), [](QChar c) {
        return c.script() == QChar::Script_Cyrillic;
    });
    for (int cut = 1; cyrillic && cut <= 2 && word.size() - cut >= 4; ++cut) {
        if (haystack.contains(word.left(word.size() - cut))) {
            return true;
        }
    }
    return false;
}

// Scores `title` (and optional `extra` text such as keywords) against the
// lowercased query. Returns 0 when there is no match.
inline int score(const QString &query, const QStringList &queryWords, const QString &title, const QString &extra = {})
{
    const QString t = title.toLower();
    if (t == query) {
        return 100;
    }
    if (t.startsWith(query)) {
        return 90;
    }
    if (t.contains(QLatin1Char(' ') + query) || t.contains(QLatin1Char('-') + query)) {
        return 80;
    }
    if (t.contains(query)) {
        return 65;
    }
    const auto allIn = [&](const QString &hay) {
        for (const QString &w : queryWords) {
            if (!wordMatches(w, hay)) {
                return false;
            }
        }
        return true;
    };
    if (allIn(t)) {
        return 50;
    }
    if (!extra.isEmpty() && allIn(t + QLatin1Char(' ') + extra.toLower())) {
        return 35;
    }
    return 0;
}

} // namespace Match
