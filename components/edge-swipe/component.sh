# edge-swipe — свайп у левого края тачпада меняет яркость, у правого — громкость.
# Нужен доступ к тачпаду (udev-правило с uaccess) и пользовательская служба systemd.
NAME="Edge Swipe"
DESC="край тачпада: слева яркость, справа громкость"
PKGS=(python python-evdev wireplumber)
RULE=/etc/udev/rules.d/70-touchpad-edge.rules
SERVICE="$HOME/.config/systemd/user/edge-swipe.service"

c_check() {
    [ -n "$TOUCHPAD" ] || { echo "тачпад не найден"; return 2; }
    is_plasma6 || { echo "яркость меняется через KDE (PowerDevil) — без Plasma работать будет только громкость"; return 1; }
    local cur; cur=$(grep -oP 'python3 \K\S+(?=/edge_swipe\.py)' "$SERVICE" 2>/dev/null)
    if [ -n "$cur" ] && [ "$(readlink -f "$cur")" != "$(readlink -f "$DIR")" ]; then
        echo "тачпад: $TOUCHPAD; сейчас запускается из $cur — переустановка перенесёт сюда"
    else
        echo "тачпад: $TOUCHPAD"
    fi
}

c_installed() { [ -f "$SERVICE" ]; }

c_install() {
    # Правило именно 70-…: тег uaccess обрабатывается в 73-seat-late.rules, более позднее не сработает
    local want="SUBSYSTEM==\"input\", KERNEL==\"event*\", ATTRS{name}==\"$TOUCHPAD\", TAG+=\"uaccess\""
    if [ "$(cat "$RULE" 2>/dev/null)" != "$want" ]; then
        info "Нужен доступ к тачпаду «$TOUCHPAD» — правило udev ($RULE), спросит sudo"
        echo "$want" | sudo tee "$RULE" >/dev/null || return 1
        sudo udevadm control --reload
        sudo udevadm trigger --subsystem-match=input --action=change
        sleep 1
        ok "Правило udev"
    else
        ok "Правило udev уже есть"
    fi
    mkdir -p "$(dirname "$SERVICE")"
    cat > "$SERVICE" <<UNIT
[Unit]
Description=Touchpad edge swipe: brightness (left) / volume (right)
After=graphical-session.target pipewire.service
PartOf=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 $DIR/edge_swipe.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable edge-swipe.service >/dev/null 2>&1
    systemctl --user restart edge-swipe.service
    sleep 1
    if systemctl --user is-active --quiet edge-swipe.service; then
        ok "Служба edge-swipe запущена"
    else
        fail "Служба не запустилась: journalctl --user -u edge-swipe"
        return 1
    fi
}

c_uninstall() {
    systemctl --user disable --now edge-swipe.service 2>/dev/null
    rm -f "$SERVICE"
    systemctl --user daemon-reload
    ok "Служба удалена"
    if [ -f "$RULE" ] && ask "Убрать и правило udev ($RULE, нужен sudo)?" Y; then
        sudo rm -f "$RULE" && sudo udevadm control --reload && ok "Правило udev удалено"
    fi
}
