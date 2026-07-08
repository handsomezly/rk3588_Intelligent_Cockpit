#ifndef IMUSERVICE_H
#define IMUSERVICE_H

#include "imueventmodel.h"
#include "imuio.h"

#include <QObject>
#include <QElapsedTimer>
#include <QString>

class ImuReaderThread;
class QAudioOutput;
class QBuffer;
class QTimer;

class ImuService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(bool calibrated READ calibrated NOTIFY snapshotChanged)
    Q_PROPERTY(QString calibrationState READ calibrationState NOTIFY snapshotChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(double roll READ roll NOTIFY snapshotChanged)
    Q_PROPERTY(double pitch READ pitch NOTIFY snapshotChanged)
    Q_PROPERTY(double yawCue READ yawCue NOTIFY snapshotChanged)
    Q_PROPERTY(double linearAccelX READ linearAccelX NOTIFY snapshotChanged)
    Q_PROPERTY(double linearAccelY READ linearAccelY NOTIFY snapshotChanged)
    Q_PROPERTY(double linearAccelZ READ linearAccelZ NOTIFY snapshotChanged)
    Q_PROPERTY(double gyroX READ gyroX NOTIFY snapshotChanged)
    Q_PROPERTY(double gyroY READ gyroY NOTIFY snapshotChanged)
    Q_PROPERTY(double gyroZ READ gyroZ NOTIFY snapshotChanged)
    Q_PROPERTY(QString motionState READ motionState NOTIFY snapshotChanged)
    Q_PROPERTY(int drivingScore READ drivingScore NOTIFY snapshotChanged)
    Q_PROPERTY(int smoothnessScore READ smoothnessScore NOTIFY snapshotChanged)
    Q_PROPERTY(double visionConfidence READ visionConfidence NOTIFY snapshotChanged)
    Q_PROPERTY(double dropRate READ dropRate NOTIFY snapshotChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY recordingChanged)
    Q_PROPERTY(QString recordingPath READ recordingPath NOTIFY recordingChanged)
    Q_PROPERTY(ImuEventModel *events READ events CONSTANT)

public:
    explicit ImuService(QObject *parent = nullptr);
    ~ImuService() override;

    bool available() const { return m_available; }
    bool calibrated() const { return m_snapshot.calibrated; }
    QString calibrationState() const;
    QString statusText() const { return m_statusText; }
    double roll() const { return m_snapshot.rollDeg; }
    double pitch() const { return m_snapshot.pitchDeg; }
    double yawCue() const { return m_snapshot.yawCueDeg; }
    double linearAccelX() const { return m_snapshot.linearAccelG.x(); }
    double linearAccelY() const { return m_snapshot.linearAccelG.y(); }
    double linearAccelZ() const { return m_snapshot.linearAccelG.z(); }
    double gyroX() const { return m_snapshot.gyroDps.x(); }
    double gyroY() const { return m_snapshot.gyroDps.y(); }
    double gyroZ() const { return m_snapshot.gyroDps.z(); }
    QString motionState() const { return m_snapshot.motionState; }
    int drivingScore() const { return m_snapshot.drivingScore; }
    int smoothnessScore() const { return m_snapshot.smoothnessScore; }
    double visionConfidence() const { return m_snapshot.visionConfidence; }
    double dropRate() const { return m_dropRate; }
    bool recording() const { return m_recording; }
    QString recordingPath() const { return m_recordingPath; }
    ImuEventModel *events() { return &m_events; }

    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void recalibrate();
    Q_INVOKABLE void resetTrip();
    Q_INVOKABLE void setRecording(bool enabled);

signals:
    void availableChanged();
    void statusChanged();
    void snapshotChanged();
    void recordingChanged();
    void criticalEvent(const QString &title, const QString &detail);
    void guardianCriticalEvent(const QString &type, int severity,
                               const QString &title, const QString &detail);

private:
    friend class ImuReaderThread;
    void postAvailable(bool available);
    void postStatus(const QString &text);
    void postSnapshot(const ImuSnapshot &snapshot, double dropRate);
    void postEvents(const QList<ImuEvent> &events);
    void postRecording(bool recording, const QString &path, const QString &errorText);
    static QString findConfigPath();
    static QString createRecordingPath();
    void playCriticalTone();
    void sendMotionContext();

    ImuReaderThread *m_thread = nullptr;
    bool m_available = false;
    QString m_statusText = QStringLiteral("等待 IMU 服务启动");
    ImuSnapshot m_snapshot;
    double m_dropRate = 0.0;
    bool m_recording = false;
    QString m_recordingPath;
    ImuEventModel m_events;
    ImuConfig m_config;
    ImuAxisMap m_axisMap;
    QString m_configError;
    QAudioOutput *m_alertAudio = nullptr;
    QBuffer *m_alertBuffer = nullptr;
    QTimer *m_motionTimer = nullptr;
    QElapsedTimer m_monotonicClock;
    int m_motionSocketFd = -1;
};

#endif // IMUSERVICE_H
