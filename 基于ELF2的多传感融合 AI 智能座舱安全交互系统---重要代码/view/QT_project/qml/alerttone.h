#ifndef ALERTTONE_H
#define ALERTTONE_H

#include <QByteArray>

// 16-bit signed, little-endian, mono PCM. The short attack/release envelope
// avoids clicks on small vehicle speakers.
QByteArray makeAlertTonePcm(int sampleRate, int durationMs);

#endif // ALERTTONE_H
