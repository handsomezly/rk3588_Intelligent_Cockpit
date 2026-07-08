#include "musiclibrary.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileInfoList>
#include <QRegularExpression>
#include <QRegularExpressionMatchIterator>
#include <QStringList>
#include <QTextStream>
#include <QUrl>
#include <QVariantMap>
#include <algorithm>

namespace {

const QStringList kAudioFilters = {
    QStringLiteral("*.mp3"),
    QStringLiteral("*.flac"),
    QStringLiteral("*.wav"),
    QStringLiteral("*.ogg"),
    QStringLiteral("*.m4a"),
};

const QStringList kCoverExts = {
    QStringLiteral("jpg"),
    QStringLiteral("jpeg"),
    QStringLiteral("png"),
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

QString findSibling(const QFileInfo &audio, const QStringList &exts)
{
    const QDir dir = audio.absoluteDir();
    const QString base = audio.completeBaseName();
    for (const QString &ext : exts) {
        const QString candidate = dir.absoluteFilePath(base + QStringLiteral(".") + ext);
        if (QFileInfo::exists(candidate))
            return candidate;
    }
    return QString();
}

}

MusicLibrary::MusicLibrary(QObject *parent)
    : QObject(parent)
    , m_directory(resolveMusicDir())
{
    refresh();
}

QVariantList MusicLibrary::items() const { return m_items; }
QString MusicLibrary::directory() const { return m_directory; }

void MusicLibrary::refresh()
{
    m_items.clear();

    if (m_directory.isEmpty()) {
        emit itemsChanged();
        return;
    }

    QDir dir(m_directory);
    const QFileInfoList entries =
        dir.entryInfoList(kAudioFilters, QDir::Files | QDir::Readable, QDir::Name);

    for (const QFileInfo &info : entries) {
        QVariantMap item;
        item[QStringLiteral("title")] = info.completeBaseName();
        item[QStringLiteral("source")] = QUrl::fromLocalFile(info.absoluteFilePath());
        item[QStringLiteral("sizeBytes")] = static_cast<qlonglong>(info.size());
        item[QStringLiteral("sizeText")] = humanReadableSize(info.size());
        item[QStringLiteral("durationMs")] = -1;

        const QString lrc = findSibling(info, {QStringLiteral("lrc")});
        item[QStringLiteral("lrcPath")] = lrc;

        const QString cover = findSibling(info, kCoverExts);
        item[QStringLiteral("coverUrl")] =
            cover.isEmpty() ? QUrl() : QUrl::fromLocalFile(cover);

        m_items.append(item);
    }

    emit itemsChanged();
}

QVariantList MusicLibrary::parseLrc(const QString &lrcAbsPath) const
{
    QVariantList lines;
    if (lrcAbsPath.isEmpty())
        return lines;

    QFile f(lrcAbsPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return lines;

    QTextStream in(&f);
    in.setCodec("UTF-8");
    const QString content = in.readAll();
    f.close();

    static const QRegularExpression timeRe(
        QStringLiteral(R"(\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\])"));
    static const QRegularExpression metaRe(
        QStringLiteral(R"(^\[(ti|ar|al|by|offset|length|re|ve):[^\]]*\]$)"),
        QRegularExpression::CaseInsensitiveOption);

    const QStringList rawLines = content.split(QRegularExpression(QStringLiteral("[\r\n]+")),
                                               Qt::SkipEmptyParts);
    for (const QString &rawLine : rawLines) {
        const QString trimmed = rawLine.trimmed();
        if (trimmed.isEmpty())
            continue;
        if (metaRe.match(trimmed).hasMatch())
            continue;

        QList<qint64> timestamps;
        int cursor = 0;
        auto it = timeRe.globalMatch(trimmed);
        int textStart = 0;
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            if (m.capturedStart() != cursor)
                break;
            const int mm = m.captured(1).toInt();
            const int ss = m.captured(2).toInt();
            const QString msStr = m.captured(3);
            int ms = 0;
            if (!msStr.isEmpty()) {
                if (msStr.length() == 1)
                    ms = msStr.toInt() * 100;
                else if (msStr.length() == 2)
                    ms = msStr.toInt() * 10;
                else
                    ms = msStr.toInt();
            }
            timestamps.append(static_cast<qint64>(mm) * 60000 + static_cast<qint64>(ss) * 1000 + ms);
            cursor = m.capturedEnd();
            textStart = cursor;
        }
        if (timestamps.isEmpty())
            continue;

        const QString text = trimmed.mid(textStart).trimmed();

        for (qint64 t : timestamps) {
            QVariantMap entry;
            entry[QStringLiteral("timeMs")] = t;
            entry[QStringLiteral("text")] = text;
            lines.append(entry);
        }
    }

    std::sort(lines.begin(), lines.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value(QStringLiteral("timeMs")).toLongLong()
             < b.toMap().value(QStringLiteral("timeMs")).toLongLong();
    });

    return lines;
}

QString MusicLibrary::resolveMusicDir()
{
    const QStringList candidates = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/assets/music"),
        QCoreApplication::applicationDirPath() + QStringLiteral("/../assets/music"),
        QFileInfo(QStringLiteral(__FILE__)).absolutePath() + QStringLiteral("/assets/music"),
    };
    for (const QString &path : candidates) {
        const QFileInfo info(path);
        if (info.exists() && info.isDir())
            return info.absoluteFilePath();
    }
    return QString();
}
