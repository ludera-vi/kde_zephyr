#include "controller.h"
#include "match.h"

#include <KIO/ApplicationLauncherJob>
#include <KIO/CommandLauncherJob>
#include <KIO/OpenFileManagerWindowJob>
#include <KIO/OpenUrlJob>
#include <KService>
#include <KWaylandExtras>
#include <KWindowEffects>
#include <LayerShellQt/Window>

#include <QFuture>
#include <QPainterPath>
#include <QRegion>

Controller::Controller(QObject *parent)
    : QObject(parent)
{
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(90);
    connect(&m_debounce, &QTimer::timeout, this, &Controller::runSearch);
    m_commit.setSingleShot(true);
    m_commit.setInterval(250);
    connect(&m_commit, &QTimer::timeout, this, &Controller::commit);
    connect(&m_files, &FileSearch::resultsReady, this, [this](const QList<Result> &results, bool finished) {
        m_fileResults = results;
        commit();
        if (finished) {
            setBusy(false);
        }
    });
}

void Controller::setWindow(QQuickWindow *window)
{
    m_window = window;

    // A transparent full-screen overlay: the panel is drawn inside it, and a
    // click anywhere outside the panel closes the launcher.
    auto *layer = LayerShellQt::Window::get(window);
    layer->setScope(QStringLiteral("zephyr-search"));
    layer->setLayer(LayerShellQt::Window::LayerOverlay);
    layer->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom
                                                    | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
    layer->setExclusiveZone(-1);
    layer->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityExclusive);
    layer->setWantsToBeOnActiveScreen(true);
}

void Controller::toggle()
{
    if (m_window && m_window->isVisible()) {
        hide();
    } else {
        show();
    }
}

void Controller::show()
{
    if (!m_window) {
        return;
    }
    Q_EMIT shown();
    m_window->show();
    m_window->requestActivate();
}

void Controller::hide()
{
    if (m_window) {
        m_window->hide();
    }
    m_files.cancel();
    setBusy(false);
}

void Controller::showWithQuery(const QString &query)
{
    setQuery(query);
    runSearch();
    show();
}

void Controller::setQuery(const QString &query)
{
    if (query == m_query) {
        return;
    }
    m_query = query;
    Q_EMIT queryChanged();
    m_debounce.start();
}

void Controller::setWholeSystem(bool on)
{
    if (on != m_wholeSystem) {
        m_wholeSystem = on;
        m_fileResults.clear();
        Q_EMIT optionsChanged();
        runSearch();
    }
}

void Controller::setHidden(bool on)
{
    if (on != m_hidden) {
        m_hidden = on;
        m_fileResults.clear();
        Q_EMIT optionsChanged();
        runSearch();
    }
}

void Controller::setContent(bool on)
{
    if (on != m_content) {
        m_content = on;
        m_fileResults.clear();
        Q_EMIT optionsChanged();
        runSearch();
    }
}

void Controller::setBusy(bool busy)
{
    if (busy != m_busy) {
        m_busy = busy;
        Q_EMIT busyChanged();
    }
}

void Controller::runSearch()
{
    m_debounce.stop();
    m_files.cancel();

    const QString q = m_query.trimmed();
    if (q.isEmpty()) {
        m_appResults.clear();
        m_fileResults.clear();
        m_commit.stop();
        m_model.setResults({});
        setBusy(false);
        return;
    }

    m_appResults = m_content ? QList<Result>{} : m_apps.search(q, 6, 4);

    // Until the new file results arrive, keep the old ones that still match,
    // so the list narrows smoothly instead of blinking empty and refilling.
    const QString lower = q.toLower();
    const QStringList words = Match::words(lower);
    QList<Result> kept;
    for (const Result &r : std::as_const(m_fileResults)) {
        const bool matches = r.kind == Result::TextMatch ? Match::wordMatches(lower, r.subtitle.toLower())
                                                         : Match::score(lower, words, r.title) > 0;
        if (matches) {
            kept.append(r);
        }
    }
    m_fileResults = kept;

    if (q.size() >= 2) {
        setBusy(true);
        m_files.start(q, {m_wholeSystem, m_hidden, m_content});
        m_commit.start(); // fallback if the file search is slow
    } else {
        m_fileResults.clear();
        commit();
        setBusy(false);
    }
}

void Controller::commit()
{
    m_commit.stop();
    m_model.setResults(m_appResults + m_fileResults);
}

void Controller::activate(int row, bool reveal)
{
    const Result *found = m_model.at(row);
    if (!found || !m_window) {
        return;
    }
    const Result r = *found;

    // Wayland only lets the launched app take focus if we hand it an
    // activation token issued for our (currently focused) surface.
    QString appId;
    if (r.kind == Result::App) {
        if (const KService::Ptr s = KService::serviceByStorageId(r.target)) {
            appId = s->desktopEntryName();
        }
    } else if (r.kind == Result::Setting) {
        appId = QStringLiteral("systemsettings");
    }

    KWaylandExtras::xdgActivationToken(m_window, appId).then(this, [this, r, reveal](const QString &token) {
        const QByteArray startupId = token.toUtf8();
        switch (r.kind) {
        case Result::App:
            if (const KService::Ptr s = KService::serviceByStorageId(r.target)) {
                auto *job = new KIO::ApplicationLauncherJob(s);
                job->setStartupId(startupId);
                job->start();
            }
            break;
        case Result::Setting: {
            QStringList parts = r.target.split(QLatin1Char(' '));
            const QString program = parts.takeFirst();
            auto *job = new KIO::CommandLauncherJob(program, parts);
            job->setDesktopName(program == QLatin1String("kinfocenter") ? QStringLiteral("org.kde.kinfocenter") : QStringLiteral("systemsettings"));
            job->setStartupId(startupId);
            job->start();
            break;
        }
        case Result::Folder:
        case Result::File:
        case Result::TextMatch: {
            const QUrl url = QUrl::fromLocalFile(r.target);
            if (reveal) {
                KIO::highlightInFileManager({url}, startupId);
            } else {
                auto *job = new KIO::OpenUrlJob(url);
                job->setStartupId(startupId);
                job->start();
            }
            break;
        }
        }
        hide();
    });
}

void Controller::setBlurRect(qreal x, qreal y, qreal w, qreal h, qreal radius)
{
    if (!m_window) {
        return;
    }
    QPainterPath path;
    path.addRoundedRect(QRectF(x, y, w, h), radius, radius);
    const QRegion region(path.toFillPolygon().toPolygon());
    KWindowEffects::enableBlurBehind(m_window, true, region);
    KWindowEffects::enableBackgroundContrast(m_window, true, 1.0, 1.0, 1.5, region);
}
