#include <QtTest>

#include <algorithm>

#include <QFile>
#include <QTemporaryDir>

#include "imuio.h"
#include "alerttone.h"
#include "imudevice.h"
#include "imueventmodel.h"
#include "imuprocessor.h"
#include "imuservice.h"
#include "motioncontext.h"

namespace {

constexpr quint64 kMs = 1000000ULL;

ImuSample sampleAt(quint64 timestampMs,
                   const QVector3D &accel = QVector3D(0.0f, 0.0f, 1.0f),
                   const QVector3D &gyro = QVector3D())
{
    ImuSample sample;
    sample.timestampNs = timestampMs * kMs;
    sample.sequence = static_cast<quint32>(timestampMs);
    sample.accelG = accel;
    sample.gyroDps = gyro;
    return sample;
}

void calibrate(ImuProcessor &processor, int count, int periodMs = 10)
{
    processor.startCalibration();
    for (int i = 0; i < count; ++i)
        processor.processSample(sampleAt(static_cast<quint64>(i * periodMs)));
}

} // namespace

class ImuProcessorTests : public QObject
{
    Q_OBJECT

private slots:
    void stationarySamplesCompleteCalibration();
    void movingSamplesFailCalibration();
    void hardBrakeEmitsOnceAndHonoursCooldown();
    void accelerationAndTurnAffectTripScore();
    void bumpAndVibrationLowerSmoothnessAndVisionConfidence();
    void impactRequiresAccelerationAndAngularEvidence();
    void sustainedTiltRaisesRolloverAndMountingEvents();
    void staticTiltSeparatesGravity();
    void yawCueLeaksBackTowardZero();
    void configLoadsAxisMapAndThresholds();
    void configRejectsDuplicateAxes();
    void csvLogRoundTripsSamples();
    void uapiSampleDecodesRangesAndAxisMap();
    void legacyDriverFrameDecodesCurrentKernelLayout();
    void eventModelAppendsAndAcknowledges();
    void serviceReplaysAndPublishesCalibratedSnapshot();
    void serviceReadsLegacyDriverFramesWithoutIoctl();
    void serviceControlsTripCalibrationAndRecording();
    void alertTonePcmHasExpectedEnvelope();
    void motionContextDatagramUsesVersionedSchema();
};

void ImuProcessorTests::stationarySamplesCompleteCalibration()
{
    ImuConfig config;
    config.calibrationSampleCount = 20;
    config.calibrationMaxSamples = 30;
    ImuProcessor processor(config);

    processor.startCalibration();
    for (int i = 0; i < 20; ++i) {
        processor.processSample(sampleAt(i * 5,
                                         QVector3D(0.01f, -0.02f, 1.01f),
                                         QVector3D(0.4f, -0.3f, 0.2f)));
    }

    QCOMPARE(processor.snapshot().calibrationState, ImuCalibrationState::Ready);
    QVERIFY(processor.snapshot().calibrated);
    QVERIFY(qAbs(processor.gyroBias().x() - 0.4f) < 0.02f);
    QVERIFY(qAbs(processor.gyroBias().y() + 0.3f) < 0.02f);
    QVERIFY(qAbs(processor.gyroBias().z() - 0.2f) < 0.02f);
}

void ImuProcessorTests::accelerationAndTurnAffectTripScore()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.hardAccelerationHoldMs = 100;
    config.hardTurnHoldMs = 100;
    config.manoeuvreCooldownMs = 200;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    for (int i = 0; i < 35; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(0.50f, 0.0f, 1.0f)));
    for (int i = 0; i < 20; ++i, t += 10)
        processor.processSample(sampleAt(t));
    for (int i = 0; i < 35; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(0.0f, 0.50f, 1.0f)));

    const QList<ImuEvent> events = processor.takeEvents();
    QCOMPARE(events.size(), 2);
    QCOMPARE(events.at(0).type, ImuEventType::HardAcceleration);
    QCOMPARE(events.at(1).type, ImuEventType::HardTurn);
    QVERIFY(processor.snapshot().drivingScore <= 96);
}

void ImuProcessorTests::bumpAndVibrationLowerSmoothnessAndVisionConfidence()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.bumpHoldMs = 10;
    config.vibrationHoldMs = 300;
    config.bumpCooldownMs = 200;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    for (int i = 0; i < 4; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(0.0f, 0.0f, 1.70f)));
    for (int i = 0; i < 20; ++i, t += 10)
        processor.processSample(sampleAt(t));
    for (int i = 0; i < 100; ++i, t += 10) {
        const float z = (i % 2 == 0) ? 1.35f : 0.65f;
        processor.processSample(sampleAt(t, QVector3D(0.0f, 0.0f, z),
                                         QVector3D(12.0f, 0.0f, 0.0f)));
    }

    const QList<ImuEvent> events = processor.takeEvents();
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::Bump;
    }));
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::SevereVibration;
    }));
    QVERIFY(processor.snapshot().smoothnessScore < 80);
    QVERIFY(processor.snapshot().visionConfidence < 0.6);
}

void ImuProcessorTests::impactRequiresAccelerationAndAngularEvidence()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.impactHoldMs = 10;
    config.riskCooldownMs = 500;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    for (int i = 0; i < 5; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(3.0f, 0.0f, 1.0f)));
    const QList<ImuEvent> accelerationOnly = processor.takeEvents();
    QVERIFY(std::none_of(accelerationOnly.cbegin(), accelerationOnly.cend(),
                         [](const ImuEvent &event) {
        return event.type == ImuEventType::SuspectedImpact;
    }));

    for (int i = 0; i < 5; ++i, t += 10) {
        processor.processSample(sampleAt(t, QVector3D(3.0f, 0.0f, 1.0f),
                                         QVector3D(0.0f, 180.0f, 0.0f)));
    }
    const QList<ImuEvent> events = processor.takeEvents();
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::SuspectedImpact;
    }));
}

void ImuProcessorTests::sustainedTiltRaisesRolloverAndMountingEvents()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.rolloverHoldMs = 300;
    config.mountingHoldMs = 500;
    config.riskCooldownMs = 500;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    const float mountAngle = qDegreesToRadians(12.0f);
    const QVector3D moved(0.0f, qSin(mountAngle), qCos(mountAngle));
    for (int i = 0; i < 300; ++i, t += 10)
        processor.processSample(sampleAt(t, moved));
    QList<ImuEvent> events = processor.takeEvents();
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::MountingAnomaly;
    }));
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::MountingAnomaly
            && event.detail.endsWith(QStringLiteral("°"));
    }));

    for (int i = 0; i < 100; ++i, t += 10)
        processor.processSample(sampleAt(t));
    const float rollAngle = qDegreesToRadians(55.0f);
    const QVector3D rolled(0.0f, qSin(rollAngle), qCos(rollAngle));
    for (int i = 0; i < 300; ++i, t += 10)
        processor.processSample(sampleAt(t, rolled));
    events = processor.takeEvents();
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::RolloverRisk;
    }));
    QVERIFY(std::any_of(events.cbegin(), events.cend(), [](const ImuEvent &event) {
        return event.type == ImuEventType::RolloverRisk
            && event.detail.endsWith(QStringLiteral("°"));
    }));
}

void ImuProcessorTests::movingSamplesFailCalibration()
{
    ImuConfig config;
    config.calibrationSampleCount = 20;
    config.calibrationMaxSamples = 20;
    ImuProcessor processor(config);

    processor.startCalibration();
    for (int i = 0; i < 20; ++i) {
        const float x = (i % 2 == 0) ? 0.5f : -0.5f;
        processor.processSample(sampleAt(i * 5,
                                         QVector3D(x, 0.0f, 1.0f),
                                         QVector3D(15.0f, 0.0f, 0.0f)));
    }

    QCOMPARE(processor.snapshot().calibrationState, ImuCalibrationState::Failed);
    QVERIFY(!processor.snapshot().calibrated);
}

void ImuProcessorTests::hardBrakeEmitsOnceAndHonoursCooldown()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.hardBrakeHoldMs = 200;
    config.manoeuvreCooldownMs = 1000;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    for (int i = 0; i < 80; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(-0.55f, 0.0f, 1.0f)));

    const QList<ImuEvent> first = processor.takeEvents();
    QCOMPARE(first.size(), 1);
    QCOMPARE(first.first().type, ImuEventType::HardBrake);
    QVERIFY(processor.snapshot().drivingScore < 100);

    for (int i = 0; i < 20; ++i, t += 10)
        processor.processSample(sampleAt(t));
    for (int i = 0; i < 40; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(-0.60f, 0.0f, 1.0f)));
    QCOMPARE(processor.takeEvents().size(), 0);

    t += 1200;
    for (int i = 0; i < 20; ++i, t += 10)
        processor.processSample(sampleAt(t));
    for (int i = 0; i < 40; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(-0.60f, 0.0f, 1.0f)));
    QCOMPARE(processor.takeEvents().size(), 1);
}

void ImuProcessorTests::staticTiltSeparatesGravity()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    const float angle = qDegreesToRadians(15.0f);
    const QVector3D tilted(0.0f, qSin(angle), qCos(angle));
    quint64 t = 200;
    for (int i = 0; i < 500; ++i, t += 10)
        processor.processSample(sampleAt(t, tilted));

    const ImuSnapshot snap = processor.snapshot();
    QVERIFY(qAbs(snap.rollDeg - 15.0) < 2.0);
    QVERIFY(snap.linearAccelG.length() < 0.08f);
}

void ImuProcessorTests::yawCueLeaksBackTowardZero()
{
    ImuConfig config;
    config.calibrationSampleCount = 10;
    config.calibrationMaxSamples = 10;
    config.yawLeakSeconds = 1.0;
    ImuProcessor processor(config);
    calibrate(processor, 10);

    quint64 t = 200;
    for (int i = 0; i < 100; ++i, t += 10)
        processor.processSample(sampleAt(t, QVector3D(0.0f, 0.0f, 1.0f), QVector3D(0, 0, 30)));
    const double peak = processor.snapshot().yawCueDeg;
    QVERIFY(peak > 10.0);

    for (int i = 0; i < 400; ++i, t += 10)
        processor.processSample(sampleAt(t));
    QVERIFY(qAbs(processor.snapshot().yawCueDeg) < qAbs(peak) * 0.1);
}

void ImuProcessorTests::configLoadsAxisMapAndThresholds()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("imu.json"));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(R"({
        "axis_map": {"forward":"+y", "left":"-x", "up":"+z"},
        "events": {"hard_brake_g":-0.42, "hard_turn_g":0.36},
        "calibration": {"samples":120}
    })");
    file.close();

    ImuConfig config;
    ImuAxisMap map;
    QString error;
    QVERIFY2(loadImuConfig(path, &config, &map, &error), qPrintable(error));
    QCOMPARE(config.calibrationSampleCount, 120);
    QCOMPARE(config.hardBrakeEnterG, -0.42);
    QCOMPARE(config.hardTurnEnterG, 0.36);
    QCOMPARE(map.apply(QVector3D(1, 2, 3)), QVector3D(2, -1, 3));
}

void ImuProcessorTests::configRejectsDuplicateAxes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("imu.json"));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(R"({"axis_map":{"forward":"+x","left":"-x","up":"+z"}})");
    file.close();

    ImuConfig config;
    ImuAxisMap map;
    QString error;
    QVERIFY(!loadImuConfig(path, &config, &map, &error));
    QVERIFY(error.contains(QStringLiteral("重复")));
}

void ImuProcessorTests::csvLogRoundTripsSamples()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("drive.csv"));
    ImuCsvLogWriter writer;
    QString error;
    QVERIFY2(writer.open(path, 200, 8, 500, QStringLiteral("+x,+y,+z"), &error),
             qPrintable(error));

    ImuSample first = sampleAt(1234, QVector3D(0.1f, -0.2f, 0.98f),
                               QVector3D(1.0f, 2.0f, 3.0f));
    first.sequence = 77;
    ImuSnapshot snap;
    snap.rollDeg = 4.5;
    snap.drivingScore = 96;
    QVERIFY(writer.append(first, snap, QStringLiteral("hard_brake"), &error));
    writer.close();

    const QList<ImuSample> samples = readImuCsv(path, &error);
    QCOMPARE(samples.size(), 1);
    QCOMPARE(samples.first().timestampNs, first.timestampNs);
    QCOMPARE(samples.first().sequence, quint32(77));
    QVERIFY((samples.first().accelG - first.accelG).length() < 0.0001f);
    QVERIFY((samples.first().gyroDps - first.gyroDps).length() < 0.0001f);
}

void ImuProcessorTests::uapiSampleDecodesRangesAndAxisMap()
{
    ImuSampleV1 raw = {};
    raw.timestamp_ns = 987654321ULL;
    raw.sequence = 42;
    raw.accel[0] = 4096;
    raw.accel[1] = -2048;
    raw.accel[2] = 8192;
    raw.gyro[0] = 655;
    raw.gyro[1] = -1310;
    raw.gyro[2] = 327;

    ImuAxisMap map;
    map.sourceIndex = {{ 1, 0, 2 }};
    map.sign = {{ 1, -1, 1 }};
    ImuSample decoded;
    QString error;
    QVERIFY2(decodeImuSample(raw, 8, 500, map, &decoded, &error), qPrintable(error));
    QCOMPARE(decoded.timestampNs, raw.timestamp_ns);
    QCOMPARE(decoded.sequence, quint32(42));
    QVERIFY((decoded.accelG - QVector3D(-0.5f, -1.0f, 2.0f)).length() < 0.001f);
    QVERIFY((decoded.gyroDps - QVector3D(-20.0f, -10.0f, 5.0f)).length() < 0.05f);
}

void ImuProcessorTests::legacyDriverFrameDecodesCurrentKernelLayout()
{
    Mpu6050LegacyFrame raw = {};
    raw.gyroX = 164;
    raw.gyroY = -328;
    raw.gyroZ = 82;
    raw.accelX = 8192;
    raw.accelY = -4096;
    raw.accelZ = 16384;
    raw.temperatureRaw = 340;

    ImuAxisMap map;
    map.sourceIndex = {{ 1, 0, 2 }};
    map.sign = {{ 1, -1, 1 }};

    ImuSample decoded;
    QString error;
    QVERIFY2(decodeLegacyMpu6050Frame(raw, 123456789ULL, 9, map, &decoded, &error),
             qPrintable(error));
    QCOMPARE(decoded.timestampNs, 123456789ULL);
    QCOMPARE(decoded.sequence, quint32(9));
    QVERIFY((decoded.accelG - QVector3D(-0.25f, -0.5f, 1.0f)).length() < 0.001f);
    QVERIFY((decoded.gyroDps - QVector3D(-20.0f, -10.0f, 5.0f)).length() < 0.15f);
    QVERIFY(qAbs(decoded.temperatureC - 37.53) < 0.01);
}

void ImuProcessorTests::eventModelAppendsAndAcknowledges()
{
    ImuEventModel model;
    ImuEvent event;
    event.type = ImuEventType::SuspectedImpact;
    event.title = QStringLiteral("疑似强冲击，请检查车辆");
    event.detail = QStringLiteral("峰值 3.20 g");
    event.severity = 3;
    model.appendEvent(event);

    QCOMPARE(model.rowCount(), 1);
    QCOMPARE(model.data(model.index(0, 0), ImuEventModel::TitleRole).toString(), event.title);
    QVERIFY(model.data(model.index(0, 0), ImuEventModel::CriticalRole).toBool());
    QVERIFY(model.acknowledge(0));
    QCOMPARE(model.rowCount(), 0);
    QVERIFY(!model.acknowledge(0));
}

void ImuProcessorTests::serviceReplaysAndPublishesCalibratedSnapshot()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString csvPath = dir.filePath(QStringLiteral("replay.csv"));
    const QString configPath = dir.filePath(QStringLiteral("config.json"));

    QFile configFile(configPath);
    QVERIFY(configFile.open(QIODevice::WriteOnly));
    configFile.write(R"({
        "axis_map":{"forward":"+x","left":"+y","up":"+z"},
        "calibration":{"samples":20}
    })");
    configFile.close();

    ImuCsvLogWriter writer;
    QString error;
    QVERIFY2(writer.open(csvPath, 200, 8, 500, QStringLiteral("+x,+y,+z"), &error),
             qPrintable(error));
    for (int i = 0; i < 80; ++i) {
        ImuSample sample = sampleAt(1000 + i * 5);
        sample.sequence = static_cast<quint32>(i);
        QVERIFY(writer.append(sample, ImuSnapshot(), QString(), &error));
    }
    writer.close();

    qputenv("COCKPIT_IMU_CONFIG", configPath.toUtf8());
    qputenv("COCKPIT_IMU_REPLAY", csvPath.toUtf8());
    qputenv("COCKPIT_IMU_REPLAY_FAST", "1");
    ImuService service;
    QSignalSpy snapshotSpy(&service, &ImuService::snapshotChanged);
    service.start();
    QTRY_VERIFY_WITH_TIMEOUT(service.available(), 1000);
    QTRY_VERIFY_WITH_TIMEOUT(service.calibrated(), 1000);
    QVERIFY(snapshotSpy.count() > 0);
    service.stop();
    qunsetenv("COCKPIT_IMU_CONFIG");
    qunsetenv("COCKPIT_IMU_REPLAY");
    qunsetenv("COCKPIT_IMU_REPLAY_FAST");
}

void ImuProcessorTests::serviceReadsLegacyDriverFramesWithoutIoctl()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString devicePath = dir.filePath(QStringLiteral("mpu6050-legacy.bin"));
    const QString configPath = dir.filePath(QStringLiteral("config.json"));

    QFile configFile(configPath);
    QVERIFY(configFile.open(QIODevice::WriteOnly));
    configFile.write(R"({
        "axis_map":{"forward":"+x","left":"+y","up":"+z"},
        "calibration":{"samples":20}
    })");
    configFile.close();

    QFile deviceFile(devicePath);
    QVERIFY(deviceFile.open(QIODevice::WriteOnly));
    for (int i = 0; i < 120; ++i) {
        Mpu6050LegacyFrame frame = {};
        frame.accelZ = 16384;
        QVERIFY(deviceFile.write(reinterpret_cast<const char *>(&frame),
                                 sizeof(frame)) == sizeof(frame));
    }
    deviceFile.close();

    qputenv("COCKPIT_IMU_CONFIG", configPath.toUtf8());
    qputenv("COCKPIT_IMU_DEVICE", devicePath.toUtf8());
    qunsetenv("COCKPIT_IMU_REPLAY");
    qunsetenv("COCKPIT_IMU_REPLAY_FAST");

    ImuService service;
    service.start();
    QTRY_VERIFY_WITH_TIMEOUT(service.calibrated(), 1500);
    QVERIFY(service.available());
    service.stop();

    qunsetenv("COCKPIT_IMU_CONFIG");
    qunsetenv("COCKPIT_IMU_DEVICE");
}

void ImuProcessorTests::serviceControlsTripCalibrationAndRecording()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString csvPath = dir.filePath(QStringLiteral("driving.csv"));
    const QString configPath = dir.filePath(QStringLiteral("config.json"));

    QFile configFile(configPath);
    QVERIFY(configFile.open(QIODevice::WriteOnly));
    configFile.write(R"({
        "axis_map":{"forward":"+x","left":"+y","up":"+z"},
        "calibration":{"samples":20},
        "events":{"hard_acceleration_g":0.25}
    })");
    configFile.close();

    ImuCsvLogWriter writer;
    QString error;
    QVERIFY(writer.open(csvPath, 200, 8, 500, QStringLiteral("+x,+y,+z"), &error));
    for (int i = 0; i < 20; ++i) {
        ImuSample sample = sampleAt(1000 + i * 5);
        sample.sequence = static_cast<quint32>(i);
        QVERIFY(writer.append(sample, ImuSnapshot(), QString(), &error));
    }
    for (int i = 20; i < 120; ++i) {
        ImuSample sample = sampleAt(1000 + i * 5, QVector3D(0.5f, 0.0f, 1.0f));
        sample.sequence = static_cast<quint32>(i);
        QVERIFY(writer.append(sample, ImuSnapshot(), QString(), &error));
    }
    writer.close();

    qputenv("COCKPIT_IMU_CONFIG", configPath.toUtf8());
    qputenv("COCKPIT_IMU_REPLAY", csvPath.toUtf8());
    qputenv("COCKPIT_IMU_REPLAY_FAST", "1");
    qputenv("COCKPIT_IMU_RECORD_DIR", dir.path().toUtf8());
    ImuService service;
    service.start();
    QTRY_VERIFY_WITH_TIMEOUT(service.calibrated(), 1000);
    QTRY_VERIFY_WITH_TIMEOUT(service.drivingScore() < 100, 1000);

    service.resetTrip();
    QTRY_COMPARE_WITH_TIMEOUT(service.drivingScore(), 100, 1000);

    service.recalibrate();
    QTRY_COMPARE_WITH_TIMEOUT(service.calibrationState(), QStringLiteral("collecting"), 1000);

    service.setRecording(true);
    QTRY_VERIFY_WITH_TIMEOUT(service.recording(), 1000);
    QVERIFY(QFileInfo::exists(service.recordingPath()));
    service.setRecording(false);
    QTRY_VERIFY_WITH_TIMEOUT(!service.recording(), 1000);
    service.stop();

    qunsetenv("COCKPIT_IMU_CONFIG");
    qunsetenv("COCKPIT_IMU_REPLAY");
    qunsetenv("COCKPIT_IMU_REPLAY_FAST");
    qunsetenv("COCKPIT_IMU_RECORD_DIR");
}

void ImuProcessorTests::alertTonePcmHasExpectedEnvelope()
{
    const QByteArray pcm = makeAlertTonePcm(16000, 250);
    QCOMPARE(pcm.size(), 16000 / 4 * 2);
    const qint16 *samples = reinterpret_cast<const qint16 *>(pcm.constData());
    const int count = pcm.size() / int(sizeof(qint16));
    QVERIFY(qAbs(samples[0]) < 100);
    QVERIFY(qAbs(samples[count - 1]) < 1000);
    qint16 peak = 0;
    for (int i = 0; i < count; ++i)
        peak = qMax<qint16>(peak, qAbs(samples[i]));
    QVERIFY(peak > 8000);
    QVERIFY(peak < 30000);
}

void ImuProcessorTests::motionContextDatagramUsesVersionedSchema()
{
    ImuSnapshot snapshot;
    snapshot.calibrated = true;
    snapshot.motionState = QStringLiteral("likely_moving");
    snapshot.visionConfidence = 0.42;
    snapshot.rollDeg = 3.5;
    snapshot.pitchDeg = -2.0;
    const QJsonDocument document = QJsonDocument::fromJson(
        buildMotionContextDatagram(snapshot, true, 1234));

    QVERIFY(document.isObject());
    const QJsonObject object = document.object();
    QCOMPARE(object.value(QStringLiteral("version")).toInt(), 1);
    QCOMPARE(object.value(QStringLiteral("available")).toBool(), true);
    QCOMPARE(object.value(QStringLiteral("calibrated")).toBool(), true);
    QCOMPARE(object.value(QStringLiteral("motion_state")).toString(),
             QStringLiteral("likely_moving"));
    QCOMPARE(object.value(QStringLiteral("monotonic_ms")).toDouble(), 1234.0);
    QVERIFY(qAbs(object.value(QStringLiteral("vision_confidence")).toDouble()
                 - 0.42) < 0.001);
}

// ImuService publishes worker-thread snapshots through queued invocations, so
// this integration test suite needs a real QCoreApplication event dispatcher.
QTEST_GUILESS_MAIN(ImuProcessorTests)

#include "imu_tests.moc"
