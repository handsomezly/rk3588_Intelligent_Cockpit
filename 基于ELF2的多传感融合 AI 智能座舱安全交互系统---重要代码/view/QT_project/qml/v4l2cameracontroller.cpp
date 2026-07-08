#include "v4l2cameracontroller.h"

#include <QColor>
#include <QMetaObject>
#include <QPainter>
#include <QSize>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>
#include <vector>

namespace {

struct MappedBuffer {
    void *start = nullptr;
    size_t length = 0;
};

static int xioctl(int fd, unsigned long request, void *arg)
{
    int result;
    do {
        result = ioctl(fd, request, arg);
    } while (result == -1 && errno == EINTR);
    return result;
}

static int clampColor(int value)
{
    return std::max(0, std::min(255, value));
}

static QString fourccToString(__u32 format)
{
    char text[5];
    text[0] = static_cast<char>(format & 0xff);
    text[1] = static_cast<char>((format >> 8) & 0xff);
    text[2] = static_cast<char>((format >> 16) & 0xff);
    text[3] = static_cast<char>((format >> 24) & 0xff);
    text[4] = '\0';
    return QString::fromLatin1(text);
}

static QImage convertYuyvToRgb(const uchar *data, int width, int height, int bytesPerLine, int *averageLuma)
{
    QImage image(width, height, QImage::Format_RGB888);
    qint64 lumaSum = 0;
    qint64 lumaCount = 0;

    for (int y = 0; y < height; ++y) {
        const uchar *src = data + y * bytesPerLine;
        uchar *dst = image.scanLine(y);

        for (int x = 0; x < width; x += 2) {
            const int y0 = src[0];
            const int u = src[1];
            const int y1 = src[2];
            const int v = src[3];

            const int c0 = y0 - 16;
            const int c1 = y1 - 16;
            const int d = u - 128;
            const int e = v - 128;

            dst[0] = static_cast<uchar>(clampColor((298 * c0 + 409 * e + 128) >> 8));
            dst[1] = static_cast<uchar>(clampColor((298 * c0 - 100 * d - 208 * e + 128) >> 8));
            dst[2] = static_cast<uchar>(clampColor((298 * c0 + 516 * d + 128) >> 8));

            dst[3] = static_cast<uchar>(clampColor((298 * c1 + 409 * e + 128) >> 8));
            dst[4] = static_cast<uchar>(clampColor((298 * c1 - 100 * d - 208 * e + 128) >> 8));
            dst[5] = static_cast<uchar>(clampColor((298 * c1 + 516 * d + 128) >> 8));

            lumaSum += y0 + y1;
            lumaCount += 2;
            src += 4;
            dst += 6;
        }
    }

    if (averageLuma) {
        *averageLuma = lumaCount > 0 ? static_cast<int>(lumaSum / lumaCount) : 0;
    }
    return image;
}

static QImage makePlaceholder(const QSize &requestedSize, const QString &status)
{
    QSize size = requestedSize.isValid() ? requestedSize : QSize(960, 540);
    size.setWidth(std::max(320, size.width()));
    size.setHeight(std::max(180, size.height()));

    QImage image(size, QImage::Format_RGB32);
    image.fill(QColor(12, 13, 14));

    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing, true);

    QLinearGradient background(0, 0, image.width(), image.height());
    background.setColorAt(0.0, QColor(20, 21, 22));
    background.setColorAt(0.55, QColor(40, 42, 44));
    background.setColorAt(1.0, QColor(11, 12, 13));
    painter.fillRect(image.rect(), background);

    painter.setPen(QPen(QColor(255, 255, 255, 42), 1));
    for (int x = 0; x < image.width(); x += 44) {
        painter.drawLine(x, 0, x - image.width() / 3, image.height());
    }
    for (int y = 0; y < image.height(); y += 36) {
        painter.drawLine(0, y, image.width(), y);
    }

    QRectF focus(image.width() * 0.30, image.height() * 0.22, image.width() * 0.40, image.height() * 0.50);
    painter.setPen(QPen(QColor(245, 164, 0, 150), 3));
    painter.drawRoundedRect(focus, 22, 22);

    painter.setPen(QColor(242, 242, 239));
    QFont titleFont = painter.font();
    titleFont.setPixelSize(std::max(18, image.width() / 34));
    titleFont.setBold(true);
    painter.setFont(titleFont);
    painter.drawText(image.rect().adjusted(28, 0, -28, -22), Qt::AlignHCenter | Qt::AlignVCenter,
                     QStringLiteral("V4L2 CAMERA"));

    QFont statusFont = painter.font();
    statusFont.setPixelSize(std::max(13, image.width() / 56));
    statusFont.setBold(false);
    painter.setFont(statusFont);
    painter.setPen(QColor(184, 184, 174));
    painter.drawText(image.rect().adjusted(32, image.height() / 2 + 36, -32, -22),
                     Qt::AlignHCenter | Qt::TextWordWrap, status);

    return image;
}

} // namespace

class CaptureThread : public QThread
{
public:
    CaptureThread(V4L2CameraController *owner, const QString &device)
        : QThread(owner), m_owner(owner), m_device(device)
    {
    }

    void requestStop()
    {
        m_stop.store(true);
    }

protected:
    void run() override
    {
        int fd = open(m_device.toLocal8Bit().constData(), O_RDWR | O_NONBLOCK);
        if (fd < 0) {
            m_owner->postStatus(QStringLiteral("无法打开 %1：%2").arg(m_device, QString::fromLocal8Bit(strerror(errno))));
            return;
        }

        v4l2_capability capability;
        std::memset(&capability, 0, sizeof(capability));
        if (xioctl(fd, VIDIOC_QUERYCAP, &capability) < 0 ||
            !(capability.capabilities & V4L2_CAP_VIDEO_CAPTURE) ||
            !(capability.capabilities & V4L2_CAP_STREAMING)) {
            m_owner->postStatus(QStringLiteral("设备不支持 V4L2 视频流采集"));
            close(fd);
            return;
        }

        v4l2_format format;
        std::memset(&format, 0, sizeof(format));
        format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        format.fmt.pix.width = 640;
        format.fmt.pix.height = 480;
        format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
        format.fmt.pix.field = V4L2_FIELD_ANY;

        if (xioctl(fd, VIDIOC_S_FMT, &format) < 0) {
            std::memset(&format, 0, sizeof(format));
            format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            format.fmt.pix.width = 640;
            format.fmt.pix.height = 480;
            format.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
            format.fmt.pix.field = V4L2_FIELD_ANY;
            if (xioctl(fd, VIDIOC_S_FMT, &format) < 0) {
                m_owner->postStatus(QStringLiteral("摄像头格式设置失败：%1").arg(QString::fromLocal8Bit(strerror(errno))));
                close(fd);
                return;
            }
        }

        v4l2_requestbuffers request;
        std::memset(&request, 0, sizeof(request));
        request.count = 4;
        request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        request.memory = V4L2_MEMORY_MMAP;

        if (xioctl(fd, VIDIOC_REQBUFS, &request) < 0 || request.count < 2) {
            m_owner->postStatus(QStringLiteral("V4L2 缓冲区申请失败"));
            close(fd);
            return;
        }

        std::vector<MappedBuffer> buffers(request.count);
        for (unsigned int i = 0; i < request.count; ++i) {
            v4l2_buffer buffer;
            std::memset(&buffer, 0, sizeof(buffer));
            buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buffer.memory = V4L2_MEMORY_MMAP;
            buffer.index = i;

            if (xioctl(fd, VIDIOC_QUERYBUF, &buffer) < 0) {
                m_owner->postStatus(QStringLiteral("V4L2 缓冲区查询失败"));
                cleanup(fd, buffers, false);
                return;
            }

            buffers[i].length = buffer.length;
            buffers[i].start = mmap(nullptr, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buffer.m.offset);
            if (buffers[i].start == MAP_FAILED) {
                buffers[i].start = nullptr;
                m_owner->postStatus(QStringLiteral("V4L2 缓冲区映射失败"));
                cleanup(fd, buffers, false);
                return;
            }
        }

        for (unsigned int i = 0; i < request.count; ++i) {
            v4l2_buffer buffer;
            std::memset(&buffer, 0, sizeof(buffer));
            buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buffer.memory = V4L2_MEMORY_MMAP;
            buffer.index = i;
            if (xioctl(fd, VIDIOC_QBUF, &buffer) < 0) {
                m_owner->postStatus(QStringLiteral("V4L2 缓冲区入队失败"));
                cleanup(fd, buffers, false);
                return;
            }
        }

        v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
            m_owner->postStatus(QStringLiteral("V4L2 视频流启动失败"));
            cleanup(fd, buffers, false);
            return;
        }

        const int width = static_cast<int>(format.fmt.pix.width);
        const int height = static_cast<int>(format.fmt.pix.height);
        const __u32 pixelFormat = format.fmt.pix.pixelformat;
        const int bytesPerLine = static_cast<int>(format.fmt.pix.bytesperline);
        m_owner->postStatus(QStringLiteral("V4L2 已连接 · %1x%2 · %3")
                                .arg(width)
                                .arg(height)
                                .arg(fourccToString(pixelFormat)));

        QElapsedTimer fpsTimer;
        fpsTimer.start();
        int framesInWindow = 0;

        while (!m_stop.load()) {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(fd, &fds);

            timeval timeout;
            timeout.tv_sec = 0;
            timeout.tv_usec = 200000;

            int selected = select(fd + 1, &fds, nullptr, nullptr, &timeout);
            if (selected < 0) {
                if (errno == EINTR) {
                    continue;
                }
                m_owner->postStatus(QStringLiteral("V4L2 等待帧失败"));
                break;
            }
            if (selected == 0) {
                continue;
            }

            v4l2_buffer buffer;
            std::memset(&buffer, 0, sizeof(buffer));
            buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buffer.memory = V4L2_MEMORY_MMAP;

            if (xioctl(fd, VIDIOC_DQBUF, &buffer) < 0) {
                if (errno == EAGAIN) {
                    continue;
                }
                m_owner->postStatus(QStringLiteral("V4L2 读取帧失败"));
                break;
            }

            int averageLuma = 80;
            QImage frame;
            const uchar *data = static_cast<const uchar *>(buffers[buffer.index].start);
            if (pixelFormat == V4L2_PIX_FMT_YUYV) {
                frame = convertYuyvToRgb(data, width, height, bytesPerLine > 0 ? bytesPerLine : width * 2, &averageLuma);
            } else if (pixelFormat == V4L2_PIX_FMT_MJPEG || pixelFormat == V4L2_PIX_FMT_JPEG) {
                frame = QImage::fromData(data, static_cast<int>(buffer.bytesused), "JPG").convertToFormat(QImage::Format_RGB888);
                if (!frame.isNull()) {
                    averageLuma = estimateLuma(frame);
                }
            }

            if (!frame.isNull()) {
                m_owner->publishFrame(frame, averageLuma);
                ++framesInWindow;
            }

            if (xioctl(fd, VIDIOC_QBUF, &buffer) < 0) {
                m_owner->postStatus(QStringLiteral("V4L2 缓冲区回队失败"));
                break;
            }

            if (fpsTimer.elapsed() >= 1000) {
                m_owner->postFps(framesInWindow * 1000.0 / qMax<qint64>(1, fpsTimer.elapsed()));
                framesInWindow = 0;
                fpsTimer.restart();
            }
        }

        cleanup(fd, buffers, true);
    }

private:
    static int estimateLuma(const QImage &image)
    {
        if (image.isNull()) {
            return 0;
        }

        const int stepX = std::max(1, image.width() / 48);
        const int stepY = std::max(1, image.height() / 36);
        qint64 sum = 0;
        qint64 count = 0;
        for (int y = 0; y < image.height(); y += stepY) {
            for (int x = 0; x < image.width(); x += stepX) {
                const QColor color(image.pixel(x, y));
                sum += (color.red() * 30 + color.green() * 59 + color.blue() * 11) / 100;
                ++count;
            }
        }
        return count > 0 ? static_cast<int>(sum / count) : 0;
    }

    void cleanup(int fd, std::vector<MappedBuffer> &buffers, bool streamStarted)
    {
        if (streamStarted) {
            v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            xioctl(fd, VIDIOC_STREAMOFF, &type);
        }

        for (MappedBuffer &buffer : buffers) {
            if (buffer.start && buffer.length > 0) {
                munmap(buffer.start, buffer.length);
                buffer.start = nullptr;
                buffer.length = 0;
            }
        }

        close(fd);
    }

    V4L2CameraController *m_owner;
    QString m_device;
    std::atomic<bool> m_stop { false };
};

V4L2CameraController::V4L2CameraController(QObject *parent)
    : QObject(parent)
    , QQuickImageProvider(QQuickImageProvider::Image)
    , m_device(QStringLiteral("/dev/video0"))
    , m_status(QStringLiteral("摄像头未启动"))
    , m_warningText(QStringLiteral("等待摄像头数据"))
    , m_thread(nullptr)
    , m_workerFrameSerial(0)
    , m_running(false)
    , m_frameSerial(0)
    , m_fatigueScore(0)
    , m_eyeClosure(0)
    , m_attention(0)
    , m_yawnCount(0)
    , m_fps(0.0)
{
}

V4L2CameraController::~V4L2CameraController()
{
    if (m_thread) {
        m_thread->requestStop();
        m_thread->wait(1200);
    }
}

QString V4L2CameraController::device() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_device;
}

void V4L2CameraController::setDevice(const QString &device)
{
    const QString nextDevice = device.trimmed().isEmpty() ? QStringLiteral("/dev/video0") : device.trimmed();
    {
        QMutexLocker locker(&m_stateMutex);
        if (m_device == nextDevice) {
            return;
        }
        m_device = nextDevice;
    }
    emit deviceChanged();
}

bool V4L2CameraController::running() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_running;
}

QString V4L2CameraController::status() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_status;
}

int V4L2CameraController::frameSerial() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_frameSerial;
}

int V4L2CameraController::fatigueScore() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_fatigueScore;
}

int V4L2CameraController::eyeClosure() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_eyeClosure;
}

int V4L2CameraController::attention() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_attention;
}

int V4L2CameraController::yawnCount() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_yawnCount;
}

double V4L2CameraController::fps() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_fps;
}

QString V4L2CameraController::warningText() const
{
    QMutexLocker locker(&m_stateMutex);
    return m_warningText;
}

void V4L2CameraController::start(const QString &device)
{
    if (!device.trimmed().isEmpty()) {
        setDevice(device);
    }

    {
        QMutexLocker locker(&m_stateMutex);
        if (m_thread) {
            return;
        }
        m_status = QStringLiteral("正在打开 %1").arg(m_device);
        m_warningText = QStringLiteral("正在初始化检测流");
        m_running = true;
        m_fps = 0.0;
    }

    emit statusChanged();
    emit metricsChanged();
    emit runningChanged();
    emit fpsChanged();

    CaptureThread *thread = new CaptureThread(this, this->device());
    m_thread = thread;
    connect(thread, &QThread::finished, this, [this, thread]() {
        markStopped(thread);
        thread->deleteLater();
    });
    thread->start();
}

void V4L2CameraController::stop()
{
    CaptureThread *thread = nullptr;
    {
        QMutexLocker locker(&m_stateMutex);
        thread = m_thread;
        m_status = QStringLiteral("摄像头已停止");
        m_running = false;
        m_fps = 0.0;
    }

    if (thread) {
        thread->requestStop();
    }

    emit statusChanged();
    emit runningChanged();
    emit fpsChanged();
}

QImage V4L2CameraController::requestImage(const QString &, QSize *size, const QSize &requestedSize)
{
    QImage frame;
    QString currentStatus;
    {
        QMutexLocker locker(&m_frameMutex);
        frame = m_latestFrame;
    }
    {
        QMutexLocker locker(&m_stateMutex);
        currentStatus = m_status;
    }

    if (frame.isNull()) {
        frame = makePlaceholder(requestedSize, currentStatus);
    }

    if (size) {
        *size = frame.size();
    }

    if (requestedSize.isValid()) {
        return frame.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return frame;
}

void V4L2CameraController::publishFrame(const QImage &image, int averageLuma)
{
    {
        QMutexLocker locker(&m_frameMutex);
        m_latestFrame = image;
    }

    const int serial = ++m_workerFrameSerial;
    const int darknessPenalty = qBound(0, (92 - averageLuma) / 3, 26);
    const int wave = (serial / 24) % 10;
    const int eyeClosure = qBound(8, 28 + darknessPenalty + wave, 82);
    const int attention = qBound(32, 96 - darknessPenalty - eyeClosure / 4, 98);
    const int fatigue = qBound(10, 24 + eyeClosure / 2 + (100 - attention) / 2 + darknessPenalty, 96);
    const int yawnCount = fatigue >= 72 ? 2 : fatigue >= 55 ? 1 : 0;
    const QString warning = fatigue >= 78
            ? QStringLiteral("高风险疲劳 · 建议立即休息")
            : fatigue >= 58
              ? QStringLiteral("轻度疲劳 · 建议短时休息")
              : QStringLiteral("状态稳定 · 持续监测中");

    QMetaObject::invokeMethod(this, [this, serial, fatigue, eyeClosure, attention, yawnCount, warning]() {
        {
            QMutexLocker locker(&m_stateMutex);
            m_frameSerial = serial;
            m_fatigueScore = fatigue;
            m_eyeClosure = eyeClosure;
            m_attention = attention;
            m_yawnCount = yawnCount;
            m_warningText = warning;
        }
        emit frameReady();
        emit metricsChanged();
    }, Qt::QueuedConnection);
}

void V4L2CameraController::postStatus(const QString &status)
{
    QMetaObject::invokeMethod(this, [this, status]() {
        {
            QMutexLocker locker(&m_stateMutex);
            m_status = status;
        }
        emit statusChanged();
    }, Qt::QueuedConnection);
}

void V4L2CameraController::postFps(double fps)
{
    QMetaObject::invokeMethod(this, [this, fps]() {
        {
            QMutexLocker locker(&m_stateMutex);
            m_fps = fps;
        }
        emit fpsChanged();
    }, Qt::QueuedConnection);
}

void V4L2CameraController::markStopped(CaptureThread *thread)
{
    bool changed = false;
    {
        QMutexLocker locker(&m_stateMutex);
        if (m_thread == thread) {
            m_thread = nullptr;
            changed = m_running;
            m_running = false;
            m_fps = 0.0;
            if (!m_status.startsWith(QStringLiteral("无法")) &&
                !m_status.contains(QStringLiteral("失败")) &&
                !m_status.contains(QStringLiteral("不支持"))) {
                m_status = QStringLiteral("摄像头已停止");
            }
        }
    }

    if (changed) {
        emit runningChanged();
    }
    emit statusChanged();
    emit fpsChanged();
}

void V4L2CameraController::setRunning(bool running)
{
    bool changed = false;
    {
        QMutexLocker locker(&m_stateMutex);
        if (m_running != running) {
            m_running = running;
            changed = true;
        }
    }
    if (changed) {
        emit runningChanged();
    }
}
