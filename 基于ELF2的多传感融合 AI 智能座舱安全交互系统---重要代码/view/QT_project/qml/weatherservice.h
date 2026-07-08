#ifndef WEATHERSERVICE_H
#define WEATHERSERVICE_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantList>

class QNetworkAccessManager;
class QNetworkReply;

class WeatherService : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString city READ city WRITE setCity NOTIFY cityChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)
    Q_PROPERTY(bool hasError READ hasError NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QString cityName READ cityName NOTIFY dataChanged)
    Q_PROPERTY(QString province READ province NOTIFY dataChanged)
    Q_PROPERTY(QString reportTime READ reportTime NOTIFY dataChanged)
    Q_PROPERTY(int temperature READ temperature NOTIFY dataChanged)
    Q_PROPERTY(QString weather READ weather NOTIFY dataChanged)
    Q_PROPERTY(QString windDirection READ windDirection NOTIFY dataChanged)
    Q_PROPERTY(QString windPower READ windPower NOTIFY dataChanged)
    Q_PROPERTY(int humidity READ humidity NOTIFY dataChanged)
    Q_PROPERTY(QVariantList forecast READ forecast NOTIFY dataChanged)

public:
    explicit WeatherService(QObject *parent = nullptr);

    QString city() const;
    void setCity(const QString &city);

    bool loading() const;
    bool hasError() const;
    QString errorText() const;

    QString cityName() const;
    QString province() const;
    QString reportTime() const;
    int temperature() const;
    QString weather() const;
    QString windDirection() const;
    QString windPower() const;
    int humidity() const;
    QVariantList forecast() const;

    Q_INVOKABLE void refresh();

signals:
    void cityChanged();
    void stateChanged();
    void dataChanged();

private slots:
    void handleLiveReply();
    void handleForecastReply();

private:
    void requestLive();
    void requestForecast();
    void setLoading(bool loading);
    void setError(const QString &text);
    void clearError();
    void finishRequest();

    QNetworkAccessManager *m_network;
    QTimer m_refreshTimer;

    QString m_city;
    bool m_loading;
    QString m_errorText;
    int m_pendingRequests;

    QString m_cityName;
    QString m_province;
    QString m_reportTime;
    int m_temperature;
    QString m_weather;
    QString m_windDirection;
    QString m_windPower;
    int m_humidity;
    QVariantList m_forecast;
};

#endif // WEATHERSERVICE_H
