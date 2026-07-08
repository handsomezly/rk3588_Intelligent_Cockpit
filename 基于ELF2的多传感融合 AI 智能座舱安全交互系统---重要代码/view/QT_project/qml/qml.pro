QT += quick network multimedia 3dcore 3drender 3dinput 3dlogic 3dextras 3dquick 3dquickextras
CONFIG += c++11

# The following define makes your compiler emit warnings if you use
# any feature of Qt which as been marked deprecated (the exact warnings
# depend on your compiler). Please consult the documentation of the
# deprecated API in order to know how to port your code away from it.
DEFINES += QT_DEPRECATED_WARNINGS

# You can also make your code fail to compile if you use deprecated APIs.
# In order to do so, uncomment the following line.
# You can also select to disable deprecated APIs only up to a certain version of Qt.
#DEFINES += QT_DISABLE_DEPRECATED_BEFORE=0x060000    # disables all the APIs deprecated before Qt 6.0.0

SOURCES += \
        alerttone.cpp \
        aiassistant.cpp \
        brightnesscontroller.cpp \
        cameraview.cpp \
        fatigueclient.cpp \
        guardianeventpublisher.cpp \
        imudevice.cpp \
        imueventmodel.cpp \
        imuio.cpp \
        imuprocessor.cpp \
        imuservice.cpp \
        main.cpp \
        motioncontext.cpp \
        musiclibrary.cpp \
        sensorservice.cpp \
        ttsservice.cpp \
        videolibrary.cpp \
        voicecontroller.cpp \
        weatherservice.cpp \
        windowcontroller.cpp

HEADERS += \
        alerttone.h \
        aiassistant.h \
        brightnesscontroller.h \
        cameraview.h \
        fatigueclient.h \
        guardianeventpublisher.h \
        imudevice.h \
        imueventmodel.h \
        imuio.h \
        imuprocessor.h \
        imuservice.h \
        imutypes.h \
        imu_uapi.h \
        musiclibrary.h \
        motioncontext.h \
        sensorservice.h \
        ttsservice.h \
        videolibrary.h \
        voicecontroller.h \
        weatherservice.h \
        windowcontroller.h

# sherpa-onnx 是 aarch64 二进制，host x86 上自动跳过 (stub)
# 在 chroot 内或板子上编译（uname -m = aarch64）时自动启用
HOST_ARCH = $$system(uname -m)
equals(HOST_ARCH, aarch64) | equals(HOST_ARCH, arm64) {

    # sherpa-onnx ASR：放好 3rdparty/sherpa-onnx/{include,lib} 后自动启用
    exists($$PWD/3rdparty/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h) {
        DEFINES += HAS_SHERPA_ONNX
        INCLUDEPATH += $$PWD/3rdparty/sherpa-onnx/include
        LIBS += -L$$PWD/3rdparty/sherpa-onnx/lib -lsherpa-onnx-c-api -lonnxruntime
        QMAKE_RPATHDIR += $$PWD/3rdparty/sherpa-onnx/lib /opt/qml/bin
    }

}

RESOURCES += qml.qrc

# Additional import path used to resolve QML modules in Qt Creator's code model
QML_IMPORT_PATH =

# Additional import path used to resolve QML modules just for Qt Quick Designer
QML_DESIGNER_IMPORT_PATH =

# Default rules for deployment.
qnx: target.path = /tmp/$${TARGET}/bin
else: unix:!android: target.path = /opt/$${TARGET}/bin
!isEmpty(target.path): INSTALLS += target

# Asset bundle — 3D car model + local videos, installed beside the binary.
# Recursive glob (second arg = true) so assets/videos/*.mp4 etc. get picked up.
assets.files = $$files($$PWD/assets/*, true)
assets.path = $${target.path}/assets
!isEmpty(target.path): INSTALLS += assets

# Family guardian WebSocket gateway, deployed beside the cockpit binary.
guardianGateway.files = \
    $$PWD/../../../guardian_gateway/__init__.py \
    $$PWD/../../../guardian_gateway/protocol.py \
    $$PWD/../../../guardian_gateway/requirements.txt \
    $$PWD/../../../guardian_gateway/server.py \
    $$PWD/../../../guardian_gateway/state.py
guardianGateway.path = $${target.path}/guardian_gateway
!isEmpty(target.path): INSTALLS += guardianGateway
