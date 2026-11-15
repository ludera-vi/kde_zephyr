# asus-helper — отдельный проект со своим репозиторием и установщиком.
# Здесь только скачивание и запуск его install.sh (он сам спросит про пакеты и режимы).
NAME="Asus Helper"
DESC="ноутбук ASUS: режимы, GPU, подсветка, лимит заряда"
PKGS=(git)
REPO_URL=${ASUS_HELPER_REPO:-https://github.com/ludera-vi/asus-helper.git}
# Своя рабочая копия вместо скачивания: ASUS_HELPER_SRC=… или папка asus-helper рядом с kde_zephyr
# (в ней бывают коммиты, которых ещё нет на GitHub — не откатывать их скачанной версией)
SIBLING=$(readlink -f "$ROOT/../asus-helper")
if [ -n "${ASUS_HELPER_SRC:-}" ]; then
    SRC=$ASUS_HELPER_SRC
elif [ -f "$SIBLING/install.sh" ] && [ -d "$SIBLING/asushelper" ]; then
    SRC=$SIBLING
else
    SRC=$DIR/src
fi

c_check() {
    if [ "$IS_ASUS" != 1 ]; then echo "не ASUS ($VENDOR) — не нужен"; return 2; fi
    if [ "$IS_LAPTOP" != 1 ]; then echo "ASUS, но не ноутбук"; return 1; fi
    if ! is_arch; then echo "его установщик рассчитан на Arch"; return 1; fi
    [ "$SRC" = "$DIR/src" ] && echo "$PRODUCT; ставится с GitHub" || echo "$PRODUCT; ставится из $SRC"
}

c_installed() {
    command -v asus-helper >/dev/null || pacman -Q asus-helper >/dev/null 2>&1
}

c_install() {
    if [ "$SRC" != "$DIR/src" ]; then
        # Рабочую копию не трогаем (pull мог бы конфликтовать с правками) — ставим как есть
        info "Беру asus-helper из рабочей копии $SRC"
        local ahead; ahead=$(git -C "$SRC" rev-list --count '@{u}..HEAD' 2>/dev/null)
        [ "${ahead:-0}" -gt 0 ] && warn "В ней $ahead коммит(ов), которых нет на GitHub — на другой машине их не будет, пока не сделаешь git push"
    elif [ -d "$SRC/.git" ]; then
        run "Обновить исходники asus-helper" git -C "$SRC" pull --ff-only || warn "Не обновились, ставлю то, что есть"
    elif [ -f "$SRC/install.sh" ]; then
        info "Беру asus-helper из $SRC"
    else
        run "Скачать asus-helper" git clone --depth 1 "$REPO_URL" "$SRC" || return 1
    fi
    if pacman -Q asus-helper >/dev/null 2>&1; then
        warn "asus-helper стоит пакетом из AUR — обновляй его через AUR-помощник (yay/paru)"
        return 0
    fi
    info "Дальше — установщик asus-helper:"
    if c_installed; then bash "$SRC/install.sh" --update; else bash "$SRC/install.sh"; fi
}

c_uninstall() {
    [ -f "$SRC/uninstall.sh" ] || run "Скачать asus-helper" git clone --depth 1 "$REPO_URL" "$SRC" || return 1
    bash "$SRC/uninstall.sh"
}
