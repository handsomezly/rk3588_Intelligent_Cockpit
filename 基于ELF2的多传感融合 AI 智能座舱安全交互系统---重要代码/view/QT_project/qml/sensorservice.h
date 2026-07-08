#ifndef SENSORSERVICE_H
#define SENSORSERVICE_H

#include <QObject>
#include <QThread>

class QTimer;

// 跑在 worker thread 里，专门做阻塞 ioctl。
// DHT11 驱动的 ioctl 要发 18ms 启动信号 + 等 pulse，通常阻塞 100ms+，
// 放主线程会让视频丢帧 / QML 卡顿。
class SensorWorker : public QObject
{
    Q_OBJECT
public:
    explicit SensorWorker(QObject *parent = nullptr);
    ~SensorWorker() override;

public slots:
    void start();   // QThread::started 触发，在 worker thread 里 open fd + 启 timer

signals:
    void cabinReading(double temperature, double humidity);
    void driverReading(double temperature);
    void ambientReading(double lux);

private slots:
    void pollDht11();
    void pollMlx90614();
    void pollBh1750();

private:
    int m_dhtFd = -1;
    int m_mlxFd = -1;
    int m_bhFd = -1;
    QTimer *m_dhtTimer = nullptr;
    QTimer *m_mlxTimer = nullptr;
    QTimer *m_bhTimer = nullptr;
};

class SensorService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(double cabinTemperature READ cabinTemperature NOTIFY cabinUpdated)
    Q_PROPERTY(double cabinHumidity READ cabinHumidity NOTIFY cabinUpdated)
    Q_PROPERTY(bool cabinValid READ cabinValid NOTIFY cabinUpdated)
    Q_PROPERTY(double driverTemperature READ driverTemperature NOTIFY driverUpdated)
    Q_PROPERTY(bool driverValid READ driverValid NOTIFY driverUpdated)
    Q_PROPERTY(double ambientLux READ ambientLux NOTIFY ambientUpdated)
    Q_PROPERTY(bool ambientValid READ ambientValid NOTIFY ambientUpdated)

public:
    explicit SensorService(QObject *parent = nullptr);
    ~SensorService() override;

    double cabinTemperature() const { return m_cabinTemp; }
    double cabinHumidity() const { return m_cabinHumidity; }
    bool cabinValid() const { return m_cabinValid; }
    double driverTemperature() const { return m_driverTemp; }
    bool driverValid() const { return m_driverValid; }
    double ambientLux() const { return m_ambientLux; }
    bool ambientValid() const { return m_ambientValid; }

signals:
    void cabinUpdated();
    void driverUpdated();
    void ambientUpdated();

private slots:
    void handleCabinReading(double temperature, double humidity);
    void handleDriverReading(double temperature);
    void handleAmbientReading(double lux);

private:
    QThread m_workerThread;
    SensorWorker *m_worker = nullptr;

    double m_cabinTemp = 0.0;
    double m_cabinHumidity = 0.0;
    bool m_cabinValid = false;

    double m_driverTemp = 0.0;
    bool m_driverValid = false;

    double m_ambientLux = 0.0;
    bool m_ambientValid = false;
};

#endif // SENSORSERVICE_H
