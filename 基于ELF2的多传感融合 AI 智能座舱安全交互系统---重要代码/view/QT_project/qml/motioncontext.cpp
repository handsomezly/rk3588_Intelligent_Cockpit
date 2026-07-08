#include "motioncontext.h"

#include <QJsonDocument>
#include <QJsonObject>

QByteArray buildMotionContextDatagram(const ImuSnapshot &snapshot,
                                      bool available,
                                      qint64 monotonicMs)
{
    QJsonObject object;
    object.insert(QStringLiteral("version"), 1);
    object.insert(QStringLiteral("monotonic_ms"), monotonicMs);
    object.insert(QStringLiteral("available"), available);
    object.insert(QStringLiteral("calibrated"), snapshot.calibrated);
    object.insert(QStringLiteral("motion_state"), snapshot.motionState);
    object.insert(QStringLiteral("vision_confidence"), snapshot.visionConfidence);
    object.insert(QStringLiteral("roll_deg"), snapshot.rollDeg);
    object.insert(QStringLiteral("pitch_deg"), snapshot.pitchDeg);
    return QJsonDocument(object).toJson(QJsonDocument::Compact);
}
