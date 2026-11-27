"""Compose a global selection across screen origins and pixel ratios."""

from PySide6.QtCore import QRect, QRectF
from PySide6.QtGui import QColor, QImage, QPainter, QPixmap


def crop_screens(frames, selection):
    intersecting = [(geometry, image, geometry.intersected(selection))
                    for geometry, image in frames if geometry.intersects(selection)]
    if not intersecting:
        return QPixmap()
    ratio = max(image.devicePixelRatio() for _, image, _ in intersecting)
    result = QImage(round(selection.width() * ratio), round(selection.height() * ratio),
                    QImage.Format.Format_ARGB32_Premultiplied)
    result.fill(QColor("white"))
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    for geometry, image, overlap in intersecting:
        source_ratio = image.devicePixelRatio()
        local = overlap.translated(-geometry.topLeft())
        source = QRect(round(local.x() * source_ratio), round(local.y() * source_ratio),
                       round(local.width() * source_ratio), round(local.height() * source_ratio))
        offset = overlap.topLeft() - selection.topLeft()
        destination = QRectF(offset.x() * ratio, offset.y() * ratio,
                             overlap.width() * ratio, overlap.height() * ratio)
        cropped = image.copy(source)
        cropped.setDevicePixelRatio(1)
        painter.drawPixmap(destination, cropped, QRectF(cropped.rect()))
    painter.end()
    # OCR consumes physical pixels, not display points.
    return QPixmap.fromImage(result)
