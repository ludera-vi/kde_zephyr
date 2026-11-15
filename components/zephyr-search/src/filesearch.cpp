#include "filesearch.h"
#include "match.h"

#include <KIO/Global>

#include <QDir>
#include <QFileInfo>
#include <QStorageInfo>
#include <QUrl>

#include <algorithm>

namespace
{
constexpr int MaxNameCandidates = 20000; // stop reading fd after this many lines
constexpr int MaxTextMatches = 40;
constexpr int MaxFolders = 8;
constexpr int MaxFiles = 20;

QString prettyDir(const QString &path)
{
    QString dir = QFileInfo(path).path();
    const QString home = QDir::homePath();
    if (dir == home || dir.startsWith(home + QLatin1Char('/'))) {
        dir.replace(0, home.size(), QStringLiteral("~"));
    }
    return dir;
}

bool hasHiddenComponent(const QString &path)
{
    return path.contains(QLatin1String("/."));
}

bool isInside(const QString &path, const QString &dir)
{
    return path.startsWith(dir + QLatin1Char('/'));
}

bool isUnderAny(const QString &path, const QStringList &dirs)
{
    return std::any_of(dirs.begin(), dirs.end(), [&](const QString &dir) {
        return isInside(path, dir);
    });
}

// Real disks mounted outside the system tree: /zephyr, /mnt/*, /media/*, /run/media/<user>/*.
// Read on every search so that plugging a drive in works straight away.
QStringList connectedDisks()
{
    static const QStringList systemMounts{QStringLiteral("/boot"), QStringLiteral("/efi"),  QStringLiteral("/etc"),  QStringLiteral("/home"),
                                          QStringLiteral("/nix"),  QStringLiteral("/opt"),  QStringLiteral("/root"), QStringLiteral("/snap"),
                                          QStringLiteral("/srv"),  QStringLiteral("/tmp"),  QStringLiteral("/usr"),  QStringLiteral("/var")};
    QStringList disks;
    const QList<QStorageInfo> volumes = QStorageInfo::mountedVolumes();
    for (const QStorageInfo &volume : volumes) {
        const QByteArray device = volume.device();
        const QString root = volume.rootPath();
        if (!volume.isValid() || !volume.isReady() || root == QLatin1String("/")) {
            continue;
        }
        // Network shares, loop images (snap, AppImage) and compressed RAM are not disks.
        if (!device.startsWith("/dev/") || device.startsWith("/dev/loop") || device.startsWith("/dev/zram")) {
            continue;
        }
        // Hidden mounts are snapshots (/.snapshots); under /run only /run/media holds user disks,
        // the rest is tooling such as Timeshift mirroring the whole system.
        if (hasHiddenComponent(root) || (isInside(root, QStringLiteral("/run")) && !isInside(root, QStringLiteral("/run/media")))) {
            continue;
        }
        const bool system = std::any_of(systemMounts.begin(), systemMounts.end(), [&](const QString &mount) {
            return root == mount || isInside(root, mount);
        });
        if (!system && QFileInfo(root).isReadable()) {
            disks << root;
        }
    }
    return disks;
}

// Drops roots already covered by another root, so no file is reported twice.
QStringList withoutNested(const QStringList &roots)
{
    QStringList out;
    for (const QString &root : roots) {
        const bool nested = std::any_of(roots.begin(), roots.end(), [&](const QString &other) {
            return isInside(root, other);
        });
        if (!nested && !out.contains(root)) {
            out << root;
        }
    }
    return out;
}

// Top-level directories for a whole-system search, minus the virtual ones.
// Symlinks are skipped too: /bin and /lib only lead back into /usr.
QStringList systemRoots()
{
    static const QStringList skip{QStringLiteral("proc"), QStringLiteral("sys"), QStringLiteral("dev"), QStringLiteral("run"), QStringLiteral("tmp")};
    QStringList roots;
    for (const QString &d : QDir(QStringLiteral("/")).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks)) {
        if (!skip.contains(d)) {
            roots << QLatin1Char('/') + d;
        }
    }
    return roots;
}
} // namespace

FileSearch::FileSearch(QObject *parent)
    : QObject(parent)
{
    m_publishTimer.setSingleShot(true);
    m_publishTimer.setInterval(350); // partial results only for slow searches
    connect(&m_publishTimer, &QTimer::timeout, this, [this] {
        publish(false);
    });
}

void FileSearch::cancel()
{
    m_publishTimer.stop();
    if (m_process) {
        m_process->disconnect(this);
        m_process->kill();
        m_process->waitForFinished(100);
        m_process->deleteLater();
    }
    m_process = nullptr;
    m_buffer.clear();
    m_candidates.clear();
    m_lines = 0;
    m_pendingRoots.clear();
    m_scanningSystem = false;
}

void FileSearch::start(const QString &query, Options options)
{
    cancel();
    m_query = query.trimmed().toLower();
    m_queryWords = Match::words(m_query);
    m_options = options;
    if (m_query.size() < 2) {
        return;
    }

    // Tools search for the longest word; the remaining words are checked while ranking.
    QString pattern = m_queryWords.value(0);
    for (const QString &w : std::as_const(m_queryWords)) {
        if (w.size() > pattern.size()) {
            pattern = w;
        }
    }

    m_userRoots = withoutNested(QStringList{QDir::homePath()} + connectedDisks());
    const QStringList roots = options.wholeSystem ? withoutNested(m_userRoots + systemRoots()) : m_userRoots;

    QString program;
    QStringList args;
    if (options.content) {
        program = QStringLiteral("rg");
        args << QStringLiteral("--null") << QStringLiteral("--line-number") << QStringLiteral("--no-heading") << QStringLiteral("--color=never")
             << QStringLiteral("--ignore-case") << QStringLiteral("--fixed-strings") << QStringLiteral("--max-count=1")
             << QStringLiteral("--max-columns=300") << QStringLiteral("--max-columns-preview") << QStringLiteral("--max-filesize=4M");
        if (options.hidden) {
            args << QStringLiteral("--hidden");
        }
        args << QStringLiteral("--") << query.trimmed();
    } else {
        program = QStringLiteral("fd");
        args << QStringLiteral("--color=never") << QStringLiteral("--absolute-path") << QStringLiteral("--ignore-case")
             << QStringLiteral("--fixed-strings");
        if (options.hidden) {
            args << QStringLiteral("--hidden");
        }
        if (options.wholeSystem) {
            args << QStringLiteral("--no-ignore") << QStringLiteral("--exclude") << QStringLiteral(".git");
        }
        args << QStringLiteral("--") << pattern;
    }

    m_program = program;
    m_baseArgs = args;
    if (options.content && options.wholeSystem) {
        // Text hits arrive in walk order and stop at MaxTextMatches, so system folders
        // full of common words would crowd out the user's files: search those first.
        m_pendingRoots = roots;
        launch(m_userRoots);
    } else {
        launch(roots);
    }
}

// Takes a copy: the argument may be m_pendingRoots itself, which is edited below.
void FileSearch::launch(QStringList roots)
{
    for (const QString &root : roots) {
        m_pendingRoots.removeAll(root);
    }
    m_process = new QProcess(this);
    m_process->setProgram(m_program);
    m_process->setArguments(m_baseArgs + roots);
    m_process->setStandardErrorFile(QProcess::nullDevice());
    connect(m_process, &QProcess::readyReadStandardOutput, this, &FileSearch::readOutput);
    connect(m_process, &QProcess::finished, this, [this] {
        readOutput();
        if (m_process && !m_pendingRoots.isEmpty()) {
            m_process->deleteLater();
            m_scanningSystem = true;
            launch(m_pendingRoots);
            return;
        }
        publish(true);
        if (m_process) {
            m_process->deleteLater();
            m_process = nullptr;
        }
    });
    m_process->start();
}

void FileSearch::readOutput()
{
    if (!m_process) {
        return;
    }
    m_buffer += m_process->readAllStandardOutput();

    qsizetype nl;
    while ((nl = m_buffer.indexOf('\n')) >= 0) {
        const QByteArray line = m_buffer.left(nl);
        m_buffer.remove(0, nl + 1);
        ++m_lines;

        if (m_options.content) {
            const qsizetype nul = line.indexOf('\0');
            if (nul < 0) {
                continue;
            }
            const QString path = QString::fromUtf8(line.left(nul));
            if (m_scanningSystem && isUnderAny(path, m_userRoots)) {
                continue; // /home was already covered through the home folder
            }
            const QByteArray rest = line.mid(nul + 1);
            const qsizetype colon = rest.indexOf(':');
            const int lineNo = rest.left(colon).toInt();
            QString text = QString::fromUtf8(rest.mid(colon + 1));
            for (QChar &c : text) {
                if (c.category() == QChar::Separator_Line || c.category() == QChar::Separator_Paragraph || c.category() == QChar::Other_Control) {
                    c = QLatin1Char(' ');
                }
            }
            text = text.simplified();
            // Start the snippet shortly before the match so it is always visible.
            const qsizetype hit = text.indexOf(m_query, 0, Qt::CaseInsensitive);
            if (hit > 50) {
                const qsizetype from = text.lastIndexOf(QLatin1Char(' '), hit - 25);
                text = QStringLiteral("…") + text.mid(from > 0 ? from + 1 : hit - 25);
            }
            text = text.left(240);
            Result r{Result::TextMatch, QFileInfo(path).fileName(), text, {}, path, lineNo};
            r.detail = prettyDir(path);
            m_candidates.append(r);
        } else {
            QString path = QString::fromUtf8(line);
            if (path.endsWith(QLatin1Char('/')) && path.size() > 1) {
                path.chop(1);
            }
            if (!m_options.hidden && hasHiddenComponent(path)) {
                continue;
            }
            const QString base = QFileInfo(path).fileName();
            // ".config" should rank like "config".
            const QString bare = base.startsWith(QLatin1Char('.')) ? base.mid(1) : base;
            int s = Match::score(m_query, m_queryWords, bare);
            if (s == 0) {
                continue;
            }
            s -= path.count(QLatin1Char('/'));
            if (!m_options.hidden && hasHiddenComponent(path)) {
                s -= 10;
            }
            if (m_options.wholeSystem && isUnderAny(path, m_userRoots)) {
                s += 10;
            }
            m_candidates.append(Result{Result::File, base, {}, {}, path, 0, s});
        }

        const bool enough = m_options.content ? m_candidates.size() >= MaxTextMatches : m_lines >= MaxNameCandidates;
        if (enough) {
            m_process->disconnect(this);
            m_process->kill();
            m_process->deleteLater();
            m_process = nullptr;
            publish(true);
            return;
        }
    }

    if (!m_publishTimer.isActive()) {
        m_publishTimer.start();
    }
}

void FileSearch::publish(bool finished)
{
    m_publishTimer.stop();
    QList<Result> out;

    if (m_options.content) {
        for (Result r : std::as_const(m_candidates)) {
            r.icon = KIO::iconNameForUrl(QUrl::fromLocalFile(r.target));
            r.subtitle = QStringLiteral("%1:  %2").arg(r.line).arg(r.subtitle);
            out.append(r);
        }
    } else {
        QList<Result> sorted = m_candidates;
        std::stable_sort(sorted.begin(), sorted.end(), [](const Result &a, const Result &b) {
            return a.score != b.score ? a.score > b.score : a.target.size() < b.target.size();
        });
        QList<Result> folders;
        QList<Result> files;
        for (Result r : std::as_const(sorted)) {
            if (folders.size() >= MaxFolders && files.size() >= MaxFiles) {
                break;
            }
            const QFileInfo fi(r.target);
            if (!fi.exists()) {
                continue; // deleted since it was listed, or a broken symlink
            }
            r.kind = fi.isDir() ? Result::Folder : Result::File;
            QList<Result> &bucket = fi.isDir() ? folders : files;
            if (bucket.size() >= (fi.isDir() ? MaxFolders : MaxFiles)) {
                continue;
            }
            r.icon = KIO::iconNameForUrl(QUrl::fromLocalFile(r.target));
            r.subtitle = prettyDir(r.target);
            bucket.append(r);
        }
        out = folders + files;
    }

    Q_EMIT resultsReady(out, finished);
}
