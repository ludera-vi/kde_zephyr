# Виджет панели: точка со счётчиком окон, при наведении раскрывается в ряд иконок.
NAME="Minimized Dot"
DESC="виджет: точка со счётчиком окон"
PKGS=(kpackage)
ID=org.vi.minimizeddot

c_check()     { is_plasma6 || { echo "нужна KDE Plasma 6"; return 2; }; }
c_installed() { plasmoid_installed $ID; }
c_install()   { plasmoid_install $ID "$DIR/package" "Minimized Dot"; }
c_uninstall() { plasmoid_uninstall $ID; }
