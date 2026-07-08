#include "alerttone.h"

#include <QtEndian>
#include <QtMath>

QByteArray makeAlertTonePcm(int sampleRate, int durationMs)
{
    if (sampleRate <= 0 || durationMs <= 0)
        return QByteArray();
    const int sampleCount = qMax(1, sampleRate * durationMs / 1000);
    const int envelopeSamples = qMax(1, qMin(sampleCount / 2, sampleRate / 25));
    QByteArray pcm(sampleCount * int(sizeof(qint16)), Qt::Uninitialized);
    for (int i = 0; i < sampleCount; ++i) {
        const double t = static_cast<double>(i) / sampleRate;
        const double attack = qMin(1.0, static_cast<double>(i) / envelopeSamples);
        const double release = qMin(1.0,
            static_cast<double>(sampleCount - 1 - i) / envelopeSamples);
        const double envelope = qMax(0.0, qMin(attack, release));
        const double signal = 0.70 * qSin(2.0 * M_PI * 760.0 * t)
                            + 0.30 * qSin(2.0 * M_PI * 1040.0 * t);
        const qint16 value = static_cast<qint16>(signal * envelope * 18000.0);
        qToLittleEndian<qint16>(value,
            reinterpret_cast<uchar *>(pcm.data() + i * int(sizeof(qint16))));
    }
    return pcm;
}
