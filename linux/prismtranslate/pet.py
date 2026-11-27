"""Product pet artwork shared by the launcher and capture selection.

Geometry, palettes and expressions follow FloatingBall.swift/CapturePet.swift.
All head coordinates are in points, y up, around a radius of 23.
"""

import math

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QLinearGradient, QPainterPath, QPen, QRadialGradient, QTransform

SKINS = {"classic": "经典棱镜", "cat": "橘猫", "shiba": "柴犬", "panda": "熊猫", "chick": "小黄鸡"}
PALETTES = {
    "classic": ("#5c70fa", "#8c4deb", "#7361fa"),
    "cat": ("#ffbd6b", "#f28c38", "#ed7a26"),
    "shiba": ("#ed9e4d", "#db8038", "#d9732e"),
    "panda": ("#ffffff", "#e0e3e8", "#333338"),
    "chick": ("#ffe86b", "#ffc738", "#fa991a"),
}


def path(commands):
    result = QPainterPath()
    for command in commands:
        operation, *values = command
        if operation == "M":
            result.moveTo(*values)
        elif operation == "L":
            result.lineTo(*values)
        elif operation == "C":
            result.cubicTo(*values)
        elif operation == "Q":
            result.quadTo(*values)
        else:
            result.closeSubpath()
    return result


def ellipse(painter, x, y, w, h, color, rotation=0):
    painter.save()
    painter.translate(x, y)
    painter.rotate(rotation)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QColor(color))
    painter.drawEllipse(QRectF(-w / 2, -h / 2, w, h))
    painter.restore()


def stroke(painter, shape, color, width):
    painter.setPen(QPen(QColor(color), width, Qt.PenStyle.SolidLine,
                        Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
    painter.setBrush(Qt.BrushStyle.NoBrush)
    painter.drawPath(shape)


def arc(cx, cy, radius, start, end):
    result = QPainterPath()
    for index in range(33):
        angle = start + (end - start) * index / 32
        point = QPointF(cx + radius * math.cos(angle), cy + radius * math.sin(angle))
        result.moveTo(point) if index == 0 else result.lineTo(point)
    return result


def head(painter, skin, mood="idle", gaze=(0, 0), openness=1, sleeping=False, headphones=False, time=0):
    """Draw the original 46 pt head, without owning an animation timer."""
    painter.save()
    painter.scale(1, -1)
    r = 23
    top, bottom, accent = PALETTES[skin]
    gradient = QLinearGradient(-r if skin == "classic" else 0, r, r if skin == "classic" else 0, -r)
    gradient.setColorAt(0, QColor(top))
    gradient.setColorAt(1, QColor(bottom))
    if skin in ("cat", "shiba"):
        angle, tip, spread = (38, 1.36, 24) if skin == "cat" else (40, 1.32, 22)
        for side in (-1, 1):
            for length, width, color in ((tip, spread, bottom),
                                         (1.2 if skin == "cat" else 1.18, 12, "#ffb8bf" if skin == "cat" else "#ffe6c7")):
                points = []
                for degrees, distance in ((side * angle - width, .78), (side * angle, length),
                                          (side * angle + width, .78)):
                    radians = math.radians(degrees)
                    points.append((math.sin(radians) * r * distance, math.cos(radians) * r * distance))
                ear = path([("M", *points[0]), ("L", *points[1]), ("L", *points[2]), ("Z",)])
                painter.setBrush(QColor(color))
                painter.setPen(QPen(QColor(color), .12 * r, Qt.PenStyle.SolidLine,
                                    Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
                painter.drawPath(ear)
    elif skin == "panda":
        for side in (-1, 1):
            angle = math.radians(side * 42)
            ellipse(painter, math.sin(angle) * .88 * r, math.cos(angle) * .88 * r, .68 * r, .68 * r, "#26262b")
    elif skin == "chick":
        for degrees in (-16, 0, 16):
            angle = math.radians(degrees)
            ellipse(painter, math.sin(angle) * 1.04 * r, math.cos(angle) * 1.04 * r,
                    .16 * r, .38 * r, "#fab829", -degrees)
    painter.setBrush(gradient)
    painter.setPen(QPen(QColor("#40ffffff"), 1))
    painter.drawEllipse(QRectF(-r, -r, 2 * r, 2 * r))
    if skin in ("cat", "shiba"):
        painter.save()
        clip = QPainterPath()
        clip.addEllipse(QRectF(-r, -r, 2 * r, 2 * r))
        painter.setClipPath(clip)
        if skin == "cat":
            for x, top_y in ((-.2, .86), (0, .98), (.2, .86)):
                stroke(painter, path([("M", x * r, top_y * r), ("L", x * r, .62 * r)]), "#db7326", .1 * r)
            ellipse(painter, 0, -.32 * r, .95 * r, .6 * r, "#ffedd1")
        else:
            ellipse(painter, 0, -.45 * r, 1.55 * r, r, "#fff7eb")
            for side in (-1, 1):
                ellipse(painter, side * .3 * r, .38 * r, .17 * r, .1 * r, "#fff2db")
        painter.restore()
    if skin == "panda":
        for side in (-1, 1):
            ellipse(painter, side * .36 * r, 0, .36 * r, .5 * r, "#26262b", math.degrees(side * .45))
    if skin == "classic":
        painter.save()
        painter.scale(1, -1)
        font = QFont()
        font.setPixelSize(19)
        font.setWeight(QFont.Weight.DemiBold)
        painter.setFont(font)
        painter.setPen(QColor("white"))
        painter.drawText(QRectF(-r, -r, 2 * r, 2 * r), Qt.AlignmentFlag.AlignCenter, "译")
        painter.restore()
    else:
        dark = "#33241c"
        eye_y = {"cat": .06, "shiba": .08, "panda": .02, "chick": .1}[skin] * r
        spacing = (.36 if skin in ("cat", "panda") else .34) * r
        expression = "sleep" if sleeping else mood
        for side in (-1, 1):
            cx, cy = side * spacing, eye_y
            color = "white" if skin == "panda" else dark
            if expression == "happy":
                stroke(painter, arc(cx, cy - .19 * r * .25, .15 * r * .62, .15 * math.pi, .85 * math.pi), color, .065 * r)
            elif expression == "sleep":
                stroke(painter, arc(cx, cy + .19 * r * .25, .15 * r * .62, 1.15 * math.pi, 1.85 * math.pi), color, .065 * r)
            elif expression == "sad":
                stroke(painter, path([("M", cx + side * .083 * r, cy + .076 * r),
                                      ("L", cx - side * .068 * r, cy),
                                      ("L", cx + side * .083 * r, cy - .076 * r)]), color, .065 * r)
            elif openness < .3:
                stroke(painter, path([("M", cx - .09 * r, cy), ("L", cx + .09 * r, cy)]), color, .065 * r)
            else:
                x, y = cx + gaze[0] * .08 * r, cy + gaze[1] * .06 * r
                if skin == "panda":
                    ellipse(painter, cx, cy, .15 * r, .19 * r * openness, color)
                    ellipse(painter, cx + gaze[0] * .048 * r, cy + gaze[1] * .036 * r,
                            .093 * r, .093 * r * openness, dark)
                else:
                    ellipse(painter, x, y, .15 * r, .19 * r * openness, color)
                    ellipse(painter, x + .033 * r, y + .0418 * r * openness, .054 * r, .054 * r, "white")
        blush_y, blush_spacing = {"cat": (-.2, .6), "shiba": (-.2, .55),
                                  "panda": (-.34, .62), "chick": (-.18, .56)}[skin]
        blush = QColor(255, 107, 128, 140 if expression == "happy" else 82)
        for side in (-1, 1):
            ellipse(painter, side * blush_spacing * r, blush_y * r, .22 * r, .13 * r, blush)
        nose_y = {"cat": -.13, "shiba": -.15, "panda": -.26, "chick": -.13}[skin] * r
        if skin == "cat":
            painter.fillPath(path([("M", -.07 * r, -.1 * r), ("L", .07 * r, -.1 * r),
                                   ("L", 0, -.17 * r), ("Z",)]), QColor("#f2808c"))
        elif skin == "chick":
            gap = .07 * r if expression == "happy" else 0
            painter.fillPath(path([("M", -.12 * r, -.13 * r - gap), ("L", .12 * r, -.13 * r - gap),
                                   ("L", 0, -.24 * r - gap), ("Z",)]), QColor("#ed7a1a"))
            painter.fillPath(path([("M", -.14 * r, -.13 * r), ("L", 0, -.02 * r),
                                   ("L", .14 * r, -.13 * r), ("Z",)]), QColor("#ff9926"))
        else:
            ellipse(painter, 0, nose_y, (.15 if skin == "panda" else .18) * r,
                    (.1 if skin == "panda" else .12) * r, dark)
        if skin != "chick":
            mouth_y = {"cat": -.2, "shiba": -.24, "panda": -.33}[skin] * r
            if expression == "happy":
                mouth = arc(0, mouth_y, .11 * r, math.pi, 2 * math.pi)
                mouth.closeSubpath()
                painter.fillPath(mouth, QColor("#d95261"))
            elif expression == "sad":
                stroke(painter, arc(0, mouth_y - .12 * r, .09 * r, .2 * math.pi, .8 * math.pi), dark, .045 * r)
            else:
                for side in (-1, 1):
                    stroke(painter, arc(side * .065 * r, mouth_y, .065 * r, math.pi, 2 * math.pi), dark, .045 * r)
            if skin == "cat":
                for side in (-1, 1):
                    for start_y, end_y in ((-.16, -.1), (-.25, -.32)):
                        stroke(painter, path([("M", side * .5 * r, start_y * r),
                                              ("L", side * .95 * r, end_y * r)]), "#908c522e", .035 * r)
    highlight = QRadialGradient(-.36 * r, .5 * r, .5 * r)
    highlight.setColorAt(0, QColor(255, 255, 255, 97 if skin == "classic" else 76))
    highlight.setColorAt(1, QColor(255, 255, 255, 0))
    highlight_shape = QPainterPath()
    highlight_shape.addEllipse(QRectF(-r, -r, 2 * r, 2 * r))
    painter.fillPath(highlight_shape, highlight)
    if headphones:
        painter.save()
        painter.setOpacity(float(headphones))
        if skin == "chick":
            clip = QPainterPath()
            clip.addRect(QRectF(-36, -36, 72, 72))
            for degrees in (-16, 0, 16):
                angle = math.radians(degrees)
                feather = QPainterPath()
                feather.addEllipse(QRectF(-.08 * r, -.19 * r, .16 * r, .38 * r))
                transform = QTransform().translate(math.sin(angle) * 1.04 * r, math.cos(angle) * 1.04 * r).rotate(-degrees)
                clip.addPath(transform.map(feather))
            painter.setClipPath(clip)
        stroke(painter, arc(0, 0, 1.04 * r, math.radians(-5), math.radians(185)), "#99ffffff", .12 * r + 2)
        stroke(painter, arc(0, 0, 1.04 * r, math.radians(-5), math.radians(185)), "#2e3340", .12 * r)
        for side in (-1, 1):
            painter.setPen(QPen(QColor("#99ffffff"), 1))
            painter.setBrush(QColor("#2e3340"))
            painter.drawRoundedRect(QRectF(side * 1.04 * r - .18 * r, -.41 * r, .36 * r, .64 * r), .12 * r, .12 * r)
        painter.restore()
    if mood == "busy":
        angle = -time * 2 * math.pi * .9
        track = QColor(accent)
        track.setAlphaF(.18)
        stroke(painter, arc(0, 0, r + 3.5, 0, 2 * math.pi), track, 2.4)
        stroke(painter, arc(0, 0, r + 3.5, angle, angle + .6 * math.pi), accent, 2.4)
    if sleeping and skin != "classic":
        painter.save()
        painter.scale(1, -1)
        for index, size in enumerate((.34, .26)):
            phase = (time / 2.4 + index * .5) % 1
            color = QColor(accent)
            color.setAlphaF(math.sin(phase * math.pi))
            painter.setPen(color)
            font = QFont()
            font.setPixelSize(round(size * r))
            font.setWeight(QFont.Weight.Bold)
            painter.setFont(font)
            painter.drawText(QPointF((.62 + phase * .28) * r, -(.55 + phase * .4) * r), "z")
        painter.restore()
    painter.restore()


# Approved capture pose, copied as path coordinates from CapturePet.swift.
TORSO = [("M", 5, -14), ("C", 20, -28, 48, -31, 67, -25), ("C", 84, -24, 91, -15, 91, -4),
         ("C", 91, 15, 71, 25, 43, 22), ("C", 17, 21, 2, 12, 3, 1), ("C", 3, -5, 4, -10, 5, -14), ("Z",)]
FRONT_LEG = [("M", 2, -17), ("C", 7, -22, 16, -17, 16, -10), ("C", 16, -2, 11, 6, 11, 14),
             ("C", 15, 21, 10, 25, 4, 25), ("C", -3, 25, -7, 22, -7, 16),
             ("C", -7, 9, -3, 2, -3, -5), ("C", -3, -11, -2, -15, 2, -17), ("Z",)]
UPPER_LEG = [("M", 29, -18), ("C", 35, -23, 42, -18, 43, -11), ("C", 44, -5, 44, -2, 47, 2),
             ("C", 51, 9, 46, 14, 40, 14), ("C", 33, 15, 28, 11, 29, 5),
             ("C", 29, -1, 25, -11, 29, -18), ("Z",)]
FAN_WING = [("M", 18, -20), ("C", 30, -23, 35, -15, 29, -5), ("C", 22, 7, 11, 21, -1, 30),
            ("C", -4, 32, -7, 31, -6, 26), ("C", -11, 29, -13, 25, -9, 20),
            ("C", -14, 22, -14, 17, -11, 12), ("C", -14, 7, -9, -6, -1, -12),
            ("C", 4, -16, 11, -19, 18, -20), ("Z",)]
UPPER_WING = [("M", 30, -17), ("C", 41, -24, 51, -17, 56, -8), ("C", 63, 2, 70, 8, 68, 12),
              ("C", 67, 14, 60, 12, 57, 10), ("C", 60, 14, 57, 16, 52, 12),
              ("C", 52, 15, 47, 14, 43, 10), ("C", 36, 5, 29, -3, 28, -10),
              ("C", 27, -13, 28, -16, 30, -17), ("Z",)]


def capture_pet(painter, skin, corner, front):
    painter.save()
    painter.translate(corner)
    gradient = QLinearGradient(0, -27, 0, 31)
    gradient.setColorAt(0, QColor(PALETTES[skin][0]))
    gradient.setColorAt(1, QColor(PALETTES[skin][1]))
    if not front:
        painter.setClipRect(QRectF(-20, -70, 150, 70))
        painter.fillPath(path(TORSO), gradient)
        if skin == "cat":
            for x in (59, 67, 75):
                stroke(painter, path([("M", x, -23), ("Q", x - 1, -18, x - 3, -15)]), "#db7326", 1.6)
        elif skin == "shiba":
            painter.fillPath(path([("M", 45, -3), ("C", 60, -8, 75, -5, 84, 0),
                                   ("L", 45, 0), ("Z",)]), QColor("#fff7eb"))
    else:
        if skin != "chick":
            ellipse(painter, 2, 8.5, 18, 3, QColor(0, 0, 0, 31))
            ellipse(painter, 38.5, 1.5, 19, 3, QColor(0, 0, 0, 38))
        painter.fillPath(path(FAN_WING if skin == "chick" else FRONT_LEG), gradient)
        painter.fillPath(path(UPPER_WING if skin == "chick" else UPPER_LEG), gradient)
        if skin == "chick":
            painter.fillPath(path([("M", -1, -2), ("C", -7, 6, -6, 14, -3, 17),
                                   ("C", 1, 12, 4, 5, 5, 0), ("C", 5, -3, 2, -4, -1, -2), ("Z",)]),
                             QColor(255, 255, 255, 41))
        else:
            stroke(painter, path([("M", 1, -1), ("C", -1, 6, -2, 13, -1, 17)]), QColor(255, 255, 255, 59), .8)
            for x in (0, 4):
                stroke(painter, path([("M", x, 19), ("Q", x + .4, 21, x, 23)]), QColor(77, 54, 36, 77), .65)
            for x in (37, 41):
                stroke(painter, path([("M", x, 10), ("Q", x + .3, 12, x, 13)]), QColor(77, 54, 36, 69), .6)
        painter.translate(10, -26)
        painter.scale(18 / 23, 18 / 23)
        head(painter, skin)
    painter.restore()
