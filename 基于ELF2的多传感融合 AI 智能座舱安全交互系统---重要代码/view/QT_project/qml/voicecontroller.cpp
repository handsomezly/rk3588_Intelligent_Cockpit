#include "voicecontroller.h"

#include <QAudioFormat>
#include <QAudioInput>
#include <QAudioDeviceInfo>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QIODevice>
#include <QSet>

#include <cmath>
#include <cstdint>

#ifdef HAS_SHERPA_ONNX
#include <sherpa-onnx/c-api/c-api.h>
#endif

namespace {
constexpr int kSampleRate = 16000;
constexpr int kSampleSize = 16;
constexpr int kChannels = 1;
}

namespace {

// 这些不是麦克风：ALSA 内部 plugin、PulseAudio 输出 monitor（回采）、采样率转换层。
// 之前只看 "usb" 字符串会被 `usbstream:CARD=rockchipdp0`（ALSA usbstream plugin，
// DisplayPort 音频回路，不是 USB 麦克风）误命中，导致 16k mono 不支持，ASR 拿不到能用的输入。
bool isBogusInput(const QString &n)
{
    if (n.startsWith(QStringLiteral("usbstream:"))) return true;
    if (n.endsWith(QStringLiteral(".monitor")))     return true;
    if (n.startsWith(QStringLiteral("alsa_output."))) return true;
    static const QSet<QString> bogusExact = {
        QStringLiteral("samplerate"), QStringLiteral("speexrate"),
        QStringLiteral("upmix"),      QStringLiteral("vdownmix"),
        QStringLiteral("oss"),        QStringLiteral("jack"),
        QStringLiteral("pulse")
    };
    return bogusExact.contains(n);
}

// 给候选打分，分数高的优先：
//   100 = PulseAudio USB 输入（走系统音频栈，最稳）
//    90 = ALSA 直接访问 USB 设备（plughw 自带格式转换）
//    80 = ALSA 直接 hw 访问（USB PnP 默认 CARD 名通常是 "Device"）
//    50 = 含 PnP / C-Media 字样的其他 USB 麦克风
//     0 = 不算 USB 麦克风（fallback 用默认设备）
//    -1 = 假设备（ALSA plugin / output monitor）
int matchScore(const QString &n)
{
    if (isBogusInput(n)) return -1;
    if (n.startsWith(QStringLiteral("alsa_input.usb-")))    return 100;
    if (n.startsWith(QStringLiteral("plughw:CARD=Device"))) return 90;
    if (n.startsWith(QStringLiteral("hw:CARD=Device")))     return 80;
    if (n.contains(QStringLiteral("PnP"), Qt::CaseInsensitive))     return 50;
    if (n.contains(QStringLiteral("C-Media"), Qt::CaseInsensitive)) return 50;
    return 0;
}

QAudioDeviceInfo pickInputDevice()
{
    const auto all = QAudioDeviceInfo::availableDevices(QAudio::AudioInput);
    qInfo() << "VoiceController: 可用音频输入设备:";
    for (const auto &d : all)
        qInfo() << "  -" << d.deviceName();

    int bestScore = 0;
    QAudioDeviceInfo bestDev;
    for (const auto &d : all) {
        const int s = matchScore(d.deviceName());
        if (s > bestScore) {
            bestScore = s;
            bestDev = d;
        }
    }
    if (bestScore > 0) {
        qInfo() << "VoiceController: 选用 USB 麦克风 (score" << bestScore << "):" << bestDev.deviceName();
        return bestDev;
    }
    const auto def = QAudioDeviceInfo::defaultInputDevice();
    qInfo() << "VoiceController: 没找到 USB 麦克风，回落默认:" << def.deviceName();
    return def;
}
}

VoiceController::VoiceController(QObject *parent)
    : QObject(parent)
{
    setStatus(QStringLiteral("等待初始化"));
}

VoiceController::~VoiceController()
{
    if (m_recording)
        stopRecording();
#ifdef HAS_SHERPA_ONNX
    if (m_stream)
        SherpaOnnxDestroyOnlineStream(reinterpret_cast<const SherpaOnnxOnlineStream *>(m_stream));
    if (m_recognizer)
        SherpaOnnxDestroyOnlineRecognizer(reinterpret_cast<const SherpaOnnxOnlineRecognizer *>(m_recognizer));
#endif
}

bool VoiceController::init(const QString &modelDir)
{
#ifdef HAS_SHERPA_ONNX
    const QString encoderPath = modelDir + QStringLiteral("/encoder.onnx");
    const QString decoderPath = modelDir + QStringLiteral("/decoder.onnx");
    const QString tokensPath  = modelDir + QStringLiteral("/tokens.txt");
    if (!QFileInfo::exists(encoderPath) || !QFileInfo::exists(decoderPath) || !QFileInfo::exists(tokensPath)) {
        setStatus(QStringLiteral("找不到 ASR 模型文件 (%1)").arg(modelDir));
        setAvailable(false);
        return false;
    }

    // QByteArray 必须保留到 Create 调用之后；存到成员变量
    m_encoderBytes = encoderPath.toUtf8();
    m_decoderBytes = decoderPath.toUtf8();
    m_tokensBytes  = tokensPath.toUtf8();

    SherpaOnnxOnlineRecognizerConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.feat_config.sample_rate = kSampleRate;
    cfg.feat_config.feature_dim = 80;
    cfg.model_config.paraformer.encoder = m_encoderBytes.constData();
    cfg.model_config.paraformer.decoder = m_decoderBytes.constData();
    cfg.model_config.tokens = m_tokensBytes.constData();
    cfg.model_config.num_threads = 2;
    cfg.model_config.provider = "cpu";
    cfg.decoding_method = "greedy_search";

    const SherpaOnnxOnlineRecognizer *recognizer = SherpaOnnxCreateOnlineRecognizer(&cfg);
    if (!recognizer) {
        setStatus(QStringLiteral("ASR 模型加载失败"));
        setAvailable(false);
        return false;
    }
    m_recognizer = const_cast<void *>(static_cast<const void *>(recognizer));
    setStatus(QStringLiteral("语音助手就绪"));
    setAvailable(true);
    return true;
#else
    Q_UNUSED(modelDir)
    setStatus(QStringLiteral("语音功能未编译（缺 sherpa-onnx SDK）"));
    setAvailable(false);
    return false;
#endif
}

void VoiceController::startRecording()
{
    if (!m_available) {
        emit recognized(QString());
        return;
    }
    if (m_recording)
        return;

    QAudioFormat format;
    format.setSampleRate(kSampleRate);
    format.setChannelCount(kChannels);
    format.setSampleSize(kSampleSize);
    format.setCodec(QStringLiteral("audio/pcm"));
    format.setByteOrder(QAudioFormat::LittleEndian);
    format.setSampleType(QAudioFormat::SignedInt);

    QAudioDeviceInfo info = pickInputDevice();
    if (info.isNull()) {
        setStatus(QStringLiteral("找不到任何麦克风设备"));
        return;
    }
    if (!info.isFormatSupported(format)) {
        QAudioFormat nf = info.nearestFormat(format);
        qWarning() << "VoiceController:" << info.deviceName()
                   << "不支持 16kHz mono s16le，nearestFormat ="
                   << nf.sampleRate() << "Hz" << nf.channelCount() << "ch"
                   << "sampleSize=" << nf.sampleSize();
        // sherpa-onnx Paraformer 严格要求 16k mono，喂 8k/stereo 识别率为 0，不如显式报错让用户换设备
        if (nf.sampleRate() != kSampleRate || nf.channelCount() != kChannels) {
            setStatus(QStringLiteral("麦克风不支持 16kHz 单声道，无法做语音识别"));
            return;
        }
        format = nf;
    }

    m_audioInput = new QAudioInput(info, format, this);
    m_audioIO = m_audioInput->start();
    if (!m_audioIO) {
        setStatus(QStringLiteral("打开麦克风失败"));
        delete m_audioInput;
        m_audioInput = nullptr;
        return;
    }
    connect(m_audioIO, &QIODevice::readyRead, this, &VoiceController::handleAudioReadyRead);

#ifdef HAS_SHERPA_ONNX
    if (m_stream) {
        SherpaOnnxDestroyOnlineStream(reinterpret_cast<const SherpaOnnxOnlineStream *>(m_stream));
        m_stream = nullptr;
    }
    const SherpaOnnxOnlineStream *s = SherpaOnnxCreateOnlineStream(
        reinterpret_cast<const SherpaOnnxOnlineRecognizer *>(m_recognizer));
    m_stream = const_cast<void *>(static_cast<const void *>(s));
#endif

    setPartialText(QString());
    setRecording(true);
    setStatus(QStringLiteral("录音中…"));
}

void VoiceController::stopRecording()
{
    if (!m_recording)
        return;

    if (m_audioInput) {
        m_audioInput->stop();
        m_audioInput->deleteLater();
        m_audioInput = nullptr;
        m_audioIO = nullptr;
    }

    QString finalText;
#ifdef HAS_SHERPA_ONNX
    if (m_stream && m_recognizer) {
        const SherpaOnnxOnlineRecognizer *rec =
            reinterpret_cast<const SherpaOnnxOnlineRecognizer *>(m_recognizer);
        const SherpaOnnxOnlineStream *str =
            reinterpret_cast<const SherpaOnnxOnlineStream *>(m_stream);
        SherpaOnnxOnlineStreamInputFinished(str);
        while (SherpaOnnxIsOnlineStreamReady(rec, str))
            SherpaOnnxDecodeOnlineStream(rec, str);
        const SherpaOnnxOnlineRecognizerResult *res = SherpaOnnxGetOnlineStreamResult(rec, str);
        if (res && res->text)
            finalText = QString::fromUtf8(res->text).trimmed();
        if (res)
            SherpaOnnxDestroyOnlineRecognizerResult(res);
        SherpaOnnxDestroyOnlineStream(str);
        m_stream = nullptr;
    }
#endif

    setRecording(false);
    setLevel(0.0);
    setPartialText(QString());
    setStatus(m_available ? QStringLiteral("语音助手就绪") : QStringLiteral("语音功能未启用"));
    emit recognized(finalText);
}

void VoiceController::handleAudioReadyRead()
{
    if (!m_audioIO)
        return;
    const QByteArray chunk = m_audioIO->readAll();
    if (chunk.isEmpty())
        return;
    processFrames(chunk.constData(), chunk.size());
}

void VoiceController::processFrames(const char *data, qint64 bytes)
{
    const int16_t *samples = reinterpret_cast<const int16_t *>(data);
    const qint64 n = bytes / 2;
    if (n <= 0)
        return;

    double sumSq = 0.0;
    for (qint64 i = 0; i < n; ++i) {
        const double s = samples[i] / 32768.0;
        sumSq += s * s;
    }
    const double rms = std::sqrt(sumSq / n);
    const double clamped = std::min(1.0, rms * 3.0);
    setLevel(clamped);

#ifdef HAS_SHERPA_ONNX
    if (!m_stream || !m_recognizer)
        return;
    const SherpaOnnxOnlineRecognizer *rec =
        reinterpret_cast<const SherpaOnnxOnlineRecognizer *>(m_recognizer);
    const SherpaOnnxOnlineStream *str =
        reinterpret_cast<const SherpaOnnxOnlineStream *>(m_stream);
    QVector<float> floatSamples(static_cast<int>(n));
    for (qint64 i = 0; i < n; ++i)
        floatSamples[static_cast<int>(i)] = samples[i] / 32768.0f;
    SherpaOnnxOnlineStreamAcceptWaveform(str, kSampleRate, floatSamples.constData(), static_cast<int>(n));
    while (SherpaOnnxIsOnlineStreamReady(rec, str))
        SherpaOnnxDecodeOnlineStream(rec, str);
    const SherpaOnnxOnlineRecognizerResult *res = SherpaOnnxGetOnlineStreamResult(rec, str);
    if (res && res->text) {
        const QString txt = QString::fromUtf8(res->text).trimmed();
        if (!txt.isEmpty())
            setPartialText(txt);
    }
    if (res)
        SherpaOnnxDestroyOnlineRecognizerResult(res);
#endif
}

void VoiceController::setAvailable(bool v)
{
    if (m_available == v) return;
    m_available = v;
    emit availableChanged();
}
void VoiceController::setRecording(bool v)
{
    if (m_recording == v) return;
    m_recording = v;
    emit recordingChanged();
}
void VoiceController::setLevel(double v)
{
    if (qFuzzyCompare(m_level, v)) return;
    m_level = v;
    emit levelChanged();
}
void VoiceController::setPartialText(const QString &v)
{
    if (m_partialText == v) return;
    m_partialText = v;
    emit partialTextChanged();
}
void VoiceController::setStatus(const QString &v)
{
    if (m_statusText == v) return;
    m_statusText = v;
    emit statusChanged();
}
