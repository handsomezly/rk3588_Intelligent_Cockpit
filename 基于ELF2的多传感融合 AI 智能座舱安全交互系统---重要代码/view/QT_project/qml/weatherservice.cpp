#include "weatherservice.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantMap>

namespace {

// 在这里粘贴你的高德 Web 服务 API Key（控制台 → Web 服务）。
// 留空或保持占位会让 weatherService.hasError 返回 true，并在页面上提示。
const QString kAmapApiKey = QStringLiteral("3542ab669010b73c35b2400847ec40db");

const QString kAmapEndpoint = QStringLiteral("https://restapi.amap.com/v3/weather/weatherInfo");
const int kRefreshIntervalMs = 10 * 60 * 1000;

}

WeatherService::WeatherService(QObject *parent)
    : QObject(parent)
    , m_network(new QNetworkAccessManager(this))
    , m_city(QStringLiteral("421200"))
    , m_loading(false)
    , m_pendingRequests(0)
    , m_temperature(0)
    , m_humidity(0)
{
    m_refreshTimer.setInterval(kRefreshIntervalMs);
    connect(&m_refreshTimer, &QTimer::timeout, this, &WeatherService::refresh);
    m_refreshTimer.start();
    refresh();
}

QString WeatherService::city() const { return m_city; }

void WeatherService::setCity(const QString &city)
{
    if (m_city == city)
        return;
    m_city = city;
    emit cityChanged();
    refresh();
}

bool WeatherService::loading() const { return m_loading; }
bool WeatherService::hasError() const { return !m_errorText.isEmpty(); }
QString WeatherService::errorText() const { return m_errorText; }

QString WeatherService::cityName() const { return m_cityName; }
QString WeatherService::province() const { return m_province; }
QString WeatherService::reportTime() const { return m_reportTime; }
int WeatherService::temperature() const { return m_temperature; }
QString WeatherService::weather() const { return m_weather; }
QString WeatherService::windDirection() const { return m_windDirection; }
QString WeatherService::windPower() const { return m_windPower; }
int WeatherService::humidity() const { return m_humidity; }
QVariantList WeatherService::forecast() const { return m_forecast; }

void WeatherService::refresh()
{
    clearError();
    if (kAmapApiKey.isEmpty() || kAmapApiKey == QStringLiteral("YOUR_AMAP_KEY")) {
        setError(QStringLiteral("请在 weatherservice.cpp 中填入高德 API Key"));
        return;
    }
    requestLive();
    requestForecast();
}

void WeatherService::requestLive()
{
    QUrl url(kAmapEndpoint);
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("key"), kAmapApiKey);
    q.addQueryItem(QStringLiteral("city"), m_city);
    q.addQueryItem(QStringLiteral("extensions"), QStringLiteral("base"));
    q.addQueryItem(QStringLiteral("output"), QStringLiteral("JSON"));
    url.setQuery(q);
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", "ELF2-Cockpit/1.0");
    auto *reply = m_network->get(req);
    ++m_pendingRequests;
    setLoading(true);
    connect(reply, &QNetworkReply::finished, this, &WeatherService::handleLiveReply);
}

void WeatherService::requestForecast()
{
    QUrl url(kAmapEndpoint);
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("key"), kAmapApiKey);
    q.addQueryItem(QStringLiteral("city"), m_city);
    q.addQueryItem(QStringLiteral("extensions"), QStringLiteral("all"));
    q.addQueryItem(QStringLiteral("output"), QStringLiteral("JSON"));
    url.setQuery(q);
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent", "ELF2-Cockpit/1.0");
    auto *reply = m_network->get(req);
    ++m_pendingRequests;
    setLoading(true);
    connect(reply, &QNetworkReply::finished, this, &WeatherService::handleForecastReply);
}

void WeatherService::handleLiveReply()
{
    auto *reply = qobject_cast<QNetworkReply *>(sender());
    if (!reply)
        return;
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        setError(QStringLiteral("网络异常：") + reply->errorString());
        finishRequest();
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
    const QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("status")).toString() != QStringLiteral("1")) {
        setError(QStringLiteral("高德返回错误：") + obj.value(QStringLiteral("info")).toString());
        finishRequest();
        return;
    }

    const QJsonArray lives = obj.value(QStringLiteral("lives")).toArray();
    if (lives.isEmpty()) {
        setError(QStringLiteral("无实时数据"));
        finishRequest();
        return;
    }

    const QJsonObject live = lives.first().toObject();
    m_province = live.value(QStringLiteral("province")).toString();
    m_cityName = live.value(QStringLiteral("city")).toString();
    m_weather = live.value(QStringLiteral("weather")).toString();
    m_temperature = live.value(QStringLiteral("temperature")).toString().toInt();
    m_windDirection = live.value(QStringLiteral("winddirection")).toString();
    m_windPower = live.value(QStringLiteral("windpower")).toString();
    m_humidity = live.value(QStringLiteral("humidity")).toString().toInt();
    m_reportTime = live.value(QStringLiteral("reporttime")).toString();
    emit dataChanged();
    finishRequest();
}

void WeatherService::handleForecastReply()
{
    auto *reply = qobject_cast<QNetworkReply *>(sender());
    if (!reply)
        return;
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        setError(QStringLiteral("网络异常：") + reply->errorString());
        finishRequest();
        return;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
    const QJsonObject obj = doc.object();
    if (obj.value(QStringLiteral("status")).toString() != QStringLiteral("1")) {
        setError(QStringLiteral("高德返回错误：") + obj.value(QStringLiteral("info")).toString());
        finishRequest();
        return;
    }

    const QJsonArray forecasts = obj.value(QStringLiteral("forecasts")).toArray();
    if (forecasts.isEmpty()) {
        setError(QStringLiteral("无预报数据"));
        finishRequest();
        return;
    }

    const QJsonObject firstCity = forecasts.first().toObject();
    QVariantList list;
    for (const QJsonValue &item : firstCity.value(QStringLiteral("casts")).toArray()) {
        const QJsonObject cast = item.toObject();
        QVariantMap m;
        m[QStringLiteral("date")] = cast.value(QStringLiteral("date")).toString();
        m[QStringLiteral("week")] = cast.value(QStringLiteral("week")).toString();
        m[QStringLiteral("dayWeather")] = cast.value(QStringLiteral("dayweather")).toString();
        m[QStringLiteral("nightWeather")] = cast.value(QStringLiteral("nightweather")).toString();
        m[QStringLiteral("dayTemp")] = cast.value(QStringLiteral("daytemp")).toString().toInt();
        m[QStringLiteral("nightTemp")] = cast.value(QStringLiteral("nighttemp")).toString().toInt();
        m[QStringLiteral("dayWind")] = cast.value(QStringLiteral("daywind")).toString();
        m[QStringLiteral("nightWind")] = cast.value(QStringLiteral("nightwind")).toString();
        m[QStringLiteral("dayPower")] = cast.value(QStringLiteral("daypower")).toString();
        m[QStringLiteral("nightPower")] = cast.value(QStringLiteral("nightpower")).toString();
        list.append(m);
    }
    m_forecast = list;
    emit dataChanged();
    finishRequest();
}

void WeatherService::setLoading(bool loading)
{
    if (m_loading == loading)
        return;
    m_loading = loading;
    emit stateChanged();
}

void WeatherService::setError(const QString &text)
{
    if (m_errorText == text)
        return;
    m_errorText = text;
    emit stateChanged();
}

void WeatherService::clearError()
{
    if (m_errorText.isEmpty())
        return;
    m_errorText.clear();
    emit stateChanged();
}

void WeatherService::finishRequest()
{
    if (m_pendingRequests > 0)
        --m_pendingRequests;
    if (m_pendingRequests <= 0)
        setLoading(false);
}
