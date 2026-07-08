#ifndef MUSICLIBRARY_H
#define MUSICLIBRARY_H

#include <QObject>
#include <QString>
#include <QVariantList>

class MusicLibrary : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    Q_PROPERTY(QString directory READ directory NOTIFY itemsChanged)

public:
    explicit MusicLibrary(QObject *parent = nullptr);

    QVariantList items() const;
    QString directory() const;

    Q_INVOKABLE void refresh();
    Q_INVOKABLE QVariantList parseLrc(const QString &lrcAbsPath) const;

signals:
    void itemsChanged();

private:
    static QString resolveMusicDir();

    QString m_directory;
    QVariantList m_items;
};

#endif // MUSICLIBRARY_H
