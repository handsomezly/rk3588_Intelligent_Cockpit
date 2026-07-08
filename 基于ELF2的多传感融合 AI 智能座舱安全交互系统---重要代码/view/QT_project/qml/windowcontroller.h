#ifndef WINDOWCONTROLLER_H
#define WINDOWCONTROLLER_H

#include <QObject>

class QQuickView;
class QWindow;

class WindowController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool fullscreen READ fullscreen NOTIFY fullscreenChanged)

public:
    explicit WindowController(QQuickView *view, QObject *parent = nullptr);

    bool fullscreen() const;

    Q_INVOKABLE void toggleFullscreen();
    Q_INVOKABLE void setFullscreen(bool on);

signals:
    void fullscreenChanged();

private slots:
    void handleVisibilityChanged();

private:
    QQuickView *m_view;
    bool m_fullscreen;
};

#endif // WINDOWCONTROLLER_H
