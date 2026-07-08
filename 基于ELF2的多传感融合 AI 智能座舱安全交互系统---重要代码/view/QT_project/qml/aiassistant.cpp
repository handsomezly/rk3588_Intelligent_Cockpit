#include "aiassistant.h"

#include "ttsservice.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QRegularExpressionMatch>
#include <QStandardPaths>

namespace {

const QString kApiKey = QStringLiteral(
    "sk-acadc683961a4735bf9bc6941757f1d9");
const QString kEndpoint =
    QStringLiteral("https://api.deepseek.com/chat/completions");
const QString kModel = QStringLiteral("deepseek-chat");
const QString kSystemPrompt = QStringLiteral(
    "你是 ELF2 智能座舱的车载 AI 助手，运行在驾驶环境。回答时遵循："
    "（1）回复简洁直接，单次不超过 200 字；"
    "（2）不使用 markdown 符号（**、#、```），用纯文本；"
    "（3）涉及驾驶建议优先考虑安全；"
    "（4）使用简体中文回答。");

const char *kSsePrefix = "data: ";
const int kSsePrefixLen = 6;

}

ChatMessagesModel::ChatMessagesModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ChatMessagesModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid())
        return 0;
    return m_entries.size();
}

QVariant ChatMessagesModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_entries.size())
        return QVariant();
    const Entry &e = m_entries.at(index.row());
    switch (role) {
    case RoleRole:    return e.role;
    case ContentRole: return e.content;
    case ErrorRole:   return e.error;
    default:          return QVariant();
    }
}

QHash<int, QByteArray> ChatMessagesModel::roleNames() const
{
    return {
        {RoleRole, "role"},
        {ContentRole, "content"},
        {ErrorRole, "error"},
    };
}

void ChatMessagesModel::append(const Entry &entry)
{
    beginInsertRows(QModelIndex(), m_entries.size(), m_entries.size());
    m_entries.append(entry);
    endInsertRows();
}

void ChatMessagesModel::appendChunkToLast(const QString &chunk)
{
    if (m_entries.isEmpty() || chunk.isEmpty())
        return;
    const int row = m_entries.size() - 1;
    m_entries[row].content.append(chunk);
    const QModelIndex idx = index(row, 0);
    emit dataChanged(idx, idx, {ContentRole});
}

void ChatMessagesModel::setLastError(const QString &errorText)
{
    if (m_entries.isEmpty())
        return;
    const int row = m_entries.size() - 1;
    m_entries[row].error = true;
    if (!errorText.isEmpty())
        m_entries[row].content = errorText;
    const QModelIndex idx = index(row, 0);
    emit dataChanged(idx, idx, {ContentRole, ErrorRole});
}

void ChatMessagesModel::clearLastIfEmpty()
{
    if (m_entries.isEmpty())
        return;
    const int row = m_entries.size() - 1;
    if (!m_entries.at(row).content.isEmpty())
        return;
    beginRemoveRows(QModelIndex(), row, row);
    m_entries.removeAt(row);
    endRemoveRows();
}

void ChatMessagesModel::clear()
{
    if (m_entries.isEmpty())
        return;
    beginResetModel();
    m_entries.clear();
    endResetModel();
}

ChatMessagesModel::Entry ChatMessagesModel::lastEntry() const
{
    if (m_entries.isEmpty())
        return {};
    return m_entries.last();
}

// ---------------------------------------------------------------------------

AiAssistant::AiAssistant(QObject *parent)
    : QObject(parent)
    , m_network(new QNetworkAccessManager(this))
{
    loadHistory();
}

void AiAssistant::sendMessage(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty())
        return;
    if (m_streaming) {
        setError(QStringLiteral("当前请求还在进行，请稍候"));
        return;
    }
    if (kApiKey.isEmpty() || kApiKey.startsWith(QStringLiteral("YOUR_"))) {
        setError(QStringLiteral("未配置云端 API Key"));
        return;
    }
    clearError();

    ChatMessagesModel::Entry user;
    user.role = QStringLiteral("user");
    user.content = trimmed;
    m_model.append(user);
    persistHistory();

    postRequest();
}

void AiAssistant::clearConversation()
{
    if (m_streaming)
        cancel();
    m_model.clear();
    clearError();
    persistHistory();
}

void AiAssistant::cancel()
{
    if (!m_reply)
        return;
    QNetworkReply *r = m_reply;
    m_reply = nullptr;
    r->disconnect(this);
    r->abort();
    r->deleteLater();
    m_sseBuffer.clear();
    m_ttsBuffer.clear();
    if (m_tts) m_tts->cancelAll();
    finalizeStream(false);
}

void AiAssistant::retryLast()
{
    const auto last = m_model.lastEntry();
    if (last.role != QStringLiteral("user"))
        return;
    if (m_streaming)
        return;
    clearError();
    postRequest();
}

void AiAssistant::postRequest()
{
    QJsonArray msgs;
    {
        QJsonObject sys;
        sys[QStringLiteral("role")] = QStringLiteral("system");
        sys[QStringLiteral("content")] = kSystemPrompt;
        msgs.append(sys);
    }
    for (const auto &e : m_model.entries()) {
        if (e.error || e.role.isEmpty())
            continue;
        QJsonObject o;
        o[QStringLiteral("role")] = e.role;
        o[QStringLiteral("content")] = e.content;
        msgs.append(o);
    }

    QJsonObject body;
    body[QStringLiteral("model")] = kModel;
    body[QStringLiteral("messages")] = msgs;
    body[QStringLiteral("stream")] = true;
    body[QStringLiteral("temperature")] = 0.7;

    QNetworkRequest req((QUrl(kEndpoint)));
    req.setRawHeader("Authorization",
                     ("Bearer " + kApiKey).toUtf8());
    req.setRawHeader("Content-Type", "application/json");
    req.setRawHeader("Accept", "text/event-stream");
    req.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);

    ChatMessagesModel::Entry placeholder;
    placeholder.role = QStringLiteral("assistant");
    placeholder.content = QString();
    m_model.append(placeholder);
    m_streamingHasContent = false;

    m_sseBuffer.clear();
    m_ttsBuffer.clear();
    if (m_tts) m_tts->cancelAll();  // 新一轮回答开始，停掉上一轮没播完的语音
    m_reply = m_network->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(m_reply, &QIODevice::readyRead, this, &AiAssistant::handleReadyRead);
    connect(m_reply, &QNetworkReply::finished, this, &AiAssistant::handleFinished);
    setStreaming(true);
}

void AiAssistant::handleReadyRead()
{
    if (!m_reply)
        return;
    m_sseBuffer.append(m_reply->readAll());

    int frameEnd;
    while ((frameEnd = m_sseBuffer.indexOf("\n\n")) != -1) {
        QByteArray frame = m_sseBuffer.left(frameEnd);
        m_sseBuffer.remove(0, frameEnd + 2);
        processSseFrame(frame);
    }
}

void AiAssistant::processSseFrame(const QByteArray &frame)
{
    for (const QByteArray &line : frame.split('\n')) {
        const QByteArray trimmed = line.trimmed();
        if (trimmed.isEmpty())
            continue;
        if (!trimmed.startsWith(kSsePrefix))
            continue;
        const QByteArray payload = trimmed.mid(kSsePrefixLen).trimmed();
        if (payload == "[DONE]") {
            finalizeStream(true);
            return;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(payload);
        if (!doc.isObject())
            continue;
        const QJsonObject obj = doc.object();
        const QJsonArray choices = obj.value(QStringLiteral("choices")).toArray();
        if (choices.isEmpty())
            continue;
        const QJsonObject choice = choices.first().toObject();
        const QJsonObject delta = choice.value(QStringLiteral("delta")).toObject();
        const QString chunk = delta.value(QStringLiteral("content")).toString();
        if (!chunk.isEmpty()) {
            m_model.appendChunkToLast(chunk);
            m_streamingHasContent = true;
            m_ttsBuffer.append(chunk);
            flushTtsBuffer(false);
        }
    }
}

void AiAssistant::handleFinished()
{
    if (!m_reply)
        return;
    QNetworkReply *r = m_reply;
    m_reply = nullptr;

    const QNetworkReply::NetworkError netErr = r->error();
    const QByteArray remaining = r->readAll();
    if (!remaining.isEmpty())
        m_sseBuffer.append(remaining);

    int frameEnd;
    while ((frameEnd = m_sseBuffer.indexOf("\n\n")) != -1) {
        QByteArray frame = m_sseBuffer.left(frameEnd);
        m_sseBuffer.remove(0, frameEnd + 2);
        processSseFrame(frame);
    }

    if (netErr != QNetworkReply::NoError) {
        QString detail = r->errorString();
        const int httpStatus =
            r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (httpStatus > 0)
            detail = QStringLiteral("HTTP %1 - %2").arg(httpStatus).arg(detail);
        if (!remaining.isEmpty()) {
            const QJsonDocument errDoc = QJsonDocument::fromJson(remaining);
            if (errDoc.isObject()) {
                const QJsonObject errObj = errDoc.object()
                    .value(QStringLiteral("error")).toObject();
                const QString msg = errObj.value(QStringLiteral("message")).toString();
                if (!msg.isEmpty())
                    detail = msg;
            }
        }
        setError(QStringLiteral("网络错误：") + detail);
        m_model.clearLastIfEmpty();
        finalizeStream(false);
        r->deleteLater();
        return;
    }

    finalizeStream(true);
    r->deleteLater();
}

void AiAssistant::finalizeStream(bool ok)
{
    m_sseBuffer.clear();
    if (ok && m_streamingHasContent) {
        flushTtsBuffer(true);  // 把最后一句没标点结尾的尾巴也送出去
        persistHistory();
    } else if (!m_streamingHasContent) {
        m_model.clearLastIfEmpty();
    }
    m_ttsBuffer.clear();
    m_streamingHasContent = false;
    setStreaming(false);
}

void AiAssistant::flushTtsBuffer(bool finalize)
{
    if (!m_tts || m_ttsBuffer.isEmpty()) return;
    // 中文句末 + 换行 + 英文问感叹号；不切 '.'（避免在小数 / 序号上误切）
    static const QRegularExpression kSentenceEnd(QStringLiteral("[。？！；\\n!?]"));
    while (true) {
        QRegularExpressionMatch m = kSentenceEnd.match(m_ttsBuffer);
        if (!m.hasMatch()) break;
        const int end = m.capturedEnd();   // 含标点
        const QString sentence = m_ttsBuffer.left(end);
        m_ttsBuffer.remove(0, end);
        m_tts->enqueueSpeak(sentence);     // TTS 内部排队，第一句很快返回开始播
    }
    if (finalize && !m_ttsBuffer.trimmed().isEmpty()) {
        m_tts->enqueueSpeak(m_ttsBuffer);
        m_ttsBuffer.clear();
    }
}

void AiAssistant::setStreaming(bool on)
{
    if (m_streaming == on)
        return;
    m_streaming = on;
    emit streamingChanged();
}

void AiAssistant::setError(const QString &text)
{
    if (m_errorText == text)
        return;
    m_errorText = text;
    emit errorChanged();
}

void AiAssistant::clearError()
{
    if (m_errorText.isEmpty())
        return;
    m_errorText.clear();
    emit errorChanged();
}

QString AiAssistant::historyFilePath() const
{
    const QString dir = QStandardPaths::writableLocation(
        QStandardPaths::AppConfigLocation);
    QDir().mkpath(dir);
    return dir + QStringLiteral("/chat_history.json");
}

void AiAssistant::persistHistory() const
{
    QJsonArray arr;
    for (const auto &e : m_model.entries()) {
        if (e.error || e.role.isEmpty() || e.content.isEmpty())
            continue;
        QJsonObject o;
        o[QStringLiteral("role")] = e.role;
        o[QStringLiteral("content")] = e.content;
        arr.append(o);
    }
    QJsonObject root;
    root[QStringLiteral("messages")] = arr;

    const QString path = historyFilePath();
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    f.close();
}

void AiAssistant::loadHistory()
{
    const QString path = historyFilePath();
    QFile f(path);
    if (!f.exists())
        return;
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QByteArray data = f.readAll();
    f.close();

    const QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject())
        return;
    const QJsonArray arr = doc.object().value(QStringLiteral("messages")).toArray();
    for (const QJsonValue &v : arr) {
        const QJsonObject o = v.toObject();
        ChatMessagesModel::Entry e;
        e.role = o.value(QStringLiteral("role")).toString();
        e.content = o.value(QStringLiteral("content")).toString();
        if (e.role.isEmpty() || e.content.isEmpty())
            continue;
        m_model.append(e);
    }
}
