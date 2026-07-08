#ifndef VIDEOLIBRARY_H
#define VIDEOLIBRARY_H

#include <QObject>
#include <QString>
#include <QVariantList>

class VideoLibrary : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    Q_PROPERTY(QString directory READ directory NOTIFY itemsChanged)

public:
    explicit VideoLibrary(QObject *parent = nullptr);

    QVariantList items() const;
    QString directory() const;

    Q_INVOKABLE void refresh();

signals:
    void itemsChanged();

private:
    static QString resolveVideoDir();

    QString m_directory;
    QVariantList m_items;
};

#endif // VIDEOLIBRARY_H
