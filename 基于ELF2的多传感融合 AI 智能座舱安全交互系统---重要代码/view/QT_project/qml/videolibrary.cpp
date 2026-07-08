#include "videolibrary.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFileInfoList>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

namespace {

const QStringList kVideoFilters = {
    QStringLiteral("*.mp4"),
    QStringLiteral("*.mkv"),
    QStringLiteral("*.mov"),
    QStringLiteral("*.webm"),
    QStringLiteral("*.avi"),
};

QString humanReadableSize(qint64 bytes)
{
    if (bytes <= 0)
        return QStringLiteral("—");
    const double kb = bytes / 1024.0;
    if (kb < 1024.0)
        return QString::number(kb, 'f', 1) + QStringLiteral(" KB");
    const double mb = kb / 1024.0;
    if (mb < 1024.0)
        return QString::number(mb, 'f', 1) + QStringLiteral(" MB");
    const double gb = mb / 1024.0;
    return QString::number(gb, 'f', 2) + QStringLiteral(" GB");
}

}

VideoLibrary::VideoLibrary(QObject *parent)
    : QObject(parent)
    , m_directory(resolveVideoDir())
{
    refresh();
}

QVariantList VideoLibrary::items() const { return m_items; }
QString VideoLibrary::directory() const { return m_directory; }

void VideoLibrary::refresh()
{
    m_items.clear();

    if (m_directory.isEmpty()) {
        emit itemsChanged();
        return;
    }

    QDir dir(m_directory);
    const QFileInfoList entries =
        dir.entryInfoList(kVideoFilters, QDir::Files | QDir::Readable, QDir::Name);

    for (const QFileInfo &info : entries) {
        QVariantMap item;
        item[QStringLiteral("title")] = info.completeBaseName();
        item[QStringLiteral("source")] = QUrl::fromLocalFile(info.absoluteFilePath());
        item[QStringLiteral("sizeBytes")] = static_cast<qlonglong>(info.size());
        item[QStringLiteral("sizeText")] = humanReadableSize(info.size());
        item[QStringLiteral("durationMs")] = -1;
        m_items.append(item);
    }

    emit itemsChanged();
}

QString VideoLibrary::resolveVideoDir()
{
    const QStringList candidates = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/assets/videos"),
        QCoreApplication::applicationDirPath() + QStringLiteral("/../assets/videos"),
        QFileInfo(QStringLiteral(__FILE__)).absolutePath() + QStringLiteral("/assets/videos"),
    };
    for (const QString &path : candidates) {
        const QFileInfo info(path);
        if (info.exists() && info.isDir())
            return info.absoluteFilePath();
    }
    return QString();
}
