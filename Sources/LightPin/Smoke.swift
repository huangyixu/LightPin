import AppKit

// Explicit local UI verification mode. Does not register hotkeys, read the clipboard,
// access capture history, capture the desktop, or change system preferences.
@MainActor
func runSmokeCheck(directory: String) throws {
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let sample = NSImage(size: NSSize(width: 1000, height: 600))
    sample.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.21, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: 1000, height: 600).fill()
    ("LightPin / Capture your ideas" as NSString).draw(at: CGPoint(x: 70, y: 410), withAttributes: [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.white])
    ("截图 · 标注 · 文字识别" as NSString).draw(at: CGPoint(x: 70, y: 330), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white])
    sample.unlockFocus()
    let delegate = AppDelegate(); delegate.buildHome()
    let text = TextResultController(text: "LightPin / Capture your ideas\n截图 · 标注 · 文字识别", provider: UnconfiguredTranslationProvider())
    let settings = ShortcutSettings(bindings: KeyBinding.defaults)
    var rect = CGRect(origin: .zero, size: sample.size)
    guard let cg = sample.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw CocoaError(.fileReadUnknown) }
    let selectedWindow = CGRect(x: 60, y: 100, width: 650, height: 320)
    let selection = SelectionView(image: cg, size: sample.size, windows: [selectedWindow])
    selection.updateHover(CGPoint(x: 100, y: 150))
    selection.beginEditing()
    selection.canvas?.history.append(Mark(kind: .arrow, points: [CGPoint(x: 40, y: 260), CGPoint(x: 390, y: 180)], color: .systemRed, width: 4))
    selection.updateUndo()
    let selectionWindow = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    selectionWindow.contentView = selection; selectionWindow.isReleasedWhenClosed = false
    let selector = NSWindowController(window: selectionWindow)
    func render(_ name: String, _ controller: NSWindowController) throws {
        guard let window = controller.window, let view = window.contentView else { throw CocoaError(.fileReadUnknown) }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.18))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        print("Rendered \(name): \(Int(view.bounds.width)) × \(Int(view.bounds.height))")
        window.orderOut(nil)
    }
    for (name, controller) in [("home", delegate.home!), ("ocr", text), ("settings", settings), ("inline-editor", selector)] { try render(name, controller) }
    selection.activateTool(.rectangle)
    try render("secondary-panel", selector)
    let png = selection.resultImage()?.pngData
    try png?.write(to: output.appendingPathComponent("rounded-export.png"))
    selection.resizeAnchor = .bottomRight; selection.hover = CGPoint(x: selectedWindow.maxX, y: selectedWindow.maxY)
    try render("resize-magnifier", selector)
    selection.resizeAnchor = nil
    selection.selectTool(selection.toolButtons[Mark.Kind.allCases.firstIndex(of: .text)!])
    if let canvas = selection.canvas {
        canvas.beginText(Mark(kind: .text, points: [CGPoint(x:80,y:120),CGPoint(x:380,y:160)], color:.systemYellow,width:4,text:"",fontSize:24))
        canvas.textBox?.editor.string = "直接在截图中输入文字，长句会自动换行。拖动顶部即可移动文本框。"
        canvas.fitTextBox()
        try render("inline-text-editing", selector)
        canvas.commitText()
        try render("inline-text-finished", selector)
    }
    if let canvas = selection.canvas {
        selectionWindow.makeKeyAndOrderFront(nil)
        canvas.beginText(Mark(kind:.text,points:[CGPoint(x:40,y:80),CGPoint(x:250,y:130)],color:.red,width:2,text:"",fontSize:24))
        precondition(selectionWindow.firstResponder === canvas.textBox?.editor)
        selectionWindow.makeFirstResponder(canvas)
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05))
        precondition(canvas.textBox == nil, "Empty text editor must disappear on focus loss")
        canvas.beginText(Mark(kind:.text,points:[CGPoint(x:40,y:80),CGPoint(x:250,y:130)],color:.red,width:2,text:"保留文字",fontSize:24))
        selectionWindow.makeFirstResponder(canvas)
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05))
        precondition(canvas.textBox?.editor.string == "保留文字", "Nonempty editor must retain text")
        canvas.commitText()
        print("Empty/nonempty text focus checks passed")
    }
    selection.openSizePicker()
    if let panel = selection.sizePicker { try render("font-dropdown", NSWindowController(window: panel)) }
    selection.dismissSizePicker()
    selection.openAreaMenu()
    if let panel = selection.sizePicker { try render("area-menu", NSWindowController(window:panel)) }
    selection.dismissSizePicker()
    selection.activateTool(.ellipse)
    try render("area-selected", selector)
    selection.openMaskMenu()
    if let panel = selection.sizePicker { try render("mask-menu", NSWindowController(window:panel)) }
    selection.dismissSizePicker()
    selection.activateTool(.mosaic)
    selection.canvas?.history.append(Mark(kind:.mosaic,points:[CGPoint(x:20,y:40),CGPoint(x:480,y:95)],color:.red,width:2))
    try render("mosaic-preview",selector)
    selection.openColorPicker()
    try render("color-picker", NSWindowController(window: NSColorPanel.shared))
    selection.endInteraction()
    var settingsClosed = false
    settings.onClose = { settingsClosed = true }
    for controller in [delegate.home!, text, settings] {
        controller.window?.orderFront(nil)
        WindowClosing.close(controller.window)
        precondition(controller.window?.isVisible == false, "Command-W must close regular windows")
    }
    precondition(settingsClosed, "Settings close must restore shortcut lifecycle")
    selection.openSizePicker()
    WindowClosing.close(selection.sizePicker)
    precondition(selection.sizePicker == nil, "Dropdown close must clear its owner")
    let capturePanel = SelectionPanel(contentRect:rect,styleMask:[.borderless],backing:.buffered,defer:false)
    capturePanel.isReleasedWhenClosed = false
    capturePanel.contentView = selection
    var cancelled = false
    selection.onFinish = { _,_ in cancelled = true; capturePanel.close() }
    capturePanel.orderFront(nil)
    WindowClosing.close(capturePanel)
    precondition(cancelled && !capturePanel.isVisible, "Capture close must cancel its session")
    NSColorPanel.shared.orderFront(nil)
    WindowClosing.close(NSColorPanel.shared)
    precondition(!NSColorPanel.shared.isVisible, "Color panel must close")
    print("Window close checks passed: home, OCR, settings callback, dropdown, capture cancellation, color panel")
}
