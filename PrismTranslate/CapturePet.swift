import AppKit

/// Approved LIWE-13 A pose. Paths are in points relative to the selection's
/// top-left, with y down. The original BallView owns all head drawing.
@MainActor
final class CapturePet {
    private let skin: BallSkin
    private let head: BallView

    init(skin: BallSkin) {
        precondition(skin != .classic)
        self.skin = skin
        head = BallView(frame: CGRect(origin: .zero, size: BallView.canvasSize))
        head.skin = skin
        head.setHeadphonesInitially(false)
        // No animation timer: idle head, fixed 18/23 uniform scale.
        head.setAccessibilityElement(false)
    }

    func drawBack(in context: CGContext, at topLeft: CGPoint) {
        local(context, topLeft) {
            context.saveGState()
            context.clip(to: CGRect(x: -20, y: -70, width: 150, height: 70))
            if skin == .panda {
                context.setShadow(offset: CGSize(width: 0, height: 0.8), blur: 1.4,
                                  color: color(0, 0, 0, 0.12))
            }
            fill(context, Self.torso)
            if skin == .cat {
                for x: CGFloat in [59, 67, 75] {
                    stroke(context, path([.move(x, -23), .quad(x - 1, -18, x - 3, -15)]),
                           color(0.86, 0.45, 0.15), 1.6)
                }
            } else if skin == .shiba {
                solid(context, path([.move(45, -3), .curve(60, -8, 75, -5, 84, 0),
                                     .line(45, 0), .close]), color(1, 0.97, 0.92))
            }
            context.restoreGState()
        }
    }

    func drawFront(in context: CGContext, at topLeft: CGPoint) {
        local(context, topLeft) {
            if skin != .chick {
                context.setFillColor(color(0, 0, 0, 0.12))
                context.fillEllipse(in: CGRect(x: -7, y: 7, width: 18, height: 3))
                context.setFillColor(color(0, 0, 0, 0.15))
                context.fillEllipse(in: CGRect(x: 29, y: 0, width: 19, height: 3))
            }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1.2), blur: 1.5,
                              color: color(0, 0, 0, 0.12))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            fill(context, skin == .chick ? Self.fanWing : Self.frontLeg)
            fill(context, skin == .chick ? Self.upperWing : Self.upperLeg)
            context.endTransparencyLayer()
            context.restoreGState()
            if skin == .chick {
                // Fan-wing option 02 only: three staggered feather tips are
                // part of each continuous silhouette. No paw/toe marks.
                solid(context, path([.move(-1, -2), .curve(-7, 6, -6, 14, -3, 17),
                                     .curve(1, 12, 4, 5, 5, 0), .curve(5, -3, 2, -4, -1, -2),
                                     .close]), color(1, 1, 1, 0.16))
            } else {
                stroke(context, path([.move(1, -1), .curve(-1, 6, -2, 13, -1, 17)]),
                       color(1, 1, 1, 0.23), 0.8)
                for x: CGFloat in [0, 4] {
                    stroke(context, path([.move(x, 19), .quad(x + 0.4, 21, x, 23)]),
                           color(0.30, 0.21, 0.14, 0.30), 0.65)
                }
                for x: CGFloat in [37, 41] {
                    stroke(context, path([.move(x, 10), .quad(x + 0.3, 12, x, 13)]),
                           color(0.30, 0.21, 0.14, 0.27), 0.6)
                }
            }
            context.saveGState()
            context.translateBy(x: 10, y: -26)
            context.scaleBy(x: 18 / 23, y: -18 / 23)
            context.translateBy(x: -BallView.ballCenter.x, y: -BallView.ballCenter.y)
            head.draw(head.bounds)
            context.restoreGState()
        }
    }

    private func local(_ context: CGContext, _ origin: CGPoint, _ draw: () -> Void) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        draw()
        context.restoreGState()
    }

    private func fill(_ context: CGContext, _ path: CGPath) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        // One shared gradient prevents seams at the shoulders/wing roots.
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [skin.palette.top, skin.palette.bottom] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: -27),
                                   end: CGPoint(x: 0, y: skin == .chick ? 31 : 24),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private func solid(_ context: CGContext, _ path: CGPath, _ color: CGColor) {
        context.addPath(path); context.setFillColor(color); context.fillPath()
    }

    private func stroke(_ context: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        context.addPath(path)
        context.setStrokeColor(color); context.setLineWidth(width)
        context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private enum Command {
        case move(CGFloat, CGFloat), line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case quad(CGFloat, CGFloat, CGFloat, CGFloat), close
    }

    private func path(_ commands: [Command]) -> CGPath { Self.makePath(commands) }
    private static func makePath(_ commands: [Command]) -> CGPath {
        let path = CGMutablePath()
        for command in commands {
            switch command {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .curve(x1, y1, x2, y2, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
            case let .quad(x1, y1, x, y):
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private static let torso = makePath([
        .move(5, -14), .curve(20, -28, 48, -31, 67, -25), .curve(84, -24, 91, -15, 91, -4),
        .curve(91, 15, 71, 25, 43, 22), .curve(17, 21, 2, 12, 3, 1),
        .curve(3, -5, 4, -10, 5, -14), .close
    ])
    private static let frontLeg = makePath([
        .move(2, -17), .curve(7, -22, 16, -17, 16, -10), .curve(16, -2, 11, 6, 11, 14),
        .curve(15, 21, 10, 25, 4, 25), .curve(-3, 25, -7, 22, -7, 16),
        .curve(-7, 9, -3, 2, -3, -5), .curve(-3, -11, -2, -15, 2, -17), .close
    ])
    private static let upperLeg = makePath([
        .move(29, -18), .curve(35, -23, 42, -18, 43, -11), .curve(44, -5, 44, -2, 47, 2),
        .curve(51, 9, 46, 14, 40, 14), .curve(33, 15, 28, 11, 29, 5),
        .curve(29, -1, 25, -11, 29, -18), .close
    ])
    private static let fanWing = makePath([
        .move(18, -20), .curve(30, -23, 35, -15, 29, -5), .curve(22, 7, 11, 21, -1, 30),
        .curve(-4, 32, -7, 31, -6, 26), .curve(-11, 29, -13, 25, -9, 20),
        .curve(-14, 22, -14, 17, -11, 12), .curve(-14, 7, -9, -6, -1, -12),
        .curve(4, -16, 11, -19, 18, -20), .close
    ])
    private static let upperWing = makePath([
        .move(30, -17), .curve(41, -24, 51, -17, 56, -8), .curve(63, 2, 70, 8, 68, 12),
        .curve(67, 14, 60, 12, 57, 10), .curve(60, 14, 57, 16, 52, 12),
        .curve(52, 15, 47, 14, 43, 10), .curve(36, 5, 29, -3, 28, -10),
        .curve(27, -13, 28, -16, 30, -17), .close
    ])
}
