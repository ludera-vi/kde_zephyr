# Виджет панели: температура CPU/GPU, расход батареи в ваттах, время от батареи, топ процессов.
NAME="Battery Watts"
DESC="виджет: температуры и расход батареи в ваттах"
PKGS=(kpackage upower)
ID=org.vi.batterywatts

c_check() {
    is_plasma6 || { echo "нужна KDE Plasma 6"; return 2; }
    [ "$HAS_BATTERY" = 1 ] || { echo "батареи нет — покажет только температуры"; return 1; }
    [ "$HAS_NVIDIA" = 1 ] || echo "NVIDIA нет — температура GPU показываться не будет"
    return 0
}
c_installed() { plasmoid_installed $ID; }
c_install()   { plasmoid_install $ID "$DIR/package" "Battery Watts"; }
c_uninstall() { plasmoid_uninstall $ID; }
