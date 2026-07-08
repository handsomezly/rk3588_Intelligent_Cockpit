#include <QtTest>

#include "guardianeventpublisher.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

class GuardianEventPublisherTests : public QObject
{
    Q_OBJECT

    static int bindReceiver(const QString &path)
    {
        const int fd = ::socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd < 0) return -1;
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        const QByteArray encoded = path.toLocal8Bit();
        std::strncpy(addr.sun_path, encoded.constData(), sizeof(addr.sun_path) - 1);
        if (::bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
            ::close(fd);
            return -1;
        }
        timeval tv{0, 100000};
        ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        return fd;
    }

    static QJsonObject receive(int fd)
    {
        char data[2048];
        const ssize_t n = ::recv(fd, data, sizeof(data), 0);
        return n > 0 ? QJsonDocument::fromJson(QByteArray(data, int(n))).object()
                     : QJsonObject();
    }

private slots:
    void publishesEdgesWithoutDuplicates()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("events.sock"));
        const int fd = bindReceiver(path);
        QVERIFY(fd >= 0);
        qputenv("COCKPIT_GUARDIAN_EVENT_SOCKET", path.toLocal8Bit());

        GuardianEventPublisher publisher(nullptr, nullptr);
        publisher.processCameraState(true, true, QStringLiteral("running"), 1000);
        QCOMPARE(receive(fd).value(QStringLiteral("type")).toString(),
                 QStringLiteral("trip_started"));
        publisher.processCameraState(true, true, QStringLiteral("running"), 1100);
        QVERIFY(receive(fd).isEmpty());

        publisher.processFatigueState(true, true, 1200);
        const QJsonObject alert = receive(fd);
        QCOMPARE(alert.value(QStringLiteral("type")).toString(), QStringLiteral("alert"));
        QCOMPARE(alert.value(QStringLiteral("alertType")).toString(), QStringLiteral("fatigue"));

        publisher.processFatigueState(true, false, 1300);
        QCOMPARE(receive(fd).value(QStringLiteral("type")).toString(),
                 QStringLiteral("recovered"));

        publisher.processCameraState(true, false, QStringLiteral("off"), 1400);
        QCOMPARE(receive(fd).value(QStringLiteral("type")).toString(),
                 QStringLiteral("trip_ended"));
        ::close(fd);
        qunsetenv("COCKPIT_GUARDIAN_EVENT_SOCKET");
    }

    void disconnectDoesNotEndTrip()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("events.sock"));
        const int fd = bindReceiver(path);
        QVERIFY(fd >= 0);
        qputenv("COCKPIT_GUARDIAN_EVENT_SOCKET", path.toLocal8Bit());
        GuardianEventPublisher publisher(nullptr, nullptr);
        publisher.processCameraState(true, true, QStringLiteral("running"), 1000);
        QVERIFY(!receive(fd).isEmpty());
        publisher.processCameraState(false, false, QStringLiteral("off"), 2000);
        QVERIFY(receive(fd).isEmpty());
        ::close(fd);
        qunsetenv("COCKPIT_GUARDIAN_EVENT_SOCKET");
    }

    void imuAlertBeforeCameraIsForwardedForGatewayAutoStart()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("events.sock"));
        const int fd = bindReceiver(path);
        QVERIFY(fd >= 0);
        qputenv("COCKPIT_GUARDIAN_EVENT_SOCKET", path.toLocal8Bit());
        GuardianEventPublisher publisher(nullptr, nullptr);

        publisher.processImuCritical(
            QStringLiteral("suspected_impact"), 3,
            QStringLiteral("疑似强冲击"),
            QStringLiteral("请及时确认驾驶员状态"), 3000);
        const QJsonObject alert = receive(fd);
        QCOMPARE(alert.value(QStringLiteral("type")).toString(),
                 QStringLiteral("alert"));
        QCOMPARE(alert.value(QStringLiteral("alertType")).toString(),
                 QStringLiteral("suspected_impact"));

        ::close(fd);
        qunsetenv("COCKPIT_GUARDIAN_EVENT_SOCKET");
    }

    void cameraStopDoesNotInventRecovery()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("events.sock"));
        const int fd = bindReceiver(path);
        QVERIFY(fd >= 0);
        qputenv("COCKPIT_GUARDIAN_EVENT_SOCKET", path.toLocal8Bit());
        GuardianEventPublisher publisher(nullptr, nullptr);

        publisher.processCameraState(true, true, QStringLiteral("running"), 1000);
        QVERIFY(!receive(fd).isEmpty());
        publisher.processFatigueState(true, true, 1100);
        QVERIFY(!receive(fd).isEmpty());
        publisher.processCameraState(true, false, QStringLiteral("off"), 1200);
        QCOMPARE(receive(fd).value(QStringLiteral("type")).toString(),
                 QStringLiteral("trip_ended"));
        QVERIFY(receive(fd).isEmpty());

        ::close(fd);
        qunsetenv("COCKPIT_GUARDIAN_EVENT_SOCKET");
    }
};

QTEST_MAIN(GuardianEventPublisherTests)
#include "guardianpublisher_tests.moc"
