# Виджет панели: минималистичный переключатель рабочих столов — цифры и кнопка «+».
NAME="Desktop Units"
DESC="виджет: рабочие столы цифрами и кнопка +"
PKGS=(kpackage)
ID=org.vi.desktopunits

c_check()     { is_plasma6 || { echo "нужна KDE Plasma 6"; return 2; }; }
c_installed() { plasmoid_installed $ID; }
c_install()   { plasmoid_install $ID "$DIR/package" "Рабочие столы (цифры)"; }
c_uninstall() { plasmoid_uninstall $ID; }
