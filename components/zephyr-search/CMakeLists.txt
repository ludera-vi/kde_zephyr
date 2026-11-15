cmake_minimum_required(VERSION 3.20)
project(zephyr-search VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Qml Quick)
foreach(kf CoreAddons Service KIO GlobalAccel WindowSystem DBusAddons)
    find_package(KF6${kf} REQUIRED)
endforeach()
find_package(LayerShellQt REQUIRED)

qt_standard_project_setup(REQUIRES 6.6)

qt_add_executable(zephyr-search
    src/main.cpp
    src/controller.cpp src/controller.h
    src/resultsmodel.cpp src/resultsmodel.h
    src/appindex.cpp src/appindex.h
    src/filesearch.cpp src/filesearch.h
    src/match.h
)

qt_add_qml_module(zephyr-search
    URI Zephyr
    VERSION 1.0
    QML_FILES qml/Main.qml qml/Chip.qml
)

target_link_libraries(zephyr-search PRIVATE
    Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick
    KF6::CoreAddons KF6::Service KF6::KIOGui KF6::GlobalAccel
    KF6::WindowSystem KF6::DBusAddons
    LayerShellQt::Interface
)

include(GNUInstallDirs)
install(TARGETS zephyr-search RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES zephyr-search.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
