#include "fatigueclient.h"

#include <QByteArray>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QThread>
#include <QTimer>

#include <atomic>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

// Must match v2/code/frame_shm.py.
constexpr quint32 kShmMagic = 0x46504B43;  // 'CKPF' little-endian
constexpr int kHeaderSize = 64;
constexpr int kOffMagic = 0;
constexpr int kOffWidth = 8;
constexpr int kOffHeight = 12;
constexpr int kOffChannels = 16;
constexpr int kOffNumSlots = 20;
constexpr int kOffSlotSize = 24;
constexpr int kOffLatest = 32;

template <typename T>
T readLE(const uchar *base, int offset)
{
    T value;
    std::memcpy(&value, base + offset, sizeof(T));
    return value;
}

} // namespace

// =============================== worker thread =============================== //

class FatigueClientThread : public QThread
{
public:
    FatigueClientThread(FatigueClient *owner, QString sockPath, QString shmPath)
        : QThread(owner), m_owner(owner),
          m_sockPath(std::move(sockPath)), m_shmPath(std::move(shmPath))
    {
    }

    void requestStop() { m_stop.store(true); }

protected:
    void run() override
    {
        QByteArray buffer;
        int fd = -1;

        while (!m_stop.load()) {
            if (fd < 0) {
                fd = connectSocket();
                if (fd < 0) {
                    interruptibleSleep(500);
                    continue;
                }
                buffer.clear();
                m_owner->postConnected(true);
            }

            char chunk[8192];
            const ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
            if (n == 0) {                       // peer closed
                disconnect(fd);
                continue;
            }
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                    continue;                   // recv timeout -> re-check stop
                disconnect(fd);
                continue;
            }

            buffer.append(chunk, static_cast<int>(n));

            // Only the freshest complete line matters; drop any backlog so the
            // display never lags behind the service.
            const int lastNl = buffer.lastIndexOf('\n');
            if (lastNl < 0) {
                if (buffer.size() > (1 << 20))   // runaway guard
                    buffer.clear();
                continue;
            }
            const int prevNl = buffer.lastIndexOf('\n', lastNl - 1);
            const QByteArray line = buffer.mid(prevNl + 1, lastNl - (prevNl + 1));
            buffer = buffer.mid(lastNl + 1);

            QJsonParseError perr{};
            const QJsonDocument doc = QJsonDocument::fromJson(line, &perr);
            if (perr.error != QJsonParseError::NoError || !doc.isObject())
                continue;
            m_owner->postMetrics(doc.object());

            // Only copy/emit the frame when a viewer wants it (camera page).
            if (m_owner->m_wantFrames.load()
                    && m_owner->m_cameraEnabledForFrames.load()) {
                QImage frame = readLatestFrame();
                if (!frame.isNull())
                    m_owner->postFrame(frame);
            }
        }

        if (fd >= 0)
            ::close(fd);
        unmapShm();
    }

private:
    int connectSocket()
    {
        int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0)
            return -1;

        sockaddr_un addr;
        std::memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        const QByteArray path = m_sockPath.toLocal8Bit();
        std::strncpy(addr.sun_path, path.constData(), sizeof(addr.sun_path) - 1);

        if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
            ::close(fd);
            return -1;
        }

        timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 200000;   // 200ms so run() loops back to check m_stop
        ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        return fd;
    }

    void disconnect(int &fd)
    {
        if (fd >= 0) {
            ::close(fd);
            fd = -1;
        }
        unmapShm();                 // service may restart and recreate the file
        m_owner->postConnected(false);
    }

    bool ensureShmMapped()
    {
        if (m_shmBase)
            return true;
        const int fd = ::open(m_shmPath.toLocal8Bit().constData(), O_RDONLY);
        if (fd < 0)
            return false;
        struct stat st;
        if (::fstat(fd, &st) < 0 || st.st_size < kHeaderSize) {
            ::close(fd);
            return false;
        }
        void *base = ::mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
        ::close(fd);
        if (base == MAP_FAILED)
            return false;
        m_shmBase = static_cast<uchar *>(base);
        m_shmSize = static_cast<size_t>(st.st_size);
        return true;
    }

    void unmapShm()
    {
        if (m_shmBase) {
            ::munmap(m_shmBase, m_shmSize);
            m_shmBase = nullptr;
            m_shmSize = 0;
        }
    }

    QImage readLatestFrame()
    {
        if (!ensureShmMapped())
            return QImage();

        const uchar *base = m_shmBase;
        if (readLE<quint32>(base, kOffMagic) != kShmMagic)
            return QImage();

        const int width = static_cast<int>(readLE<quint32>(base, kOffWidth));
        const int height = static_cast<int>(readLE<quint32>(base, kOffHeight));
        const int channels = static_cast<int>(readLE<quint32>(base, kOffChannels));
        const quint32 numSlots = readLE<quint32>(base, kOffNumSlots);
        const quint64 slotSize = readLE<quint64>(base, kOffSlotSize);
        if (width <= 0 || height <= 0 || channels != 3 || numSlots == 0)
            return QImage();

        const quint32 latest = readLE<quint32>(base, kOffLatest);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (latest >= numSlots)
            return QImage();

        const quint64 offset = static_cast<quint64>(kHeaderSize) + latest * slotSize;
        if (offset + slotSize > m_shmSize)
            return QImage();

        // Wrap the slot tightly (row stride = width*3) then copy to detach from
        // the mapping before the writer can recycle the slot.
        QImage view(base + offset, width, height, width * 3, QImage::Format_RGB888);
        return view.copy();
    }

    void interruptibleSleep(int totalMs)
    {
        int slept = 0;
        while (slept < totalMs && !m_stop.load()) {
            QThread::msleep(50);
            slept += 50;
        }
    }

    FatigueClient *m_owner;
    QString m_sockPath;
    QString m_shmPath;
    std::atomic<bool> m_stop { false };
    uchar *m_shmBase = nullptr;
    size_t m_shmSize = 0;
};

// =============================== FatigueClient =============================== //

FatigueClient::FatigueClient(QObject *parent)
    : QObject(parent)
{
    const QByteArray controlPath = qgetenv("COCKPIT_FATIGUE_CONTROL_SOCKET");
    m_controlSockPath = controlPath.isEmpty()
            ? QStringLiteral("/tmp/cockpit_fatigue_control.sock")
            : QString::fromLocal8Bit(controlPath);

    bool timeoutOk = false;
    const int timeout = QString::fromLocal8Bit(
                qgetenv("COCKPIT_CAMERA_CONTROL_TIMEOUT_MS")).toInt(&timeoutOk);
    if (timeoutOk && timeout > 0)
        m_cameraControlTimeoutMs = timeout;

    m_cameraControlTimer = new QTimer(this);
    m_cameraControlTimer->setSingleShot(true);
    connect(m_cameraControlTimer, &QTimer::timeout, this, [this]() {
        if (!m_cameraControlBusy)
            return;
        m_cameraControlBusy = false;
        m_cameraState = m_cameraEnabled
                ? QStringLiteral("running") : QStringLiteral("off");
        m_cameraError = QStringLiteral("摄像头控制超时，请重试");
        emit cameraControlChanged();
    });
}

FatigueClient::~FatigueClient()
{
    stop();
}

void FatigueClient::start()
{
    if (m_thread)
        return;
    m_thread = new FatigueClientThread(this, m_sockPath, m_shmPath);
    connect(m_thread, &QThread::finished, m_thread, &QObject::deleteLater);
    m_thread->start();
}

void FatigueClient::stop()
{
    if (!m_thread)
        return;
    m_thread->requestStop();
    m_thread->wait(1500);
    m_thread = nullptr;          // deleteLater handles the QObject

    if (m_connected) {
        m_connected = false;
        emit connectedChanged();
    }
    if (m_status != QStringLiteral("disconnected")) {
        m_status = QStringLiteral("disconnected");
        emit metricsChanged();
    }
    m_cameraControlTimer->stop();
    m_cameraEnabled = false;
    m_cameraEnabledForFrames.store(false);
    m_cameraState = QStringLiteral("off");
    m_cameraControlBusy = false;
    m_cameraError.clear();
    emit cameraControlChanged();
}

void FatigueClient::setCameraEnabled(bool enabled)
{
    if (m_cameraControlBusy)
        return;
    if (!m_connected) {
        m_cameraError = QStringLiteral("推理服务未连接");
        emit cameraControlChanged();
        return;
    }
    if (enabled == m_cameraEnabled
            && ((enabled && m_cameraState == QStringLiteral("running"))
                || (!enabled && m_cameraState == QStringLiteral("off"))))
        return;

    QString errorText;
    if (!sendCameraCommand(enabled, &errorText)) {
        m_cameraControlBusy = false;
        m_cameraState = m_cameraEnabled
                ? QStringLiteral("running") : QStringLiteral("off");
        m_cameraError = errorText;
        emit cameraControlChanged();
        return;
    }

    m_requestedCameraEnabled = enabled;
    m_cameraControlBusy = true;
    m_cameraState = enabled
            ? QStringLiteral("starting") : QStringLiteral("stopping");
    m_cameraError.clear();
    m_cameraControlTimer->start(m_cameraControlTimeoutMs);
    emit cameraControlChanged();
}

bool FatigueClient::sendCameraCommand(bool enabled, QString *errorText)
{
    const int fd = ::socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) {
        if (errorText)
            *errorText = QStringLiteral("无法创建摄像头控制 Socket: %1")
                    .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return false;
    }

    sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const QByteArray path = m_controlSockPath.toLocal8Bit();
    if (path.size() >= static_cast<int>(sizeof(addr.sun_path))) {
        ::close(fd);
        if (errorText)
            *errorText = QStringLiteral("摄像头控制 Socket 路径过长");
        return false;
    }
    std::strncpy(addr.sun_path, path.constData(), sizeof(addr.sun_path) - 1);

    const QJsonObject command {
        {QStringLiteral("command"), QStringLiteral("set_camera")},
        {QStringLiteral("enabled"), enabled},
    };
    const QByteArray payload = QJsonDocument(command).toJson(QJsonDocument::Compact);
    const ssize_t sent = ::sendto(fd, payload.constData(), payload.size(), 0,
                                  reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
    const int savedErrno = errno;
    ::close(fd);
    if (sent != payload.size()) {
        if (errorText)
            *errorText = QStringLiteral("控制服务不可用: %1")
                    .arg(QString::fromLocal8Bit(std::strerror(savedErrno)));
        return false;
    }
    return true;
}

void FatigueClient::postConnected(bool connected)
{
    QMetaObject::invokeMethod(this, [this, connected]() {
        if (m_connected != connected) {
            m_connected = connected;
            emit connectedChanged();
        }
        if (!connected && m_status != QStringLiteral("disconnected")) {
            m_status = QStringLiteral("disconnected");
            m_faceFound = false;
            m_fatigueAlarm = false;
            m_fatigueReason.clear();
            m_perclos = 0.0;
            emit metricsChanged();
        }
        if (!connected) {
            m_cameraControlTimer->stop();
            m_cameraEnabled = false;
            m_cameraEnabledForFrames.store(false);
            m_cameraState = QStringLiteral("off");
            m_cameraControlBusy = false;
            m_cameraError.clear();
            emit cameraControlChanged();
        }
    }, Qt::QueuedConnection);
}

void FatigueClient::postFrame(const QImage &image)
{
    QMetaObject::invokeMethod(this, [this, image]() {
        emit frameReady(image);
    }, Qt::QueuedConnection);
}

void FatigueClient::postMetrics(const QJsonObject &m)
{
    QMetaObject::invokeMethod(this, [this, m]() {
        auto rectFrom = [](const QJsonValue &v) -> QRectF {
            if (!v.isArray())
                return QRectF();
            const QJsonArray a = v.toArray();
            if (a.size() != 4)
                return QRectF();
            const double x1 = a.at(0).toDouble();
            const double y1 = a.at(1).toDouble();
            const double x2 = a.at(2).toDouble();
            const double y2 = a.at(3).toDouble();
            return QRectF(x1, y1, x2 - x1, y2 - y1);
        };

        m_status = m.value(QStringLiteral("status")).toString(QStringLiteral("normal"));
        m_fatigueAlarm = m.value(QStringLiteral("fatigue_alarm")).toBool();
        m_fatigueReason = m.value(QStringLiteral("fatigue_reason")).toString();
        m_perclos = m.value(QStringLiteral("perclos")).toDouble();
        m_validCount = m.value(QStringLiteral("valid_count")).toInt();
        m_windowLen = m.value(QStringLiteral("window_len")).toInt();
        m_fps = m.value(QStringLiteral("fps")).toDouble();
        m_faceFound = m.value(QStringLiteral("face_found")).toBool();
        m_eyeLeft = m.value(QStringLiteral("eye_left")).toString();
        m_eyeRight = m.value(QStringLiteral("eye_right")).toString();
        m_pOpenLeft = m.value(QStringLiteral("p_open_left")).toDouble();
        m_pOpenRight = m.value(QStringLiteral("p_open_right")).toDouble();
        m_blinkRate = m.value(QStringLiteral("blink_rate")).toDouble();
        // null mean_blink_ms -> -1 sentinel ("--" in the UI).
        const QJsonValue meanV = m.value(QStringLiteral("mean_blink_ms"));
        m_meanBlinkMs = meanV.isNull() ? -1.0 : meanV.toDouble();
        m_longBlinkCount = m.value(QStringLiteral("long_blink_count")).toInt();
        m_frameWidth = m.value(QStringLiteral("frame_w")).toInt();
        m_frameHeight = m.value(QStringLiteral("frame_h")).toInt();
        m_faceBox = rectFrom(m.value(QStringLiteral("face_box")));
        m_eyeLeftBox = rectFrom(m.value(QStringLiteral("eye_left_box")));
        m_eyeRightBox = rectFrom(m.value(QStringLiteral("eye_right_box")));
        m_motionGated = m.value(QStringLiteral("motion_gated")).toBool(false);
        m_motionGateReason = m.value(QStringLiteral("motion_gate_reason"))
                                 .toString(QStringLiteral("imu_missing"));
        m_imuVisionConfidence = m.value(QStringLiteral("vision_confidence")).toDouble(1.0);
        m_vehicleMotionState = m.value(QStringLiteral("vehicle_motion_state"))
                                   .toString(QStringLiteral("unknown"));

        const bool hasCameraStatus = m.contains(QStringLiteral("camera_state"));
        if (hasCameraStatus) {
            const bool reportedEnabled = m.value(QStringLiteral("camera_enabled")).toBool(false);
            const QString reportedState = m.value(QStringLiteral("camera_state"))
                    .toString(QStringLiteral("off"));
            const QString reportedError = m.value(QStringLiteral("camera_error")).toString();
            const bool requestConfirmed = !m_cameraControlBusy
                    || reportedState == QStringLiteral("error")
                    || (m_requestedCameraEnabled
                        && reportedEnabled
                        && reportedState == QStringLiteral("running"))
                    || (!m_requestedCameraEnabled
                        && !reportedEnabled
                        && reportedState == QStringLiteral("off"));

            // The stream may still contain one snapshot from before the command.
            // Keep the local starting/stopping state until a matching ack arrives.
            if (requestConfirmed) {
                m_cameraEnabled = reportedEnabled;
                m_cameraEnabledForFrames.store(m_cameraEnabled);
                m_cameraState = reportedState;
                m_cameraError = reportedError;
                if (reportedState == QStringLiteral("running")
                        || reportedState == QStringLiteral("off")
                        || reportedState == QStringLiteral("error")) {
                    m_cameraControlTimer->stop();
                    m_cameraControlBusy = false;
                }
            }
        }
        if (!m_cameraEnabled) {
            m_fatigueAlarm = false;
            m_fatigueReason.clear();
            m_perclos = 0.0;
            m_faceFound = false;
        }

        emit metricsChanged();
        emit cameraControlChanged();
    }, Qt::QueuedConnection);
}
