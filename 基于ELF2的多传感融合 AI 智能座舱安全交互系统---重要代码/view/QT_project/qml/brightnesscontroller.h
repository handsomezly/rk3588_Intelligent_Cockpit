#ifndef BRIGHTNESSCONTROLLER_H
#define BRIGHTNESSCONTROLLER_H

#include <QObject>
#include <QString>

class SensorService;

// MIPI 屏背光亮度控制。
// 直接读写 /sys/class/backlight/<dev>/{brightness,max_brightness}，跟 SensorService
// 读 /dev/* 一样走文件系统。写背光是几字节同步小写，不阻塞，留在主线程即可
// （区别于 DHT11 那种阻塞 ioctl 必须搬 worker thread）。
//
// 自动调光：通过 setSensorService() 接上 SensorService，内部 connect 它的
// ambientUpdated 信号；autoMode 为真时按 BH1750 的 lux 映射亮度。解耦方式跟
// AiAssistant::setTtsService 一致——main.cpp 实例化后接一次即可。
class BrightnessController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)   // 百分比 0-100
    Q_PROPERTY(bool autoMode READ autoMode WRITE setAutoMode NOTIFY autoModeChanged)
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    explicit BrightnessController(QObject *parent = nullptr);

    int brightness() const { return m_percent; }
    bool autoMode() const { return m_auto; }
    bool available() const { return m_available; }

    void setBrightness(int percent);     // clamp 0-100 → raw → 写 sysfs → 存 QSettings
    void setAutoMode(bool on);           // 存 QSettings；置 true 时立即按当前 lux 应用一次

    // 自动调光入口：仅 autoMode 时生效，lux → percent 曲线 + 平滑去抖 + 写 sysfs。
    Q_INVOKABLE void applyAmbientLux(double lux);

    // 接上传感器，内部连 ambientUpdated。不 own SensorService。
    void setSensorService(SensorService *sensor);

signals:
    void brightnessChanged();
    void autoModeChanged();

private slots:
    void handleAmbientUpdated();

private:
    int findBacklight();                 // 扫描 /sys/class/backlight，定位可用节点
    bool writeRaw(int raw);              // 写 brightness 文件
    int percentToRaw(int percent) const;
    int rawToPercent(int raw) const;
    static int luxToPercent(double lux); // 对数映射

    SensorService *m_sensor = nullptr;
    QString m_brightnessPath;            // .../brightness
    int m_rawMax = 255;                  // max_brightness
    int m_rawMin = 1;                    // 不让屏彻底黑掉
    int m_percent = 80;
    bool m_auto = false;
    bool m_available = false;
};

#endif // BRIGHTNESSCONTROLLER_H
