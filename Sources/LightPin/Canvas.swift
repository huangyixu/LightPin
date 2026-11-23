import AppKit

final class Canvas: NSView {
    var image: NSImage
    var history = MarkHistory()
    var pending: Mark?
    var isMoveMode = false { didSet { window?.invalidateCursorRects(for:self) } }
    var onMoveStart: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnd: (() -> Void)?
    var onComplete: (() -> Void)?
    var tool: Mark.Kind = .arrow { didSet { window?.invalidateCursorRects(for: self) } }
    var ink = NSColor.systemRed { didSet { updateTextStyle() } }
    var stroke: CGFloat = 2
    var textValue = "文字"
    var fontSize: CGFloat = 24 { didSet { updateTextStyle() } }
    var outline: WindowOutline?
    var textBox: InlineTextBox?
    var editingText: Mark?
    var textDragStart: CGPoint?
    var textDragFrame: CGRect?
    var cornerRadius: CGFloat = 0
    private(set) var pointerIsHidden = false
    var hidePointer: () -> Void = { NSCursor.hide() }
    var showPointer: () -> Void = { NSCursor.unhide() }
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: NSImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { paint(in: bounds) }
    func paint(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let outline {
            outline.path(in: rect).addClip()
        } else if cornerRadius > 0 {
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius*rect.width/image.size.width, yRadius: cornerRadius*rect.height/image.size.height).addClip()
        } else { NSBezierPath(rect: rect).addClip() }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let sx = rect.width / image.size.width, sy = rect.height / image.size.height
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(scaleByX: sx, byY: sy)
        (transform as NSAffineTransform).concat()
        for mark in history.marks + (pending.map { [$0] } ?? []) where mark.id != editingText?.id { draw(mark) }
        NSGraphicsContext.restoreGraphicsState()
    }
    func draw(_ mark: Mark) {
        guard let first = mark.points.first, let last = mark.points.last else { return }
        mark.color.setStroke()
        mark.color.setFill()
        let path = NSBezierPath()
        path.lineWidth = mark.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch mark.kind {
        case .rectangle: path.appendRect(mark.rect)
        case .ellipse: path.appendOval(in: mark.rect)
        case .redact:
            mark.color.setFill()
            mark.rect.fill()
            return
        case .mosaic:
            drawMosaic(mark); return
        case .text:
            (mark.text as NSString).draw(with: mark.rect.width > 0 ? mark.rect : CGRect(x: first.x, y: first.y, width: image.size.width-first.x, height: image.size.height-first.y), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                .font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold),
                .foregroundColor: mark.color
            ], context: nil)
            return
        case .pen:
            path.move(to: first)
            for point in mark.points.dropFirst() { path.line(to: point) }
        case .arrow:
            path.move(to: first); path.line(to: last)
            for tip in Geometry.arrowHead(from: first, to: last, length: max(14, mark.width*4)) {
                path.move(to: last); path.line(to: tip)
            }
        }
        path.stroke()
    }
    func drawMosaic(_ mark: Mark) {
        let target = mark.rect.intersection(CGRect(origin:.zero,size:image.size))
        guard target.width > 0, target.height > 0 else { return }
        var imageRect = CGRect(origin:.zero,size:image.size)
        guard let source = image.cgImage(forProposedRect:&imageRect,context:nil,hints:nil) else { return }
        let sx = CGFloat(source.width)/image.size.width, sy = CGFloat(source.height)/image.size.height
        let cropRect = CGRect(x:floor(target.minX*sx),y:floor(target.minY*sy),width:ceil(target.width*sx),height:ceil(target.height*sy))
        guard let crop = source.cropping(to:cropRect) else { return }
        let block = max(8,mark.width*6)
        let w = max(1,Int(ceil(target.width/block))), h = max(1,Int(ceil(target.height/block)))
        guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(crop,in:CGRect(x:0,y:0,width:w,height:h))
        guard let pixels = context.makeImage() else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage:pixels,size:target.size).draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x/bounds.width, 0), 1)*image.size.width,
                       y: min(max(p.y/bounds.height, 0), 1)*image.size.height)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2, isMoveMode || (tool != .text && textBox == nil) {
            cancelPending(); onComplete?(); return
        }
        if isMoveMode { commitText(); onMoveStart?(event.locationInWindow); return }
        let p = point(event)
        if tool == .text {
            guard bounds.width >= 40, bounds.height >= 45 else { NSSound.beep(); return }
            commitText()
            if let mark = history.marks.last(where: { $0.kind == .text && $0.rect.contains(p) }) {
                beginText(mark)
                if event.clickCount < 2 { textDragStart = convert(event.locationInWindow, from: nil); textDragFrame = textBox?.frame; window?.makeFirstResponder(self) }
            } else {
                let x = min(p.x, max(0,image.size.width-40)), y = min(max(16,p.y), max(0,image.size.height-35))
                let width = min(300, image.size.width-x-4)
                guard width > 10 else { return }
                beginText(Mark(kind: .text, points: [CGPoint(x:x,y:y), CGPoint(x:x+width,y:min(image.size.height,y+fontSize*1.4))], color: ink, width: stroke, text: "", fontSize: fontSize))
            }
            return
        }
        commitText()
        pending = Mark(kind: tool, points: [p, p], color: ink, width: stroke, text: textValue, fontSize: fontSize)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if isMoveMode { NSCursor.closedHand.set(); onMove?(event.locationInWindow); return }
        if let start = textDragStart, let frame = textDragFrame {
            let p = convert(event.locationInWindow, from: nil)
            moveText(to: frame.origin + CGPoint(x:p.x-start.x, y:p.y-start.y)); NSCursor.closedHand.set(); return
        }
        guard pending != nil else { return }
        if pending?.kind == .arrow, !pointerIsHidden { hidePointer(); pointerIsHidden = true }
        if tool == .pen { pending?.points.append(point(event)) }
        else if tool != .text { pending?.points[1] = point(event) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if isMoveMode { onMoveEnd?(); NSCursor.openHand.set(); return }
        textDragStart = nil; textDragFrame = nil
        restorePointer()
        if let mark = pending {
            if mark.kind == .text || mark.rect.width + mark.rect.height > 2 { history.append(mark) }
        }
        pending = nil; needsDisplay = true; onChange?()
    }
    func restorePointer() {
        if pointerIsHidden { showPointer(); pointerIsHidden = false }
    }
    func cancelPending() { pending = nil; restorePointer(); needsDisplay = true }
    @objc func lostFocus(_ notification: Notification) { cancelPending() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window) }
        restorePointer()
        if let newWindow { NotificationCenter.default.addObserver(self, selector: #selector(lostFocus(_:)), name: NSWindow.didResignKeyNotification, object: newWindow) }
        super.viewWillMove(toWindow: newWindow)
    }
    @objc func undoMark() { commitText(); history.undo(); needsDisplay = true; onChange?() }
    @objc func redoMark() { commitText(); history.redo(); needsDisplay = true; onChange?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redoMark() } else { undoMark() }
        } else { super.keyDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isMoveMode ? .openHand : (tool == .text ? .iBeam : .crosshair)) }
    func cursor(at p: CGPoint) -> NSCursor {
        if isMoveMode { return .openHand }
        if let box = textBox, box.frame.contains(p) { return p.y < box.frame.minY+14 ? .openHand : .iBeam }
        let logical = CGPoint(x: p.x*image.size.width/bounds.width, y: p.y*image.size.height/bounds.height)
        if tool == .text, history.marks.contains(where: { $0.kind == .text && $0.rect.contains(logical) }) { return .openHand }
        return tool == .text ? .iBeam : .crosshair
    }
    func beginText(_ mark: Mark) {
        editingText = mark
        let sx = bounds.width/image.size.width, sy = bounds.height/image.size.height
        let box = InlineTextBox(frame: CGRect(x: max(0,mark.rect.minX*sx-2), y: max(0,mark.rect.minY*sy-15), width: mark.rect.width*sx+4, height: mark.rect.height*sy+17))
        box.editor.string = mark.text
        textBox = box; addSubview(box)
        box.bar.move = { [weak self] delta in
            guard let self, let box = self.textBox else { return }
            self.moveText(to: box.frame.origin + delta)
        }
        box.changed = { [weak self] in self?.fitTextBox() }
        box.editor.lostFocus = { [weak self, weak box] in
            guard let self, let box, self.textBox === box,
                  box.editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.commitText()
        }
        box.editor.font = .systemFont(ofSize: mark.fontSize*sx, weight: .semibold); box.editor.textColor = mark.color
        fitTextBox(); window?.makeFirstResponder(box.editor); needsDisplay = true
    }
    func updateTextStyle() {
        guard let box = textBox else { return }
        editingText?.fontSize = fontSize; editingText?.color = ink
        box.editor.font = .systemFont(ofSize: fontSize*bounds.width/image.size.width, weight: .semibold)
        box.editor.textColor = ink; fitTextBox()
    }
    func fitTextBox() {
        guard let box = textBox else { return }
        box.layoutSubtreeIfNeeded()
        let text = box.editor.string.isEmpty ? "文字" : box.editor.string
        let height = (text as NSString).boundingRect(with: NSSize(width: max(1,box.frame.width-4), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin,.usesFontLeading], attributes: [.font: box.editor.font ?? NSFont.systemFont(ofSize:24)]).height
        box.setFrameSize(NSSize(width: min(box.frame.width,bounds.width-box.frame.minX), height: min(max(45,ceil(height)+22),bounds.height-box.frame.minY)))
        box.needsLayout = true
    }
    func moveText(to point: CGPoint) {
        guard let box = textBox else { return }
        box.setFrameOrigin(CGPoint(x:max(0,min(bounds.width-box.frame.width,point.x)),y:max(0,min(bounds.height-box.frame.height,point.y))))
    }
    func commitText() {
        guard let box = textBox, var mark = editingText else { return }
        let sx = image.size.width/bounds.width, sy = image.size.height/bounds.height
        let rect = CGRect(x:(box.frame.minX+2)*sx,y:(box.frame.minY+15)*sy,width:max(1,box.frame.width-4)*sx,height:max(1,box.frame.height-17)*sy)
        mark.points = [rect.origin, CGPoint(x:rect.maxX,y:rect.maxY)]; mark.text = box.editor.string
        box.removeFromSuperview(); textBox = nil; editingText = nil
        if !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { history.replace(mark) } else { history.remove(id: mark.id) }
        needsDisplay = true; onChange?()
    }
    func renderedImage() -> NSImage? {
        commitText()
        var rect = CGRect(origin: .zero, size: image.size)
        guard let original = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: original.width,
                pixelsHigh: original.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let cg = graphics.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: original.width, height: original.height))
        cg.translateBy(x: 0, y: CGFloat(original.height))
        cg.scaleBy(x: CGFloat(original.width)/image.size.width, y: -CGFloat(original.height)/image.size.height)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        paint(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size
        let output = NSImage(size: image.size)
        output.addRepresentation(bitmap)
        return output
    }
}

private extension CGPoint { static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x:a.x+b.x,y:a.y+b.y) } }
