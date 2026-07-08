#ifndef GUARDIANEVENTPUBLISHER_H
#define GUARDIANEVENTPUBLISHER_H

#include <QObject>
#include <QJsonObject>
#include <QString>

class GuardianEventPublisher : public QObject
{
    Q_OBJECT

public:
    explicit GuardianEventPublisher(QObject *fatigueService,
                                    QObject *imuService,
                                    QObject *parent = nullptr);

    void processCameraState(bool connected, bool enabled,
                            const QString &state, qint64 timestampMs = 0);
    void processFatigueState(bool cameraEnabled, bool alarm,
                             qint64 timestampMs = 0);
    void processImuCritical(const QString &type, int severity,
                            const QString &title, const QString &detail,
                            qint64 timestampMs = 0);

private slots:
    void syncFatigueState();
    void onImuCritical(const QString &type, int severity,
                       const QString &title, const QString &detail);

private:
    void sendEvent(const QString &type, qint64 timestampMs,
                   const QJsonObject &fields = QJsonObject());

    QObject *m_fatigueService = nullptr;
    QString m_socketPath;
    bool m_tripActive = false;
    bool m_lastFatigueAlarm = false;
};

#endif // GUARDIANEVENTPUBLISHER_H

