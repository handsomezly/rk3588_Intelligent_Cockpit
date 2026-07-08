#ifndef TTSSERVICE_H
#define TTSSERVICE_H

#include <QByteArray>
#include <QDateTime>
#include <QMediaPlayer>
#include <QObject>
#include <QQueue>
#include <QString>

class QNetworkAccessManager;
class QNetworkReply;
class QBuffer;
class QTemporaryFile;

// 百度 TTS REST 客户端 + QMediaPlayer 串行播放队列。
// AiAssistant 流式过程中按 。？！\n 切句，每句调 enqueueSpeak()，
// TtsService 内部排队请求百度 API 拿 MP3，再用 QMediaPlayer 顺序播放。
//
// 设计选择：
//  - access_token 有 30 天有效期，缓存在内存
//  - 一次只跑一个 HTTP 请求 + 一个 player 播放，避免并发
//  - 队列模型：sentences -> 请求 -> mp3 字节 -> player
//  - cancelAll() 用于"开始新对话/切走 AI 页"时清空队列
class TtsService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorChanged)

public:
    explicit TtsService(QObject *parent = nullptr);
    ~TtsService() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);

    bool busy() const { return m_busy; }
    QString errorText() const { return m_errorText; }

    // 主入口：把一句话加入合成队列。空串忽略。
    Q_INVOKABLE void enqueueSpeak(const QString &sentence);
    // 清空所有未播放的句子并停掉当前播放（开始新对话 / 用户切走时调）
    Q_INVOKABLE void cancelAll();

signals:
    void enabledChanged();
    void busyChanged();
    void errorChanged();

private slots:
    void handleTokenReply();
    void handleSynthesisReply();
    void handlePlayerStateChanged(QMediaPlayer::State state);
    void handlePlayerError(QMediaPlayer::Error error);

private:
    void pumpQueue();              // 看队列里有没有句子，没在做事就启动下一个
    void requestAccessToken();     // 用 API Key + Secret 换 token
    void requestSynthesis(const QString &text);  // 拿 mp3 字节
    void enqueuePlayback(const QByteArray &mp3); // 喂给 player
    void playNextIfIdle();         // player idle 时取出下一个 mp3 播放
    void setBusy(bool b);
    void setError(const QString &text);
    void clearError();
    bool tokenValid() const;

    QNetworkAccessManager *m_network;
    QString m_accessToken;
    QDateTime m_tokenExpiry;
    QNetworkReply *m_tokenReply = nullptr;
    QNetworkReply *m_synthReply = nullptr;

    QQueue<QString> m_pendingSentences;   // 等待合成的文字
    QQueue<QByteArray> m_pendingPlayback; // 等待播放的 mp3 bytes
    QString m_inflightSentence;           // 当前正在请求合成的句子（出错重试用，可选）

    QMediaPlayer *m_player = nullptr;
    QTemporaryFile *m_playerFile = nullptr;  // Qt 5.15 gstreamer 后端对 QBuffer/MP3 流支持不稳，用临时文件最可靠

    bool m_enabled = true;
    bool m_busy = false;
    QString m_errorText;
};

#endif // TTSSERVICE_H
