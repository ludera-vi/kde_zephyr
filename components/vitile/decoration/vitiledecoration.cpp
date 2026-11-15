// Рамка vitile для KWin 6 (KDecoration3).
//
// Окно «в плитке» (скрипт vitile ставит ему keepBelow — плитки и так держатся под
// плавающими окнами и диалогами) — без заголовка: тонкая цветная обводка и
// скруглённые углы. Скругление и обводку рисует сам KWin (setBorderRadius /
// setBorderOutline), поэтому скругляется и содержимое окна, а размытие и тени
// это учитывают.
// Остальные окна — с заголовком: значок, название и кнопки в порядке из настроек KDE.
//
// Настройки — kwinrc, группа [vitile-decoration] (их пишет vitile.py apply).

#include <KDecoration3/DecoratedWindow>
#include <KDecoration3/Decoration>
#include <KDecoration3/DecorationButton>
#include <KDecoration3/DecorationButtonGroup>
#include <KDecoration3/DecorationSettings>

#include <KConfigGroup>
#include <KPluginFactory>
#include <KSharedConfig>

#include <QPainter>
#include <QPainterPath>

namespace Vitile
{

struct Config {
    qreal width = 3;
    qreal radius = 10;
    QColor active = QColor(0x7a, 0xa2, 0xf7);
    QColor inactive = QColor(0x3b, 0x42, 0x61);
    qreal titleHeight = 30;

    static Config load()
    {
        Config c;
        auto config = KSharedConfig::openConfig(QStringLiteral("kwinrc"));
        config->reparseConfiguration();
        const KConfigGroup g = config->group(QStringLiteral("vitile-decoration"));
        c.width = g.readEntry("BorderWidth", c.width);
        c.radius = g.readEntry("Radius", c.radius);
        c.active = g.readEntry("ActiveColor", c.active);
        c.inactive = g.readEntry("InactiveColor", c.inactive);
        c.titleHeight = g.readEntry("TitleHeight", c.titleHeight);
        return c;
    }
};

class Decoration;

// Кнопка заголовка: круглая подложка при наведении, значок рисуем линиями
class Button : public KDecoration3::DecorationButton
{
    Q_OBJECT

public:
    Button(KDecoration3::DecorationButtonType type, KDecoration3::Decoration *decoration, QObject *parent)
        : KDecoration3::DecorationButton(type, decoration, parent)
    {
        connect(this, &DecorationButton::hoveredChanged, this, [this] {
            update();
        });
    }

    // Какие кнопки умеем. Для остальных возвращаем nullptr — KDecoration их пропускает.
    static KDecoration3::DecorationButton *create(KDecoration3::DecorationButtonType type, KDecoration3::Decoration *decoration, QObject *parent)
    {
        using T = KDecoration3::DecorationButtonType;
        switch (type) {
        case T::Menu:
        case T::OnAllDesktops:
        case T::Minimize:
        case T::Maximize:
        case T::Close:
        case T::KeepAbove:
        case T::KeepBelow:
            return new Button(type, decoration, parent);
        default:
            return nullptr;
        }
    }

    void paint(QPainter *painter, const QRectF &repaintArea) override
    {
        Q_UNUSED(repaintArea)
        if (!isVisible()) {
            return;
        }
        using T = KDecoration3::DecorationButtonType;
        const QRectF r = geometry();
        const auto *w = decoration()->window();
        const QPalette pal = w->palette();
        const QColor fg = pal.color(w->isActive() ? QPalette::Active : QPalette::Inactive, QPalette::WindowText);

        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);

        if (type() == T::Menu) {
            w->icon().paint(painter, r.adjusted(2, 2, -2, -2).toRect());
            painter->restore();
            return;
        }

        if (isHovered() || isPressed() || isChecked()) {
            QColor bg = type() == T::Close && (isHovered() || isPressed()) ? QColor(0xe0, 0x4f, 0x5f) : fg;
            if (type() != T::Close || !(isHovered() || isPressed())) {
                bg.setAlphaF(isPressed() ? 0.35 : 0.18);
            }
            painter->setPen(Qt::NoPen);
            painter->setBrush(bg);
            painter->drawEllipse(r.adjusted(1, 1, -1, -1));
        }

        QColor ink = (type() == T::Close && (isHovered() || isPressed())) ? Qt::white : fg;
        if (!isEnabled()) {
            ink.setAlphaF(0.35);
        }
        QPen pen(ink, qMax(1.2, r.width() / 14.0));
        pen.setCapStyle(Qt::RoundCap);
        pen.setJoinStyle(Qt::RoundJoin);
        painter->setPen(pen);
        painter->setBrush(Qt::NoBrush);
        const QRectF g = r.adjusted(r.width() * 0.32, r.height() * 0.32, -r.width() * 0.32, -r.height() * 0.32);

        switch (type()) {
        case T::Close:
            painter->drawLine(g.topLeft(), g.bottomRight());
            painter->drawLine(g.topRight(), g.bottomLeft());
            break;
        case T::Minimize:
            painter->drawLine(QPointF(g.left(), g.center().y() + g.height() * 0.25), QPointF(g.right(), g.center().y() + g.height() * 0.25));
            break;
        case T::Maximize:
            if (isChecked()) { // развёрнуто — два окошка «восстановить»
                const qreal d = g.width() * 0.25;
                painter->drawRoundedRect(g.adjusted(0, d, -d, 0), 1.5, 1.5);
                painter->drawPolyline(QList<QPointF>{QPointF(g.left() + d, g.top() + d), QPointF(g.left() + d, g.top()),
                                                     QPointF(g.right(), g.top()), QPointF(g.right(), g.bottom() - d),
                                                     QPointF(g.right() - d, g.bottom() - d)});
            } else {
                painter->drawRoundedRect(g, 1.5, 1.5);
            }
            break;
        case T::OnAllDesktops:
            painter->setBrush(isChecked() ? ink : Qt::transparent);
            painter->drawEllipse(g.center(), g.width() * 0.3, g.width() * 0.3);
            break;
        case T::KeepAbove:
            painter->drawPolyline(QList<QPointF>{QPointF(g.left(), g.center().y() + g.height() * 0.2), QPointF(g.center().x(), g.top() + g.height() * 0.15),
                                                 QPointF(g.right(), g.center().y() + g.height() * 0.2)});
            break;
        case T::KeepBelow:
            painter->drawPolyline(QList<QPointF>{QPointF(g.left(), g.center().y() - g.height() * 0.2), QPointF(g.center().x(), g.bottom() - g.height() * 0.15),
                                                 QPointF(g.right(), g.center().y() - g.height() * 0.2)});
            break;
        default:
            break;
        }
        painter->restore();
    }
};

class Decoration : public KDecoration3::Decoration
{
    Q_OBJECT

public:
    explicit Decoration(QObject *parent, const QVariantList &args)
        : KDecoration3::Decoration(parent, args)
    {
    }

    bool init() override
    {
        auto *w = window();
        m_config = Config::load();

        m_left = new KDecoration3::DecorationButtonGroup(KDecoration3::DecorationButtonGroup::Position::Left, this, &Button::create);
        m_right = new KDecoration3::DecorationButtonGroup(KDecoration3::DecorationButtonGroup::Position::Right, this, &Button::create);

        connect(w, &KDecoration3::DecoratedWindow::activeChanged, this, &Decoration::refresh);
        connect(w, &KDecoration3::DecoratedWindow::keepBelowChanged, this, &Decoration::refresh);
        connect(w, &KDecoration3::DecoratedWindow::maximizedChanged, this, &Decoration::refresh);
        connect(w, &KDecoration3::DecoratedWindow::widthChanged, this, &Decoration::refresh);
        connect(w, &KDecoration3::DecoratedWindow::paletteChanged, this, [this] {
            update();
        });
        connect(w, &KDecoration3::DecoratedWindow::captionChanged, this, [this] {
            update();
        });
        connect(settings().get(), &KDecoration3::DecorationSettings::reconfigured, this, [this] {
            m_config = Config::load();
            refresh();
        });
        refresh();
        return true;
    }

    void paint(QPainter *painter, const QRectF &repaintArea) override
    {
        if (tiled()) {
            return; // всё рисует KWin: обводку и скругление
        }
        const auto *w = window();
        const QPalette pal = w->palette();
        const auto group = w->isActive() ? QPalette::Active : QPalette::Inactive;
        const QRectF bar(0, 0, size().width(), borderTop());

        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);
        // KWin скругляет содержимое окна, а заливку заголовка обрезаем по скруглению сами
        if (!w->isMaximized() && m_config.radius > 0) {
            QPainterPath clip;
            clip.addRoundedRect(QRectF(QPointF(0, 0), size()), m_config.radius, m_config.radius);
            painter->setClipPath(clip);
        }
        QColor bg = pal.color(group, QPalette::Window);
        painter->fillRect(bar, w->isActive() ? bg : bg.darker(115));

        // Название — по центру, но не залезая на кнопки
        const qreal leftEdge = m_left->geometry().right() + 8;
        const qreal rightEdge = m_right->geometry().left() - 8;
        const qreal side = qMax(leftEdge, bar.width() - rightEdge);
        QRectF textRect(side, 0, bar.width() - 2 * side, bar.height());
        if (textRect.width() < 40) {
            textRect = QRectF(leftEdge, 0, rightEdge - leftEdge, bar.height());
        }
        QFont font = settings()->font();
        painter->setFont(font);
        QColor text = pal.color(group, QPalette::WindowText);
        if (!w->isActive()) {
            text.setAlphaF(0.6);
        }
        painter->setPen(text);
        painter->drawText(textRect, Qt::AlignCenter,
                          painter->fontMetrics().elidedText(w->caption(), Qt::ElideMiddle, int(textRect.width())));
        painter->restore();

        m_left->paint(painter, repaintArea);
        m_right->paint(painter, repaintArea);
    }

private:
    bool tiled() const
    {
        return window()->isKeepBelow();
    }

    void refresh()
    {
        const auto *w = window();
        const bool maximized = w->isMaximized();
        const QColor color = w->isActive() ? m_config.active : m_config.inactive;
        const KDecoration3::BorderRadius radius(maximized ? 0 : m_config.radius);
        const bool showButtons = !tiled();

        for (auto *b : m_left->buttons() + m_right->buttons()) {
            b->setVisible(showButtons);
        }

        if (tiled()) {
            setBorders(QMarginsF(0, 0, 0, 0));
            setResizeOnlyBorders(QMarginsF(4, 4, 4, 4));
            setTitleBar(QRectF());
            setBorderRadius(radius);
            setBorderOutline(KDecoration3::BorderOutline(m_config.width, color, radius));
        } else {
            const qreal h = m_config.titleHeight;
            setBorders(QMarginsF(0, h, 0, 0));
            setResizeOnlyBorders(QMarginsF(4, 4, 4, 4));
            setTitleBar(QRectF(0, 0, w->width(), h));
            setBorderRadius(radius);
            setBorderOutline(maximized ? KDecoration3::BorderOutline()
                                       : KDecoration3::BorderOutline(1, QColor(0, 0, 0, 110), radius));
            layoutButtons();
        }
        update();
    }

    void layoutButtons()
    {
        const qreal h = m_config.titleHeight;
        const qreal size = h - 8;
        for (auto *b : m_left->buttons() + m_right->buttons()) {
            b->setGeometry(QRectF(0, 0, size, size));
        }
        m_left->setSpacing(4);
        m_right->setSpacing(4);
        m_left->setPos(QPointF(8, 4));
        m_right->setPos(QPointF(window()->width() - m_right->geometry().width() - 8, 4));
    }

    Config m_config;
    KDecoration3::DecorationButtonGroup *m_left = nullptr;
    KDecoration3::DecorationButtonGroup *m_right = nullptr;
};

} // namespace Vitile

K_PLUGIN_FACTORY_WITH_JSON(VitileDecorationFactory, "metadata.json", registerPlugin<Vitile::Decoration>();)

#include "vitiledecoration.moc"
