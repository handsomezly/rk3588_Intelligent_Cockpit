# MPU6050 / RK3588 板端接入说明

## 1. 数据通道

Qt 进程默认从 `/dev/mpu6050` 读取数据，也可用环境变量指定测试设备：

```bash
export COCKPIT_IMU_DEVICE=/dev/mpu6050
```

采集线程支持两种驱动模式。

### 推荐模式：Cockpit IMU ABI

如果驱动支持用户态 ABI，采集线程会请求：

- 采样率：200 Hz
- 加速度量程：±8 g
- 角速度量程：±500 °/s
- DLPF：`cfg=3`（MPU6050 约 42 Hz）
- QML 发布频率：最高 30 Hz
- 发往疲劳服务的运动上下文：10 Hz，Unix 数据报

用户态 ABI 定义在 [imu_uapi.h](imu_uapi.h)。驱动至少需要支持：

1. `COCKPIT_IMU_IOC_GET_INFO`，返回 ABI 版本、样本大小和当前量程；
2. `COCKPIT_IMU_IOC_SET_CONFIG`，接收采样率、量程和 DLPF；
3. `poll()`；
4. `read()` 返回一个或多个完整的 32 字节 `ImuSampleV1`，不能返回半包；
5. `timestamp_ns` 使用单调时钟，`sequence` 每个样本递增。

### 当前驱动兼容模式：14 字节 legacy 帧

仓库中的 [driver/04_mpu6050/mpu6050.c](../../driver/04_mpu6050/mpu6050.c)
没有实现 `ioctl`，`read()` 返回 7 个 `short`：

```text
gyro_x, gyro_y, gyro_z, accel_x, accel_y, accel_z, temp
```

Qt 采集线程会自动识别“不支持 ioctl”的情况，并按该 legacy 布局解码：

- `GYRO_CONFIG=0x18`：±2000 °/s，约 16.4 LSB/(°/s)；
- `ACCEL_CONFIG=0x00`：±2 g，16384 LSB/g；
- `SMPLRT_DIV=0x07` 且 DLPF 开启：有效采样率约 125 Hz；
- 时间戳和序号由用户态采集线程补齐。

这能让现有驱动直接参与 UI、姿态、事件状态机和疲劳服务融合。后续如果要提升
时间戳精度、减少用户态轮询或支持 FIFO，再把驱动升级到 Cockpit IMU ABI。

建议权限规则：

```text
KERNEL=="mpu6050", MODE="0660", GROUP="video"
```

## 2. 安装方向与轴映射

业务坐标固定为：

- `+X`：车辆前进方向；
- `+Y`：车辆左侧；
- `+Z`：车辆上方。

按实际安装方向修改 `assets/config/cockpit-imu.json` 的 `axis_map`。例如传感器
X 轴朝后、Y 轴朝左、Z 轴朝上：

```json
"axis_map": { "forward": "-x", "left": "+y", "up": "+z" }
```

三个业务轴必须映射到三个不同的传感器轴。应用也会优先读取
`/etc/elf2/cockpit-imu.json`，便于板端单独标定而不重新编译。

## 3. 启动与校准

应用启动后车辆和设备应保持静止约 4 秒（默认 800 个样本），用于计算陀螺仪
零偏和静止加速度偏差。校准期间不要晃动、点火或关车门。失败后可在“车辆姿态”
页面点击“静止零偏校准”。

校准只消除启动时固定偏差，不会把后续设备松动当作正常姿态。安装异常、疑似
碰撞和侧翻均为风险提示，不能单独作为事故结论。

## 4. 疲劳服务融合

Qt 每 100 ms 向 `/tmp/cockpit_imu_motion.sock` 发送运动状态和视觉可信度。
`v2/code/fatigue_service.py` 接收后执行以下保守策略：

- IMU 缺失、未校准或数据超过 500 ms：视觉检测照常运行；
- 车身剧烈晃动：短暂跳过视觉观测并禁止产生新告警；
- 抑制最多 2 秒，避免烂路导致疲劳检测长期失效；
- 恢复稳定后连续确认 1.5 秒再允许新告警；
- 已经成立的疲劳告警不会因 IMU 晃动被清除。

启动示例：

```bash
cd /opt/cockpit/v2/code
python3 fatigue_service.py --face-model ../models/RetinaFace_mobile320.rknn \
  --eye-model ../eye_cnn.rknn --camera /dev/video21
```

## 5. 日志与回放

详情页“记录原始数据”会写入 `Documents/ELF2/imu/imu-*.csv`。也可指定目录：

```bash
export COCKPIT_IMU_RECORD_DIR=/data/cockpit/imu
```

不接传感器时可回放同格式 CSV：

```bash
export COCKPIT_IMU_REPLAY=/data/cockpit/imu/imu-demo.csv
export COCKPIT_IMU_REPLAY_FAST=0
./qml
```

`COCKPIT_IMU_REPLAY_FAST=1` 会跳过真实时间等待，供自动测试使用。

## 6. 验证命令

```bash
mkdir -p /tmp/imu-tests-build
cd /tmp/imu-tests-build
qmake /path/to/QML_version/qml/tests/imu_tests.pro
make -j4
./imu_tests

cd /path/to/v2/code
python3 -m unittest discover -s ../tests -v
```

实车调参顺序建议为：确认轴映射 → 静态姿态 → 低速直行/刹车 → 转弯 → 减速带
→ 持续振动。先保存 CSV，再调整 JSON 阈值；疑似碰撞阈值不要在有人驾驶道路上用
危险动作验证。

## 7. Qt 摄像头开关

新版 Qt 和 `v2/code/fatigue_service.py` 启动后摄像头默认关闭。疲劳服务必须保持
运行，因为它在关闭状态下仍通过 `/tmp/cockpit_fatigue.sock` 低频发布状态；Qt 从
首页或摄像头页面开启时，会向以下控制 Socket 发送命令：

```text
/tmp/cockpit_fatigue_control.sock
```

服务可用参数覆盖路径：

```bash
python3 fatigue_service.py --control-sock /tmp/cockpit_fatigue_control.sock
```

如果修改控制路径，Qt 进程必须使用相同的环境变量：

```bash
export COCKPIT_FATIGUE_CONTROL_SOCKET=/tmp/cockpit_fatigue_control.sock
```

手工检查设备是否被释放：

```bash
fuser /dev/video21
```

启动服务后、Qt 尚未开启摄像头时应没有占用者；在 Qt 中开启后应显示疲劳服务的
进程号；关闭后应再次没有输出。关闭只释放摄像头并停止推理，疲劳服务进程和已加载
模型保持运行，以便快速恢复。
