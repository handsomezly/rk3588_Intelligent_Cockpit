#include "imuio.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>

namespace {

void setError(QString *target, const QString &text)
{
    if (target)
        *target = text;
}

bool parseAxis(const QString &text, int *index, int *sign)
{
    const QString value = text.trimmed().toLower();
    if (value.size() != 2 || (value.at(0) != QLatin1Char('+')
                              && value.at(0) != QLatin1Char('-')))
        return false;
    const QChar axis = value.at(1);
    if (axis == QLatin1Char('x'))
        *index = 0;
    else if (axis == QLatin1Char('y'))
        *index = 1;
    else if (axis == QLatin1Char('z'))
        *index = 2;
    else
        return false;
    *sign = value.at(0) == QLatin1Char('-') ? -1 : 1;
    return true;
}

double component(const QVector3D &vector, int index)
{
    if (index == 0)
        return vector.x();
    if (index == 1)
        return vector.y();
    return vector.z();
}

QString axisText(int index, int sign)
{
    const char axis = index == 0 ? 'x' : index == 1 ? 'y' : 'z';
    return QStringLiteral("%1%2").arg(sign < 0 ? QLatin1String("-") : QLatin1String("+"))
                                  .arg(QLatin1Char(axis));
}

} // namespace

QVector3D ImuAxisMap::apply(const QVector3D &source) const
{
    return QVector3D(
        static_cast<float>(component(source, sourceIndex[0]) * sign[0]),
        static_cast<float>(component(source, sourceIndex[1]) * sign[1]),
        static_cast<float>(component(source, sourceIndex[2]) * sign[2]));
}

QString ImuAxisMap::description() const
{
    return axisText(sourceIndex[0], sign[0]) + QLatin1Char(',')
         + axisText(sourceIndex[1], sign[1]) + QLatin1Char(',')
         + axisText(sourceIndex[2], sign[2]);
}

bool loadImuConfig(const QString &path,
                   ImuConfig *config,
                   ImuAxisMap *axisMap,
                   QString *errorText)
{
    if (!config || !axisMap) {
        setError(errorText, QStringLiteral("IMU 配置输出参数为空"));
        return false;
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        setError(errorText, QStringLiteral("无法读取 IMU 配置：%1").arg(file.errorString()));
        return false;
    }
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        setError(errorText, QStringLiteral("IMU 配置 JSON 无效：%1").arg(parseError.errorString()));
        return false;
    }

    ImuConfig nextConfig = *config;
    ImuAxisMap nextMap = *axisMap;
    const QJsonObject root = document.object();
    if (root.contains(QStringLiteral("axis_map"))) {
        const QJsonObject axes = root.value(QStringLiteral("axis_map")).toObject();
        const QStringList names = {
            QStringLiteral("forward"), QStringLiteral("left"), QStringLiteral("up")
        };
        QSet<int> used;
        for (int i = 0; i < names.size(); ++i) {
            int source = -1;
            int axisSign = 1;
            if (!parseAxis(axes.value(names.at(i)).toString(), &source, &axisSign)) {
                setError(errorText, QStringLiteral("轴映射 %1 无效").arg(names.at(i)));
                return false;
            }
            if (used.contains(source)) {
                setError(errorText, QStringLiteral("轴映射存在重复源轴"));
                return false;
            }
            used.insert(source);
            nextMap.sourceIndex[static_cast<size_t>(i)] = source;
            nextMap.sign[static_cast<size_t>(i)] = axisSign;
        }
    }

    const QJsonObject calibration = root.value(QStringLiteral("calibration")).toObject();
    if (calibration.contains(QStringLiteral("samples"))) {
        nextConfig.calibrationSampleCount = qBound(
            20, calibration.value(QStringLiteral("samples")).toInt(), 4000);
        nextConfig.calibrationMaxSamples = qMax(nextConfig.calibrationMaxSamples,
                                                 nextConfig.calibrationSampleCount);
    }
    const QJsonObject events = root.value(QStringLiteral("events")).toObject();
    if (events.contains(QStringLiteral("hard_brake_g")))
        nextConfig.hardBrakeEnterG = events.value(QStringLiteral("hard_brake_g")).toDouble();
    if (events.contains(QStringLiteral("hard_acceleration_g")))
        nextConfig.hardAccelerationEnterG = events.value(QStringLiteral("hard_acceleration_g")).toDouble();
    if (events.contains(QStringLiteral("hard_turn_g")))
        nextConfig.hardTurnEnterG = events.value(QStringLiteral("hard_turn_g")).toDouble();
    if (events.contains(QStringLiteral("bump_g")))
        nextConfig.bumpEnterG = events.value(QStringLiteral("bump_g")).toDouble();
    if (events.contains(QStringLiteral("vibration_rms_g")))
        nextConfig.vibrationEnterRmsG = events.value(QStringLiteral("vibration_rms_g")).toDouble();
    if (events.contains(QStringLiteral("impact_g")))
        nextConfig.impactAccelG = events.value(QStringLiteral("impact_g")).toDouble();
    if (events.contains(QStringLiteral("rollover_deg")))
        nextConfig.rolloverAngleDeg = events.value(QStringLiteral("rollover_deg")).toDouble();
    if (events.contains(QStringLiteral("mounting_deg")))
        nextConfig.mountingAngleDeg = events.value(QStringLiteral("mounting_deg")).toDouble();

    *config = nextConfig;
    *axisMap = nextMap;
    setError(errorText, QString());
    return true;
}

ImuCsvLogWriter::ImuCsvLogWriter()
    : m_stream(&m_file)
{
    m_stream.setRealNumberNotation(QTextStream::FixedNotation);
    m_stream.setRealNumberPrecision(6);
}

ImuCsvLogWriter::~ImuCsvLogWriter()
{
    close();
}

bool ImuCsvLogWriter::open(const QString &path,
                           int sampleRateHz,
                           int accelRangeG,
                           int gyroRangeDps,
                           const QString &axisMap,
                           QString *errorText)
{
    close();
    m_file.setFileName(path);
    if (!m_file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        setError(errorText, QStringLiteral("无法创建 IMU 日志：%1").arg(m_file.errorString()));
        return false;
    }
    m_stream << "# cockpit_imu_csv_v1\n"
             << "# created_utc=" << QDateTime::currentDateTimeUtc().toString(Qt::ISODate) << '\n'
             << "# sample_rate_hz=" << sampleRateHz << '\n'
             << "# accel_range_g=" << accelRangeG << '\n'
             << "# gyro_range_dps=" << gyroRangeDps << '\n'
             << "# axis_map=" << axisMap << '\n'
             << "timestamp_ns,sequence,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps,"
                "roll_deg,pitch_deg,yaw_cue_deg,score,smoothness,event\n";
    m_stream.flush();
    setError(errorText, QString());
    return true;
}

bool ImuCsvLogWriter::append(const ImuSample &sample,
                             const ImuSnapshot &snapshot,
                             const QString &eventName,
                             QString *errorText)
{
    if (!m_file.isOpen()) {
        setError(errorText, QStringLiteral("IMU 日志尚未打开"));
        return false;
    }
    QString safeEvent = eventName;
    safeEvent.replace(QLatin1Char(','), QLatin1Char('_'));
    safeEvent.replace(QLatin1Char('\n'), QLatin1Char(' '));
    m_stream << sample.timestampNs << ',' << sample.sequence << ','
             << sample.accelG.x() << ',' << sample.accelG.y() << ',' << sample.accelG.z() << ','
             << sample.gyroDps.x() << ',' << sample.gyroDps.y() << ',' << sample.gyroDps.z() << ','
             << snapshot.rollDeg << ',' << snapshot.pitchDeg << ',' << snapshot.yawCueDeg << ','
             << snapshot.drivingScore << ',' << snapshot.smoothnessScore << ',' << safeEvent << '\n';
    if (m_stream.status() != QTextStream::Ok) {
        setError(errorText, QStringLiteral("写入 IMU 日志失败"));
        return false;
    }
    setError(errorText, QString());
    return true;
}

void ImuCsvLogWriter::close()
{
    if (!m_file.isOpen())
        return;
    m_stream.flush();
    m_file.close();
}

QList<ImuSample> readImuCsv(const QString &path, QString *errorText)
{
    QList<ImuSample> samples;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        setError(errorText, QStringLiteral("无法读取 IMU 日志：%1").arg(file.errorString()));
        return samples;
    }
    QTextStream stream(&file);
    while (!stream.atEnd()) {
        const QString line = stream.readLine().trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#'))
            || line.startsWith(QStringLiteral("timestamp_ns,")))
            continue;
        const QStringList fields = line.split(QLatin1Char(','));
        if (fields.size() < 8) {
            setError(errorText, QStringLiteral("IMU 日志行字段不足"));
            return QList<ImuSample>();
        }
        bool okTimestamp = false;
        bool okSequence = false;
        ImuSample sample;
        sample.timestampNs = fields.at(0).toULongLong(&okTimestamp);
        sample.sequence = fields.at(1).toUInt(&okSequence);
        bool ok[6] = { false, false, false, false, false, false };
        const float ax = fields.at(2).toFloat(&ok[0]);
        const float ay = fields.at(3).toFloat(&ok[1]);
        const float az = fields.at(4).toFloat(&ok[2]);
        const float gx = fields.at(5).toFloat(&ok[3]);
        const float gy = fields.at(6).toFloat(&ok[4]);
        const float gz = fields.at(7).toFloat(&ok[5]);
        if (!okTimestamp || !okSequence
            || !ok[0] || !ok[1] || !ok[2] || !ok[3] || !ok[4] || !ok[5]) {
            setError(errorText, QStringLiteral("IMU 日志包含无效数值"));
            return QList<ImuSample>();
        }
        sample.accelG = QVector3D(ax, ay, az);
        sample.gyroDps = QVector3D(gx, gy, gz);
        samples.append(sample);
    }
    setError(errorText, QString());
    return samples;
}
