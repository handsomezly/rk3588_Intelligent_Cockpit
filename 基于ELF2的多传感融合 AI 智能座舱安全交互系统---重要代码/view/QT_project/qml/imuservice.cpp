#include "imuservice.h"

#include "alerttone.h"
#include "imudevice.h"
#include "imuprocessor.h"
#include "motioncontext.h"

#include <QAudioDeviceInfo>
#include <QAudioFormat>
#include <QAudioOutput>
#include <QtCore/QBuffer>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QMetaObject>
#include <QMutex>
#include <QMutexLocker>
#include <QStandardPaths>
#include <QThread>
#include <QTimer>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

constexpr int kDefaultSampleRateHz = 200;
constexpr int kDefaultAccelRangeG = 8;
constexpr int kDefaultGyroRangeDps = 500;
constexpr int kDefaultDlpfCfg = 3;
constexpr quint64 kUiPublishPeriodNs = 33333333ULL;
constexpr int kLegacySamplePeriodUs = 8000;

enum class DeviceFrameMode
{
    CockpitUapiV1,
    Mpu6050Legacy
};

QString imuDevicePath()
{
    const QString envPath = QString::fromLocal8Bit(qgetenv("COCKPIT_IMU_DEVICE"));
    return envPath.isEmpty() ? QStringLiteral("/dev/mpu6050") : envPath;
}

bool isUnsupportedIoctlError(int value)
{
    return value == ENOTTY || value == EINVAL || value == ENOSYS;
}

quint64 monotonicTimestampNs()
{
    timespec ts;
    if (::clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return static_cast<quint64>(ts.tv_sec) * 1000000000ULL
             + static_cast<quint64>(ts.tv_nsec);
    }
    return static_cast<quint64>(QDateTime::currentMSecsSinceEpoch()) * 1000000ULL;
}

QString guardianImuType(ImuEventType type)
{
    switch (type) {
    case ImuEventType::SuspectedImpact: return QStringLiteral("suspected_impact");
    case ImuEventType::RolloverRisk: return QStringLiteral("rollover_risk");
    case ImuEventType::MountingAnomaly: return QStringLiteral("mounting_anomaly");
    default: return QStringLiteral("imu_critical");
    }
}

} // namespace

class ImuReaderThread : public QThread
{
public:
    ImuReaderThread(ImuService *owner,
                    const ImuConfig &config,
                    const ImuAxisMap &axisMap,
                    const QString &replayPath,
                    bool replayFast)
        : QThread(owner)
        , m_owner(owner)
        , m_processor(config)
        , m_axisMap(axisMap)
        , m_replayPath(replayPath)
        , m_replayFast(replayFast)
    {
    }

    void requestStop() { m_stop.store(true); }
    void requestRecalibrate() { m_recalibrateRequested.store(true); }
    void requestResetTrip() { m_resetTripRequested.store(true); }
    void requestRecording(bool enabled, const QString &path)
    {
        QMutexLocker locker(&m_commandMutex);
        m_recordingRequested = enabled;
        m_recordingPath = path;
        m_recordingCommandPending = true;
    }

protected:
    void run() override
    {
        if (!m_replayPath.isEmpty())
            runReplay();
        else
            runDevice();
    }

private:
    void processOne(const ImuSample &sample)
    {
        applyCommands();
        if (m_haveSequence && sample.sequence > m_lastSequence + 1)
            m_lostSamples += sample.sequence - m_lastSequence - 1;
        m_lastSequence = sample.sequence;
        m_haveSequence = true;
        ++m_seenSamples;

        m_processor.processSample(sample);
        const QList<ImuEvent> events = m_processor.takeEvents();
        if (!events.isEmpty())
            m_owner->postEvents(events);

        if (m_logWriter.isOpen()) {
            QStringList eventNames;
            for (const ImuEvent &event : events)
                eventNames.append(event.title);
            QString error;
            if (!m_logWriter.append(sample, m_processor.snapshot(),
                                    eventNames.join(QLatin1Char('|')), &error)) {
                m_logWriter.close();
                m_owner->postRecording(false, QString(), error);
            }
        }

        if (m_lastPublishNs == 0
            || sample.timestampNs - m_lastPublishNs >= kUiPublishPeriodNs
            || m_processor.snapshot().calibrationState != m_lastCalibrationState) {
            m_lastPublishNs = sample.timestampNs;
            m_lastCalibrationState = m_processor.snapshot().calibrationState;
            const double total = static_cast<double>(m_seenSamples + m_lostSamples);
            const double dropRate = total > 0.0 ? m_lostSamples / total : 0.0;
            m_owner->postSnapshot(m_processor.snapshot(), dropRate);
        }
    }

    void applyCommands()
    {
        if (m_recalibrateRequested.exchange(false)) {
            m_processor.startCalibration();
            m_owner->postStatus(QStringLiteral("请保持车辆静止，正在重新校准 IMU"));
            m_owner->postSnapshot(m_processor.snapshot(), currentDropRate());
        }
        if (m_resetTripRequested.exchange(false)) {
            m_processor.resetTrip();
            m_owner->postSnapshot(m_processor.snapshot(), currentDropRate());
            m_owner->postStatus(QStringLiteral("本次行程评分已重置"));
        }

        bool hasRecordingCommand = false;
        bool wantRecording = false;
        QString requestedPath;
        {
            QMutexLocker locker(&m_commandMutex);
            if (m_recordingCommandPending) {
                hasRecordingCommand = true;
                wantRecording = m_recordingRequested;
                requestedPath = m_recordingPath;
                m_recordingCommandPending = false;
            }
        }
        if (!hasRecordingCommand)
            return;
        if (!wantRecording) {
            m_logWriter.close();
            m_owner->postRecording(false, QString(), QString());
            return;
        }

        QString error;
        if (m_logWriter.open(requestedPath, m_activeSampleRateHz,
                             m_activeAccelRangeG, m_activeGyroRangeDps,
                             m_axisMap.description(), &error)) {
            m_owner->postRecording(true, requestedPath, QString());
        } else {
            m_owner->postRecording(false, QString(), error);
        }
    }

    double currentDropRate() const
    {
        const double total = static_cast<double>(m_seenSamples + m_lostSamples);
        return total > 0.0 ? m_lostSamples / total : 0.0;
    }

    void runReplay()
    {
        QString error;
        const QList<ImuSample> samples = readImuCsv(m_replayPath, &error);
        if (samples.isEmpty()) {
            m_owner->postStatus(error.isEmpty()
                ? QStringLiteral("IMU 回放文件为空") : error);
            m_owner->postAvailable(false);
            return;
        }
        m_owner->postAvailable(true);
        m_owner->postStatus(QStringLiteral("IMU 回放模式"));
        m_processor.startCalibration();

        quint64 previousNs = 0;
        for (const ImuSample &sample : samples) {
            if (m_stop.load())
                break;
            if (!m_replayFast && previousNs > 0 && sample.timestampNs > previousNs) {
                const quint64 waitUs = qMin<quint64>(
                    (sample.timestampNs - previousNs) / 1000ULL, 100000ULL);
                QThread::usleep(static_cast<unsigned long>(waitUs));
            }
            previousNs = sample.timestampNs;
            processOne(sample);
        }
        while (!m_stop.load()) {
            applyCommands();
            QThread::msleep(20);
        }
        m_logWriter.close();
    }

    void runDevice()
    {
        while (!m_stop.load()) {
            const QString devicePath = imuDevicePath();
            const QByteArray encodedDevicePath = devicePath.toLocal8Bit();
            const int fd = ::open(encodedDevicePath.constData(), O_RDONLY | O_CLOEXEC);
            if (fd < 0) {
                m_owner->postAvailable(false);
                m_owner->postStatus(QStringLiteral("等待 %1：%2")
                                    .arg(devicePath,
                                         QString::fromLocal8Bit(std::strerror(errno))));
                interruptibleSleep(500);
                continue;
            }

            DeviceFrameMode frameMode = DeviceFrameMode::CockpitUapiV1;
            int sampleRateHz = kDefaultSampleRateHz;
            int accelRange = kDefaultAccelRangeG;
            int gyroRange = kDefaultGyroRangeDps;
            ImuDeviceInfoV1 info = {};
            if (::ioctl(fd, COCKPIT_IMU_IOC_GET_INFO, &info) == 0) {
                if (info.abi_version != COCKPIT_IMU_ABI_VERSION
                    || info.sample_size != sizeof(ImuSampleV1)) {
                    m_owner->postStatus(QStringLiteral("MPU6050 驱动 ABI 不兼容"));
                    ::close(fd);
                    m_owner->postAvailable(false);
                    interruptibleSleep(1000);
                    continue;
                }
                sampleRateHz = static_cast<int>(info.sample_rate_hz);
                accelRange = static_cast<int>(info.accel_range_g);
                gyroRange = static_cast<int>(info.gyro_range_dps);
            } else if (isUnsupportedIoctlError(errno)) {
                frameMode = DeviceFrameMode::Mpu6050Legacy;
                // The current driver writes SMPLRT_DIV=0x07 with DLPF enabled,
                // so the effective sample rate is about 1 kHz / (1 + 7).
                sampleRateHz = 125;
                accelRange = 2;
                gyroRange = 2000;
            } else {
                m_owner->postStatus(QStringLiteral("MPU6050 驱动查询失败：%1")
                                    .arg(QString::fromLocal8Bit(std::strerror(errno))));
                ::close(fd);
                m_owner->postAvailable(false);
                interruptibleSleep(1000);
                continue;
            }

            if (frameMode == DeviceFrameMode::CockpitUapiV1) {
                ImuDeviceConfigV1 wanted = {};
                wanted.abi_version = COCKPIT_IMU_ABI_VERSION;
                wanted.sample_rate_hz = kDefaultSampleRateHz;
                wanted.accel_range_g = kDefaultAccelRangeG;
                wanted.gyro_range_dps = kDefaultGyroRangeDps;
                wanted.dlpf_cfg = kDefaultDlpfCfg;
                if (::ioctl(fd, COCKPIT_IMU_IOC_SET_CONFIG, &wanted) == 0) {
                    sampleRateHz = kDefaultSampleRateHz;
                    accelRange = kDefaultAccelRangeG;
                    gyroRange = kDefaultGyroRangeDps;
                }
            }

            m_activeSampleRateHz = sampleRateHz;
            m_activeAccelRangeG = accelRange;
            m_activeGyroRangeDps = gyroRange;
            m_processor.startCalibration();
            m_haveSequence = false;
            m_syntheticSequence = 0;
            m_seenSamples = 0;
            m_lostSamples = 0;
            m_lastPublishNs = 0;
            m_owner->postAvailable(true);
            m_owner->postStatus(frameMode == DeviceFrameMode::Mpu6050Legacy
                ? QStringLiteral("MPU6050 legacy 驱动模式：请保持车辆静止，正在校准 IMU")
                : QStringLiteral("请保持车辆静止，正在校准 IMU"));

            bool disconnected = false;
            while (!m_stop.load() && !disconnected) {
                applyCommands();
                pollfd pfd;
                pfd.fd = fd;
                pfd.events = POLLIN;
                pfd.revents = 0;
                const int ready = ::poll(&pfd, 1, 200);
                if (ready < 0) {
                    if (errno == EINTR)
                        continue;
                    disconnected = true;
                    break;
                }
                if (ready == 0)
                    continue;
                if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    disconnected = true;
                    break;
                }

                if (frameMode == DeviceFrameMode::CockpitUapiV1) {
                    ImuSampleV1 raw[16];
                    const ssize_t bytes = ::read(fd, raw, sizeof(raw));
                    if (bytes < 0 && errno == EINTR)
                        continue;
                    if (bytes <= 0 || bytes % static_cast<ssize_t>(sizeof(ImuSampleV1)) != 0) {
                        disconnected = true;
                        break;
                    }
                    const int count = static_cast<int>(bytes / sizeof(ImuSampleV1));
                    for (int i = 0; i < count; ++i) {
                        ImuSample sample;
                        QString error;
                        if (decodeImuSample(raw[i], accelRange, gyroRange,
                                            m_axisMap, &sample, &error)) {
                            processOne(sample);
                        }
                    }
                    continue;
                }

                Mpu6050LegacyFrame raw = {};
                const ssize_t bytes = ::read(fd, &raw, sizeof(raw));
                if (bytes < 0 && errno == EINTR)
                    continue;
                if (bytes != static_cast<ssize_t>(sizeof(raw))) {
                    disconnected = true;
                    break;
                }
                ImuSample sample;
                QString error;
                if (decodeLegacyMpu6050Frame(raw, monotonicTimestampNs(),
                                             m_syntheticSequence++,
                                             m_axisMap, &sample, &error)) {
                    processOne(sample);
                }
                if (!m_stop.load())
                    QThread::usleep(kLegacySamplePeriodUs);
            }
            ::close(fd);
            m_owner->postAvailable(false);
            if (!m_stop.load()) {
                m_owner->postStatus(QStringLiteral("IMU 已断开，正在重连"));
                interruptibleSleep(200);
            }
        }
        m_logWriter.close();
    }

    void interruptibleSleep(int totalMs)
    {
        for (int elapsed = 0; elapsed < totalMs && !m_stop.load(); elapsed += 50)
            QThread::msleep(50);
    }

    ImuService *m_owner;
    ImuProcessor m_processor;
    ImuAxisMap m_axisMap;
    QString m_replayPath;
    bool m_replayFast = false;
    std::atomic<bool> m_stop { false };
    std::atomic<bool> m_recalibrateRequested { false };
    std::atomic<bool> m_resetTripRequested { false };
    QMutex m_commandMutex;
    bool m_recordingCommandPending = false;
    bool m_recordingRequested = false;
    QString m_recordingPath;
    ImuCsvLogWriter m_logWriter;
    int m_activeSampleRateHz = kDefaultSampleRateHz;
    int m_activeAccelRangeG = kDefaultAccelRangeG;
    int m_activeGyroRangeDps = kDefaultGyroRangeDps;
    bool m_haveSequence = false;
    quint32 m_lastSequence = 0;
    quint32 m_syntheticSequence = 0;
    quint64 m_seenSamples = 0;
    quint64 m_lostSamples = 0;
    quint64 m_lastPublishNs = 0;
    ImuCalibrationState m_lastCalibrationState = ImuCalibrationState::Uncalibrated;
};

ImuService::ImuService(QObject *parent)
    : QObject(parent)
    , m_events(this)
{
    m_monotonicClock.start();
    m_motionTimer = new QTimer(this);
    m_motionTimer->setInterval(100);
    connect(m_motionTimer, &QTimer::timeout,
            this, &ImuService::sendMotionContext);
    const QString configPath = findConfigPath();
    if (!configPath.isEmpty()
        && !loadImuConfig(configPath, &m_config, &m_axisMap, &m_configError)) {
        m_statusText = m_configError;
    }
}

ImuService::~ImuService()
{
    stop();
    if (m_motionSocketFd >= 0)
        ::close(m_motionSocketFd);
}

QString ImuService::calibrationState() const
{
    switch (m_snapshot.calibrationState) {
    case ImuCalibrationState::Collecting: return QStringLiteral("collecting");
    case ImuCalibrationState::Ready: return QStringLiteral("ready");
    case ImuCalibrationState::Failed: return QStringLiteral("failed");
    case ImuCalibrationState::Uncalibrated: return QStringLiteral("uncalibrated");
    }
    return QStringLiteral("uncalibrated");
}

void ImuService::start()
{
    if (m_thread)
        return;
    if (!m_configError.isEmpty()) {
        emit statusChanged();
        return;
    }
    const QString replayPath = QString::fromLocal8Bit(qgetenv("COCKPIT_IMU_REPLAY"));
    const QByteArray fastValue = qgetenv("COCKPIT_IMU_REPLAY_FAST");
    const bool replayFast = fastValue == "1"
                         || fastValue.compare("true", Qt::CaseInsensitive) == 0;
    m_thread = new ImuReaderThread(this, m_config, m_axisMap, replayPath, replayFast);
    connect(m_thread, &QThread::finished, m_thread, &QObject::deleteLater);
    m_thread->start();
    m_motionTimer->start();
}

void ImuService::stop()
{
    if (!m_thread)
        return;
    m_thread->requestStop();
    m_thread->wait(1500);
    m_thread = nullptr;
    if (m_available) {
        m_available = false;
        emit availableChanged();
    }
    if (m_recording) {
        m_recording = false;
        emit recordingChanged();
    }
    sendMotionContext();
    m_motionTimer->stop();
}

void ImuService::recalibrate()
{
    if (m_thread)
        m_thread->requestRecalibrate();
}

void ImuService::resetTrip()
{
    if (m_thread)
        m_thread->requestResetTrip();
}

void ImuService::setRecording(bool enabled)
{
    if (!m_thread) {
        if (enabled) {
            m_statusText = QStringLiteral("IMU 服务未启动，无法记录");
            emit statusChanged();
        }
        return;
    }
    if (enabled == m_recording)
        return;
    m_thread->requestRecording(enabled, enabled ? createRecordingPath() : QString());
}

void ImuService::postAvailable(bool available)
{
    QMetaObject::invokeMethod(this, [this, available]() {
        if (m_available == available)
            return;
        m_available = available;
        emit availableChanged();
    }, Qt::QueuedConnection);
}

void ImuService::postStatus(const QString &text)
{
    QMetaObject::invokeMethod(this, [this, text]() {
        if (m_statusText == text)
            return;
        m_statusText = text;
        emit statusChanged();
    }, Qt::QueuedConnection);
}

void ImuService::postSnapshot(const ImuSnapshot &snapshot, double dropRate)
{
    QMetaObject::invokeMethod(this, [this, snapshot, dropRate]() {
        m_snapshot = snapshot;
        m_dropRate = dropRate;
        if (snapshot.calibrationState == ImuCalibrationState::Ready)
            m_statusText = QStringLiteral("IMU 运行正常");
        else if (snapshot.calibrationState == ImuCalibrationState::Failed)
            m_statusText = QStringLiteral("静止校准失败，请重新校准");
        emit snapshotChanged();
        emit statusChanged();
    }, Qt::QueuedConnection);
}

void ImuService::postEvents(const QList<ImuEvent> &events)
{
    QMetaObject::invokeMethod(this, [this, events]() {
        bool critical = false;
        for (const ImuEvent &event : events) {
            m_events.appendEvent(event);
            if (event.type == ImuEventType::SuspectedImpact
                || event.type == ImuEventType::RolloverRisk
                || event.type == ImuEventType::MountingAnomaly) {
                emit criticalEvent(event.title, event.detail);
                emit guardianCriticalEvent(guardianImuType(event.type), event.severity,
                                           event.title, event.detail);
                critical = true;
            }
        }
        if (critical)
            playCriticalTone();
    }, Qt::QueuedConnection);
}

void ImuService::postRecording(bool recording,
                               const QString &path,
                               const QString &errorText)
{
    QMetaObject::invokeMethod(this, [this, recording, path, errorText]() {
        const bool changed = m_recording != recording || m_recordingPath != path;
        m_recording = recording;
        m_recordingPath = path;
        if (!errorText.isEmpty()) {
            m_statusText = errorText;
            emit statusChanged();
        } else if (recording) {
            m_statusText = QStringLiteral("正在记录 IMU 原始数据");
            emit statusChanged();
        }
        if (changed)
            emit recordingChanged();
    }, Qt::QueuedConnection);
}

QString ImuService::findConfigPath()
{
    const QString envPath = QString::fromLocal8Bit(qgetenv("COCKPIT_IMU_CONFIG"));
    if (!envPath.isEmpty())
        return envPath;
    const QStringList candidates = {
        QStringLiteral("/etc/elf2/cockpit-imu.json"),
        QCoreApplication::applicationDirPath()
            + QStringLiteral("/assets/config/cockpit-imu.json"),
        QFileInfo(QStringLiteral(__FILE__)).absolutePath()
            + QStringLiteral("/assets/config/cockpit-imu.json"),
    };
    for (const QString &path : candidates) {
        if (QFileInfo::exists(path))
            return path;
    }
    return QString();
}

QString ImuService::createRecordingPath()
{
    QString root = QString::fromLocal8Bit(qgetenv("COCKPIT_IMU_RECORD_DIR"));
    if (root.isEmpty()) {
        root = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation)
             + QStringLiteral("/ELF2/imu");
    }
    QDir().mkpath(root);
    const QString name = QStringLiteral("imu-%1.csv")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss-zzz")));
    return QDir(root).filePath(name);
}

void ImuService::playCriticalTone()
{
    if (m_alertAudio) {
        QAudioOutput *oldAudio = m_alertAudio;
        QBuffer *oldBuffer = m_alertBuffer;
        m_alertAudio = nullptr;
        m_alertBuffer = nullptr;
        disconnect(oldAudio, nullptr, this, nullptr);
        oldAudio->stop();
        oldAudio->deleteLater();
        if (oldBuffer)
            oldBuffer->deleteLater();
    }

    QAudioFormat format;
    format.setSampleRate(16000);
    format.setChannelCount(1);
    format.setSampleSize(16);
    format.setCodec(QStringLiteral("audio/pcm"));
    format.setByteOrder(QAudioFormat::LittleEndian);
    format.setSampleType(QAudioFormat::SignedInt);
    const QAudioDeviceInfo device = QAudioDeviceInfo::defaultOutputDevice();
    if (device.isNull() || !device.isFormatSupported(format))
        return;

    m_alertBuffer = new QBuffer(this);
    m_alertBuffer->setData(makeAlertTonePcm(format.sampleRate(), 320));
    if (!m_alertBuffer->open(QIODevice::ReadOnly)) {
        m_alertBuffer->deleteLater();
        m_alertBuffer = nullptr;
        return;
    }

    m_alertAudio = new QAudioOutput(device, format, this);
    m_alertAudio->setVolume(0.68);
    QAudioOutput *audio = m_alertAudio;
    QBuffer *buffer = m_alertBuffer;
    connect(audio, &QAudioOutput::stateChanged, this,
            [this, audio, buffer](QAudio::State state) {
        if (state != QAudio::IdleState && state != QAudio::StoppedState)
            return;
        if (m_alertAudio == audio)
            m_alertAudio = nullptr;
        if (m_alertBuffer == buffer)
            m_alertBuffer = nullptr;
        audio->deleteLater();
        buffer->deleteLater();
    });
    audio->start(buffer);
}

void ImuService::sendMotionContext()
{
    if (m_motionSocketFd < 0) {
        m_motionSocketFd = ::socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (m_motionSocketFd < 0)
            return;
    }

    QString path = QString::fromLocal8Bit(qgetenv("COCKPIT_IMU_MOTION_SOCKET"));
    if (path.isEmpty())
        path = QStringLiteral("/tmp/cockpit_imu_motion.sock");
    const QByteArray encodedPath = path.toLocal8Bit();
    sockaddr_un address;
    if (encodedPath.size() >= static_cast<int>(sizeof(address.sun_path)))
        return;
    std::memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, encodedPath.constData(),
                 sizeof(address.sun_path) - 1);
    const QByteArray payload = buildMotionContextDatagram(
        m_snapshot, m_available, m_monotonicClock.elapsed());
    ::sendto(m_motionSocketFd, payload.constData(), payload.size(), MSG_DONTWAIT,
             reinterpret_cast<const sockaddr *>(&address), sizeof(address));
}
