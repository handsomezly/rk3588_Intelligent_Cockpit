#ifndef IMUTYPES_H
#define IMUTYPES_H

#include <QList>
#include <QString>
#include <QVector3D>
#include <QtGlobal>

enum class ImuCalibrationState {
    Uncalibrated,
    Collecting,
    Ready,
    Failed,
};

enum class ImuEventType {
    HardBrake,
    HardAcceleration,
    HardTurn,
    Bump,
    SevereVibration,
    SuspectedImpact,
    RolloverRisk,
    MountingAnomaly,
};

struct ImuSample
{
    quint64 timestampNs = 0;
    quint32 sequence = 0;
    QVector3D accelG { 0.0f, 0.0f, 1.0f };
    QVector3D gyroDps;
    double temperatureC = 0.0;
    quint16 flags = 0;
};

struct ImuEvent
{
    ImuEventType type = ImuEventType::HardBrake;
    quint64 timestampNs = 0;
    int severity = 1;
    double peak = 0.0;
    QString title;
    QString detail;
};

struct ImuSnapshot
{
    ImuCalibrationState calibrationState = ImuCalibrationState::Uncalibrated;
    bool calibrated = false;
    QVector3D rawAccelG { 0.0f, 0.0f, 1.0f };
    QVector3D gyroDps;
    QVector3D linearAccelG;
    double rollDeg = 0.0;
    double pitchDeg = 0.0;
    double yawCueDeg = 0.0;
    QString motionState = QStringLiteral("unknown");
    int drivingScore = 100;
    int smoothnessScore = 100;
    double visionConfidence = 1.0;
};

struct ImuConfig
{
    int calibrationSampleCount = 20;
    int calibrationMaxSamples = 1200;
    double calibrationAccelMinG = 0.85;
    double calibrationAccelMaxG = 1.15;
    double calibrationGyroMaxDps = 5.0;

    double attitudeTimeConstantSeconds = 0.35;
    double yawLeakSeconds = 3.0;
    double manoeuvreFilterSeconds = 0.08;

    double hardBrakeEnterG = -0.35;
    double hardBrakeReleaseG = -0.18;
    double hardAccelerationEnterG = 0.30;
    double hardAccelerationReleaseG = 0.15;
    double hardTurnEnterG = 0.30;
    double hardTurnReleaseG = 0.15;
    int hardBrakeHoldMs = 250;
    int hardAccelerationHoldMs = 300;
    int hardTurnHoldMs = 300;
    int manoeuvreCooldownMs = 3000;

    double bumpEnterG = 0.45;
    double bumpReleaseG = 0.15;
    int bumpHoldMs = 20;
    int bumpCooldownMs = 1500;
    double vibrationEnterRmsG = 0.18;
    double vibrationReleaseRmsG = 0.10;
    int vibrationHoldMs = 1000;
    int vibrationCooldownMs = 5000;

    double impactAccelG = 2.5;
    double impactGyroDps = 150.0;
    int impactHoldMs = 30;
    double rolloverAngleDeg = 45.0;
    double rolloverReleaseDeg = 30.0;
    int rolloverHoldMs = 1000;
    double mountingAngleDeg = 8.0;
    double mountingReleaseDeg = 5.0;
    int mountingHoldMs = 5000;
    int riskCooldownMs = 10000;
};

Q_DECLARE_METATYPE(ImuCalibrationState)
Q_DECLARE_METATYPE(ImuEventType)
Q_DECLARE_METATYPE(ImuEvent)
Q_DECLARE_METATYPE(ImuSnapshot)

#endif // IMUTYPES_H
