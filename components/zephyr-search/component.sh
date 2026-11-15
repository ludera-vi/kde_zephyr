# Zephyr Search — быстрый поиск приложений, настроек, файлов (Qt6/QML + KF6, layer-shell).
# Собирается в build/ и ставится в ~/.local; запускается в фоне при входе, вызывается Alt+Space.
NAME="Zephyr Search"
DESC="поиск приложений, настроек и файлов по Alt+Space"
PKGS=(gcc make cmake extra-cmake-modules qt6-base qt6-declarative kcoreaddons kservice kio kglobalaccel
      kwindowsystem kdbusaddons layer-shell-qt kirigami fd ripgrep)
BUILD="$DIR/build"
AUTOSTART="$HOME/.config/autostart/zephyr-search.desktop"

c_check() {
    is_plasma6 || { echo "нужна KDE Plasma 6"; return 2; }
    is_wayland || { echo "окно сделано через layer-shell — нужен Wayland"; return 1; }
    return 0
}

c_installed() { [ -x "$HOME/.local/bin/zephyr-search" ]; }

c_install() {
    run "Настроить сборку" cmake -S "$DIR" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$HOME/.local" || return 1
    run "Собрать" cmake --build "$BUILD" -j"$(nproc)" || return 1
    run "Поставить в ~/.local" cmake --install "$BUILD" || return 1
    mkdir -p "$(dirname "$AUTOSTART")"
    sed "s|^Exec=zephyr-search$|Exec=$HOME/.local/bin/zephyr-search --daemon|" "$DIR/zephyr-search.desktop" > "$AUTOSTART"
    ok "Автозапуск при входе в систему"
    # Перезапустить фоновый процесс, чтобы работала новая версия
    pkill -x zephyr-search 2>/dev/null && sleep 0.5
    (setsid "$HOME/.local/bin/zephyr-search" --daemon >/dev/null 2>&1 &)
    ok "Запущен — открывается по Alt+Space"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "~/.local/bin нет в PATH — из терминала команда не найдётся (Alt+Space работает)";; esac
}

c_uninstall() {
    pkill -x zephyr-search 2>/dev/null
    if [ -f "$BUILD/install_manifest.txt" ]; then
        xargs -d '\n' rm -f < "$BUILD/install_manifest.txt"
    else
        rm -f "$HOME/.local/bin/zephyr-search" "$HOME/.local/share/applications/zephyr-search.desktop"
    fi
    rm -f "$AUTOSTART"
    ok "Zephyr Search удалён ${D}(Alt+Space вернуть KRunner: Параметры системы → Комбинации клавиш)${R}"
}
