#include "brightnesscontroller.h"

#include "sensorservice.h"

#include <QByteArray>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStringList>

#include <algorithm>
#include <cmath>

namespace {
constexpr const char *kBacklightDir = "/sys/class/backlight";
// QSettings 键。组织名/应用名在 main.cpp 已设为 ELF2 / Cockpit。
constexpr const char *kKeyPercent = "brightness/percent";
constexpr const char *kKeyAuto    = "brightness/auto";
// 自动调光每秒来一次读数，差值 <kAutoDeadband 不动，避免亮度抖动。
constexpr int kAutoDeadband = 3;
}

BrightnessController::BrightnessController(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_percent = settings.value(QString::fromLatin1(kKeyPercent), 80).toInt();
    m_percent = std::max(0, std::min(100, m_percent));
    m_auto = settings.value(QString::fromLatin1(kKeyAuto), false).toBool();

    const int rawMax = findBacklight();
    if (rawMax > 0) {
        m_rawMax = rawMax;
        m_available = true;
        // 开机把保存的手动亮度落到硬件；若 auto 开着，首个 ambientUpdated（~1s）会接管。
        writeRaw(percentToRaw(m_percent));
    } else {
        qWarning() << "BrightnessController: 未找到可用背光节点（host x86 上属正常），亮度调节禁用";
    }
}

int BrightnessController::findBacklight()
{
    QDir dir(QString::fromLatin1(kBacklightDir));
    if (!dir.exists())
        return -1;

    const QStringList entries = dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &name : entries) {
        const QString base = dir.absoluteFilePath(name);
        const QString bright = base + QStringLiteral("/brightness");
        const QString maxPath = base + QStringLiteral("/max_brightness");
        if (!QFileInfo::exists(bright) || !QFileInfo::exists(maxPath))
            continue;

        QFile maxFile(maxPath);
        if (!maxFile.open(QIODevice::ReadOnly | QIODevice::Text))
            continue;
        bool ok = false;
        const int rawMax = maxFile.readAll().trimmed().toInt(&ok);
        maxFile.close();
        if (!ok || rawMax <= 0)
            continue;

        m_brightnessPath = bright;
        qInfo() << "BrightnessController: 使用背光节点" << base << "max_brightness=" << rawMax;
        return rawMax;
    }
    return -1;
}

int BrightnessController::percentToRaw(int percent) const
{
    percent = std::max(0, std::min(100, percent));
    // 0% 也保留 m_rawMin，避免屏幕彻底黑掉（车机场景不应全黑）。
    const int span = m_rawMax - m_rawMin;
    return m_rawMin + static_cast<int>(std::lround(span * percent / 100.0));
}

int BrightnessController::rawToPercent(int raw) const
{
    const int span = m_rawMax - m_rawMin;
    if (span <= 0)
        return 0;
    int p = static_cast<int>(std::lround((raw - m_rawMin) * 100.0 / span));
    return std::max(0, std::min(100, p));
}

int BrightnessController::luxToPercent(double lux)
{
    // 对数映射：lux 1→20%、10→40%、100→60%、1000→80%、10000→100%。下限 10% 防过暗。
    const double safeLux = std::max(1.0, lux);
    int p = static_cast<int>(std::lround(20.0 + 20.0 * std::log10(safeLux)));
    return std::max(10, std::min(100, p));
}

bool BrightnessController::writeRaw(int raw)
{
    if (m_brightnessPath.isEmpty())
        return false;
    raw = std::max(0, std::min(m_rawMax, raw));
    QFile f(m_brightnessPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning() << "BrightnessController: 写背光失败" << m_brightnessPath
                   << f.errorString() << "（多半是权限，需 udev 放权给 elf 用户）";
        return false;
    }
    f.write(QByteArray::number(raw));
    f.close();
    return true;
}

void BrightnessController::setBrightness(int percent)
{
    percent = std::max(0, std::min(100, percent));
    if (m_available)
        writeRaw(percentToRaw(percent));
    if (m_percent != percent) {
        m_percent = percent;
        QSettings().setValue(QString::fromLatin1(kKeyPercent), m_percent);
        emit brightnessChanged();
    }
}

void BrightnessController::setAutoMode(bool on)
{
    if (m_auto != on) {
        m_auto = on;
        QSettings().setValue(QString::fromLatin1(kKeyAuto), m_auto);
        emit autoModeChanged();
    }
    // 刚打开自动：立刻按当前 lux 应用一次，不必等下一拍。
    if (on && m_available && m_sensor && m_sensor->ambientValid())
        applyAmbientLux(m_sensor->ambientLux());
}

void BrightnessController::applyAmbientLux(double lux)
{
    if (!m_auto || !m_available)
        return;
    const int target = luxToPercent(lux);
    if (std::abs(target - m_percent) < kAutoDeadband)
        return;
    setBrightness(target);
}

void BrightnessController::setSensorService(SensorService *sensor)
{
    if (m_sensor == sensor)
        return;
    if (m_sensor)
        disconnect(m_sensor, nullptr, this, nullptr);
    m_sensor = sensor;
    if (m_sensor) {
        connect(m_sensor, &SensorService::ambientUpdated,
                this, &BrightnessController::handleAmbientUpdated);
        // 接上时若已 auto + 有有效读数，立即应用。
        if (m_auto && m_available && m_sensor->ambientValid())
            applyAmbientLux(m_sensor->ambientLux());
    }
}

void BrightnessController::handleAmbientUpdated()
{
    if (m_auto && m_sensor)
        applyAmbientLux(m_sensor->ambientLux());
}
