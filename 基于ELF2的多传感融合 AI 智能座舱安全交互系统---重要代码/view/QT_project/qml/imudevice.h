#ifndef IMUDEVICE_H
#define IMUDEVICE_H

#include "imu_uapi.h"
#include "imuio.h"

struct Mpu6050LegacyFrame
{
    int16_t gyroX;
    int16_t gyroY;
    int16_t gyroZ;
    int16_t accelX;
    int16_t accelY;
    int16_t accelZ;
    int16_t temperatureRaw;
};

bool decodeImuSample(const ImuSampleV1 &raw,
                     int accelRangeG,
                     int gyroRangeDps,
                     const ImuAxisMap &axisMap,
                     ImuSample *sample,
                     QString *errorText = nullptr);

bool decodeLegacyMpu6050Frame(const Mpu6050LegacyFrame &raw,
                              quint64 timestampNs,
                              quint32 sequence,
                              const ImuAxisMap &axisMap,
                              ImuSample *sample,
                              QString *errorText = nullptr);

#endif // IMUDEVICE_H
