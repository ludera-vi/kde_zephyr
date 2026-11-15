# vitile — плитка окон для KWin в духе Hyprland (скрипт + эффект + рамка на C++).
# Устанавливается и удаляется самим vitile.py; он же помнит, что поменял в KDE (.backup.json).
NAME="vitile"
DESC="плитка окон для KWin в духе Hyprland"
PKGS=(python gcc make cmake extra-cmake-modules kwin kdecoration qt6-base)
UNIT_FILE="$HOME/.config/systemd/user/vitile-deco@.service"

c_check() {
    is_plasma6 || { echo "нужна KDE Plasma 6"; return 2; }
    is_wayland || { echo "проверялось только на Wayland"; return 1; }
    other_location && { echo "сейчас запускается из $(other_location_path) — переустановка перенесёт сюда"; return 0; }
    return 0
}

other_location_path() { grep -oP 'python3 \K\S+(?=/vitile\.py)' "$UNIT_FILE" 2>/dev/null | head -1; }
other_location() {
    local p; p=$(other_location_path)
    [ -n "$p" ] && [ "$(readlink -f "$p")" != "$(readlink -f "$DIR")" ]
}

c_installed() { [ -d "$HOME/.local/share/kwin/scripts/vitile" ]; }

c_install() {
    # Ставили из другой папки — забрать оттуда копию прежних настроек KDE, иначе uninstall не вернёт их
    if other_location; then
        local old; old=$(other_location_path)
        if [ -f "$old/.backup.json" ] && [ ! -f "$DIR/.backup.json" ]; then
            cp "$old/.backup.json" "$DIR/.backup.json" && info "Взял .backup.json из $old"
            [ -f "$old/.theme" ] && cp "$old/.theme" "$DIR/.theme"
        fi
    fi
    python3 "$DIR/vitile.py" install
}

c_uninstall() { python3 "$DIR/vitile.py" uninstall; }
