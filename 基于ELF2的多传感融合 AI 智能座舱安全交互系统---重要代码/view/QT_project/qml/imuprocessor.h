#ifndef IMUPROCESSOR_H
#define IMUPROCESSOR_H

#include "imutypes.h"

#include <QQueue>

class ImuProcessor
{
public:
    explicit ImuProcessor(const ImuConfig &config = ImuConfig());

    void reset();
    void startCalibration();
    void processSample(const ImuSample &sample);
    void resetTrip();

    ImuSnapshot snapshot() const { return m_snapshot; }
    QVector3D gyroBias() const { return m_gyroBias; }
    QList<ImuEvent> takeEvents();

private:
    struct Detector {
        bool candidate = false;
        bool active = false;
        quint64 candidateSinceNs = 0;
        quint64 cooldownUntilNs = 0;
        double peak = 0.0;
    };

    void processCalibration(const ImuSample &sample);
    void finishCalibration();
    void updateAttitudeAndFeatures(const ImuSample &sample, double dt);
    void updateEvents(quint64 timestampNs);
    void updateDetector(Detector &detector,
                        ImuEventType type,
                        bool enter,
                        bool release,
                        double magnitude,
                        quint64 timestampNs,
                        int holdMs,
                        int cooldownMs);
    void emitEvent(ImuEventType type, quint64 timestampNs, double peak);

    ImuConfig m_config;
    ImuSnapshot m_snapshot;
    QList<ImuEvent> m_events;

    int m_calibrationAttempts = 0;
    int m_calibrationAccepted = 0;
    QVector3D m_accelSum;
    QVector3D m_gyroSum;
    QVector3D m_accelBias;
    QVector3D m_gyroBias;

    quint64 m_lastTimestampNs = 0;
    QVector3D m_manoeuvreAccel;
    Detector m_brakeDetector;
    Detector m_accelerationDetector;
    Detector m_turnDetector;
    Detector m_bumpDetector;
    Detector m_vibrationDetector;
    Detector m_impactDetector;
    Detector m_rolloverDetector;
    Detector m_mountingDetector;
    QQueue<QPair<quint64, double>> m_vibrationWindow;
    double m_vibrationSquareSum = 0.0;
    double m_vibrationRms = 0.0;
};

#endif // IMUPROCESSOR_H
