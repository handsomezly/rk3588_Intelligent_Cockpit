#ifndef MOTIONCONTEXT_H
#define MOTIONCONTEXT_H

#include "imutypes.h"

#include <QByteArray>

QByteArray buildMotionContextDatagram(const ImuSnapshot &snapshot,
                                      bool available,
                                      qint64 monotonicMs);

#endif // MOTIONCONTEXT_H
