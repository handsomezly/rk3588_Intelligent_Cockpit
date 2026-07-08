#include "ttsservice.h"

#include <QDebug>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTemporaryFile>
#include <QUrl>
#include <QUrlQuery>

namespace {

// 百度智能云语音合成 -- 跟 DeepSeek / 高德 key 一样的硬编码处理，
// 已知技术债，跟着一起搬到 /etc/elf2/cockpit.conf。
constexpr const char *kBaiduApiKey    = "mkiybhA5cp30Sa2gLe4ir0EO";
constexpr const char *kBaiduSecretKey = "L3LjS4hEiJCerjh4pYCWnV7zDSiBQIX0";

constexpr const char *kTokenUrl = "https://aip.baidubce.com/oauth/2.0/token";
constexpr const char *kTtsUrl   = "https://tsn.baidubce.com/text2audio";

constexpr const char *kCuid = "elf2-cockpit";

// 百度单次 ≤ 1024 字节 utf-8。中文 3 字节估上限 ~340 字，留余量取 200。
constexpr int kMaxSentenceChars = 200;

}

TtsService::TtsService(QObject *parent)
    : QObject(parent)
    , m_network(new QNetworkAccessManager(this))
    , m_player(new QMediaPlayer(this))
{
    connect(m_player, &QMediaPlayer::stateChanged,
            this, &TtsService::handlePlayerStateChanged);
    connect(m_player, QOverload<QMediaPlayer::Error>::of(&QMediaPlayer::error),
            this, &TtsService::handlePlayerError);
}

TtsService::~TtsService()
{
    cancelAll();
    if (m_playerFile) {
        m_playerFile->deleteLater();
        m_playerFile = nullptr;
    }
}

void TtsService::setEnabled(bool on)
{
    if (m_enabled == on) return;
    m_enabled = on;
    emit enabledChanged();
    if (!on) cancelAll();
}

void TtsService::enqueueSpeak(const QString &sentence)
{
    if (!m_enabled) return;
    QString s = sentence.trimmed();
    if (s.isEmpty()) return;
    // 超长就切片入队，避免触发百度的字节上限
    while (s.length() > kMaxSentenceChars) {
        m_pendingSentences.enqueue(s.left(kMaxSentenceChars));
        s = s.mid(kMaxSentenceChars);
    }
    if (!s.isEmpty())
        m_pendingSentences.enqueue(s);
    clearError();
    pumpQueue();
}

void TtsService::cancelAll()
{
    m_pendingSentences.clear();
    m_pendingPlayback.clear();
    m_inflightSentence.clear();
    if (m_tokenReply) {
        m_tokenReply->abort();
        m_tokenReply = nullptr;
    }
    if (m_synthReply) {
        m_synthReply->abort();
        m_synthReply = nullptr;
    }
    if (m_player->state() != QMediaPlayer::StoppedState) {
        m_player->stop();
    }
    setBusy(false);
}

bool TtsService::tokenValid() const
{
    return !m_accessToken.isEmpty()
        && m_tokenExpiry.isValid()
        && m_tokenExpiry > QDateTime::currentDateTime();
}

void TtsService::pumpQueue()
{
    if (!m_enabled) return;
    // 缺 token 但有句子要合成 → 先去换 token
    if (!tokenValid() && !m_pendingSentences.isEmpty() && !m_tokenReply) {
        requestAccessToken();
        return;
    }
    // 有 token + 有句子 + 当前没合成请求 → 发下一个
    if (tokenValid() && !m_pendingSentences.isEmpty() && !m_synthReply) {
        m_inflightSentence = m_pendingSentences.dequeue();
        requestSynthesis(m_inflightSentence);
    }
    // player 空闲 + 有 mp3 → 播下一段
    playNextIfIdle();

    const bool b = !m_pendingSentences.isEmpty()
                || m_tokenReply != nullptr
                || m_synthReply != nullptr
                || !m_pendingPlayback.isEmpty()
                || (m_player->state() != QMediaPlayer::StoppedState);
    setBusy(b);
}

void TtsService::requestAccessToken()
{
    QUrl url(QString::fromLatin1(kTokenUrl));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("grant_type"),    QStringLiteral("client_credentials"));
    q.addQueryItem(QStringLiteral("client_id"),     QString::fromLatin1(kBaiduApiKey));
    q.addQueryItem(QStringLiteral("client_secret"), QString::fromLatin1(kBaiduSecretKey));
    url.setQuery(q);

    QNetworkRequest req(url);
    m_tokenReply = m_network->get(req);
    connect(m_tokenReply, &QNetworkReply::finished,
            this, &TtsService::handleTokenReply);
    setBusy(true);
}

void TtsService::handleTokenReply()
{
    if (!m_tokenReply) return;
    QNetworkReply *r = m_tokenReply;
    m_tokenReply = nullptr;
    r->deleteLater();

    if (r->error() != QNetworkReply::NoError) {
        setError(QStringLiteral("TTS token 请求失败: %1").arg(r->errorString()));
        m_pendingSentences.clear();
        setBusy(false);
        return;
    }

    QJsonParseError jerr;
    const QJsonDocument doc = QJsonDocument::fromJson(r->readAll(), &jerr);
    if (jerr.error != QJsonParseError::NoError || !doc.isObject()) {
        setError(QStringLiteral("TTS token 响应解析失败"));
        m_pendingSentences.clear();
        setBusy(false);
        return;
    }
    const QJsonObject obj = doc.object();
    if (!obj.contains(QStringLiteral("access_token"))) {
        setError(QStringLiteral("TTS token 响应缺 access_token: %1")
                 .arg(QString::fromUtf8(doc.toJson(QJsonDocument::Compact))));
        m_pendingSentences.clear();
        setBusy(false);
        return;
    }
    m_accessToken = obj.value(QStringLiteral("access_token")).toString();
    const int expSec = obj.value(QStringLiteral("expires_in")).toInt(2592000);  // 默认 30 天
    m_tokenExpiry = QDateTime::currentDateTime().addSecs(qMax(60, expSec - 60));
    qInfo() << "TtsService: 获取 access_token 成功，有效期至" << m_tokenExpiry.toString(Qt::ISODate);
    pumpQueue();
}

void TtsService::requestSynthesis(const QString &text)
{
    QUrl url(QString::fromLatin1(kTtsUrl));
    QUrlQuery form;
    form.addQueryItem(QStringLiteral("tex"),  QString::fromUtf8(QUrl::toPercentEncoding(text)));
    form.addQueryItem(QStringLiteral("tok"),  m_accessToken);
    form.addQueryItem(QStringLiteral("cuid"), QString::fromLatin1(kCuid));
    form.addQueryItem(QStringLiteral("ctp"),  QStringLiteral("1"));
    form.addQueryItem(QStringLiteral("lan"),  QStringLiteral("zh"));
    form.addQueryItem(QStringLiteral("spd"),  QStringLiteral("5"));   // 语速 0-15
    form.addQueryItem(QStringLiteral("pit"),  QStringLiteral("5"));   // 音调 0-15
    form.addQueryItem(QStringLiteral("vol"),  QStringLiteral("10"));  // 音量 0-15
    form.addQueryItem(QStringLiteral("per"),  QStringLiteral("0"));   // 0=度小美 1=度小宇 3=度逍遥 4=度丫丫
    form.addQueryItem(QStringLiteral("aue"),  QStringLiteral("3"));   // 3=mp3, 4=pcm-16k, 5=pcm-8k, 6=wav

    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/x-www-form-urlencoded"));

    m_synthReply = m_network->post(req, form.toString(QUrl::FullyEncoded).toUtf8());
    connect(m_synthReply, &QNetworkReply::finished,
            this, &TtsService::handleSynthesisReply);
    setBusy(true);
}

void TtsService::handleSynthesisReply()
{
    if (!m_synthReply) return;
    QNetworkReply *r = m_synthReply;
    m_synthReply = nullptr;
    r->deleteLater();

    if (r->error() != QNetworkReply::NoError) {
        setError(QStringLiteral("TTS 合成请求失败: %1").arg(r->errorString()));
        m_inflightSentence.clear();
        pumpQueue();
        return;
    }

    const QByteArray body = r->readAll();
    const QString contentType = r->header(QNetworkRequest::ContentTypeHeader).toString();
    // 百度错误返回 application/json，正常返回 audio/mp3。token 失效会返回 JSON err_no=110/111。
    if (contentType.contains(QStringLiteral("json"), Qt::CaseInsensitive)) {
        const QString msg = QString::fromUtf8(body);
        // token 过期：清掉 token，把句子塞回队列重试
        if (msg.contains(QStringLiteral("\"err_no\":110")) || msg.contains(QStringLiteral("\"err_no\":111"))) {
            qWarning() << "TtsService: token 失效，重新换 token";
            m_accessToken.clear();
            m_tokenExpiry = QDateTime();
            if (!m_inflightSentence.isEmpty())
                m_pendingSentences.prepend(m_inflightSentence);
            m_inflightSentence.clear();
            pumpQueue();
            return;
        }
        setError(QStringLiteral("TTS 合成错误: %1").arg(msg));
        m_inflightSentence.clear();
        pumpQueue();
        return;
    }

    enqueuePlayback(body);
    m_inflightSentence.clear();
    pumpQueue();
}

void TtsService::enqueuePlayback(const QByteArray &mp3)
{
    m_pendingPlayback.enqueue(mp3);
    playNextIfIdle();
}

void TtsService::playNextIfIdle()
{
    if (m_player->state() != QMediaPlayer::StoppedState) return;
    if (m_pendingPlayback.isEmpty()) return;

    const QByteArray mp3 = m_pendingPlayback.dequeue();

    if (m_playerFile) {
        m_playerFile->deleteLater();
        m_playerFile = nullptr;
    }
    m_playerFile = new QTemporaryFile(this);
    m_playerFile->setFileTemplate(QDir::tempPath() + QStringLiteral("/cockpit-tts-XXXXXX.mp3"));
    if (!m_playerFile->open()) {
        setError(QStringLiteral("无法创建 TTS 临时文件"));
        m_playerFile->deleteLater();
        m_playerFile = nullptr;
        pumpQueue();
        return;
    }
    m_playerFile->write(mp3);
    m_playerFile->flush();
    m_player->setMedia(QUrl::fromLocalFile(m_playerFile->fileName()));
    m_player->play();
}

void TtsService::handlePlayerStateChanged(QMediaPlayer::State state)
{
    if (state == QMediaPlayer::StoppedState) {
        if (m_playerFile) {
            m_playerFile->deleteLater();
            m_playerFile = nullptr;
        }
        pumpQueue();
    }
}

void TtsService::handlePlayerError(QMediaPlayer::Error error)
{
    if (error == QMediaPlayer::NoError) return;
    setError(QStringLiteral("TTS 播放错误: %1").arg(m_player->errorString()));
    if (m_playerFile) {
        m_playerFile->deleteLater();
        m_playerFile = nullptr;
    }
    m_player->stop();
    pumpQueue();
}

void TtsService::setBusy(bool b)
{
    if (m_busy == b) return;
    m_busy = b;
    emit busyChanged();
}

void TtsService::setError(const QString &text)
{
    if (m_errorText == text) return;
    m_errorText = text;
    emit errorChanged();
    qWarning() << "TtsService:" << text;
}

void TtsService::clearError()
{
    if (m_errorText.isEmpty()) return;
    m_errorText.clear();
    emit errorChanged();
}
