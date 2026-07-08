#include <QtTest>

#include "fatigueclient.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

class FatigueClientTests : public QObject
{
    Q_OBJECT

private:
    static int bindReceiver(const QString &path)
    {
        const int fd = ::socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd < 0)
            return -1;
        sockaddr_un addr;
        std::memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        const QByteArray encoded = path.toLocal8Bit();
        std::strncpy(addr.sun_path, encoded.constData(), sizeof(addr.sun_path) - 1);
        if (::bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
            ::close(fd);
            return -1;
        }
        timeval tv{0, 200000};
        ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        return fd;
    }

    static QJsonObject receiveCommand(int fd)
    {
        char data[1024];
        const ssize_t size = ::recv(fd, data, sizeof(data), 0);
        if (size <= 0)
            return QJsonObject();
        return QJsonDocument::fromJson(QByteArray(data, static_cast<int>(size))).object();
    }

    static void connectForTest(FatigueClient &client)
    {
        client.postConnected(true);
        QTRY_VERIFY(client.connected());
    }

private slots:
    void cleanup()
    {
        qunsetenv("COCKPIT_FATIGUE_CONTROL_SOCKET");
        qunsetenv("COCKPIT_CAMERA_CONTROL_TIMEOUT_MS");
    }

    void sendsEnableCommandAndWaitsForServiceAcknowledgement()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("control.sock"));
        const int receiver = bindReceiver(path);
        QVERIFY2(receiver >= 0, std::strerror(errno));
        qputenv("COCKPIT_FATIGUE_CONTROL_SOCKET", path.toLocal8Bit());

        FatigueClient client;
        connectForTest(client);
        client.setCameraEnabled(true);

        const QJsonObject command = receiveCommand(receiver);
        QCOMPARE(command.value(QStringLiteral("command")).toString(), QStringLiteral("set_camera"));
        QCOMPARE(command.value(QStringLiteral("enabled")).toBool(), true);
        QCOMPARE(client.cameraState(), QStringLiteral("starting"));
        QVERIFY(client.cameraControlBusy());
        QVERIFY(!client.cameraEnabled());

        client.postMetrics(QJsonObject{
            {QStringLiteral("camera_enabled"), true},
            {QStringLiteral("camera_state"), QStringLiteral("running")},
            {QStringLiteral("camera_error"), QString()},
        });
        QTRY_COMPARE(client.cameraState(), QStringLiteral("running"));
        QVERIFY(client.cameraEnabled());
        QVERIFY(!client.cameraControlBusy());
        ::close(receiver);
    }

    void suppressesDuplicateRequestWhileBusy()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("control.sock"));
        const int receiver = bindReceiver(path);
        QVERIFY(receiver >= 0);
        qputenv("COCKPIT_FATIGUE_CONTROL_SOCKET", path.toLocal8Bit());

        FatigueClient client;
        connectForTest(client);
        client.setCameraEnabled(true);
        QVERIFY(!receiveCommand(receiver).isEmpty());

        client.setCameraEnabled(true);
        QVERIFY(receiveCommand(receiver).isEmpty());
        ::close(receiver);
    }

    void staleOppositeMetricsDoNotAcknowledgePendingEnable()
    {
        FatigueClient client;
        client.m_requestedCameraEnabled = true;
        client.m_cameraControlBusy = true;
        client.m_cameraState = QStringLiteral("starting");

        client.postMetrics(QJsonObject{
            {QStringLiteral("camera_enabled"), false},
            {QStringLiteral("camera_state"), QStringLiteral("off")},
            {QStringLiteral("camera_error"), QString()},
        });

        QTest::qWait(20);
        QVERIFY(client.cameraControlBusy());
        QCOMPARE(client.cameraState(), QStringLiteral("starting"));

        client.postMetrics(QJsonObject{
            {QStringLiteral("camera_enabled"), true},
            {QStringLiteral("camera_state"), QStringLiteral("running")},
            {QStringLiteral("camera_error"), QString()},
        });
        QTRY_VERIFY(!client.cameraControlBusy());
        QVERIFY(client.cameraEnabled());
    }

    void sendFailureLeavesCameraOffAndExposesError()
    {
        QTemporaryDir dir;
        qputenv("COCKPIT_FATIGUE_CONTROL_SOCKET",
                dir.filePath(QStringLiteral("missing.sock")).toLocal8Bit());

        FatigueClient client;
        connectForTest(client);
        client.setCameraEnabled(true);

        QVERIFY(!client.cameraEnabled());
        QVERIFY(!client.cameraControlBusy());
        QCOMPARE(client.cameraState(), QStringLiteral("off"));
        QVERIFY(!client.cameraError().isEmpty());
    }

    void timeoutRollsPendingEnableBackToOff()
    {
        QTemporaryDir dir;
        const QString path = dir.filePath(QStringLiteral("control.sock"));
        const int receiver = bindReceiver(path);
        QVERIFY(receiver >= 0);
        qputenv("COCKPIT_FATIGUE_CONTROL_SOCKET", path.toLocal8Bit());
        qputenv("COCKPIT_CAMERA_CONTROL_TIMEOUT_MS", "60");

        FatigueClient client;
        connectForTest(client);
        client.setCameraEnabled(true);
        QVERIFY(!receiveCommand(receiver).isEmpty());

        QTRY_VERIFY_WITH_TIMEOUT(!client.cameraControlBusy(), 500);
        QCOMPARE(client.cameraState(), QStringLiteral("off"));
        QVERIFY(client.cameraError().contains(QStringLiteral("超时")));
        ::close(receiver);
    }

    void disconnectClearsCameraAndFatigueState()
    {
        FatigueClient client;
        connectForTest(client);
        client.postMetrics(QJsonObject{
            {QStringLiteral("camera_enabled"), true},
            {QStringLiteral("camera_state"), QStringLiteral("running")},
            {QStringLiteral("fatigue_alarm"), true},
            {QStringLiteral("perclos"), 0.3},
        });
        QTRY_VERIFY(client.cameraEnabled());

        client.postConnected(false);

        QTRY_VERIFY(!client.connected());
        QCOMPARE(client.cameraState(), QStringLiteral("off"));
        QVERIFY(!client.cameraEnabled());
        QVERIFY(!client.fatigueAlarm());
        QCOMPARE(client.perclos(), 0.0);
    }
};

QTEST_MAIN(FatigueClientTests)
#include "fatigueclient_tests.moc"
