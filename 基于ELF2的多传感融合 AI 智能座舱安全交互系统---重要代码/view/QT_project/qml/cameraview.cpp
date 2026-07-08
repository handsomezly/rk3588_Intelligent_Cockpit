#include "cameraview.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

CameraView::CameraView(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}

QRectF CameraView::contentRect() const
{
    QMutexLocker locker(&m_mutex);
    return m_contentRect;
}

void CameraView::setImage(const QImage &image)
{
    // Convert once to a render-friendly format; createTextureFromImage would
    // convert anyway, doing it here keeps the render thread cheap.
    QImage frame = image.format() == QImage::Format_RGB888
                       ? image
                       : image.convertToFormat(QImage::Format_RGB888);

    bool sizeChanged = false;
    bool hadFrame = m_hasFrame;
    {
        QMutexLocker locker(&m_mutex);
        m_image = frame;
        m_textureDirty = true;
        if (m_frameSize != frame.size()) {
            m_frameSize = frame.size();
            sizeChanged = true;
        }
        m_hasFrame = !frame.isNull();
    }

    if (sizeChanged) {
        emit frameSizeChanged();
        recomputeContentRect();
    }
    if (m_hasFrame != hadFrame)
        emit hasFrameChanged();

    update();
}

void CameraView::clear()
{
    bool hadFrame;
    {
        QMutexLocker locker(&m_mutex);
        hadFrame = m_hasFrame;
        m_image = QImage();
        m_textureDirty = true;
        m_hasFrame = false;
    }
    if (hadFrame)
        emit hasFrameChanged();
    update();
}

void CameraView::recomputeContentRect()
{
    QSize frameSize;
    {
        QMutexLocker locker(&m_mutex);
        frameSize = m_frameSize;
    }

    QRectF rect(0, 0, width(), height());
    if (frameSize.width() > 0 && frameSize.height() > 0 && width() > 0 && height() > 0) {
        const qreal scale = qMin(width() / frameSize.width(),
                                 height() / frameSize.height());
        const qreal w = frameSize.width() * scale;
        const qreal h = frameSize.height() * scale;
        rect = QRectF((width() - w) / 2.0, (height() - h) / 2.0, w, h);
    }

    bool changed = false;
    {
        QMutexLocker locker(&m_mutex);
        if (m_contentRect != rect) {
            m_contentRect = rect;
            changed = true;
        }
    }
    if (changed)
        emit contentRectChanged();
}

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
void CameraView::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    recomputeContentRect();
}
#else
void CameraView::geometryChanged(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChanged(newGeometry, oldGeometry);
    recomputeContentRect();
}
#endif

QSGNode *CameraView::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    bool dirty;
    bool haveFrame;
    QImage localImage;
    QRectF rect;
    {
        QMutexLocker locker(&m_mutex);
        dirty = m_textureDirty;
        haveFrame = m_hasFrame;
        if (dirty)
            localImage = m_image;
        rect = m_contentRect;
        m_textureDirty = false;
    }

    if (!haveFrame) {
        delete oldNode;   // clear to transparent (black card shows through)
        return nullptr;
    }

    auto *node = static_cast<QSGSimpleTextureNode *>(oldNode);
    if (!node) {
        node = new QSGSimpleTextureNode();
        node->setFiltering(QSGTexture::Linear);
        node->setOwnsTexture(true);
    }

    if (dirty && !localImage.isNull() && window()) {
        QSGTexture *texture = window()->createTextureFromImage(localImage);
        // ownsTexture(true): setTexture() frees the previously owned texture,
        // so we must NOT delete it ourselves (that double-frees -> crash).
        node->setTexture(texture);
    }

    if (rect.isEmpty())
        rect = QRectF(0, 0, width(), height());
    node->setRect(rect);
    return node;
}
