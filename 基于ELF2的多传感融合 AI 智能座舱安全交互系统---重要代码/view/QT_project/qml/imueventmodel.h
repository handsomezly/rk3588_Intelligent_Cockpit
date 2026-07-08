#ifndef IMUEVENTMODEL_H
#define IMUEVENTMODEL_H

#include "imutypes.h"

#include <QAbstractListModel>
#include <QDateTime>

class ImuEventModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        TypeRole = Qt::UserRole + 1,
        TitleRole,
        DetailRole,
        SeverityRole,
        TimestampRole,
        CriticalRole,
    };

    explicit ImuEventModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void appendEvent(const ImuEvent &event);
    Q_INVOKABLE bool acknowledge(int row);
    Q_INVOKABLE void clear();

private:
    struct Entry {
        ImuEvent event;
        QDateTime occurredAt;
    };
    QList<Entry> m_entries;
};

#endif // IMUEVENTMODEL_H
