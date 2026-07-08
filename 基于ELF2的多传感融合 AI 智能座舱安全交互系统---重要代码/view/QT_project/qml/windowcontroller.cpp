#include "windowcontroller.h"

#include <QQuickView>
#include <QWindow>

WindowController::WindowController(QQuickView *view, QObject *parent)
    : QObject(parent)
    , m_view(view)
    , m_fullscreen(false)
{
    if (m_view) {
        m_fullscreen = (m_view->visibility() == QWindow::FullScreen);
        connect(m_view, &QWindow::visibilityChanged, this, &WindowController::handleVisibilityChanged);
    }
}

bool WindowController::fullscreen() const { return m_fullscreen; }

void WindowController::toggleFullscreen()
{
    if (!m_view)
        return;
    setFullscreen(m_view->visibility() != QWindow::FullScreen);
}

void WindowController::setFullscreen(bool on)
{
    if (!m_view)
        return;
    if (on)
        m_view->showFullScreen();
    else
        m_view->showNormal();
}

void WindowController::handleVisibilityChanged()
{
    if (!m_view)
        return;
    const bool fs = (m_view->visibility() == QWindow::FullScreen);
    if (fs == m_fullscreen)
        return;
    m_fullscreen = fs;
    emit fullscreenChanged();
}
