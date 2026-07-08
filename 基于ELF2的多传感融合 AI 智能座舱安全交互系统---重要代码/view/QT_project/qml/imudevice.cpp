#include "imudevice.h"

namespace {

static_assert(sizeof(Mpu6050LegacyFrame) == 14,
              "Mpu6050LegacyFrame must match current kernel driver layout");

void setError(QString *target, const QString &text)
{
    if (target)
        *target = text;
}

} // namespace

bool decodeImuSample(const ImuSampleV1 &raw,
                     int accelRangeG,
                     int gyroRangeDps,
                     const ImuAxisMap &axisMap,
                     ImuSample *sample,
                     QString *errorText)
{
    if (!sample || accelRangeG <= 0 || gyroRangeDps <= 0) {
        setError(errorText, QStringLiteral("IMU 量程或输出参数无效"));
        return false;
    }
    const float accelScale = static_cast<float>(accelRangeG) / 32768.0f;
    const float gyroScale = static_cast<float>(gyroRangeDps) / 32768.0f;
    const QVector3D sensorAccel(raw.accel[0] * accelScale,
                                raw.accel[1] * accelScale,
                                raw.accel[2] * accelScale);
    const QVector3D sensorGyro(raw.gyro[0] * gyroScale,
                               raw.gyro[1] * gyroScale,
                               raw.gyro[2] * gyroScale);
    sample->timestampNs = raw.timestamp_ns;
    sample->sequence = raw.sequence;
    sample->accelG = axisMap.apply(sensorAccel);
    sample->gyroDps = axisMap.apply(sensorGyro);
    sample->temperatureC = raw.temperature_raw / 340.0 + 36.53;
    sample->flags = raw.flags;
    setError(errorText, QString());
    return true;
}

bool decodeLegacyMpu6050Frame(const Mpu6050LegacyFrame &raw,
                              quint64 timestampNs,
                              quint32 sequence,
                              const ImuAxisMap &axisMap,
                              ImuSample *sample,
                              QString *errorText)
{
    if (!sample) {
        setError(errorText, QStringLiteral("IMU 输出参数为空"));
        return false;
    }

    // driver/04_mpu6050/mpu6050.c initializes:
    //   GYRO_CONFIG  = 0x18 -> ±2000 dps, 16.4 LSB/(°/s)
    //   ACCEL_CONFIG = 0x00 -> ±2 g,    16384 LSB/g
    const QVector3D sensorAccel(raw.accelX / 16384.0f,
                                raw.accelY / 16384.0f,
                                raw.accelZ / 16384.0f);
    const QVector3D sensorGyro(raw.gyroX / 16.4f,
                               raw.gyroY / 16.4f,
                               raw.gyroZ / 16.4f);

    sample->timestampNs = timestampNs;
    sample->sequence = sequence;
    sample->accelG = axisMap.apply(sensorAccel);
    sample->gyroDps = axisMap.apply(sensorGyro);
    sample->temperatureC = raw.temperatureRaw / 340.0 + 36.53;
    sample->flags = 0;
    setError(errorText, QString());
    return true;
}
