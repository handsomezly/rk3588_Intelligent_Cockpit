#include "guardianeventpublisher.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QVariant>

#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

qint64 eventTimestamp(qint64 value)
{
    return value > 0 ? value : QDateTime::currentMSecsSinceEpoch();
}

} // namespace

GuardianEventPublisher::GuardianEventPublisher(QObject *fatigueService,
                                               QObject *imuService,
                                               QObject *parent)
    : QObject(parent)
    , m_fatigueService(fatigueService)
{
    m_socketPath = QString::fromLocal8Bit(qgetenv("COCKPIT_GUARDIAN_EVENT_SOCKET"));
    if (m_socketPath.isEmpty())
        m_socketPath = QStringLiteral("/tmp/cockpit_guardian_events.sock");

    if (m_fatigueService) {
        connect(m_fatigueService, SIGNAL(cameraControlChanged()),
                this, SLOT(syncFatigueState()));
        connect(m_fatigueService, SIGNAL(metricsChanged()),
                this, SLOT(syncFatigueState()));
    }
    if (imuService) {
        connect(imuService,
                SIGNAL(guardianCriticalEvent(QString,int,QString,QString)),
                this,
                SLOT(onImuCritical(QString,int,QString,QString)));
    }
}

void GuardianEventPublisher::syncFatigueState()
{
    if (!m_fatigueService)
        return;
    const bool connected = m_fatigueService->property("connected").toBool();
    const bool enabled = m_fatigueService->property("cameraEnabled").toBool();
    const QString state = m_fatigueService->property("cameraState").toString();
    processCameraState(connected, enabled, state);
    processFatigueState(enabled,
                        m_fatigueService->property("fatigueAlarm").toBool());
}

void GuardianEventPublisher::onImuCritical(const QString &type, int severity,
                                           const QString &title,
                                           const QString &detail)
{
    processImuCritical(type, severity, title, detail);
}

void GuardianEventPublisher::processCameraState(bool connected, bool enabled,
                                                const QString &state,
                                                qint64 timestampMs)
{
    if (!connected)
        return;
    if (enabled && state == QStringLiteral("running") && !m_tripActive) {
        m_tripActive = true;
        m_lastFatigueAlarm = false;
        sendEvent(QStringLiteral("trip_started"), timestampMs);
        return;
    }
    if (!enabled && state == QStringLiteral("off") && m_tripActive) {
        sendEvent(QStringLiteral("trip_ended"), timestampMs);
        m_tripActive = false;
        m_lastFatigueAlarm = false;
    }
}

void GuardianEventPublisher::processFatigueState(bool cameraEnabled, bool alarm,
                                                 qint64 timestampMs)
{
    if (!m_tripActive || !cameraEnabled)
        return;
    if (alarm == m_lastFatigueAlarm)
        return;
    m_lastFatigueAlarm = alarm;
    if (alarm) {
        sendEvent(QStringLiteral("alert"), timestampMs, {
            {QStringLiteral("alertType"), QStringLiteral("fatigue")},
            {QStringLiteral("level"), QStringLiteral("warning")},
            {QStringLiteral("title"), QStringLiteral("检测到疲劳风险")},
            {QStringLiteral("summary"), QStringLiteral("状态持续监测中")},
        });
    } else {
        sendEvent(QStringLiteral("recovered"), timestampMs, {
            {QStringLiteral("alertType"), QStringLiteral("fatigue")},
            {QStringLiteral("level"), QStringLiteral("normal")},
            {QStringLiteral("title"), QStringLiteral("状态已恢复")},
            {QStringLiteral("summary"), QStringLiteral("驾驶状态恢复平稳")},
        });
    }
}

void GuardianEventPublisher::processImuCritical(const QString &type, int severity,
                                                const QString &title,
                                                const QString &detail,
                                                qint64 timestampMs)
{
    sendEvent(QStringLiteral("alert"), timestampMs, {
        {QStringLiteral("alertType"), type},
        {QStringLiteral("level"), severity >= 3
            ? QStringLiteral("danger") : QStringLiteral("warning")},
        {QStringLiteral("title"), title},
        {QStringLiteral("summary"), detail},
    });
}

void GuardianEventPublisher::sendEvent(const QString &type, qint64 timestampMs,
                                       const QJsonObject &fields)
{
    QJsonObject event = fields;
    event.insert(QStringLiteral("version"), 1);
    event.insert(QStringLiteral("type"), type);
    event.insert(QStringLiteral("ts"), eventTimestamp(timestampMs));
    const QByteArray payload = QJsonDocument(event).toJson(QJsonDocument::Compact);

    const int fd = ::socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0)
        return;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    const QByteArray path = m_socketPath.toLocal8Bit();
    if (path.size() >= int(sizeof(address.sun_path))) {
        ::close(fd);
        return;
    }
    std::strncpy(address.sun_path, path.constData(), sizeof(address.sun_path) - 1);
    ::sendto(fd, payload.constData(), payload.size(), MSG_DONTWAIT,
             reinterpret_cast<const sockaddr *>(&address), sizeof(address));
    ::close(fd);
}
