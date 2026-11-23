import AppKit

final class TextDragBar: NSView {
    var move: ((CGPoint) -> Void)?
    private var last = CGPoint.zero
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow; NSCursor.closedHand.set() }
    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        move?(CGPoint(x: p.x-last.x, y: last.y-p.y)); last = p
    }
    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.8).setFill(); bounds.fill()
        ("拖动文字" as NSString).draw(at: CGPoint(x: 5, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white])
    }
}
final class InlineTextEditor: NSTextView {
    var lostFocus: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Finish the responder change before removing an empty editor from its window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.lostFocus?()
            }
        }
        return resigned
    }
}
final class InlineTextBox: NSView, NSTextViewDelegate {
    let editor = InlineTextEditor()
    let scroll = NSScrollView()
    let bar = TextDragBar()
    var changed: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.borderColor = NSColor.systemGreen.cgColor; layer?.borderWidth = 1
        clipsToBounds = true
        editor.allowsUndo = true
        editor.isRichText = false; editor.drawsBackground = false; editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true; editor.delegate = self
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = editor; addSubview(scroll); addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 14)
        scroll.frame = CGRect(x: 2, y: 15, width: max(1,bounds.width-4), height: max(1,bounds.height-17))
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, editor.frame.height)))
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }
    func textDidChange(_ notification: Notification) { changed?() }
}
