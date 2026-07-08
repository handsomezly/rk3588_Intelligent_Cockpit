#include "imueventmodel.h"

namespace {

QString eventTypeKey(ImuEventType type)
{
    switch (type) {
    case ImuEventType::HardBrake: return QStringLiteral("hard_brake");
    case ImuEventType::HardAcceleration: return QStringLiteral("hard_acceleration");
    case ImuEventType::HardTurn: return QStringLiteral("hard_turn");
    case ImuEventType::Bump: return QStringLiteral("bump");
    case ImuEventType::SevereVibration: return QStringLiteral("severe_vibration");
    case ImuEventType::SuspectedImpact: return QStringLiteral("suspected_impact");
    case ImuEventType::RolloverRisk: return QStringLiteral("rollover_risk");
    case ImuEventType::MountingAnomaly: return QStringLiteral("mounting_anomaly");
    }
    return QStringLiteral("unknown");
}

bool isCritical(ImuEventType type, int severity)
{
    return type == ImuEventType::SuspectedImpact
        || type == ImuEventType::RolloverRisk
        || (type == ImuEventType::MountingAnomaly && severity >= 2);
}

} // namespace

ImuEventModel::ImuEventModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ImuEventModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_entries.size();
}

QVariant ImuEventModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_entries.size())
        return QVariant();
    const Entry &entry = m_entries.at(index.row());
    switch (role) {
    case TypeRole: return eventTypeKey(entry.event.type);
    case TitleRole: return entry.event.title;
    case DetailRole: return entry.event.detail;
    case SeverityRole: return entry.event.severity;
    case TimestampRole: return entry.occurredAt.toString(QStringLiteral("hh:mm:ss"));
    case CriticalRole: return isCritical(entry.event.type, entry.event.severity);
    default: return QVariant();
    }
}

QHash<int, QByteArray> ImuEventModel::roleNames() const
{
    return {
        { TypeRole, "type" },
        { TitleRole, "title" },
        { DetailRole, "detail" },
        { SeverityRole, "severity" },
        { TimestampRole, "timestamp" },
        { CriticalRole, "critical" },
    };
}

void ImuEventModel::appendEvent(const ImuEvent &event)
{
    beginInsertRows(QModelIndex(), 0, 0);
    Entry entry;
    entry.event = event;
    entry.occurredAt = QDateTime::currentDateTime();
    m_entries.prepend(entry);
    endInsertRows();
    constexpr int kMaxEvents = 100;
    if (m_entries.size() > kMaxEvents) {
        beginRemoveRows(QModelIndex(), kMaxEvents, m_entries.size() - 1);
        while (m_entries.size() > kMaxEvents)
            m_entries.removeLast();
        endRemoveRows();
    }
}

bool ImuEventModel::acknowledge(int row)
{
    if (row < 0 || row >= m_entries.size())
        return false;
    beginRemoveRows(QModelIndex(), row, row);
    m_entries.removeAt(row);
    endRemoveRows();
    return true;
}

void ImuEventModel::clear()
{
    if (m_entries.isEmpty())
        return;
    beginResetModel();
    m_entries.clear();
    endResetModel();
}
