import CoreGraphics

/// Selection uses global AppKit points (y up). Image crops use pixels (y down).
/// No UI rendering enters this boundary.
enum CaptureGeometry {
    struct Surface {
        let frame: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        var scaleX: CGFloat { CGFloat(pixelWidth) / frame.width }
        var scaleY: CGFloat { CGFloat(pixelHeight) / frame.height }
    }

    struct Crop {
        let surfaceIndex: Int
        let source: CGRect
        let destination: CGRect
    }

    struct Plan {
        let width: Int
        let height: Int
        let crops: [Crop]
    }

    static func selection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func pixelRect(selection: CGRect, surface: Surface) -> CGRect {
        let part = selection.intersection(surface.frame)
        guard !part.isNull, part.width > 0, part.height > 0 else { return .null }
        let left = floor((part.minX - surface.frame.minX) * surface.scaleX)
        let top = floor((surface.frame.maxY - part.maxY) * surface.scaleY)
        let right = ceil((part.maxX - surface.frame.minX) * surface.scaleX)
        let bottom = ceil((surface.frame.maxY - part.minY) * surface.scaleY)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: surface.pixelWidth, height: surface.pixelHeight))
    }

    /// Cross-display selections use the highest participating density. Gaps
    /// between displays cannot be submitted: they have no source pixels.
    static func plan(selection: CGRect, surfaces: [Surface]) -> Plan? {
        guard selection.width > 0, selection.height > 0,
              selection.width.isFinite, selection.height.isFinite else { return nil }
        let parts = surfaces.enumerated().compactMap { index, surface -> (Int, CGRect)? in
            let part = selection.intersection(surface.frame)
            return part.isNull || part.isEmpty ? nil : (index, part)
        }
        // Subtract each display from the uncovered rectangle set. This also
        // handles mirrored/overlapping display arrangements without area sums.
        var uncovered = [selection]
        for surface in surfaces {
            uncovered = uncovered.flatMap { subtract(surface.frame, from: $0) }
        }
        guard uncovered.isEmpty, !parts.isEmpty else { return nil }
        if parts.count == 1 {
            let source = pixelRect(selection: selection, surface: surfaces[parts[0].0])
            return Plan(width: Int(source.width), height: Int(source.height),
                        crops: [Crop(surfaceIndex: parts[0].0, source: source,
                                     destination: CGRect(origin: .zero, size: source.size))])
        }
        let scale = parts.reduce(CGFloat(0)) {
            max($0, surfaces[$1.0].scaleX, surfaces[$1.0].scaleY)
        }
        let width = Int(ceil(selection.width * scale))
        let height = Int(ceil(selection.height * scale))
        let crops = parts.map { index, part in
            let left = floor((part.minX - selection.minX) * scale)
            let top = floor((selection.maxY - part.maxY) * scale)
            let right = ceil((part.maxX - selection.minX) * scale)
            let bottom = ceil((selection.maxY - part.minY) * scale)
            return Crop(surfaceIndex: index,
                        source: pixelRect(selection: selection, surface: surfaces[index]),
                        destination: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        return Plan(width: width, height: height, crops: crops)
    }

    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}

enum CaptureDecorationLayout {
    struct Layout {
        let showsPet: Bool
        let readout: CGRect
    }

    /// Conservative envelope including shadows, converted from the approved
    /// x -18...109 / y -57...37 design coordinates to AppKit y up.
    static func envelope(at topLeft: CGPoint) -> CGRect {
        CGRect(x: topLeft.x - 18, y: topLeft.y - 37, width: 127, height: 94)
    }

    static func layout(selection: CGRect, pointer: CGPoint, screen: CGRect,
                       readoutSize: CGSize, hasPet: Bool, wasVisible: Bool,
                       recovering: Bool) -> Layout {
        let topLeft = CGPoint(x: selection.minX, y: selection.maxY)
        let pet = envelope(at: topLeft)
        var visible = canShowPet(selection: selection, screen: screen, hasPet: hasPet,
                                 wasVisible: wasVisible, recovering: recovering)
        let insetScreen = screen.insetBy(dx: 8, dy: 8)
        // Right/down, left/down, right/up, left/up in screen point coordinates.
        let candidates = [
            CGRect(x: pointer.x + 16, y: pointer.y - 16 - readoutSize.height,
                   width: readoutSize.width, height: readoutSize.height),
            CGRect(x: pointer.x - 16 - readoutSize.width, y: pointer.y - 16 - readoutSize.height,
                   width: readoutSize.width, height: readoutSize.height),
            CGRect(x: pointer.x + 16, y: pointer.y + 16,
                   width: readoutSize.width, height: readoutSize.height),
            CGRect(x: pointer.x - 16 - readoutSize.width, y: pointer.y + 16,
                   width: readoutSize.width, height: readoutSize.height)
        ]
        if let rect = candidates.first(where: {
            insetScreen.contains($0) && (!visible || !$0.intersects(pet.insetBy(dx: -8, dy: -8)))
        }) {
            return Layout(showsPet: visible, readout: rect)
        }
        visible = false // Precision/readability takes priority over decoration.
        let preferred = candidates.first(where: { insetScreen.contains($0) }) ?? candidates[0]
        let rect = CGRect(x: min(max(preferred.minX, insetScreen.minX), insetScreen.maxX - readoutSize.width),
                          y: min(max(preferred.minY, insetScreen.minY), insetScreen.maxY - readoutSize.height),
                          width: readoutSize.width, height: readoutSize.height)
        return Layout(showsPet: visible, readout: rect)
    }

    static func canShowPet(selection: CGRect, screen: CGRect, hasPet: Bool,
                           wasVisible: Bool, recovering: Bool) -> Bool {
        let margin: CGFloat = recovering && !wasVisible ? 4 : 0
        return hasPet && selection.width >= 80 + margin && selection.height >= 40 + margin
            && screen.contains(envelope(at: CGPoint(x: selection.minX, y: selection.maxY))
                .insetBy(dx: -4 - margin, dy: -4 - margin))
    }
}
