#ifndef AIASSISTANT_H
#define AIASSISTANT_H

#include <QAbstractListModel>
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QStringList>

class QNetworkAccessManager;
class QNetworkReply;
class TtsService;

class ChatMessagesModel : public QAbstractListModel
{
    Q_OBJECT
public:
    enum Roles {
        RoleRole = Qt::UserRole + 1,
        ContentRole,
        ErrorRole,
    };

    struct Entry {
        QString role;       // "user" | "assistant"
        QString content;
        bool error = false;
    };

    explicit ChatMessagesModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void append(const Entry &entry);
    void appendChunkToLast(const QString &chunk);
    void setLastError(const QString &errorText);
    void clearLastIfEmpty();
    void clear();

    const QVector<Entry> &entries() const { return m_entries; }
    Entry lastEntry() const;
    bool isEmpty() const { return m_entries.isEmpty(); }

private:
    QVector<Entry> m_entries;
};

class AiAssistant : public QObject
{
    Q_OBJECT
    Q_PROPERTY(ChatMessagesModel *messages READ messages CONSTANT)
    Q_PROPERTY(bool streaming READ streaming NOTIFY streamingChanged)
    Q_PROPERTY(bool hasError READ hasError NOTIFY errorChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY errorChanged)

public:
    explicit AiAssistant(QObject *parent = nullptr);

    ChatMessagesModel *messages() { return &m_model; }
    bool streaming() const { return m_streaming; }
    bool hasError() const { return !m_errorText.isEmpty(); }
    QString errorText() const { return m_errorText; }

    // TTS 解耦：AiAssistant 持有指针，不 own 也不 #include header，
    // main.cpp 实例化两个 controller 后调一次 setTtsService 接上。
    void setTtsService(TtsService *tts) { m_tts = tts; }

    Q_INVOKABLE void sendMessage(const QString &text);
    Q_INVOKABLE void clearConversation();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void retryLast();

signals:
    void streamingChanged();
    void errorChanged();

private slots:
    void handleReadyRead();
    void handleFinished();

private:
    void postRequest();
    void processSseFrame(const QByteArray &frame);
    void finalizeStream(bool ok);
    void setStreaming(bool on);
    void setError(const QString &text);
    void clearError();
    void persistHistory() const;
    void loadHistory();
    QString historyFilePath() const;
    void flushTtsBuffer(bool finalize);  // 切句送 TTS：finalize=true 时把剩余尾巴也送

    QNetworkAccessManager *m_network;
    QNetworkReply *m_reply = nullptr;
    QByteArray m_sseBuffer;
    ChatMessagesModel m_model;
    bool m_streaming = false;
    bool m_streamingHasContent = false;
    QString m_errorText;

    TtsService *m_tts = nullptr;
    QString m_ttsBuffer;  // 流式过程中累积的、还没切到句末标点的尾巴
};

#endif // AIASSISTANT_H
