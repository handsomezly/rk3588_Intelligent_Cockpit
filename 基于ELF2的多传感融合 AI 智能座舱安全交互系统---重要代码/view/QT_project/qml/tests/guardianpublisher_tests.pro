QT += core testlib
CONFIG += console c++11 testcase
CONFIG -= app_bundle

TEMPLATE = app
TARGET = guardianpublisher_tests
INCLUDEPATH += ..

SOURCES += \
    ../guardianeventpublisher.cpp \
    guardianpublisher_tests.cpp

HEADERS += ../guardianeventpublisher.h
