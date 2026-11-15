cmake_minimum_required(VERSION 3.20)
project(vitile_decoration LANGUAGES CXX)

# В /opt/cuda лежат свои копии Qt/KF6 — собираемся только с системными
list(APPEND CMAKE_IGNORE_PREFIX_PATH /opt/cuda)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

find_package(Qt6 REQUIRED COMPONENTS Core Gui)
find_package(KF6 REQUIRED COMPONENTS CoreAddons Config)
find_package(KDecoration3 REQUIRED)

add_library(org.kde.vitile MODULE vitiledecoration.cpp)
target_link_libraries(org.kde.vitile PRIVATE Qt6::Core Qt6::Gui KF6::CoreAddons KF6::ConfigCore KDecoration3::KDecoration)

# Модуль кладём так, как KWin ищет рамки: <путь модулей Qt>/org.kde.kdecoration3/
set_target_properties(org.kde.vitile PROPERTIES PREFIX ""
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/plugins/org.kde.kdecoration3)
