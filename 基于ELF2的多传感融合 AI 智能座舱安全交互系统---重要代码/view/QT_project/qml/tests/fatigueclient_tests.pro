QT += core gui testlib
CONFIG += console c++11 testcase
CONFIG -= app_bundle

TEMPLATE = app
TARGET = fatigueclient_tests

INCLUDEPATH += ..

SOURCES += \
    ../fatigueclient.cpp \
    fatigueclient_tests.cpp

HEADERS += \
    ../fatigueclient.h
