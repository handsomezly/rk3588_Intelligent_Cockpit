#ifndef COCKPIT_IMU_UAPI_H
#define COCKPIT_IMU_UAPI_H

#include <stdint.h>
#include <sys/ioctl.h>

#define COCKPIT_IMU_ABI_VERSION 1U
#define COCKPIT_IMU_FLAG_ACCEL_SATURATED 0x0001U
#define COCKPIT_IMU_FLAG_GYRO_SATURATED  0x0002U

struct ImuSampleV1
{
    uint64_t timestamp_ns;
    uint32_t sequence;
    int16_t accel[3];
    int16_t gyro[3];
    int16_t temperature_raw;
    uint16_t flags;
    uint32_t reserved;
};

struct ImuDeviceInfoV1
{
    uint32_t abi_version;
    uint32_t sample_size;
    uint32_t sample_rate_hz;
    uint32_t accel_range_g;
    uint32_t gyro_range_dps;
    uint32_t dlpf_cfg;
    uint32_t fifo_capacity;
    uint32_t reserved;
};

struct ImuDeviceConfigV1
{
    uint32_t abi_version;
    uint32_t sample_rate_hz;
    uint32_t accel_range_g;
    uint32_t gyro_range_dps;
    uint32_t dlpf_cfg;
    uint32_t reserved[3];
};

#define COCKPIT_IMU_IOC_MAGIC 'I'
#define COCKPIT_IMU_IOC_GET_INFO \
    _IOR(COCKPIT_IMU_IOC_MAGIC, 0x01, struct ImuDeviceInfoV1)
#define COCKPIT_IMU_IOC_SET_CONFIG \
    _IOW(COCKPIT_IMU_IOC_MAGIC, 0x02, struct ImuDeviceConfigV1)

#ifdef __cplusplus
static_assert(sizeof(ImuSampleV1) == 32, "ImuSampleV1 ABI must remain 32 bytes");
static_assert(sizeof(ImuDeviceInfoV1) == 32, "ImuDeviceInfoV1 ABI must remain 32 bytes");
static_assert(sizeof(ImuDeviceConfigV1) == 32, "ImuDeviceConfigV1 ABI must remain 32 bytes");
#endif

#endif // COCKPIT_IMU_UAPI_H
