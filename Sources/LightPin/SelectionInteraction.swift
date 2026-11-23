import AppKit

enum ResizeAnchor: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    func point(in rect: CGRect, radius: CGFloat = 0) -> CGPoint {
        let inset = radius*(1-1/sqrt(2))
        let r = rawValue % 2 == 0 ? rect.insetBy(dx: inset, dy: inset) : rect
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
    func resize(_ r: CGRect, to p: CGPoint, within bounds: CGRect, minimum: CGFloat = 8) -> CGRect {
        let p = CGPoint(x: max(bounds.minX, min(bounds.maxX, p.x)), y: max(bounds.minY, min(bounds.maxY, p.y)))
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if [.topLeft,.left,.bottomLeft].contains(self) { x0 = min(p.x, x1-minimum) }
        if [.topRight,.right,.bottomRight].contains(self) { x1 = max(p.x, x0+minimum) }
        if [.topLeft,.top,.topRight].contains(self) { y0 = min(p.y, y1-minimum) }
        if [.bottomLeft,.bottom,.bottomRight].contains(self) { y1 = max(p.y, y0+minimum) }
        return CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0).intersection(bounds)
    }
    static func hit(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat = 8, radius: CGFloat = 0) -> ResizeAnchor? {
        allCases.min(by: { hypot($0.point(in: rect, radius: radius).x-point.x, $0.point(in: rect, radius: radius).y-point.y) < hypot($1.point(in: rect, radius: radius).x-point.x, $1.point(in: rect, radius: radius).y-point.y) })
            .flatMap { hypot($0.point(in: rect, radius: radius).x-point.x, $0.point(in: rect, radius: radius).y-point.y) <= tolerance ? $0 : nil }
    }
}

enum SelectionTween {
    static func rect(from a: CGRect, to b: CGRect, progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress)); let eased = t*t*(3-2*t)
        return CGRect(x: a.minX+(b.minX-a.minX)*eased, y: a.minY+(b.minY-a.minY)*eased,
                      width: a.width+(b.width-a.width)*eased, height: a.height+(b.height-a.height)*eased)
    }
}

// Display-only chrome is above the image canvas, never part of exported pixels.
final class SelectionChrome: NSView {
    var paint: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { paint?() }
}

final class SizePickerPanel: NSPanel {
    var onClose: (() -> Void)?
    override func performClose(_ sender: Any?) { if let onClose { onClose() } else { close() } }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }
}

final class FlippedList: NSView {
    override var isFlipped: Bool { true }
}
extension ResizeAnchor {
    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return Self.diagonalDown
        case .topRight, .bottomLeft: return Self.diagonalUp
        }
    }
    private static let diagonalDown = diagonal(reverse: false)
    private static let diagonalUp = diagonal(reverse: true)
    private static func diagonal(reverse: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: reverse ? 24-y : y) }
            path.move(to: p(5,19)); path.line(to: p(19,5))
            path.move(to: p(5,12)); path.line(to: p(5,19)); path.line(to: p(12,19))
            path.move(to: p(12,5)); path.line(to: p(19,5)); path.line(to: p(19,12))
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke(); return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}
