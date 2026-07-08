#ifndef IMUIO_H
#define IMUIO_H

#include "imutypes.h"

#include <QFile>
#include <QList>
#include <QTextStream>

#include <array>

struct ImuAxisMap
{
    std::array<int, 3> sourceIndex {{ 0, 1, 2 }};
    std::array<int, 3> sign {{ 1, 1, 1 }};

    QVector3D apply(const QVector3D &source) const;
    QString description() const;
};

bool loadImuConfig(const QString &path,
                   ImuConfig *config,
                   ImuAxisMap *axisMap,
                   QString *errorText = nullptr);

class ImuCsvLogWriter
{
public:
    ImuCsvLogWriter();
    ~ImuCsvLogWriter();

    bool open(const QString &path,
              int sampleRateHz,
              int accelRangeG,
              int gyroRangeDps,
              const QString &axisMap,
              QString *errorText = nullptr);
    bool append(const ImuSample &sample,
                const ImuSnapshot &snapshot,
                const QString &eventName = QString(),
                QString *errorText = nullptr);
    void close();
    bool isOpen() const { return m_file.isOpen(); }

private:
    QFile m_file;
    QTextStream m_stream;
};

QList<ImuSample> readImuCsv(const QString &path, QString *errorText = nullptr);

#endif // IMUIO_H
