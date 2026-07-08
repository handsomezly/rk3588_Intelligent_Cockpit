#ifndef FATIGUECLIENT_H
#define FATIGUECLIENT_H

#include <QImage>
#include <QJsonObject>
#include <QMutex>
#include <QObject>
#include <QRectF>
#include <QString>

#include <atomic>

class FatigueClientThread;
class QTimer;
class FatigueClientTests;

// Display-side client for the v2 fatigue inference service.
//
// The v2 service (code/fatigue_service.py) owns the camera + NPU. It publishes
// raw RGB frames into a triple-buffered shared-memory file (/dev/shm/...) and
// one metrics JSON line per frame over an AF_UNIX socket. FatigueClient runs a
// worker thread that blocks on the socket (one line == one frame == a natural
// tick), reads the matching frame from shm, and forwards both to the GUI thread.
//
// Qt does NOT compute any fatigue value here — every metric below is taken
// verbatim from the service. The old V4L2CameraController (which faked the
// metrics from frame brightness) is retired.
class FatigueClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString status READ status NOTIFY metricsChanged)
    Q_PROPERTY(bool fatigueAlarm READ fatigueAlarm NOTIFY metricsChanged)
    Q_PROPERTY(QString fatigueReason READ fatigueReason NOTIFY metricsChanged)
    Q_PROPERTY(double perclos READ perclos NOTIFY metricsChanged)
    Q_PROPERTY(int validCount READ validCount NOTIFY metricsChanged)
    Q_PROPERTY(int windowLen READ windowLen NOTIFY metricsChanged)
    Q_PROPERTY(double fps READ fps NOTIFY metricsChanged)
    Q_PROPERTY(bool faceFound READ faceFound NOTIFY metricsChanged)
    Q_PROPERTY(QString eyeLeft READ eyeLeft NOTIFY metricsChanged)
    Q_PROPERTY(QString eyeRight READ eyeRight NOTIFY metricsChanged)
    Q_PROPERTY(double pOpenLeft READ pOpenLeft NOTIFY metricsChanged)
    Q_PROPERTY(double pOpenRight READ pOpenRight NOTIFY metricsChanged)
    Q_PROPERTY(double blinkRate READ blinkRate NOTIFY metricsChanged)
    Q_PROPERTY(double meanBlinkMs READ meanBlinkMs NOTIFY metricsChanged)
    Q_PROPERTY(int longBlinkCount READ longBlinkCount NOTIFY metricsChanged)
    Q_PROPERTY(int frameWidth READ frameWidth NOTIFY metricsChanged)
    Q_PROPERTY(int frameHeight READ frameHeight NOTIFY metricsChanged)
    Q_PROPERTY(QRectF faceBox READ faceBox NOTIFY metricsChanged)
    Q_PROPERTY(QRectF eyeLeftBox READ eyeLeftBox NOTIFY metricsChanged)
    Q_PROPERTY(QRectF eyeRightBox READ eyeRightBox NOTIFY metricsChanged)
    Q_PROPERTY(bool motionGated READ motionGated NOTIFY metricsChanged)
    Q_PROPERTY(QString motionGateReason READ motionGateReason NOTIFY metricsChanged)
    Q_PROPERTY(double imuVisionConfidence READ imuVisionConfidence NOTIFY metricsChanged)
    Q_PROPERTY(QString vehicleMotionState READ vehicleMotionState NOTIFY metricsChanged)
    Q_PROPERTY(bool cameraEnabled READ cameraEnabled NOTIFY cameraControlChanged)
    Q_PROPERTY(QString cameraState READ cameraState NOTIFY cameraControlChanged)
    Q_PROPERTY(bool cameraControlBusy READ cameraControlBusy NOTIFY cameraControlChanged)
    Q_PROPERTY(QString cameraError READ cameraError NOTIFY cameraControlChanged)

public:
    explicit FatigueClient(QObject *parent = nullptr);
    ~FatigueClient() override;

    bool connected() const { return m_connected; }
    QString status() const { return m_status; }
    bool fatigueAlarm() const { return m_fatigueAlarm; }
    QString fatigueReason() const { return m_fatigueReason; }
    double perclos() const { return m_perclos; }
    int validCount() const { return m_validCount; }
    int windowLen() const { return m_windowLen; }
    double fps() const { return m_fps; }
    bool faceFound() const { return m_faceFound; }
    QString eyeLeft() const { return m_eyeLeft; }
    QString eyeRight() const { return m_eyeRight; }
    double pOpenLeft() const { return m_pOpenLeft; }
    double pOpenRight() const { return m_pOpenRight; }
    double blinkRate() const { return m_blinkRate; }
    double meanBlinkMs() const { return m_meanBlinkMs; }
    int longBlinkCount() const { return m_longBlinkCount; }
    int frameWidth() const { return m_frameWidth; }
    int frameHeight() const { return m_frameHeight; }
    QRectF faceBox() const { return m_faceBox; }
    QRectF eyeLeftBox() const { return m_eyeLeftBox; }
    QRectF eyeRightBox() const { return m_eyeRightBox; }
    bool motionGated() const { return m_motionGated; }
    QString motionGateReason() const { return m_motionGateReason; }
    double imuVisionConfidence() const { return m_imuVisionConfidence; }
    QString vehicleMotionState() const { return m_vehicleMotionState; }
    bool cameraEnabled() const { return m_cameraEnabled; }
    QString cameraState() const { return m_cameraState; }
    bool cameraControlBusy() const { return m_cameraControlBusy; }
    QString cameraError() const { return m_cameraError; }

    // start()/stop() manage the connection (call start() once at app launch).
    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    // Only the camera page needs the live frame; the home overview needs metrics
    // only. Gating the ~900KB/frame shm copy keeps the home page cheap.
    Q_INVOKABLE void setWantFrames(bool on) { m_wantFrames.store(on); }
    Q_INVOKABLE void setCameraEnabled(bool enabled);

signals:
    void connectedChanged();
    void metricsChanged();
    void cameraControlChanged();
    void frameReady(const QImage &image);

private:
    friend class FatigueClientThread;
    friend class FatigueClientTests;
    // Called by the worker thread (queued onto the GUI thread).
    void postConnected(bool connected);
    void postMetrics(const QJsonObject &metrics);
    void postFrame(const QImage &image);
    bool sendCameraCommand(bool enabled, QString *errorText);

    FatigueClientThread *m_thread = nullptr;
    std::atomic<bool> m_wantFrames { false };

    QString m_sockPath = QStringLiteral("/tmp/cockpit_fatigue.sock");
    QString m_shmPath = QStringLiteral("/dev/shm/cockpit_frame");
    QString m_controlSockPath;
    QTimer *m_cameraControlTimer = nullptr;
    int m_cameraControlTimeoutMs = 3000;

    bool m_connected = false;
    QString m_status = QStringLiteral("disconnected");
    bool m_fatigueAlarm = false;
    QString m_fatigueReason;
    double m_perclos = 0.0;
    int m_validCount = 0;
    int m_windowLen = 0;
    double m_fps = 0.0;
    bool m_faceFound = false;
    QString m_eyeLeft;
    QString m_eyeRight;
    double m_pOpenLeft = 0.0;
    double m_pOpenRight = 0.0;
    double m_blinkRate = 0.0;
    double m_meanBlinkMs = 0.0;
    int m_longBlinkCount = 0;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
    QRectF m_faceBox;
    QRectF m_eyeLeftBox;
    QRectF m_eyeRightBox;
    bool m_motionGated = false;
    QString m_motionGateReason = QStringLiteral("imu_missing");
    double m_imuVisionConfidence = 1.0;
    QString m_vehicleMotionState = QStringLiteral("unknown");
    bool m_cameraEnabled = false;
    std::atomic<bool> m_cameraEnabledForFrames { false };
    QString m_cameraState = QStringLiteral("off");
    bool m_cameraControlBusy = false;
    bool m_requestedCameraEnabled = false;
    QString m_cameraError;
};

#endif // FATIGUECLIENT_H
