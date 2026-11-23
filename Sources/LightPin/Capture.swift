import AppKit
import ScreenCaptureKit
import Vision
import UniformTypeIdentifiers

// All selection geometry uses top-left display-local points; pixel conversion is explicit.
enum SelectionGeometry {
    static func pixels(_ rect: CGRect, size: CGSize, width: Int, height: Int) -> CGRect {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, size.width > 0, size.height > 0 else { return .zero }
        let sx = CGFloat(width)/size.width, sy = CGFloat(height)/size.height
        return CGRect(x: floor(clipped.minX*sx), y: floor(clipped.minY*sy),
                      width: ceil(clipped.maxX*sx)-floor(clipped.minX*sx), height: ceil(clipped.maxY*sy)-floor(clipped.minY*sy))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
    static func move(_ rect: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX, min(bounds.maxX-rect.width, rect.minX+dx)),
               y: max(bounds.minY, min(bounds.maxY-rect.height, rect.minY+dy)), width: rect.width, height: rect.height)
    }
}

enum CaptureAction: Equatable { case copy, saved }
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { (contentView as? SelectionView)?.cancel() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let view = contentView as? SelectionView { view.goBack(); return }
        if event.type == .keyDown, event.keyCode == 53, let view = contentView as? SelectionView { view.handleEscape(); return }
        if event.type == .leftMouseDown, let view = contentView as? SelectionView {
            if view.completeSmartDoubleClick(event) { return }
            view.dismissSizePicker()
        }
        if event.type == .keyDown, event.keyCode == 48, let view = contentView as? SelectionView, !view.editing {
            view.cycleWindow(backwards: event.modifierFlags.contains(.shift)); return
        }
        if event.type == .keyDown, let view = contentView as? SelectionView, !(firstResponder is NSTextView) {
            if event.modifierFlags.contains(.command), view.performKeyEquivalent(with: event) { return }
            if [UInt16(53),36,76].contains(event.keyCode) { view.keyDown(with: event); return }
        }
        super.sendEvent(event)
        if event.type == .mouseMoved, let view = contentView as? SelectionView {
            view.updateCursor(at: view.convert(event.locationInWindow, from: nil))
        }
    }
}

@MainActor
final class CaptureSession {
    var panels: [SelectionPanel] = []
    var onFinish: ((NSImage?, CaptureAction) -> Void)?
    var scrolling: ScrollCapture?
    private var finished = false
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var prepared: [(NSScreen, CGImage, [SCWindow])] = []
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windowOrder = windowInfo.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        var opacity: [UInt32: Bool] = [:]
        for info in windowInfo {
            if let id = info[kCGWindowNumber as String] as? UInt32 { opacity[id] = (info[kCGWindowAlpha as String] as? Double ?? 1) >= 0.99 }
        }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let image = try await DesktopSnapshot.capture(display: display, scale: screen.backingScaleFactor)
            let displayBounds = CGDisplayBounds(id)
            let candidates = content.windows.filter { $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                .sorted { (windowOrder.firstIndex(of: $0.windowID) ?? Int.max) < (windowOrder.firstIndex(of: $1.windowID) ?? Int.max) }
                .filter { !$0.frame.intersection(displayBounds).isNull && $0.frame.width > 2 && $0.frame.height > 2 }
            let visible = WindowVisibility.visibleIndices(candidates.map { $0.frame }, within:displayBounds, opaque:candidates.map { opacity[$0.windowID] ?? true })
            prepared.append((screen, image, visible.map { candidates[$0] }))
        }
        guard !prepared.isEmpty else { throw NSError(domain: "LightPin", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可截图的显示器。"] ) }
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image, candidates) in prepared {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver; panel.isOpaque = true; panel.hasShadow = false
            panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
            let displayBounds = CGDisplayBounds(id)
            let windows = candidates.map { $0.frame.offsetBy(dx:-displayBounds.minX,dy:-displayBounds.minY) }
            let view = SelectionView(image: image, size: screen.frame.size, windows: windows)
            view.windowOutlines = Array(repeating:nil,count:windows.count)
            view.loadOutline = { index in
                let selected = candidates[index]
                let config = SCStreamConfiguration()
                config.width = Int(selected.frame.width*screen.backingScaleFactor)
                config.height = Int(selected.frame.height*screen.backingScaleFactor)
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = false; config.shouldBeOpaque = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:selected),configuration:config) else { return nil }
                return WindowOutline(image:image)
            }
            view.onScroll = { [weak self, weak view] in
                guard let self, let view, let rect = view.selection, let first = view.croppedImage(),
                      let cg = first.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return }
                guard let capture = ScrollCapture(first:cg,rect:rect,screen:screen,
                    display:content.displays.first(where: { $0.displayID == id })!,
                    excluded:content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                    showError("请选择较高且较小的区域后重试。"); return
                }
                self.scrolling = capture
                capture.onFinish = { [weak self] image in self?.finish(image) }
                view.canvas?.commitText()
                guard view.canvas?.history.marks.isEmpty != false else { self.scrolling = nil; showError("请在添加标注前开始滚动截图。"); return }
                view.endInteraction()
                self.panels.forEach { $0.orderOut(nil) }
                capture.panel.orderFrontRegardless()
                capture.start()
            }
            configure(view)
            panel.contentView = view; panels.append(panel); panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
            if screen.frame.contains(NSEvent.mouseLocation) {
                panel.makeKey()
                view.updateHover(CGPoint(x: NSEvent.mouseLocation.x-screen.frame.minX, y: screen.frame.maxY-NSEvent.mouseLocation.y))
            }
        }
    }
    func configure(_ view: SelectionView) {
        view.onFinish = { [weak self] image, action in self?.finish(image, action) }
        view.onEditing = { [weak self, weak view] in
            // Once selected, keep only that display active; other displays cannot steal focus.
            self?.panels.filter { $0.contentView !== view }.forEach { $0.orderOut(nil) }
        }
        view.onReselect = { [weak self] in self?.panels.forEach { $0.orderFrontRegardless() } }
        view.onModalChange = { [weak self] active in self?.panels.forEach { $0.level = active ? .normal : .screenSaver } }
    }
    func startImage(_ image: NSImage) throws {
        guard let screen = NSScreen.main else { throw CocoaError(.featureUnsupported) }
        let size = screen.frame.size
        let backdrop = NSImage(size: size)
        backdrop.lockFocus(); NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); CGRect(origin: .zero, size: size).fill(); backdrop.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = backdrop.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw CocoaError(.fileReadUnknown) }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver; panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(image: cg, size: size, windows: [])
        configure(view); panel.contentView = view; panels.append(panel)
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        let scale = min(1, (size.width-80)/image.size.width, (size.height-180)/image.size.height)
        view.selection = CGRect(x: (size.width-image.size.width*scale)/2, y: (size.height-image.size.height*scale)/2,
                                width: image.size.width*scale, height: image.size.height*scale)
        view.canReselect = false
        view.beginEditing(image: image)
    }
    func finish(_ image: NSImage?, _ action: CaptureAction = .copy) {
        guard !finished else { return }; finished = true
        scrolling?.task?.cancel(); scrolling?.panel.orderOut(nil); scrolling = nil
        panels.forEach { ($0.contentView as? SelectionView)?.endInteraction(); $0.orderOut(nil); $0.close() }; panels.removeAll()
        onFinish?(image, action)
    }
}


struct WindowHitStack {
    let windows: [CGRect] // Front-to-back; equal rectangles still represent distinct windows.
    private(set) var candidates: [Int] = []
    private(set) var depth = 0
    mutating func update(at point: CGPoint) {
        let next = windows.indices.filter { windows[$0].contains(point) }
        if next != candidates { candidates = next; depth = 0 }
    }
    mutating func cycle(backwards: Bool = false) {
        guard !candidates.isEmpty else { return }
        depth = (depth + (backwards ? candidates.count-1 : 1)) % candidates.count
    }
    var selected: CGRect? { candidates.isEmpty ? nil : windows[candidates[depth]] }
}

final class SelectionView: NSView, NSTextFieldDelegate {
    var scrollTool: NSButton?
    var onScroll: (() -> Void)?
    @objc func beginScroll() { onScroll?() }
    let source: CGImage
    let snapshot: NSImage
    var hitStack: WindowHitStack
    var selection: CGRect? { didSet { needsDisplay = true; chrome?.needsDisplay = true } }
    var chrome: SelectionChrome?
    var windowOutlines: [WindowOutline?] = []
    var loadOutline: ((Int) async -> WindowOutline?)?
    var outlineTask: Task<Void,Never>?
    var requestedOutline: Int?
    var movingSelection = false
    var moveOrigin = CGPoint.zero
    var moveFrame = CGRect.zero
    var selectedOutline: WindowOutline? {
        guard isSmartWindow, !hitStack.candidates.isEmpty else { return nil }
        let index = hitStack.candidates[hitStack.depth]
        return windowOutlines.indices.contains(index) ? windowOutlines[index] : nil
    }
    func selectionPath(in rect: CGRect) -> NSBezierPath {
        selectedOutline?.path(in: rect) ?? NSBezierPath(roundedRect: rect, xRadius: selectionRadius, yRadius: selectionRadius)
    }
    func handlePoint(_ anchor: ResizeAnchor, in rect: CGRect) -> CGPoint {
        guard anchor.rawValue % 2 == 0, let outline = selectedOutline else { return anchor.point(in: rect, radius: selectionRadius) }
        let corner = anchor.point(in: rect)
        return outline.points.map { CGPoint(x:rect.minX+$0.x*rect.width,y:rect.minY+$0.y*rect.height) }
            .min(by: { hypot($0.x-corner.x,$0.y-corner.y) < hypot($1.x-corner.x,$1.y-corner.y) }) ?? corner
    }
    var isSmartWindow = false
    var animatedRect: CGRect?
    var animationTimer: Timer?
    var resizeAnchor: ResizeAnchor?
    var resizeStartRect = CGRect.zero
    var sizePicker: SizePickerPanel?
    var ownsColorPanel = false
    var selectedInk = NSColor.systemRed
    var selectedStroke: CGFloat = 2
    var selectedFontSize: CGFloat = 24
    var selectionRadius: CGFloat { isSmartWindow ? min(selectedOutline.map { $0.cornerInset*(selection?.width ?? 0) } ?? 12, (selection?.width ?? 0)/2, (selection?.height ?? 0)/2) : 0 }
    var displayedRect: CGRect? { animatedRect ?? selection }
    var hover = CGPoint.zero { didSet { chrome?.needsDisplay = true } }
    var start = CGPoint.zero
    var dragging = false
    var didDrag = false
    var canvas: Canvas?
    var canReselect = true
    var onFinish: ((NSImage?, CaptureAction) -> Void)?
    var onEditing: (() -> Void)?
    var onReselect: (() -> Void)?
    var onModalChange: ((Bool) -> Void)?
    let toolbar = NSStackView()
    let toolbarScroll = NSScrollView()
    let optionsBar = NSStackView()
    let optionsScroll = NSScrollView()
    let widthOptions = NSStackView()
    let colorOptions = NSStackView()
    let optionDivider = NSBox()
    let widthLabel = NSTextField(labelWithString: "线宽")
    var widthPresets: [NSButton] = []
    var colorSwatches: [ColorSwatchButton] = []
    var toolButtons: [NSButton] = []
    var areaKind: Mark.Kind = .rectangle
    var maskKind: Mark.Kind = .redact
    var areaMenuButton: NSButton!
    var maskMenuButton: NSButton!
    var colorIndex = 0
    let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    var colorButton: NSButton!
    var widthButton: NSButton!
    var undoButton: NSButton!
    var redoButton: NSButton!
    var ocrButton: NSButton!
    var reselectButton: NSButton!
    var textWindows: [NSWindowController] = []
    var recognitionTask: Task<Void, Never>?
    var editing: Bool { canvas != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, size: NSSize, windows: [CGRect]) {
        source = image; snapshot = NSImage(cgImage: image, size: size); hitStack = WindowHitStack(windows: windows)
        super.init(frame: CGRect(origin: .zero, size: size))
        toolbar.orientation = .horizontal; toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let symbols = ["arrow.up.right", "rectangle", "circle", "pencil.tip", "textformat", "square.fill", "square.grid.3x3.fill"]
        for (i, kind) in Mark.Kind.allCases.enumerated() {
            let b = icon(symbols[i],title:kind.rawValue,action:#selector(selectTool(_:)))
            b.tag = i; b.setButtonType(.toggle); toolButtons.append(b)
        }
        areaMenuButton = icon("chevron.down",title:"区域标注：矩形 / 椭圆",action:#selector(openAreaMenu),width:16)
        maskMenuButton = icon("chevron.down",title:"遮罩：色块覆盖 / 马赛克",action:#selector(openMaskMenu),width:16)
        for kind: Mark.Kind in [.rectangle,.arrow,.pen,.redact,.text] {
            let main = toolButtons[Mark.Kind.allCases.firstIndex(of:kind)!]
            if kind == .rectangle || kind == .redact {
                let menu = kind == .rectangle ? areaMenuButton! : maskMenuButton!
                toolbar.addArrangedSubview(ToolbarToolGroup(main:main as! ToolbarButton,menu:menu as! ToolbarButton))
            } else { toolbar.addArrangedSubview(main) }
        }
        separator()
        colorButton = icon("paintpalette",title:"自定义颜色：打开取色盘",action:#selector(openColorPicker),width:30)
        colorButton.contentTintColor = selectedInk
        widthButton = button("2",target:self,action:#selector(openSizePicker))
        widthButton.toolTip = "更多线宽 / 字号"; widthButton.widthAnchor.constraint(equalToConstant:64).isActive = true
        optionsBar.orientation = .horizontal; optionsBar.spacing = 8
        optionsBar.edgeInsets = NSEdgeInsets(top:6,left:10,bottom:6,right:10)
        widthOptions.orientation = .horizontal; widthOptions.spacing = 4
        widthLabel.font = .systemFont(ofSize:12); widthLabel.textColor = NSColor(calibratedWhite:0.35,alpha:1)
        widthOptions.addArrangedSubview(widthLabel)
        for (index,value) in [2,4,8].enumerated() {
            let preset = icon("circle.fill",title:"线宽 \(value)pt",action:#selector(chooseSize(_:)),width:26)
            preset.tag = value; (preset as? ToolbarButton)?.symbolPointSize = CGFloat(5+index*4)
            widthPresets.append(preset); widthOptions.addArrangedSubview(preset)
        }
        widthOptions.addArrangedSubview(widthButton); optionsBar.addArrangedSubview(widthOptions)
        optionDivider.boxType = .separator; optionDivider.widthAnchor.constraint(equalToConstant:1).isActive = true
        optionDivider.heightAnchor.constraint(equalToConstant:24).isActive = true; optionsBar.addArrangedSubview(optionDivider)
        colorOptions.orientation = .horizontal; colorOptions.spacing = 4
        for (index,color) in colors.enumerated() {
            let swatch = ColorSwatchButton(title:"",target:self,action:#selector(chooseColor(_:)))
            swatch.swatch = color; swatch.tag = index; swatch.isBordered = false
            swatch.toolTip = ["红色","黄色","绿色","蓝色","白色","黑色"][index]
            swatch.setAccessibilityLabel(swatch.toolTip!)
            swatch.widthAnchor.constraint(equalToConstant:28).isActive = true
            swatch.heightAnchor.constraint(equalToConstant:28).isActive = true
            colorSwatches.append(swatch); colorOptions.addArrangedSubview(swatch)
        }
        colorOptions.addArrangedSubview(colorButton); optionsBar.addArrangedSubview(colorOptions)
        optionsScroll.documentView = optionsBar
        optionsScroll.drawsBackground = true; optionsScroll.backgroundColor = NSColor(calibratedWhite:0.99,alpha:1)
        optionsScroll.appearance = NSAppearance(named:.aqua)
        optionsScroll.hasHorizontalScroller = true; optionsScroll.autohidesScrollers = true
        optionsScroll.wantsLayer = true; optionsScroll.layer?.cornerRadius = 9
        optionsScroll.layer?.borderWidth = 1; optionsScroll.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        undoButton = icon("arrow.uturn.backward", title: "撤销 ⌘Z", action: #selector(undo)); toolbar.addArrangedSubview(undoButton)
        redoButton = icon("arrow.uturn.forward", title: "重做 ⌘⇧Z", action: #selector(redo)); toolbar.addArrangedSubview(redoButton)
        reselectButton = icon("chevron.backward", title: "返回选区阶段 / 右键", action: #selector(goBack)); toolbar.addArrangedSubview(reselectButton)
        ocrButton = icon("text.viewfinder", title: "识别文字", action: #selector(recognize)); toolbar.addArrangedSubview(ocrButton)
        let scrollButton = icon("arrow.up.and.down.square", title: "区域滚动截图（先框选，再向下滚动）", action: #selector(beginScroll))
        toolbar.addArrangedSubview(scrollButton)
        scrollButton.isHidden = true
        self.scrollTool = scrollButton
        toolbar.addArrangedSubview(icon("square.and.arrow.down", title: "保存 PNG ⌘S", action: #selector(saveSelection)))
        separator()
        toolbar.addArrangedSubview(icon("xmark", title: "退出截图", action: #selector(cancel)))
        let done = icon("checkmark", title: "完成并复制 ↵", action: #selector(copySelection)); done.contentTintColor = NSColor.systemGreen
        toolbar.addArrangedSubview(done)
        toolbarScroll.drawsBackground = true; toolbarScroll.backgroundColor = NSColor(calibratedWhite:0.99,alpha:1)
        toolbarScroll.appearance = NSAppearance(named:.aqua)
        toolbarScroll.hasHorizontalScroller = true; toolbarScroll.autohidesScrollers = true
        toolbarScroll.documentView = toolbar
        toolbarScroll.wantsLayer = true; toolbarScroll.layer?.cornerRadius = 11
        toolbarScroll.layer?.borderWidth = 1; toolbarScroll.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        let chrome = SelectionChrome(frame: bounds); chrome.autoresizingMask = [.width, .height]
        chrome.paint = { [weak self] in self?.drawChrome() }; self.chrome = chrome; addSubview(chrome)
        addSubview(toolbarScroll); toolbarScroll.isHidden = true
        addSubview(optionsScroll); optionsScroll.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func icon(_ symbol: String, title: String, action: Selector, width: CGFloat = 36) -> NSButton {
        let b = ToolbarButton(title:"",target:self,action:action)
        b.contentTintColor = NSColor(calibratedWhite:0.18,alpha:1)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        if b.image == nil { b.title = title }
        b.toolTip = title; b.setAccessibilityLabel(title)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.bezelStyle = .regularSquare; b.isBordered = false
        return b
    }
    func separator() {
        let line = NSBox(); line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true; toolbar.addArrangedSubview(line)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    func updateCursor(at point: CGPoint) {
        if canvas?.pointerIsHidden == true { return }
        if movingSelection { NSCursor.closedHand.set(); return }
        if let anchor = anchor(at: point) { anchor.cursor.set(); return }
        if (!toolbarScroll.isHidden && toolbarScroll.frame.contains(point)) || (!optionsScroll.isHidden && optionsScroll.frame.contains(point)) { NSCursor.arrow.set(); return }
        if let canvas, canvas.frame.contains(point) { canvas.cursor(at: convert(point, to: canvas)).set(); return }
        (editing ? NSCursor.arrow : NSCursor.crosshair).set()
    }
    override func resetCursorRects() { if !editing { addCursorRect(bounds, cursor: .crosshair) } }
    override func mouseEntered(with event: NSEvent) {
        guard !editing else { return }
        window?.makeKey(); window?.makeFirstResponder(self); updateHover(location(event))
    }
    func updateHover(_ point: CGPoint) {
        hover = point
        guard !editing, !dragging else { return }
        hitStack.update(at: point); setSmartSelection(hitStack.selected)
    }
    func cycleWindow(backwards: Bool = false) {
        guard !editing, !dragging else { return }
        hitStack.cycle(backwards: backwards); setSmartSelection(hitStack.selected)
    }
    func setSmartSelection(_ candidate: CGRect?) {
        isSmartWindow = candidate != nil && candidate != bounds && bounds.contains(candidate!)
        let target = candidate?.intersection(bounds)
        scheduleOutline()
        guard target != selection else { needsDisplay = true; chrome?.needsDisplay = true; return }
        let from = displayedRect
        stopAnimation()
        selection = target
        guard let from, let target, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animatedRect = from
        let startTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = CGFloat((ProcessInfo.processInfo.systemUptime-startTime)/0.14)
            self.animatedRect = SelectionTween.rect(from: from, to: target, progress: progress)
            self.needsDisplay = true; self.chrome?.needsDisplay = true
            if progress >= 1 { self.stopAnimation() }
        }
        animationTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopAnimation() { animationTimer?.invalidate(); animationTimer = nil; animatedRect = nil; needsDisplay = true; chrome?.needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        snapshot.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.45).setFill()
        let shade = NSBezierPath(rect: bounds)
        if let rect = displayedRect { shade.append(selectionPath(in: rect)) }
        shade.windingRule = .evenOdd; shade.fill()
    }
    func scheduleOutline() {
        guard isSmartWindow, !hitStack.candidates.isEmpty, let loadOutline else { outlineTask?.cancel(); requestedOutline = nil; return }
        let index = hitStack.candidates[hitStack.depth]
        guard windowOutlines.indices.contains(index), windowOutlines[index] == nil, requestedOutline != index else { return }
        outlineTask?.cancel(); requestedOutline = index
        outlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:120_000_000)
            guard !Task.isCancelled else { return }
            let outline = await loadOutline(index)
            guard let self, !Task.isCancelled else { return }
            self.windowOutlines[index] = outline
            guard self.isSmartWindow, self.hitStack.candidates[self.hitStack.depth] == index else { return }
            self.canvas?.outline = outline
            self.canvas?.cornerRadius = self.selectionRadius
            self.canvas?.needsDisplay = true; self.needsDisplay = true; self.chrome?.needsDisplay = true
        }
    }
    func drawChrome() {
        if let rect = displayedRect {
            NSColor.systemGreen.setStroke()
            let border = selectionPath(in: rect)
            border.lineWidth = 1 + 1/(window?.backingScaleFactor ?? 2); border.stroke()
            if editing && canReselect {
                for anchor in ResizeAnchor.allCases {
                    let point = handlePoint(anchor, in: rect)
                    let handle = NSBezierPath(ovalIn: CGRect(x: point.x-3.5, y: point.y-3.5, width: 7, height: 7))
                    NSColor.white.setFill(); handle.fill(); NSColor.systemGreen.setStroke(); handle.lineWidth = 1; handle.stroke()
                }
            }
            let pixels = SelectionGeometry.pixels(selection ?? rect, size: bounds.size, width: source.width, height: source.height)
            var suffix = !editing && !dragging && !hitStack.candidates.isEmpty ? " · 窗口 \(hitStack.depth+1)/\(hitStack.candidates.count)" : ""
            if selectionRadius > 0 { suffix += " · 透明圆角" }
            label("\(Int(pixels.width)) × \(Int(pixels.height)) px" + suffix, at: CGPoint(x: max(8, rect.minX), y: max(42, rect.minY-30)))
        }
        if !editing {
            label("自动选窗 · Tab 切换层级 · 拖动框选 · C 取色 · 右键 / Esc 取消", at: CGPoint(x: 16, y: 12))
        }
        if !editing || resizeAnchor != nil { drawMagnifier() }
    }
    func label(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: point.x, y: point.y, width: size.width+16, height: size.height+10)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: point.x+8, y: point.y+5), withAttributes: attrs)
    }
    func drawMagnifier() {
        let sx = CGFloat(source.width)/bounds.width, sy = CGFloat(source.height)/bounds.height
        let x = min(max(Int(hover.x*sx), 0), source.width-1), y = min(max(Int(hover.y*sy), 0), source.height-1)
        let crop = CGRect(x: max(0, min(x-8, source.width-17)), y: max(0, min(y-8, source.height-17)), width: min(17, source.width), height: min(17, source.height))
        guard let zoom = source.cropping(to: crop) else { return }
        let rect = CGRect(x: min(max(8, hover.x+24), bounds.width-150), y: min(max(48, hover.y+24), bounds.height-150), width: 119, height: 119)
        // A solid neutral surround separates bright sampled pixels from the desktop.
        let frame = NSBezierPath(roundedRect:rect.insetBy(dx:-3,dy:-3),xRadius:4,yRadius:4)
        NSColor(calibratedWhite:0.16,alpha:1).setFill(); frame.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke(); frame.lineWidth = 0.75; frame.stroke()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: zoom, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.systemRed.setStroke()
        let cell = CGRect(x: rect.minX+CGFloat(x-Int(crop.minX))*7, y: rect.minY+CGFloat(y-Int(crop.minY))*7, width: 7, height: 7)
        NSBezierPath(rect: cell).stroke()
        label(pixelHex() ?? "X \(x)  Y \(y)", at: CGPoint(x: rect.minX, y: rect.maxY+6))
    }
    func pixelHex() -> String? {
        let x = min(max(Int(hover.x*CGFloat(source.width)/bounds.width), 0), source.width-1)
        let y = min(max(Int(hover.y*CGFloat(source.height)/bounds.height), 0), source.height-1)
        guard let pixel = source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let color = NSBitmapImageRep(cgImage: pixel).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((color.redComponent*255).rounded()), Int((color.greenComponent*255).rounded()), Int((color.blueComponent*255).rounded()))
    }
    func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    override func mouseMoved(with event: NSEvent) { updateHover(location(event)); updateCursor(at: location(event)) }
    func anchor(at point: CGPoint) -> ResizeAnchor? {
        guard editing, canReselect, let rect = selection,
              toolbarScroll.isHidden || !toolbarScroll.frame.contains(point),
              optionsScroll.isHidden || !optionsScroll.frame.contains(point) else { return nil }
        return ResizeAnchor.allCases.first { let p = handlePoint($0, in: rect); return hypot(p.x-point.x,p.y-point.y) <= 8 }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if anchor(at: local) != nil { return self }
        return super.hitTest(point)
    }
    private var selectionMouseDownTime: TimeInterval = 0
    private var smartFirstClick: (time: TimeInterval, point: CGPoint)?

    // The first click installs a canvas. Match the second at window level because
    // AppKit can reset clickCount when the hit view changes between clicks.
    func completeSmartDoubleClick(_ event: NSEvent) -> Bool {
        guard let first = smartFirstClick else { return false }
        smartFirstClick = nil
        let elapsed = event.timestamp - first.time
        let p = location(event)
        guard editing, canvas?.isMoveMode == true, elapsed >= 0,
              elapsed <= NSEvent.doubleClickInterval,
              hypot(p.x-first.point.x, p.y-first.point.y) <= 4 else {
            positionToolbar()
            return false
        }
        copySelection()
        return true
    }

    override func rightMouseDown(with event: NSEvent) { goBack() }
    override func mouseDown(with event: NSEvent) {
        if let anchor = anchor(at: location(event)), let rect = selection {
            canvas?.cancelPending(); dismissSizePicker()
            resizeAnchor = anchor; resizeStartRect = rect; hover = location(event)
            toolbarScroll.isHidden = true; optionsScroll.isHidden = true
            window?.makeFirstResponder(self); return
        }
        guard !editing else { window?.makeFirstResponder(canvas); return }
        window?.makeKey(); window?.makeFirstResponder(self)
        selectionMouseDownTime = event.timestamp
        // Keep the current Tab-selected layer at the click position.
        updateHover(location(event)); stopAnimation(); start = hover; dragging = true; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        if let anchor = resizeAnchor {
            hover = location(event)
            resizeSelection(to: anchor.resize(resizeStartRect, to: hover, within: bounds)); return
        }
        guard dragging, !editing else { return }; hover = location(event)
        if hypot(hover.x-start.x, hover.y-start.y) > 3 { didDrag = true }
        if didDrag { isSmartWindow = false; selection = Geometry.rect(start, hover) }; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let anchor = resizeAnchor {
            hover = location(event); resizeSelection(to: anchor.resize(resizeStartRect, to: hover, within: bounds))
            resizeAnchor = nil; positionToolbar(); chrome?.needsDisplay = true; window?.makeFirstResponder(canvas); return
        }
        guard dragging, !editing else { return }; dragging = false
        if didDrag { selection = Geometry.rect(start, location(event)) }
        guard let rect = selection, rect.width >= 2, rect.height >= 2 else { updateHover(location(event)); return }
        if !didDrag, hitStack.selected != nil {
            let firstTime = selectionMouseDownTime
            smartFirstClick = (firstTime, start)
            let remaining = max(0, NSEvent.doubleClickInterval - (event.timestamp - firstTime))
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, self.smartFirstClick?.time == firstTime else { return }
                self.smartFirstClick = nil
                self.positionToolbar()
            }
        }
        beginEditing()
    }
    func croppedImage() -> NSImage? {
        guard let rect = selection else { return nil }
        let pixels = SelectionGeometry.pixels(rect, size: bounds.size, width: source.width, height: source.height)
        guard pixels.width >= 1, pixels.height >= 1, let cropped = source.cropping(to: pixels) else { return nil }
        let logical = NSSize(width: CGFloat(cropped.width)*bounds.width/CGFloat(source.width), height: CGFloat(cropped.height)*bounds.height/CGFloat(source.height))
        return NSImage(cgImage: cropped, size: logical)
    }
    func beginEditing(image: NSImage? = nil) {
        guard canvas == nil, let rect = selection, let image = image ?? croppedImage() else { return }
        let view = Canvas(image: image); view.frame = rect
        stopAnimation()
        view.stroke = selectedStroke; view.ink = selectedInk; view.fontSize = selectedFontSize
        view.cornerRadius = selectionRadius*image.size.width/rect.width
        view.outline = selectedOutline
        refreshSizeLabel()
        view.onChange = { [weak self] in self?.updateUndo() }
        canvas = view; addSubview(view, positioned: .below, relativeTo: chrome)
        view.onMoveStart = { [weak self] point in
            guard let self, let rect = self.selection else { return }
            self.moveOrigin = self.convert(point,from:nil); self.moveFrame = rect
        }
        view.onMove = { [weak self] point in
            guard let self, self.canReselect else { return }
            let p = self.convert(point,from:nil)
            guard self.movingSelection || hypot(p.x-self.moveOrigin.x,p.y-self.moveOrigin.y) > 2 else { return }
            self.movingSelection = true; self.toolbarScroll.isHidden = true; self.optionsScroll.isHidden = true
            self.moveSelection(to:SelectionGeometry.move(self.moveFrame,dx:p.x-self.moveOrigin.x,dy:p.y-self.moveOrigin.y,within:self.bounds))
        }
        view.onMoveEnd = { [weak self] in self?.movingSelection = false; self?.positionToolbar() }
        view.onComplete = { [weak self] in self?.copySelection() }
        if canReselect { selectMove() } else { selectTool(toolButtons[0]) }
        scrollTool?.isHidden = onScroll == nil
        onEditing?(); positionToolbar(); updateUndo(); needsDisplay = true; chrome?.needsDisplay = true
        window?.makeFirstResponder(view)
    }
    func updateOptions() {
        let kind = canvas?.tool ?? .arrow
        widthOptions.isHidden = kind == .redact
        colorOptions.isHidden = kind == .mosaic
        optionDivider.isHidden = widthOptions.isHidden || colorOptions.isHidden
        widthLabel.stringValue = kind == .text ? "字号" : (kind == .mosaic ? "强度" : "线宽")
        for preset in widthPresets {
            preset.isHidden = kind == .text || kind == .mosaic
            preset.state = CGFloat(preset.tag) == selectedStroke ? .on : .off; preset.needsDisplay = true
        }
        for swatch in colorSwatches { swatch.state = swatch.swatch == selectedInk ? .on : .off; swatch.needsDisplay = true }
        colorButton.contentTintColor = selectedInk; colorButton.needsDisplay = true
        refreshSizeLabel()
    }
    @objc func chooseColor(_ sender: NSButton) {
        selectedInk = colors[sender.tag]; canvas?.ink = selectedInk; updateOptions()
    }
    func positionToolbar() {
        guard smartFirstClick == nil, let rect = selection, editing else { toolbarScroll.isHidden = true; optionsScroll.isHidden = true; return }
        toolbarScroll.isHidden = false
        optionsScroll.isHidden = canvas?.isMoveMode != false
        updateOptions()
        reselectButton.isHidden = !canReselect
        let natural = toolbar.fittingSize, options = optionsBar.fittingSize
        toolbar.frame = CGRect(origin:.zero,size:natural); optionsBar.frame = CGRect(origin:.zero,size:options)
        toolbar.layoutSubtreeIfNeeded(); optionsBar.layoutSubtreeIfNeeded()
        let width = min(natural.width,max(1,bounds.width-16))
        let height = natural.height+(width < natural.width ? 12 : 0)
        let optionsWidth = min(options.width,max(1,bounds.width-16))
        let optionsHeight = options.height+(optionsWidth < options.width ? 12 : 0)
        let totalHeight = height+(optionsScroll.isHidden ? 0 : optionsHeight+6)
        let below = rect.maxY+10
        let y = below+totalHeight <= bounds.height-8 ? below : (rect.minY-totalHeight-10 >= 8 ? rect.minY-totalHeight-10 : max(8,bounds.height-totalHeight-8))
        let x = max(8,min(rect.maxX-width,bounds.width-width-8))
        toolbarScroll.frame = CGRect(x:x,y:y,width:width,height:height)
        optionsScroll.frame = CGRect(x:max(8,min(x,bounds.width-optionsWidth-8)),y:y+height+6,width:optionsWidth,height:optionsHeight)
    }
    func updateUndo() { undoButton.isEnabled = !(canvas?.history.marks.isEmpty ?? true); redoButton.isEnabled = canvas?.history.canRedo ?? false }
    @objc func selectMove() {
        guard canReselect else { return }
        canvas?.commitText(); canvas?.cancelPending(); canvas?.isMoveMode = true
        colorButton.isEnabled = true; widthButton.isEnabled = true
        toolButtons.forEach { $0.state = .off; $0.contentTintColor = NSColor(calibratedWhite:0.18,alpha:1); $0.needsDisplay = true }
        dismissSizePicker(); closeColorPicker(); positionToolbar(); window?.makeFirstResponder(canvas)
    }
    func moveSelection(to rect: CGRect) {
        guard let canvas, rect != selection else { return }
        isSmartWindow = false; outlineTask?.cancel(); selection = rect
        guard let image = croppedImage() else { return }
        canvas.image = image; canvas.outline = nil; canvas.cornerRadius = 0
        canvas.frame = rect; canvas.needsDisplay = true; chrome?.needsDisplay = true
    }
    func group(_ kind: Mark.Kind) -> Mark.Kind {
        switch kind { case .ellipse: return .rectangle; case .mosaic: return .redact; default: return kind }
    }
    @objc func selectTool(_ sender: NSButton) {
        var kind = Mark.Kind.allCases[sender.tag]
        if kind == .rectangle { kind = areaKind }
        if kind == .redact { kind = maskKind }
        if canvas?.isMoveMode == false, canvas?.tool == kind, canReselect { selectMove(); refreshSizeLabel(); return }
        activateTool(kind)
    }
    func activateTool(_ kind: Mark.Kind) {
        canvas?.commitText(); canvas?.cancelPending(); canvas?.isMoveMode = false
        canvas?.tool = kind
        if kind == .mosaic { closeColorPicker() }
        if group(kind) == .rectangle { areaKind = kind }
        if group(kind) == .redact { maskKind = kind }
        let area = toolButtons[Mark.Kind.allCases.firstIndex(of:.rectangle)!]
        area.image = NSImage(systemSymbolName:areaKind == .ellipse ? "circle" : "rectangle",accessibilityDescription:"区域标注")
        let mask = toolButtons[Mark.Kind.allCases.firstIndex(of:.redact)!]
        mask.image = NSImage(systemSymbolName:maskKind == .mosaic ? "square.grid.3x3.fill" : "square.fill",accessibilityDescription:"遮罩")
        for b in toolButtons {
            b.state = Mark.Kind.allCases[b.tag] == group(kind) ? .on : .off
            b.contentTintColor = NSColor(calibratedWhite:0.18,alpha:1); b.needsDisplay = true
        }
        refreshSizeLabel(); dismissSizePicker(); positionToolbar(); window?.makeFirstResponder(canvas)
    }
    @objc func openAreaMenu() { openVariantMenu(anchor:areaMenuButton,kinds:[.rectangle,.ellipse]) }
    @objc func openMaskMenu() { openVariantMenu(anchor:maskMenuButton,kinds:[.redact,.mosaic]) }
    func openVariantMenu(anchor: NSButton, kinds: [Mark.Kind]) {
        dismissSizePicker()
        guard let window else { return }
        let panel = SizePickerPanel(contentRect:CGRect(x:0,y:0,width:140,height:kinds.count*30+10),styleMask:.borderless,backing:.buffered,defer:false)
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+2)
        panel.hasShadow = true; panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named:.aqua)
        panel.isOpaque = false; panel.backgroundColor = .clear
        let list = FlippedList(frame:panel.contentView!.bounds); list.wantsLayer = true
        list.layer?.backgroundColor = NSColor(calibratedWhite:0.99,alpha:1).cgColor; list.layer?.cornerRadius = 9
        list.layer?.borderWidth = 0.5; list.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        for (index,kind) in kinds.enumerated() {
            let selected = kind == (group(kind) == .rectangle ? areaKind : maskKind)
            let title = kind == .ellipse ? "椭圆" : kind.rawValue
            let b = ToolVariantButton(title:title,target:self,action:#selector(chooseVariant(_:)))
            b.symbolName = kind == .rectangle ? "rectangle" : kind == .ellipse ? "circle" : kind == .redact ? "square.fill" : "checkerboard.rectangle"
            b.state = selected ? .on : .off
            b.setAccessibilityLabel(title)
            b.tag = Mark.Kind.allCases.firstIndex(of:kind)!; b.isBordered = false; b.alignment = .left
            b.font = .systemFont(ofSize:12,weight:.medium)
            b.frame = CGRect(x:5,y:5+index*30,width:130,height:30); list.addSubview(b)
        }
        panel.contentView = list
        let anchorView: NSView = (anchor.superview as? ToolbarToolGroup) ?? anchor
        let rect = window.convertToScreen(anchorView.convert(anchorView.bounds,to:nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        panel.setFrameOrigin(CGPoint(x:max(screen.minX,min(rect.minX,screen.maxX-panel.frame.width)),y:rect.minY-panel.frame.height-6 >= screen.minY ? rect.minY-panel.frame.height-6 : min(screen.maxY-panel.frame.height,rect.maxY+6)))
        panel.onClose = { [weak self] in self?.dismissSizePicker(); self?.window?.makeKey() }
        sizePicker = panel; window.addChildWindow(panel,ordered:.above); panel.makeKeyAndOrderFront(nil)
    }
    @objc func chooseVariant(_ sender: NSButton) { activateTool(Mark.Kind.allCases[sender.tag]); window?.makeKey(); window?.makeFirstResponder(canvas) }
    func refreshSizeLabel() {
        let isText = canvas?.isMoveMode == false && canvas?.tool == .text
        let value = isText ? selectedFontSize : selectedStroke
        widthButton.title = "\(Int(value))"+(canvas?.tool == .mosaic ? " ▾" : "pt ▾")
    }
    @objc func openSizePicker() {
        if sizePicker?.isVisible == true { dismissSizePicker(); return }
        guard let window else { return }
        let values = canvas?.isMoveMode == false && canvas?.tool == .text ? [12,14,16,18,20,24,28,32,36,48,64,72] : [1,2,3,4,6,8,10,12,16]
        let panel = SizePickerPanel(contentRect: CGRect(x: 0, y: 0, width: 112, height: min(280, values.count*28+12)), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+2)
        panel.hasShadow = true; panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init()
        let list = FlippedList(frame: CGRect(x: 0, y: 0, width: 112, height: values.count*28+12))
        for (index,size) in values.enumerated() {
            let b = button(canvas?.tool == .mosaic ? "\(size)" : "\(size) pt", target: self, action: #selector(chooseSize(_:))); b.tag = size
            b.frame = CGRect(x: 6, y: 6+index*28, width: 92, height: 26); list.addSubview(b)
        }
        scroll.documentView = list; panel.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        let buttonRect = window.convertToScreen(widthButton.convert(widthButton.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        panel.setFrameOrigin(CGPoint(x: min(screen.maxX-panel.frame.width, max(screen.minX, buttonRect.minX)),
                                     y: buttonRect.minY-panel.frame.height >= screen.minY ? buttonRect.minY-panel.frame.height : min(screen.maxY-panel.frame.height, buttonRect.maxY)))
        panel.onClose = { [weak self] in self?.dismissSizePicker(); self?.window?.makeKey() }
        sizePicker = panel; window.addChildWindow(panel, ordered: .above); panel.makeKeyAndOrderFront(nil)
    }
    @objc func chooseSize(_ sender: NSButton) {
        if canvas?.isMoveMode == false && canvas?.tool == .text { selectedFontSize = CGFloat(sender.tag); canvas?.fontSize = selectedFontSize }
        else { selectedStroke = CGFloat(sender.tag); canvas?.stroke = selectedStroke }
        updateOptions(); dismissSizePicker(); window?.makeKey(); window?.makeFirstResponder(canvas?.textBox?.editor ?? canvas)
    }
    func dismissSizePicker() {
        if let panel = sizePicker { window?.removeChildWindow(panel); panel.close() }; sizePicker = nil
    }
    @objc func openColorPicker() {
        dismissSizePicker()
        let panel = NSColorPanel.shared
        panel.setTarget(self); panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true; panel.showsAlpha = false; panel.color = selectedInk
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+2)
        ownsColorPanel = true; panel.makeKeyAndOrderFront(nil)
    }
    @objc func colorChanged(_ sender: NSColorPanel) { selectedInk = sender.color; canvas?.ink = selectedInk; updateOptions() }
    func closeColorPicker() {
        if ownsColorPanel { let panel = NSColorPanel.shared; panel.setTarget(nil); panel.orderOut(nil); ownsColorPanel = false }
    }
    func resizeSelection(to rect: CGRect) {
        guard let canvas, let old = selection else { return }
        canvas.commitText()
        isSmartWindow = false; outlineTask?.cancel(); selection = rect
        guard let image = croppedImage() else { return }
        canvas.history.rebase(from: old, imageSize: canvas.image.size, to: rect, imageSize: image.size)
        canvas.image = image; canvas.cornerRadius = 0; canvas.outline = nil; canvas.frame = rect; canvas.needsDisplay = true
        chrome?.needsDisplay = true
    }
    @objc func undo() { canvas?.undoMark() }
    @objc func redo() { canvas?.redoMark() }
    @objc func reselect() {
        smartFirstClick = nil
        guard canReselect else { return }
        outlineTask?.cancel(); requestedOutline = nil
        recognitionTask?.cancel(); recognitionTask = nil
        textWindows.forEach { $0.close() }; textWindows.removeAll()
        canvas?.cancelPending(); dismissSizePicker(); closeColorPicker(); stopAnimation()
        canvas?.removeFromSuperview(); canvas = nil
        ocrButton.isEnabled = true; onReselect?()
        toolbarScroll.isHidden = true; optionsScroll.isHidden = true
        toolButtons.forEach { $0.state = .off; $0.contentTintColor = NSColor(calibratedWhite:0.18,alpha:1); $0.needsDisplay = true }
        selection = nil; isSmartWindow = false; dragging = false; movingSelection = false
        window?.makeFirstResponder(self); updateHover(hover); needsDisplay = true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let text = window?.firstResponder as? NSTextView, text.isEditable { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": copySelection(); return true
            case "s": saveSelection(); return true
            case "z": if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: cycleWindow(backwards: event.modifierFlags.contains(.shift))
        case 53: handleEscape()
        case 36, 76: if editing { copySelection() } else { beginEditing() }
        case 8 where !editing:
            if let hex = pixelHex() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string) }
        default: break
        }
    }
    func resultImage() -> NSImage? {
        if let canvas { return canvas.renderedImage() }
        guard let image = croppedImage() else { return nil }
        let renderer = Canvas(image: image); renderer.cornerRadius = selectionRadius; renderer.outline = selectedOutline
        return renderer.renderedImage()
    }
    func complete(_ action: CaptureAction) {
        guard let image = resultImage() else { NSSound.beep(); return }
        endInteraction()
        onFinish?(image, action)
    }
    @objc func copySelection() { complete(.copy) }
    @objc func saveSelection() {
        guard let image = resultImage() else { return }
        textWindows.forEach { $0.close() }; textWindows.removeAll()
        dismissSizePicker(); closeColorPicker()
        onModalChange?(true)
        defer { onModalChange?(false) }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LightPin-\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                guard let data = image.pngData else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic); complete(.saved)
            } catch { showError(error.localizedDescription) }
        }
    }
    @objc func recognize() {
        guard recognitionTask == nil, let image = resultImage() else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        ocrButton.isEnabled = false
        recognitionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    return .success((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
                } catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recognitionTask = nil; self.ocrButton.isEnabled = true
            let text: String
            switch result { case .success(let value): text = value.isEmpty ? "未识别到文字。" : value
            case .failure(let error): text = "识别失败：" + error.localizedDescription }
            let controller = TextResultController(text: text, provider: UnconfiguredTranslationProvider())
            controller.window?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+1)
            self.textWindows.append(controller); controller.showWindow(nil)
        }
    }
    func endInteraction() {
        smartFirstClick = nil
        outlineTask?.cancel()
        stopAnimation(); canvas?.cancelPending(); dismissSizePicker(); closeColorPicker()
        recognitionTask?.cancel(); textWindows.forEach { $0.close() }
    }
    func handleEscape() {
        if editing && canReselect && canvas?.isMoveMode == false {
            selectMove(); refreshSizeLabel()
        } else {
            goBack()
        }
    }
    @objc func goBack() {
        if editing && canReselect { reselect() } else { cancel() }
    }
    @objc func cancel() { endInteraction(); onFinish?(nil, .copy) }
}
