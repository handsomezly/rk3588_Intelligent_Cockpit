#ifndef VOICECONTROLLER_H
#define VOICECONTROLLER_H

#include <QByteArray>
#include <QObject>
#include <QString>

class QAudioInput;
class QIODevice;

class VoiceController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY recordingChanged)
    Q_PROPERTY(double level READ level NOTIFY levelChanged)
    Q_PROPERTY(QString partialText READ partialText NOTIFY partialTextChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)

public:
    explicit VoiceController(QObject *parent = nullptr);
    ~VoiceController() override;

    bool available() const { return m_available; }
    bool recording() const { return m_recording; }
    double level() const { return m_level; }
    QString partialText() const { return m_partialText; }
    QString statusText() const { return m_statusText; }

    bool init(const QString &modelDir);

    Q_INVOKABLE void startRecording();
    Q_INVOKABLE void stopRecording();

signals:
    void availableChanged();
    void recordingChanged();
    void levelChanged();
    void partialTextChanged();
    void statusChanged();
    void recognized(const QString &text);

private slots:
    void handleAudioReadyRead();

private:
    void setAvailable(bool v);
    void setRecording(bool v);
    void setLevel(double v);
    void setPartialText(const QString &v);
    void setStatus(const QString &v);
    void processFrames(const char *data, qint64 bytes);

    QAudioInput *m_audioInput = nullptr;
    QIODevice *m_audioIO = nullptr;
    void *m_recognizer = nullptr;
    void *m_stream = nullptr;
    QByteArray m_encoderBytes;
    QByteArray m_decoderBytes;
    QByteArray m_tokensBytes;

    bool m_available = false;
    bool m_recording = false;
    double m_level = 0.0;
    QString m_partialText;
    QString m_statusText;
};

#endif // VOICECONTROLLER_H
