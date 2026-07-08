#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickView>
#include <QScreen>
#include <QSurfaceFormat>
#include <QUrl>
#include <QtQml>

#include "aiassistant.h"
#include "brightnesscontroller.h"
#include "cameraview.h"
#include "fatigueclient.h"
#include "guardianeventpublisher.h"
#include "imuservice.h"
#include "musiclibrary.h"
#include "sensorservice.h"
#include "ttsservice.h"
#include "videolibrary.h"
#include "voicecontroller.h"
#include "weatherservice.h"
#include "windowcontroller.h"

static QUrl resolveCarModelUrl()
{
    const QStringList candidates = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/assets/car.gltf"),
        QCoreApplication::applicationDirPath() + QStringLiteral("/../assets/car.gltf"),
        QFileInfo(QStringLiteral(__FILE__)).absolutePath() + QStringLiteral("/assets/car.gltf"),
    };
    for (const QString &path : candidates) {
        if (QFileInfo::exists(path))
            return QUrl::fromLocalFile(QFileInfo(path).absoluteFilePath());
    }
    return QUrl();
}

static QString resolveCustomIconRoot()
{
    const QStringList candidates = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/assets/icons"),
        QCoreApplication::applicationDirPath() + QStringLiteral("/../assets/icons"),
        QFileInfo(QStringLiteral(__FILE__)).absolutePath() + QStringLiteral("/assets/icons"),
    };
    for (const QString &path : candidates) {
        if (QDir(path).exists()) {
            return QUrl::fromLocalFile(QDir(path).absolutePath()
                                       + QLatin1Char('/')).toString();
        }
    }

    const QString fallback = QCoreApplication::applicationDirPath()
                           + QStringLiteral("/assets/icons/");
    return QUrl::fromLocalFile(fallback).toString();
}

int main(int argc, char *argv[])
{
    QCoreApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
    // Mali Valhall blob 只提供 OpenGL ES，host 上 Mesa 同时提供 desktop GL 也兼容。
    // 之前 AA_UseDesktopOpenGL 强制桌面 GL，板子上 Scene3D 因此静默失败（QML/QSG
    // 通用渲染 OK，但 Qt 3D 用到的扩展函数指针为空），3D 车不显示。
    QCoreApplication::setAttribute(Qt::AA_UseOpenGLES);

    QCoreApplication::setOrganizationName(QStringLiteral("ELF2"));
    QCoreApplication::setApplicationName(QStringLiteral("Cockpit"));

    QSurfaceFormat format;
    format.setRenderableType(QSurfaceFormat::OpenGLES);
    format.setDepthBufferSize(24);
    format.setStencilBufferSize(8);
    // Mali blob 对 MSAA 支持不稳，关掉。需要时改回 4 单独测试。
    format.setSamples(0);
    QSurfaceFormat::setDefaultFormat(format);

    QGuiApplication app(argc, argv);

    // 视频渲染项：QSGSimpleTextureNode 直贴，取代旧的 ImageProvider+Image{source}
    // 直播反模式（板子上每帧重建 URL + 异步重载导致闪烁）。
    qmlRegisterType<CameraView>("Cockpit", 1, 0, "CameraView");

    QQuickView view;
    // 疲劳检测由 v2 独立推理服务完成；Qt 只通过 shm(画面)+socket(指标) 显示。
    FatigueClient *fatigueClient = new FatigueClient;
    WeatherService *weatherService = new WeatherService;
    VideoLibrary *videoLibrary = new VideoLibrary;
    MusicLibrary *musicLibrary = new MusicLibrary;
    AiAssistant *aiAssistant = new AiAssistant;
    SensorService *sensorService = new SensorService;
    ImuService *imuService = new ImuService;
    new GuardianEventPublisher(fatigueClient, imuService, &app);
    VoiceController *voiceController = new VoiceController;
    voiceController->init(QCoreApplication::applicationDirPath() + QStringLiteral("/assets/models/sherpa-paraformer-zh"));
    TtsService *ttsService = new TtsService;
    aiAssistant->setTtsService(ttsService);
    BrightnessController *brightnessController = new BrightnessController;
    brightnessController->setSensorService(sensorService);
    WindowController *windowController = new WindowController(&view);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("fatigueService"), fatigueClient);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("weatherService"), weatherService);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("videoLibrary"), videoLibrary);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("musicLibrary"), musicLibrary);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("aiAssistant"), aiAssistant);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("sensorService"), sensorService);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("imuService"), imuService);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("voiceController"), voiceController);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("ttsService"), ttsService);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("brightnessController"), brightnessController);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("windowController"), windowController);
    view.engine()->rootContext()->setContextProperty(QStringLiteral("carModelUrl"), resolveCarModelUrl());
    view.engine()->rootContext()->setContextProperty(QStringLiteral("customUiIconRoot"), resolveCustomIconRoot());
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    const QSize screenSize = QGuiApplication::primaryScreen()->size();
    view.resize(screenSize.width() > 0 ? screenSize.width() : 1280,
                screenSize.height() > 0 ? screenSize.height() : 800);
    view.setTitle(QStringLiteral("ELF2 RK3588 疲劳驾驶智能座舱"));
    view.setColor(QColor("#070809"));
    view.setSource(QUrl(QStringLiteral("qrc:/main.qml")));
    if (view.status() == QQuickView::Error)
        return -1;

    imuService->start();
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     imuService, &ImuService::stop);

    const QByteArray fullscreenEnv = qgetenv("COCKPIT_FULLSCREEN");
    const bool wantFullscreen =
        fullscreenEnv == "1" || fullscreenEnv.compare("true", Qt::CaseInsensitive) == 0;
    if (wantFullscreen)
        view.showFullScreen();
    else
        view.show();

    return app.exec();
}
