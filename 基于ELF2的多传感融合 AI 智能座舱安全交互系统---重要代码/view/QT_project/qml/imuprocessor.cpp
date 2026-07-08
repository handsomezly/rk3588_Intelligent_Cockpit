#include "imuprocessor.h"

#include <QtMath>

namespace {

constexpr double kNsPerSecond = 1000000000.0;

double clampValue(double value, double low, double high)
{
    return qMax(low, qMin(high, value));
}

int severityFor(double value, double threshold)
{
    const double ratio = threshold > 0.0 ? qAbs(value) / threshold : 1.0;
    if (ratio >= 2.0)
        return 3;
    if (ratio >= 1.4)
        return 2;
    return 1;
}

} // namespace

ImuProcessor::ImuProcessor(const ImuConfig &config)
    : m_config(config)
{
    reset();
}

void ImuProcessor::reset()
{
    m_snapshot = ImuSnapshot();
    m_events.clear();
    m_calibrationAttempts = 0;
    m_calibrationAccepted = 0;
    m_accelSum = QVector3D();
    m_gyroSum = QVector3D();
    m_accelBias = QVector3D();
    m_gyroBias = QVector3D();
    m_lastTimestampNs = 0;
    m_manoeuvreAccel = QVector3D();
    m_brakeDetector = Detector();
    m_accelerationDetector = Detector();
    m_turnDetector = Detector();
    m_bumpDetector = Detector();
    m_vibrationDetector = Detector();
    m_impactDetector = Detector();
    m_rolloverDetector = Detector();
    m_mountingDetector = Detector();
    m_vibrationWindow.clear();
    m_vibrationSquareSum = 0.0;
    m_vibrationRms = 0.0;
}

void ImuProcessor::startCalibration()
{
    reset();
    m_snapshot.calibrationState = ImuCalibrationState::Collecting;
}

void ImuProcessor::resetTrip()
{
    m_snapshot.drivingScore = 100;
    m_events.clear();
}

void ImuProcessor::processSample(const ImuSample &sample)
{
    m_snapshot.rawAccelG = sample.accelG;
    m_snapshot.gyroDps = sample.gyroDps - m_gyroBias;

    if (m_snapshot.calibrationState == ImuCalibrationState::Collecting) {
        processCalibration(sample);
        m_lastTimestampNs = sample.timestampNs;
        return;
    }
    if (!m_snapshot.calibrated)
        return;

    if (m_lastTimestampNs == 0 || sample.timestampNs <= m_lastTimestampNs) {
        m_lastTimestampNs = sample.timestampNs;
        return;
    }
    const double dt = (sample.timestampNs - m_lastTimestampNs) / kNsPerSecond;
    m_lastTimestampNs = sample.timestampNs;
    if (dt <= 0.0 || dt > 0.1)
        return;

    updateAttitudeAndFeatures(sample, dt);
    updateEvents(sample.timestampNs);
}

void ImuProcessor::processCalibration(const ImuSample &sample)
{
    ++m_calibrationAttempts;
    const double accelNorm = sample.accelG.length();
    const double gyroNorm = sample.gyroDps.length();
    const bool stable = accelNorm >= m_config.calibrationAccelMinG
                     && accelNorm <= m_config.calibrationAccelMaxG
                     && gyroNorm <= m_config.calibrationGyroMaxDps;
    if (stable) {
        m_accelSum += sample.accelG;
        m_gyroSum += sample.gyroDps;
        ++m_calibrationAccepted;
    }

    if (m_calibrationAccepted >= m_config.calibrationSampleCount) {
        finishCalibration();
    } else if (m_calibrationAttempts >= m_config.calibrationMaxSamples) {
        m_snapshot.calibrationState = ImuCalibrationState::Failed;
        m_snapshot.calibrated = false;
    }
}

void ImuProcessor::finishCalibration()
{
    const float n = static_cast<float>(qMax(1, m_calibrationAccepted));
    const QVector3D meanAccel = m_accelSum / n;
    m_gyroBias = m_gyroSum / n;
    m_accelBias = meanAccel - QVector3D(0.0f, 0.0f, 1.0f);
    m_snapshot.calibrationState = ImuCalibrationState::Ready;
    m_snapshot.calibrated = true;
    m_snapshot.rollDeg = 0.0;
    m_snapshot.pitchDeg = 0.0;
    m_snapshot.yawCueDeg = 0.0;
    m_snapshot.linearAccelG = QVector3D();
}

void ImuProcessor::updateAttitudeAndFeatures(const ImuSample &sample, double dt)
{
    const QVector3D accel = sample.accelG - m_accelBias;
    const QVector3D gyro = sample.gyroDps - m_gyroBias;
    m_snapshot.gyroDps = gyro;

    const double accelNorm = accel.length();
    const double rollAcc = qRadiansToDegrees(qAtan2(accel.y(), accel.z()));
    const double pitchAcc = qRadiansToDegrees(
        qAtan2(-accel.x(), qSqrt(accel.y() * accel.y() + accel.z() * accel.z())));
    const double alpha = qExp(-dt / qMax(0.01, m_config.attitudeTimeConstantSeconds));
    // Accelerometer correction is only trustworthy while its magnitude is
    // close to gravity. Sustained braking/acceleration otherwise looks like a
    // tilt and gets incorrectly removed by the gravity-separation step.
    const double correction = qAbs(accelNorm - 1.0) <= 0.08 ? alpha : 1.0;
    m_snapshot.rollDeg = correction * (m_snapshot.rollDeg + gyro.x() * dt)
                       + (1.0 - correction) * rollAcc;
    m_snapshot.pitchDeg = correction * (m_snapshot.pitchDeg + gyro.y() * dt)
                        + (1.0 - correction) * pitchAcc;

    const double yawDecay = qExp(-dt / qMax(0.1, m_config.yawLeakSeconds));
    m_snapshot.yawCueDeg = clampValue(
        (m_snapshot.yawCueDeg + gyro.z() * dt) * yawDecay, -45.0, 45.0);

    const double roll = qDegreesToRadians(m_snapshot.rollDeg);
    const double pitch = qDegreesToRadians(m_snapshot.pitchDeg);
    const QVector3D gravity(
        static_cast<float>(-qSin(pitch)),
        static_cast<float>(qSin(roll) * qCos(pitch)),
        static_cast<float>(qCos(roll) * qCos(pitch)));
    m_snapshot.linearAccelG = accel - gravity;

    const double filterAlpha = 1.0 - qExp(-dt / qMax(0.01, m_config.manoeuvreFilterSeconds));
    m_manoeuvreAccel += (m_snapshot.linearAccelG - m_manoeuvreAccel)
                       * static_cast<float>(filterAlpha);

    const double dynamic = m_snapshot.linearAccelG.length();
    const double angular = gyro.length();
    const double vertical = qAbs(m_snapshot.linearAccelG.z());
    m_vibrationWindow.enqueue(qMakePair(sample.timestampNs, vertical * vertical));
    m_vibrationSquareSum += vertical * vertical;
    const quint64 vibrationCutoff = sample.timestampNs > 1000000000ULL
                                      ? sample.timestampNs - 1000000000ULL : 0;
    while (!m_vibrationWindow.isEmpty()
           && m_vibrationWindow.head().first < vibrationCutoff) {
        m_vibrationSquareSum -= m_vibrationWindow.dequeue().second;
    }
    m_vibrationRms = m_vibrationWindow.isEmpty()
        ? 0.0
        : qSqrt(qMax(0.0, m_vibrationSquareSum / m_vibrationWindow.size()));

    if (dynamic < 0.025 && angular < 1.0)
        m_snapshot.motionState = QStringLiteral("stationary");
    else if (dynamic < 0.08 && angular < 4.0)
        m_snapshot.motionState = QStringLiteral("idle_vibration");
    else
        m_snapshot.motionState = QStringLiteral("likely_moving");

    const double disturbance = qMax(qMax(dynamic / 0.8, angular / 120.0),
                                    m_vibrationRms / 0.25);
    m_snapshot.visionConfidence = clampValue(1.0 - disturbance, 0.2, 1.0);
    m_snapshot.smoothnessScore = qBound(
        0, qRound(100.0 - m_vibrationRms * 250.0 - vertical * 30.0), 100);
}

void ImuProcessor::updateEvents(quint64 timestampNs)
{
    updateDetector(m_brakeDetector,
                   ImuEventType::HardBrake,
                   m_manoeuvreAccel.x() <= m_config.hardBrakeEnterG,
                   m_manoeuvreAccel.x() >= m_config.hardBrakeReleaseG,
                   qAbs(m_manoeuvreAccel.x()),
                   timestampNs,
                   m_config.hardBrakeHoldMs,
                   m_config.manoeuvreCooldownMs);
    updateDetector(m_accelerationDetector,
                   ImuEventType::HardAcceleration,
                   m_manoeuvreAccel.x() >= m_config.hardAccelerationEnterG,
                   m_manoeuvreAccel.x() <= m_config.hardAccelerationReleaseG,
                   qAbs(m_manoeuvreAccel.x()),
                   timestampNs,
                   m_config.hardAccelerationHoldMs,
                   m_config.manoeuvreCooldownMs);
    updateDetector(m_turnDetector,
                   ImuEventType::HardTurn,
                   qAbs(m_manoeuvreAccel.y()) >= m_config.hardTurnEnterG,
                   qAbs(m_manoeuvreAccel.y()) <= m_config.hardTurnReleaseG,
                   qAbs(m_manoeuvreAccel.y()),
                   timestampNs,
                   m_config.hardTurnHoldMs,
                   m_config.manoeuvreCooldownMs);

    const double vertical = qAbs(m_snapshot.linearAccelG.z());
    updateDetector(m_bumpDetector,
                   ImuEventType::Bump,
                   vertical >= m_config.bumpEnterG,
                   vertical <= m_config.bumpReleaseG,
                   vertical,
                   timestampNs,
                   m_config.bumpHoldMs,
                   m_config.bumpCooldownMs);
    updateDetector(m_vibrationDetector,
                   ImuEventType::SevereVibration,
                   m_vibrationRms >= m_config.vibrationEnterRmsG,
                   m_vibrationRms <= m_config.vibrationReleaseRmsG,
                   m_vibrationRms,
                   timestampNs,
                   m_config.vibrationHoldMs,
                   m_config.vibrationCooldownMs);

    const double linearNorm = m_snapshot.linearAccelG.length();
    const double gyroNorm = m_snapshot.gyroDps.length();
    updateDetector(m_impactDetector,
                   ImuEventType::SuspectedImpact,
                   linearNorm >= m_config.impactAccelG
                       && gyroNorm >= m_config.impactGyroDps,
                   linearNorm < m_config.impactAccelG * 0.5
                       || gyroNorm < m_config.impactGyroDps * 0.5,
                   linearNorm,
                   timestampNs,
                   m_config.impactHoldMs,
                   m_config.riskCooldownMs);

    const double tilt = qMax(qAbs(m_snapshot.rollDeg), qAbs(m_snapshot.pitchDeg));
    updateDetector(m_rolloverDetector,
                   ImuEventType::RolloverRisk,
                   tilt >= m_config.rolloverAngleDeg,
                   tilt <= m_config.rolloverReleaseDeg,
                   tilt,
                   timestampNs,
                   m_config.rolloverHoldMs,
                   m_config.riskCooldownMs);
    const bool lowDynamic = m_snapshot.linearAccelG.length() < 0.08
                         && m_snapshot.gyroDps.length() < 4.0;
    updateDetector(m_mountingDetector,
                   ImuEventType::MountingAnomaly,
                   lowDynamic && tilt >= m_config.mountingAngleDeg,
                   !lowDynamic || tilt <= m_config.mountingReleaseDeg,
                   tilt,
                   timestampNs,
                   m_config.mountingHoldMs,
                   m_config.riskCooldownMs);
}

void ImuProcessor::updateDetector(Detector &detector,
                                  ImuEventType type,
                                  bool enter,
                                  bool release,
                                  double magnitude,
                                  quint64 timestampNs,
                                  int holdMs,
                                  int cooldownMs)
{
    if (detector.active) {
        detector.peak = qMax(detector.peak, magnitude);
        if (release) {
            detector.active = false;
            detector.candidate = false;
            detector.peak = 0.0;
        }
        return;
    }
    if (timestampNs < detector.cooldownUntilNs)
        return;
    if (!enter) {
        detector.candidate = false;
        detector.peak = 0.0;
        return;
    }
    if (!detector.candidate) {
        detector.candidate = true;
        detector.candidateSinceNs = timestampNs;
        detector.peak = magnitude;
        return;
    }
    detector.peak = qMax(detector.peak, magnitude);
    const quint64 heldNs = timestampNs - detector.candidateSinceNs;
    if (heldNs >= static_cast<quint64>(holdMs) * 1000000ULL) {
        detector.active = true;
        detector.candidate = false;
        detector.cooldownUntilNs = timestampNs
                                 + static_cast<quint64>(cooldownMs) * 1000000ULL;
        emitEvent(type, timestampNs, detector.peak);
    }
}

void ImuProcessor::emitEvent(ImuEventType type, quint64 timestampNs, double peak)
{
    ImuEvent event;
    event.type = type;
    event.timestampNs = timestampNs;
    event.peak = peak;

    double threshold = 0.30;
    int basePenalty = 0;
    bool angularUnit = false;
    switch (type) {
    case ImuEventType::HardBrake:
        event.title = QStringLiteral("急刹车");
        threshold = qAbs(m_config.hardBrakeEnterG);
        basePenalty = 3;
        break;
    case ImuEventType::HardAcceleration:
        event.title = QStringLiteral("急加速");
        threshold = m_config.hardAccelerationEnterG;
        basePenalty = 2;
        break;
    case ImuEventType::HardTurn:
        event.title = QStringLiteral("急转弯");
        threshold = m_config.hardTurnEnterG;
        basePenalty = 2;
        break;
    case ImuEventType::Bump:
        event.title = QStringLiteral("检测到颠簸/坑洼");
        threshold = m_config.bumpEnterG;
        break;
    case ImuEventType::SevereVibration:
        event.title = QStringLiteral("行驶振动较强");
        threshold = m_config.vibrationEnterRmsG;
        break;
    case ImuEventType::SuspectedImpact:
        event.title = QStringLiteral("疑似强冲击，请检查车辆");
        threshold = m_config.impactAccelG;
        break;
    case ImuEventType::RolloverRisk:
        event.title = QStringLiteral("疑似侧翻风险，请立即检查");
        threshold = m_config.rolloverAngleDeg;
        angularUnit = true;
        break;
    case ImuEventType::MountingAnomaly:
        event.title = QStringLiteral("疑似设备移动或安装异常");
        threshold = m_config.mountingAngleDeg;
        angularUnit = true;
        break;
    default:
        event.title = QStringLiteral("驾驶动态事件");
        break;
    }
    event.severity = severityFor(peak, threshold);
    event.detail = angularUnit
        ? QStringLiteral("峰值 %1°").arg(peak, 0, 'f', 1)
        : QStringLiteral("峰值 %1 g").arg(peak, 0, 'f', 2);
    if (basePenalty > 0) {
        m_snapshot.drivingScore = qMax(0, m_snapshot.drivingScore
                                          - basePenalty * event.severity);
    }
    m_events.append(event);
}

QList<ImuEvent> ImuProcessor::takeEvents()
{
    const QList<ImuEvent> result = m_events;
    m_events.clear();
    return result;
}
