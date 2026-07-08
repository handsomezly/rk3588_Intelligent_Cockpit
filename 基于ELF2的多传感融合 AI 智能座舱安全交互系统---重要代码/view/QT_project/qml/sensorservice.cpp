#include "sensorservice.h"

#include <QDebug>
#include <QTimer>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace {

// 与 driver/ 下 demo 头宏定义一致
constexpr unsigned long kDht11IoctlRead   = _IOR(0x88, 1, char[4]);
constexpr unsigned long kMlxReadAmbient   = _IOR('M', 0, int);
constexpr unsigned long kMlxReadObject    = _IOR('M', 1, int);

constexpr int kDhtIntervalMs = 2000;  // DHT11 datasheet: 采样间隔 ≥ 2s
constexpr int kMlxIntervalMs = 1000;
constexpr int kBhIntervalMs  = 1000;

}

// =================== SensorWorker (worker thread) ===================

SensorWorker::SensorWorker(QObject *parent)
    : QObject(parent)
{
}

SensorWorker::~SensorWorker()
{
    if (m_dhtFd >= 0) ::close(m_dhtFd);
    if (m_mlxFd >= 0) ::close(m_mlxFd);
    if (m_bhFd >= 0)  ::close(m_bhFd);
}

void SensorWorker::start()
{
    // 这个 slot 由 QThread::started 通过 QueuedConnection 投递过来，
    // 此时 this 已 moveToThread 到 worker thread，下面所有操作（open / timer / ioctl）
    // 都在 worker thread 上跑，主线程不会被任何阻塞 ioctl 拖到。
    m_dhtFd = ::open("/dev/dht11", O_RDONLY);
    if (m_dhtFd < 0)
        qWarning() << "SensorWorker: open /dev/dht11 failed:" << strerror(errno);

    m_mlxFd = ::open("/dev/mlx90614", O_RDWR);
    if (m_mlxFd < 0)
        qWarning() << "SensorWorker: open /dev/mlx90614 failed:" << strerror(errno);

    m_bhFd = ::open("/dev/bh1750", O_RDWR);
    if (m_bhFd < 0)
        qWarning() << "SensorWorker: open /dev/bh1750 failed:" << strerror(errno);

    m_dhtTimer = new QTimer(this);
    m_dhtTimer->setInterval(kDhtIntervalMs);
    connect(m_dhtTimer, &QTimer::timeout, this, &SensorWorker::pollDht11);
    m_dhtTimer->start();

    m_mlxTimer = new QTimer(this);
    m_mlxTimer->setInterval(kMlxIntervalMs);
    connect(m_mlxTimer, &QTimer::timeout, this, &SensorWorker::pollMlx90614);
    m_mlxTimer->start();

    m_bhTimer = new QTimer(this);
    m_bhTimer->setInterval(kBhIntervalMs);
    connect(m_bhTimer, &QTimer::timeout, this, &SensorWorker::pollBh1750);
    m_bhTimer->start();

    pollDht11();
    pollMlx90614();
    pollBh1750();
}

void SensorWorker::pollDht11()
{
    if (m_dhtFd < 0)
        return;
    unsigned char data[4] = {0};
    if (::ioctl(m_dhtFd, kDht11IoctlRead, data) < 0)
        return;
    const double h = data[0] + data[1] / 10.0;
    const double t = data[2] + data[3] / 10.0;
    if (h < 0.0 || h > 100.0 || t < -40.0 || t > 80.0)
        return;
    emit cabinReading(t, h);
}

void SensorWorker::pollMlx90614()
{
    if (m_mlxFd < 0)
        return;
    int raw = 0;
    if (::ioctl(m_mlxFd, kMlxReadObject, &raw) < 0)
        return;
    const double t = raw / 10000.0;
    if (t < -40.0 || t > 125.0)
        return;
    emit driverReading(t);
}

void SensorWorker::pollBh1750()
{
    if (m_bhFd < 0)
        return;
    unsigned short raw = 0;
    const ssize_t n = ::read(m_bhFd, &raw, sizeof(raw));
    if (n != static_cast<ssize_t>(sizeof(raw)))
        return;
    emit ambientReading(raw / 1.2);
}

// =================== SensorService (main thread) ===================

SensorService::SensorService(QObject *parent)
    : QObject(parent)
    , m_worker(new SensorWorker)
{
    m_worker->moveToThread(&m_workerThread);
    // Cross-thread signals 默认走 QueuedConnection，主线程接收 reading 信号后更新 properties 并 emit *Updated
    connect(m_worker, &SensorWorker::cabinReading,   this, &SensorService::handleCabinReading);
    connect(m_worker, &SensorWorker::driverReading,  this, &SensorService::handleDriverReading);
    connect(m_worker, &SensorWorker::ambientReading, this, &SensorService::handleAmbientReading);
    connect(&m_workerThread, &QThread::started,  m_worker, &SensorWorker::start);
    connect(&m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);
    m_workerThread.start();
}

SensorService::~SensorService()
{
    m_workerThread.quit();
    m_workerThread.wait();
    // m_worker 在 thread finished 时 deleteLater，析构时已被 worker 自己回收 fd
}

void SensorService::handleCabinReading(double temperature, double humidity)
{
    m_cabinTemp = temperature;
    m_cabinHumidity = humidity;
    m_cabinValid = true;
    emit cabinUpdated();
}

void SensorService::handleDriverReading(double temperature)
{
    m_driverTemp = temperature;
    m_driverValid = true;
    emit driverUpdated();
}

void SensorService::handleAmbientReading(double lux)
{
    m_ambientLux = lux;
    m_ambientValid = true;
    emit ambientUpdated();
}
