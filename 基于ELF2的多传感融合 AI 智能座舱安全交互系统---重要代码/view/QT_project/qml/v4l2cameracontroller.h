#ifndef V4L2CAMERACONTROLLER_H
#define V4L2CAMERACONTROLLER_H

#include <QElapsedTimer>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QString>
#include <QThread>

#include <atomic>

class CaptureThread;

class V4L2CameraController : public QObject, public QQuickImageProvider
{
    Q_OBJECT
    Q_PROPERTY(QString device READ device WRITE setDevice NOTIFY deviceChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(int frameSerial READ frameSerial NOTIFY frameReady)
    Q_PROPERTY(int fatigueScore READ fatigueScore NOTIFY metricsChanged)
    Q_PROPERTY(int eyeClosure READ eyeClosure NOTIFY metricsChanged)
    Q_PROPERTY(int attention READ attention NOTIFY metricsChanged)
    Q_PROPERTY(int yawnCount READ yawnCount NOTIFY metricsChanged)
    Q_PROPERTY(double fps READ fps NOTIFY fpsChanged)
    Q_PROPERTY(QString warningText READ warningText NOTIFY metricsChanged)

public:
    explicit V4L2CameraController(QObject *parent = nullptr);
    ~V4L2CameraController() override;

    QString device() const;
    void setDevice(const QString &device);

    bool running() const;
    QString status() const;
    int frameSerial() const;
    int fatigueScore() const;
    int eyeClosure() const;
    int attention() const;
    int yawnCount() const;
    double fps() const;
    QString warningText() const;

    Q_INVOKABLE void start(const QString &device = QString());
    Q_INVOKABLE void stop();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

signals:
    void deviceChanged();
    void runningChanged();
    void statusChanged();
    void frameReady();
    void metricsChanged();
    void fpsChanged();

private:
    friend class CaptureThread;

    void publishFrame(const QImage &image, int averageLuma);
    void postStatus(const QString &status);
    void postFps(double fps);
    void markStopped(CaptureThread *thread);
    void setRunning(bool running);

    mutable QMutex m_stateMutex;
    mutable QMutex m_frameMutex;
    QImage m_latestFrame;
    QString m_device;
    QString m_status;
    QString m_warningText;
    CaptureThread *m_thread;
    std::atomic<int> m_workerFrameSerial;
    bool m_running;
    int m_frameSerial;
    int m_fatigueScore;
    int m_eyeClosure;
    int m_attention;
    int m_yawnCount;
    double m_fps;
};

#endif // V4L2CAMERACONTROLLER_H
