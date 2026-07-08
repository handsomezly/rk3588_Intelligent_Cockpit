#ifndef CAMERAVIEW_H
#define CAMERAVIEW_H

#include <QImage>
#include <QMutex>
#include <QQuickItem>
#include <QRectF>
#include <QSize>

// Scene-graph live-video sink. Replaces the old QQuickImageProvider +
// Image{source:url} pattern, which flickered on the Mali/RK3588 path: that
// pattern rebuilt the Image source URL every frame and reloaded asynchronously
// (cache:false), so the texture briefly cleared between loads, and it rescaled
// every frame on the CPU inside requestImage().
//
// CameraView instead holds the latest QImage and uploads it as a single texture
// in updatePaintNode() on the render thread — one texture per frame, no URL,
// no async loader, no CPU rescale. Plain SG texturing, unrelated to the Qt3D /
// MSAA Mali caveats documented in CLAUDE.md.
//
// setImage() is called on the GUI thread (frames are queued there from the
// FatigueClient worker). updatePaintNode() runs on the render thread; m_image /
// m_contentRect are guarded by m_mutex.
//
// The texture is drawn PreserveAspectFit inside the item; `contentRect` exposes
// the actual drawn video rectangle (item coordinates) so QML overlays can map
// face/eye boxes (given in camera pixel space) onto the displayed frame.
class CameraView : public QQuickItem
{
    Q_OBJECT
    Q_PROPERTY(QRectF contentRect READ contentRect NOTIFY contentRectChanged)
    Q_PROPERTY(int frameWidth READ frameWidth NOTIFY frameSizeChanged)
    Q_PROPERTY(int frameHeight READ frameHeight NOTIFY frameSizeChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)

public:
    explicit CameraView(QQuickItem *parent = nullptr);

    QRectF contentRect() const;
    int frameWidth() const { return m_frameSize.width(); }
    int frameHeight() const { return m_frameSize.height(); }
    bool hasFrame() const { return m_hasFrame; }

    // Push the latest frame (GUI thread). Triggers a repaint.
    Q_INVOKABLE void setImage(const QImage &image);
    // Drop the current frame (e.g. on disconnect) so the item clears.
    Q_INVOKABLE void clear();

signals:
    void contentRectChanged();
    void frameSizeChanged();
    void hasFrameChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) override;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
#else
    void geometryChanged(const QRectF &newGeometry, const QRectF &oldGeometry) override;
#endif

private:
    void recomputeContentRect();

    mutable QMutex m_mutex;
    QImage m_image;            // latest frame, guarded by m_mutex
    bool m_textureDirty = false;
    QSize m_frameSize;
    QRectF m_contentRect;      // drawn video rect in item coords, guarded by m_mutex
    bool m_hasFrame = false;
};

#endif // CAMERAVIEW_H
