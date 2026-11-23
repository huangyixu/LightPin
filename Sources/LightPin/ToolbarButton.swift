import AppKit

/// Draw enabled icons at full contrast even though the screenshot panel isn't a main window.
final class ToolbarButton: NSButton {
    weak var toolGroup: ToolbarToolGroup?
    var symbolPointSize: CGFloat = 19
    override var state: NSControl.StateValue { didSet { toolGroup?.needsDisplay = true; toolGroup?.disclosure.needsDisplay = true } }
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = (toolGroup?.main.state ?? state) == .on
        if toolGroup == nil && (active || hovered || isHighlighted) {
            (active ? NSColor.systemGreen.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:7,yRadius:7).fill()
        }
        let color = isEnabled ? (active ? NSColor.systemGreen : contentTintColor ?? NSColor(calibratedWhite:0.18,alpha:1)) : NSColor(calibratedWhite:0.7,alpha:1)
        if let image {
            let config = NSImage.SymbolConfiguration(pointSize:symbolPointSize,weight:.medium).applying(NSImage.SymbolConfiguration(paletteColors:[color]))
            let symbol = image.withSymbolConfiguration(config) ?? image
            let size = symbol.size
            let factor = min(1,22/max(size.width,size.height))
            let target = CGRect(x:(bounds.width-size.width*factor)/2,y:(bounds.height-size.height*factor)/2,width:size.width*factor,height:size.height*factor)
            symbol.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        } else {
            (title as NSString).draw(in:bounds.insetBy(dx:4,dy:6),withAttributes:[.foregroundColor:color,.font:NSFont.systemFont(ofSize:12)])
        }
    }
}

/// One visual control with separate primary-action and disclosure hit targets.
final class ToolbarToolGroup: NSStackView {
    let main: ToolbarButton
    let disclosure: ToolbarButton
    private var hovered = false
    init(main: ToolbarButton, menu: ToolbarButton) {
        self.main = main; self.disclosure = menu
        super.init(frame:.zero)
        orientation = .horizontal; alignment = .centerY; spacing = 0
        edgeInsets = NSEdgeInsets(top:0,left:1,bottom:0,right:4)
        menu.symbolPointSize = 10
        main.toolGroup = self; menu.toolGroup = self
        addArrangedSubview(main); addArrangedSubview(menu)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = main.state == .on
        (active ? NSColor.systemGreen.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(hovered ? 0.07 : 0.025)).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:0,dy:1),xRadius:7,yRadius:7).fill()
    }
}

final class ColorSwatchButton: NSButton {
    var swatch = NSColor.systemRed
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx:4,dy:4)
        if state == .on {
            NSColor.systemGreen.setStroke()
            let ring = NSBezierPath(roundedRect:bounds.insetBy(dx:1.5,dy:1.5),xRadius:5,yRadius:5)
            ring.lineWidth = 2; ring.stroke()
        }
        swatch.setFill(); NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        let edge = NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3); edge.lineWidth = 0.75; edge.stroke()
    }
}

/// Compact tool variants with a shared icon, label and trailing selection column.
final class ToolVariantButton: NSButton {
    var symbolName = "rectangle"
    private var hovered = false
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let ink = selected ? NSColor(calibratedRed:0.08,green:0.64,blue:0.31,alpha:1) : NSColor(calibratedWhite:0.22,alpha:1)
        if selected || hovered || isHighlighted {
            (selected ? ink.withAlphaComponent(hovered ? 0.14 : 0.08) : NSColor.black.withAlphaComponent(0.05)).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:5,yRadius:5).fill()
        }
        func symbol(_ name: String, in rect: CGRect, size: CGFloat) {
            let config = NSImage.SymbolConfiguration(pointSize:size,weight:.regular).applying(NSImage.SymbolConfiguration(paletteColors:[ink]))
            guard let image = NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(config) else { return }
            let scale = min(rect.width/image.size.width,rect.height/image.size.height,1)
            image.draw(in:CGRect(x:rect.midX-image.size.width*scale/2,y:rect.midY-image.size.height*scale/2,width:image.size.width*scale,height:image.size.height*scale),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        symbol(symbolName,in:CGRect(x:9,y:7,width:16,height:16),size:15)
        (title as NSString).draw(at:CGPoint(x:34,y:7),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:ink])
        if selected { symbol("checkmark",in:CGRect(x:bounds.width-23,y:9,width:12,height:12),size:10) }
    }
}
