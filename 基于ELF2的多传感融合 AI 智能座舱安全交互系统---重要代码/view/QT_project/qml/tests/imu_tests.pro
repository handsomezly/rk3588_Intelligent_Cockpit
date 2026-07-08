QT += core gui network multimedia testlib
CONFIG += console c++11 testcase
CONFIG -= app_bundle

TEMPLATE = app
TARGET = imu_tests

INCLUDEPATH += ..

SOURCES += \
    ../alerttone.cpp \
    imu_tests.cpp \
    ../imudevice.cpp \
    ../imueventmodel.cpp \
    ../imuio.cpp \
    ../imuservice.cpp \
    ../imuprocessor.cpp \
    ../motioncontext.cpp

HEADERS += \
    ../alerttone.h \
    ../imutypes.h \
    ../imu_uapi.h \
    ../imudevice.h \
    ../imueventmodel.h \
    ../imuio.h \
    ../imuservice.h \
    ../imuprocessor.h \
    ../motioncontext.h
