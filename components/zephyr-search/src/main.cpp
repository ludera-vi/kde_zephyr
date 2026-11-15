#include "controller.h"

#include <KDBusService>
#include <KGlobalAccel>

#include <QAction>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSettings>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("zephyr-search"));
    app.setApplicationDisplayName(QStringLiteral("Zephyr Search"));
    app.setOrganizationDomain(QStringLiteral("zephyr.local"));
    app.setDesktopFileName(QStringLiteral("zephyr-search"));
    app.setQuitOnLastWindowClosed(false);

    QCommandLineParser parser;
    QCommandLineOption daemonOption(QStringLiteral("daemon"), QStringLiteral("Start hidden in the background."));
    QCommandLineOption textOption(QStringLiteral("text"), QStringLiteral("Search inside files."));
    QCommandLineOption hiddenOption(QStringLiteral("hidden"), QStringLiteral("Include hidden files."));
    QCommandLineOption everywhereOption(QStringLiteral("everywhere"), QStringLiteral("Search the whole computer, not just home and connected disks."));
    parser.addOptions({daemonOption, textOption, hiddenOption, everywhereOption});
    parser.addPositionalArgument(QStringLiteral("query"), QStringLiteral("Open with this search text."));
    parser.addHelpOption();
    parser.process(app);

    // Options given on the command line (also when forwarded to the running instance).
    const auto applyArguments = [&](Controller &controller, const QStringList &arguments) {
        QCommandLineParser p;
        p.addOptions({daemonOption, textOption, hiddenOption, everywhereOption});
        p.parse(arguments);
        const bool modes = p.isSet(textOption) || p.isSet(hiddenOption) || p.isSet(everywhereOption);
        if (modes) {
            controller.setContent(p.isSet(textOption));
            controller.setHidden(p.isSet(hiddenOption));
            controller.setWholeSystem(p.isSet(everywhereOption));
        }
        if (!p.positionalArguments().isEmpty()) {
            controller.showWithQuery(p.positionalArguments().join(QLatin1Char(' ')));
        } else if (modes) {
            controller.show();
        } else if (!p.isSet(daemonOption)) {
            controller.toggle();
        }
    };

    // A second launch just toggles the window of the running instance.
    KDBusService service(KDBusService::Unique);

    Controller controller;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("zephyr"), &controller);
    engine.loadFromModule("Zephyr", "Main");
    if (engine.rootObjects().isEmpty()) {
        return 1;
    }
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    controller.setWindow(window);

    QObject::connect(&service, &KDBusService::activateRequested, &controller, [&](const QStringList &arguments) {
        applyArguments(controller, arguments);
    });

    auto *toggleAction = new QAction(QStringLiteral("Открыть Zephyr Search"), &app);
    toggleAction->setObjectName(QStringLiteral("toggle"));
    toggleAction->setProperty("componentDisplayName", QStringLiteral("Zephyr Search"));
    QObject::connect(toggleAction, &QAction::triggered, &controller, &Controller::toggle);

    // On the very first run take Alt+Space over from KRunner; after that the
    // user's own choice in System Settings → Shortcuts is respected.
    const QKeySequence altSpace(Qt::ALT | Qt::Key_Space);
    QSettings settings;
    if (!settings.value(QStringLiteral("shortcutClaimed")).toBool()) {
        if (!KGlobalAccel::isGlobalShortcutAvailable(altSpace)) {
            KGlobalAccel::stealShortcutSystemwide(altSpace);
        }
        settings.setValue(QStringLiteral("shortcutClaimed"), true);
    }
    KGlobalAccel::self()->setDefaultShortcut(toggleAction, {altSpace});
    KGlobalAccel::self()->setShortcut(toggleAction, {altSpace});

    applyArguments(controller, app.arguments());

    return app.exec();
}
