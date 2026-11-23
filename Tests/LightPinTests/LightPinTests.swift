import XCTest
import AppKit
@testable import LightPin

final class LightPinTests: XCTestCase {
    func testReverseDragRectangle() {
        XCTAssertEqual(Geometry.rect(CGPoint(x: 90, y: 80), CGPoint(x: 10, y: 20)), CGRect(x: 10, y: 20, width: 80, height: 60))
    }
    func testArrowPointsBackFromEndpoint() {
        let tips = Geometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), length: 20)
        XCTAssertEqual(tips[0].x, 100 - 10 * sqrt(3), accuracy: 0.001)
        XCTAssertEqual(abs(tips[0].y), 10, accuracy: 0.001)
        XCTAssertEqual(tips[0].y, -tips[1].y, accuracy: 0.001)
    }
    func testNewMarkDiscardsRedoBranch() {
        var history = MarkHistory()
        let a = Mark(kind: .rectangle, points: [.zero, CGPoint(x: 10, y: 10)], color: .red, width: 4)
        history.append(a); history.append(a); history.undo()
        XCTAssertEqual(history.marks.count, 1)
        history.redo(); XCTAssertEqual(history.marks.count, 2)
        history.undo(); history.append(a); history.redo()
        XCTAssertEqual(history.marks.count, 2)
        history.undo(); history.undo(); history.undo()
        XCTAssertTrue(history.marks.isEmpty)
    }
    func testUnconfiguredTranslationFailsExplicitly() async {
        do {
            _ = try await UnconfiguredTranslationProvider().translate("Hello", sourceLanguage: "en", targetLanguage: "zh-Hans")
            XCTFail("Must not return fake translations")
        } catch { XCTAssertTrue(error is TranslationError) }
    }
    @MainActor func testExportPreservesRetinaPixelsAndOpaqueRedaction() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Asymmetric source catches vertical inversion during export.
        for y in 0..<200 { for x in 0..<400 { bitmap.setColor(NSColor(deviceRed: y < 100 ? 1 : 0, green: 0, blue: y < 100 ? 0 : 1, alpha: 1), atX: x, y: y) } }
        bitmap.size = NSSize(width: 200, height: 100)
        let source = NSImage(size: bitmap.size); source.addRepresentation(bitmap)
        let canvas = Canvas(image: source)
        canvas.setFrameSize(NSSize(width: 100, height: 50))
        canvas.history.append(Mark(kind: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], color: .green, width: 3))
        let output = try XCTUnwrap(canvas.renderedImage())
        let result = try XCTUnwrap(output.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(result.pixelsWide, 400); XCTAssertEqual(result.pixelsHigh, 200)
        let top = try XCTUnwrap(result.colorAt(x: 300, y: 20)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(result.colorAt(x: 300, y: 180)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9); XCTAssertGreaterThan(bottom.blueComponent, 0.9)
        let hidden = try XCTUnwrap(result.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(hidden.redComponent, 0.01); XCTAssertGreaterThan(hidden.greenComponent, 0.9)
        XCTAssertLessThan(hidden.blueComponent, 0.01); XCTAssertEqual(hidden.alphaComponent, 1, accuracy: 0.01)
    }
}

final class InteractionTests: XCTestCase {
    func testShortcutDuplicatesAndDisabledBindings() {
        var bindings = KeyBinding.defaults
        XCTAssertNil(KeyBinding.validationError(bindings))
        bindings[1].key = bindings[0].key
        XCTAssertNotNil(KeyBinding.validationError(bindings))
        bindings[1].enabled = false
        XCTAssertNil(KeyBinding.validationError(bindings))
    }
    func testShortcutValidationAndRoundTrip() throws {
        var bindings = KeyBinding.defaults
        bindings[0].modifiers = 0
        XCTAssertNotNil(KeyBinding.validationError(bindings))
        bindings[0].key = 122 // F1 may be used without modifiers.
        XCTAssertNil(KeyBinding.validationError(bindings))
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode([KeyBinding].self, from: data), bindings)
        bindings[1].id = 1
        XCTAssertNotNil(KeyBinding.validationError(bindings))
    }
    @MainActor func testRecorderAcceptsCombinationAndEscapeKeepsBinding() throws {
        let recorder = KeyRecorder(binding: KeyBinding.defaults[0])
        recorder.begin()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        recorder.keyDown(with: event)
        XCTAssertEqual(recorder.binding.key, 7)
        XCTAssertEqual(recorder.binding.label, "⌃⌥X")
        XCTAssertFalse(recorder.recording)
        let saved = recorder.binding
        recorder.begin()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        recorder.keyDown(with: escape)
        XCTAssertEqual(recorder.binding, saved); XCTAssertFalse(recorder.recording)
    }
    func testRetinaSelectionClippingAndRounding() {
        let result = SelectionGeometry.pixels(CGRect(x: -10, y: 10.25, width: 60.25, height: 40.25), size: CGSize(width: 100, height: 100), width: 200, height: 200)
        XCTAssertEqual(result, CGRect(x: 0, y: 20, width: 101, height: 81))
        XCTAssertEqual(SelectionGeometry.pixels(CGRect(x: 120, y: 0, width: 10, height: 10), size: CGSize(width: 100, height: 100), width: 200, height: 200), .zero)
    }
    func testSelectionMovementStaysInsideDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let rect = CGRect(x: 10, y: 20, width: 50, height: 30)
        XCTAssertEqual(SelectionGeometry.move(rect, dx: 200, dy: -100, within: bounds), CGRect(x: 50, y: 0, width: 50, height: 30))
    }
    @MainActor func testInlineEditingCropPreservesPixels() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<60 { for x in 0..<100 { bitmap.setColor(NSColor(deviceRed: x < 50 ? 1 : 0, green: y < 30 ? 1 : 0, blue: 0, alpha: 1), atX: x, y: y) } }
        let cg = try XCTUnwrap(bitmap.cgImage)
        let view = SelectionView(image: cg, size: CGSize(width: 50, height: 30), windows: [])
        view.selection = CGRect(x: 25, y: 0, width: 25, height: 15)
        var cropped: NSImage?
        view.onFinish = { image, _ in cropped = image }
        view.beginEditing()
        XCTAssertNotNil(view.canvas)
        XCTAssertFalse(view.toolbarScroll.isHidden)
        view.complete(.copy)
        let output = try XCTUnwrap(cropped)
        XCTAssertEqual(output.size, CGSize(width: 25, height: 15))
        var rect = CGRect(origin: .zero, size: output.size)
        let rotated = try XCTUnwrap(output.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        XCTAssertEqual(rotated.width, 50); XCTAssertEqual(rotated.height, 30)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: rotated).colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(color.redComponent, 0.01); XCTAssertGreaterThan(color.greenComponent, 0.99)
    }
    func testWindowStackCyclesTopToBottomAndResetsWhenTargetsChange() {
        let top = CGRect(x: 10, y: 10, width: 40, height: 40)
        let bottom = CGRect(x: 0, y: 0, width: 100, height: 100)
        var stack = WindowHitStack(windows: [top, bottom])
        stack.update(at: CGPoint(x: 20, y: 20)); XCTAssertEqual(stack.selected, top)
        stack.cycle(); XCTAssertEqual(stack.selected, bottom)
        stack.update(at: CGPoint(x: 21, y: 21)); XCTAssertEqual(stack.selected, bottom)
        stack.cycle(); XCTAssertEqual(stack.selected, top)
        stack.cycle(backwards: true); XCTAssertEqual(stack.selected, bottom)
        stack.update(at: CGPoint(x: 80, y: 80)); XCTAssertEqual(stack.candidates, [1]); XCTAssertEqual(stack.depth, 0)
        stack.update(at: CGPoint(x: 150, y: 80)); XCTAssertNil(stack.selected)
    }
    func testIdenticalWindowBoundsRemainSeparateLayers() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        var stack = WindowHitStack(windows: [rect, rect, rect])
        stack.update(at: CGPoint(x: 10, y: 10))
        stack.cycle(); XCTAssertEqual(stack.depth, 1)
        stack.cycle(); XCTAssertEqual(stack.depth, 2)
        stack.cycle(); XCTAssertEqual(stack.depth, 0)
    }
    func testShortcutMigrationDropsRemovedActionsAndKeepsCustomCapture() {
        var old = KeyBinding.defaults
        old[1].key = 7
        old.append(KeyBinding(id: 3, key: 20, modifiers: old[0].modifiers))
        old.append(KeyBinding(id: 4, key: 21, modifiers: old[0].modifiers))
        let migrated = KeyBinding.migrated(old)
        XCTAssertEqual(migrated.map(\.id), [1,2]); XCTAssertEqual(migrated[1].key, 7)
        XCTAssertNil(KeyBinding.validationError(migrated))
    }

    @MainActor func testDragReleaseImmediatelyEntersInlineEditor() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let view = SelectionView(image: try XCTUnwrap(bitmap.cgImage), size: CGSize(width: 300, height: 250), windows: [CGRect(x: 0, y: 0, width: 300, height: 250)])
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 50, y: 60)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 220, y: 200)))
        XCTAssertFalse(view.editing)
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 220, y: 200)))
        XCTAssertTrue(view.editing)
        XCTAssertEqual(view.selection, CGRect(x: 50, y: 60, width: 170, height: 140))
        XCTAssertFalse(view.toolbarScroll.isHidden)
        XCTAssertTrue(view.bounds.contains(view.toolbarScroll.frame))
        view.reselect(); XCTAssertFalse(view.editing); XCTAssertTrue(view.toolbarScroll.isHidden)
    }
    @MainActor func testClickConfirmsTabSelectedLowerWindow() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let top = CGRect(x: 40, y: 40, width: 100, height: 100)
        let lower = CGRect(x: 10, y: 10, width: 250, height: 220)
        let view = SelectionView(image: try XCTUnwrap(bitmap.cgImage), size: CGSize(width: 300, height: 250), windows: [top, lower])
        let point = CGPoint(x: 80, y: 80)
        view.updateHover(point); XCTAssertEqual(view.selection, top)
        view.cycleWindow(); XCTAssertEqual(view.selection, lower)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        XCTAssertTrue(view.editing); XCTAssertEqual(view.selection, lower)
    }

}

final class CapturePermissionTests: XCTestCase {
    func testDenialStopsRetriesUntilUserRequestsRecovery() {
        var state = CapturePermissionState()
        XCTAssertFalse(state.requiresUserRecovery)
        state.record(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801))
        XCTAssertTrue(state.requiresUserRecovery)
        state.retryRequested()
        XCTAssertFalse(state.requiresUserRecovery)
    }
    func testWrappedDenialAndUnrelatedErrors() {
        let denial = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: denial])
        XCTAssertTrue(CapturePermissionState.isDenied(wrapped))
        XCTAssertFalse(CapturePermissionState.isDenied(NSError(domain: "other", code: -3801)))
        var state = CapturePermissionState()
        state.record(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3802))
        XCTAssertFalse(state.requiresUserRecovery)
    }
}

final class SelectionRefinementTests: XCTestCase {
    @MainActor func source() throws -> CGImage {
        let cg = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(CGColor(gray: 1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return try XCTUnwrap(cg.makeImage())
    }
    func testEightResizeAnchorsAndClamps() {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(ResizeAnchor.allCases.count, 8)
        for anchor in ResizeAnchor.allCases {
            XCTAssertEqual(ResizeAnchor.hit(anchor.point(in: rect), in: rect), anchor)
            let resized = anchor.resize(rect, to: CGPoint(x: 180, y: 180), within: bounds)
            XCTAssertTrue(bounds.contains(resized)); XCTAssertGreaterThanOrEqual(resized.width, 8); XCTAssertGreaterThanOrEqual(resized.height, 8)
        }
        XCTAssertEqual(ResizeAnchor.left.resize(rect, to: CGPoint(x: -20, y: 40), within: bounds), CGRect(x: 0, y: 30, width: 120, height: 80))
        XCTAssertEqual(ResizeAnchor.bottom.resize(rect, to: CGPoint(x: 0, y: 160), within: bounds), CGRect(x: 20, y: 30, width: 100, height: 130))
    }
    func testSelectionTweenHasExactEndpointsAndSmoothMidpoint() {
        let a = CGRect(x: 10, y: 20, width: 80, height: 100)
        let b = CGRect(x: 50, y: 60, width: 160, height: 200)
        XCTAssertEqual(SelectionTween.rect(from: a, to: b, progress: 0), a)
        XCTAssertEqual(SelectionTween.rect(from: a, to: b, progress: 1), b)
        XCTAssertEqual(SelectionTween.rect(from: a, to: b, progress: 0.5), CGRect(x: 30, y: 40, width: 120, height: 150))
    }
    @MainActor func testArrowPointerRestoresOnMouseUpAndCancellation() throws {
        let canvas = Canvas(image: NSImage(cgImage: try source(), size: CGSize(width: 400, height: 300)))
        var hides = 0, shows = 0
        canvas.hidePointer = { hides += 1 }; canvas.showPointer = { shows += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 70, y: 70)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 80)))
        XCTAssertTrue(canvas.pointerIsHidden); XCTAssertEqual(hides, 1)
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 80, y: 80)))
        XCTAssertFalse(canvas.pointerIsHidden); XCTAssertEqual(shows, 1)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 80)))
        canvas.cancelPending(); canvas.cancelPending()
        XCTAssertFalse(canvas.pointerIsHidden); XCTAssertEqual(shows, 2); XCTAssertEqual(hides, 2)
        XCTAssertEqual(canvas.history.marks.count, 1)
    }
    @MainActor func testRoundedWindowPNGHasRealAlphaAndResizeBecomesRectangle() throws {
        let view = SelectionView(image: try source(), size: CGSize(width: 400, height: 300), windows: [CGRect(x: 20, y: 20, width: 200, height: 180)])
        view.updateHover(CGPoint(x: 80, y: 80)); XCTAssertTrue(view.isSmartWindow)
        view.beginEditing()
        let png = try XCTUnwrap(view.resultImage()?.pngData)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 400); XCTAssertEqual(bitmap.pixelsHigh, 360)
        for p in [(0,0),(399,0),(0,359),(399,359)] { XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: p.0, y: p.1)).alphaComponent, 0, accuracy: 0.01) }
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 200, y: 180)).alphaComponent, 1, accuracy: 0.01)
        view.resizeSelection(to: CGRect(x: 10, y: 10, width: 220, height: 200))
        XCTAssertFalse(view.isSmartWindow)
        let resized = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(view.resultImage()?.pngData)))
        XCTAssertEqual(try XCTUnwrap(resized.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
    }
    @MainActor func testResizeKeepsAnnotationAndRedoAtSameScreenPosition() throws {
        let view = SelectionView(image: try source(), size: CGSize(width: 400, height: 300), windows: [])
        view.selection = CGRect(x: 50, y: 60, width: 200, height: 180); view.beginEditing()
        let canvas = try XCTUnwrap(view.canvas)
        canvas.history.append(Mark(kind: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .red, width: 4))
        canvas.undoMark()
        view.resizeSelection(to: CGRect(x: 30, y: 40, width: 240, height: 220))
        canvas.redoMark()
        XCTAssertEqual(canvas.history.marks[0].points[0], CGPoint(x: 30, y: 30))
        XCTAssertEqual(canvas.history.marks[0].points[1], CGPoint(x: 50, y: 50))
    }
    @MainActor func testRightClickCancelsAndFontSizeIsIndependentOfStroke() throws {
        let view = SelectionView(image: try source(), size: CGSize(width: 400, height: 300), windows: [])
        view.selection = CGRect(x: 20, y: 20, width: 200, height: 180); view.beginEditing()
        let canvas = try XCTUnwrap(view.canvas)
        view.activateTool(.text)
        let option = NSButton(); option.tag = 48; view.chooseSize(option)
        XCTAssertEqual(canvas.fontSize, 48); XCTAssertEqual(canvas.stroke, 2)
        view.activateTool(.arrow); option.tag = 8; view.chooseSize(option)
        XCTAssertEqual(canvas.stroke, 8); XCTAssertEqual(canvas.fontSize, 48)
        var cancelled = false
        view.onFinish = { image, _ in cancelled = image == nil }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: event); XCTAssertFalse(cancelled); XCTAssertFalse(view.editing)
        view.rightMouseDown(with: event); XCTAssertTrue(cancelled)
    }
}

final class InlineTextAndOutlineTests: XCTestCase {
    @MainActor func testTextWrapMoveEditUndoAndExport() throws {
        let canvas = Canvas(image: NSImage(size: NSSize(width: 400,height: 300)))
        canvas.beginText(Mark(kind: .text, points: [CGPoint(x:40,y:40),CGPoint(x:200,y:80)], color:.red,width:4,text:"",fontSize:24))
        let box = try XCTUnwrap(canvas.textBox)
        box.editor.string = "这是需要自动换行的文字，拖动后依然保留内容。"
        canvas.fitTextBox()
        XCTAssertGreaterThan(box.frame.height, 60)
        XCTAssertLessThanOrEqual(box.frame.maxX, canvas.bounds.maxX)
        XCTAssertLessThanOrEqual(box.frame.maxY, canvas.bounds.maxY)
        canvas.commitText()
        let original = try XCTUnwrap(canvas.history.marks.first)
        XCTAssertEqual(original.text, box.editor.string)
        canvas.beginText(original)
        canvas.moveText(to: CGPoint(x:220,y:220))
        XCTAssertLessThanOrEqual(try XCTUnwrap(canvas.textBox).frame.maxX,400)
        XCTAssertLessThanOrEqual(try XCTUnwrap(canvas.textBox).frame.maxY,300)
        canvas.commitText()
        XCTAssertEqual(canvas.history.marks.count,1)
        XCTAssertNotEqual(canvas.history.marks[0].points,original.points)
        canvas.undoMark(); XCTAssertEqual(canvas.history.marks[0].points,original.points)
        canvas.redoMark(); XCTAssertNotEqual(canvas.history.marks[0].points,original.points)
        canvas.beginText(canvas.history.marks[0]); canvas.textBox?.editor.string = "修改文字"; canvas.commitText()
        XCTAssertEqual(canvas.history.marks[0].text,"修改文字")
        canvas.undoMark(); XCTAssertEqual(canvas.history.marks[0].text,original.text)
    }
    @MainActor func testNativeOutlineMatchesAlphaAndRoundedHandles() throws {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:200,height:160,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(CGPath(roundedRect:CGRect(x:0,y:0,width:200,height:160),cornerWidth:32,cornerHeight:32,transform:nil)); ctx.fillPath()
        let outline = try XCTUnwrap(WindowOutline(image: try XCTUnwrap(ctx.makeImage())))
        let path = outline.path(in:CGRect(x:0,y:0,width:200,height:160))
        XCTAssertFalse(path.contains(CGPoint(x:2,y:2)))
        XCTAssertFalse(path.contains(CGPoint(x:197,y:157)))
        XCTAssertTrue(path.contains(CGPoint(x:32,y:2)))
        XCTAssertTrue(path.contains(CGPoint(x:100,y:80)))
        XCTAssertGreaterThan(outline.cornerInset,0.1)
        let rect = CGRect(x:20,y:20,width:200,height:160)
        let anchor = ResizeAnchor.topLeft.point(in:rect,radius:32)
        XCTAssertGreaterThan(anchor.x,rect.minX)
        XCTAssertEqual(ResizeAnchor.hit(anchor,in:rect,radius:32),.topLeft)
        let canvas = Canvas(image: NSImage(cgImage:try XCTUnwrap(ctx.makeImage()),size:NSSize(width:200,height:160)))
        canvas.outline = outline
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(canvas.renderedImage()?.pngData)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:1,y:1)).alphaComponent,0,accuracy:0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:100,y:80)).alphaComponent,0.99)
    }
}

final class CaptureWorkflowTests: XCTestCase {
    func testFullyOccludedAndUnionCoveredWindowsAreExcluded() {
        let screen = CGRect(x:0,y:0,width:400,height:300)
        let full = CGRect(x:0,y:0,width:200,height:200)
        XCTAssertEqual(WindowVisibility.visibleIndices([full,full],within:screen),[0])
        XCTAssertEqual(WindowVisibility.visibleIndices([CGRect(x:0,y:0,width:100,height:200),CGRect(x:100,y:0,width:100,height:200),full],within:screen),[0,1])
        XCTAssertEqual(WindowVisibility.visibleIndices([full,CGRect(x:100,y:100,width:200,height:200)],within:screen),[0,1])
        XCTAssertEqual(WindowVisibility.visibleIndices([full,full],within:screen,opaque:[false,true]),[0,1])
        XCTAssertEqual(WindowVisibility.visibleIndices([CGRect(x:0,y:0,width:400,height:300),CGRect(x:350,y:200,width:200,height:200)],within:screen),[0])
    }
    @MainActor func testDefaultMoveModeMovesCropAndDoubleClickCompletes() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:400,height:300,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x:0,y:0,width:200,height:300))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x:200,y:0,width:200,height:300))
        let view = SelectionView(image:try XCTUnwrap(context.makeImage()),size:NSSize(width:400,height:300),windows:[])
        view.selection = CGRect(x:50,y:60,width:100,height:80); view.beginEditing()
        let canvas = try XCTUnwrap(view.canvas)
        XCTAssertTrue(canvas.isMoveMode); XCTAssertTrue(view.toolButtons.allSatisfy { $0.state == .off })
        XCTAssertEqual(canvas.cursor(at:.zero),NSCursor.openHand)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:clicks,pressure:1))
        }
        let start = canvas.convert(CGPoint(x:10,y:10),to:nil)
        canvas.mouseDown(with:try event(.leftMouseDown,start))
        let end = CGPoint(x:start.x+200,y:start.y)
        canvas.mouseDragged(with:try event(.leftMouseDragged,end))
        canvas.mouseUp(with:try event(.leftMouseUp,end))
        XCTAssertEqual(view.selection,CGRect(x:250,y:60,width:100,height:80))
        XCTAssertTrue(canvas.history.marks.isEmpty)
        XCTAssertFalse(view.movingSelection); XCTAssertFalse(view.toolbarScroll.isHidden)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(canvas.image.pngData)))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:50,y:40)).blueComponent,0.9)
        view.selectTool(view.toolButtons[0]); XCTAssertFalse(canvas.isMoveMode)
        view.selectMove(); XCTAssertTrue(canvas.isMoveMode)
        var completed = 0
        view.onFinish = { image, action in if image != nil && action == .copy { completed += 1 } }
        canvas.mouseDown(with:try event(.leftMouseDown,canvas.convert(CGPoint(x:20,y:20),to:nil),clicks:2))
        XCTAssertEqual(completed,1)
    }
}

final class GroupedToolbarTests: XCTestCase {
    @MainActor func testEscapeDeselectsToolBeforeReselectingAndExiting() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(image:try XCTUnwrap(context.makeImage()),size:NSSize(width:320,height:240),windows:[])
        let region = CGRect(x:20,y:20,width:200,height:150)
        view.selection = region; view.beginEditing(); view.activateTool(.text)
        let canvas = try XCTUnwrap(view.canvas)
        canvas.beginText(Mark(kind:.text,points:[CGPoint(x:10,y:20),CGPoint(x:180,y:60)],color:.red,width:2,text:"保留标注",fontSize:20))
        var exits = 0; view.onFinish = { _,_ in exits += 1 }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
        view.keyDown(with:escape)
        XCTAssertTrue(canvas.isMoveMode); XCTAssertNil(canvas.textBox)
        XCTAssertEqual(canvas.history.marks.first?.text,"保留标注")
        XCTAssertEqual(view.selection,region); XCTAssertTrue(view.editing)
        XCTAssertTrue(view.toolButtons.allSatisfy { $0.state == .off })
        XCTAssertTrue(view.optionsScroll.isHidden); XCTAssertEqual(exits,0)
        view.keyDown(with:escape)
        XCTAssertFalse(view.editing); XCTAssertNil(view.canvas); XCTAssertEqual(exits,0)
        view.keyDown(with:escape); XCTAssertEqual(exits,1)
    }

    @MainActor func testToolGroupingToggleAndReturnStages() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:320,height:240))
        let view = SelectionView(image:try XCTUnwrap(context.makeImage()),size:NSSize(width:320,height:240),windows:[])
        view.selection = CGRect(x:20,y:20,width:200,height:150); view.beginEditing()
        XCTAssertEqual(view.canvas?.stroke,2)
        XCTAssertTrue(view.optionsScroll.isHidden)
        XCTAssertFalse(view.widthButton.isDescendant(of:view.toolbar))
        XCTAssertTrue(view.widthButton.isDescendant(of:view.optionsBar))
        XCTAssertTrue(view.canvas?.isMoveMode == true)
        let visibleTools = view.toolbar.arrangedSubviews.compactMap { ($0 as? ToolbarToolGroup)?.main ?? ($0 as? NSButton) }.filter { view.toolButtons.contains($0) }
        XCTAssertEqual(visibleTools.map { Mark.Kind.allCases[$0.tag] },[.rectangle,.arrow,.pen,.redact,.text])
        let area = view.toolButtons[Mark.Kind.allCases.firstIndex(of:.rectangle)!]
        view.selectTool(area); XCTAssertEqual(view.canvas?.tool,.rectangle); XCTAssertFalse(view.canvas!.isMoveMode)
        XCTAssertFalse(view.optionsScroll.isHidden)
        XCTAssertGreaterThan(view.optionsScroll.frame.minY,view.toolbarScroll.frame.maxY)
        XCTAssertLessThanOrEqual(view.optionsScroll.frame.maxY,view.bounds.maxY)
        view.selectTool(area); XCTAssertTrue(view.canvas!.isMoveMode); XCTAssertTrue(view.optionsScroll.isHidden)
        let option = NSButton(); option.tag = Mark.Kind.allCases.firstIndex(of:.ellipse)!
        view.chooseVariant(option); XCTAssertEqual(view.canvas?.tool,.ellipse); XCTAssertEqual(area.state,.on)
        view.selectTool(area); XCTAssertTrue(view.canvas!.isMoveMode); XCTAssertTrue(view.optionsScroll.isHidden)
        option.tag = Mark.Kind.allCases.firstIndex(of:.mosaic)!
        view.chooseVariant(option); XCTAssertEqual(view.canvas?.tool,.mosaic)
        XCTAssertTrue(view.colorOptions.isHidden); XCTAssertFalse(view.widthOptions.isHidden)
        view.activateTool(.redact)
        XCTAssertTrue(view.widthOptions.isHidden); XCTAssertFalse(view.colorOptions.isHidden)
        view.chooseColor(view.colorSwatches[5]); XCTAssertEqual(view.canvas?.ink,NSColor.black)
        XCTAssertFalse(view.canvas!.isMoveMode)
        var exits = 0; view.onFinish = { _,_ in exits += 1 }
        view.goBack(); XCTAssertFalse(view.editing); XCTAssertEqual(exits,0); XCTAssertTrue(view.optionsScroll.isHidden)
        view.goBack(); XCTAssertEqual(exits,1)
    }
    @MainActor func testMosaicActuallyPixelatesAndUndoRestoresSource() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        for y in 0..<64 { for x in 0..<64 { let v: CGFloat = (x+y)%2 == 0 ? 1 : 0; bitmap.setColor(NSColor(deviceRed:v,green:v,blue:v,alpha:1),atX:x,y:y) } }
        bitmap.size = NSSize(width:64,height:64)
        let image = NSImage(size:bitmap.size); image.addRepresentation(bitmap)
        let canvas = Canvas(image:image)
        canvas.history.append(Mark(kind:.mosaic,points:[CGPoint(x:8,y:8),CGPoint(x:56,y:56)],color:.red,width:2))
        let result = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(canvas.renderedImage()?.pngData)))
        let first = try XCTUnwrap(result.colorAt(x:10,y:10)?.usingColorSpace(.deviceRGB))
        let second = try XCTUnwrap(result.colorAt(x:11,y:10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(first.redComponent,0.1); XCTAssertLessThan(first.redComponent,0.9)
        XCTAssertEqual(first.redComponent,second.redComponent,accuracy:0.01)
        XCTAssertEqual(first.redComponent,first.greenComponent,accuracy:0.01)
        canvas.undoMark()
        let restored = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(canvas.renderedImage()?.pngData)))
        XCTAssertGreaterThan(try XCTUnwrap(restored.colorAt(x:10,y:10)).redComponent,0.99)
        XCTAssertLessThan(try XCTUnwrap(restored.colorAt(x:11,y:10)).redComponent,0.01)
    }
}

final class TextRenderingAndCloseTests: XCTestCase {
    @MainActor func testCommittedTextHasNoWhiteOutline() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:240,height:96,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x:0,y:0,width:240,height:96))
        let canvas = Canvas(image:NSImage(cgImage:try XCTUnwrap(context.makeImage()),size:NSSize(width:240,height:96)))
        canvas.beginText(Mark(kind:.text,points:[CGPoint(x:10,y:20),CGPoint(x:230,y:75)],color:NSColor(deviceRed:1,green:0,blue:0,alpha:1),width:2,text:"截图 Text",fontSize:30))
        canvas.commitText()
        let result = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(canvas.renderedImage()?.pngData)))
        var redPixels = 0, whitePixels = 0
        for y in 0..<result.pixelsHigh { for x in 0..<result.pixelsWide {
            guard let color = result.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.1 { redPixels += 1 }
            if color.greenComponent > 0.15 && color.greenComponent > color.redComponent*0.8 && color.blueComponent > color.redComponent*0.8 { whitePixels += 1 }
        } }
        XCTAssertGreaterThan(redPixels,100)
        XCTAssertEqual(whitePixels,0)
    }
    @MainActor func testCommandWIsWindowLocalAndDoesNotMatchOtherModifiers() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:13))
        }
        XCTAssertTrue(WindowClosing.isShortcut(try event([.command],"w")))
        XCTAssertFalse(WindowClosing.isShortcut(try event([],"w")))
        XCTAssertFalse(WindowClosing.isShortcut(try event([.command,.shift],"w")))
        XCTAssertFalse(WindowClosing.isShortcut(try event([.command],"q")))
    }
}

final class ScrollStripTests: XCTestCase {
    func testDownwardScrollAndUnchangedFrame() throws {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:96,height:300,bitsPerComponent:8,bytesPerRow:96,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0))
        var seed: UInt32 = 41
        for y in 0..<300 {
            for x in stride(from:0,to:96,by:8) {
                seed = seed &* 1664525 &+ 1013904223
                ctx.setFillColor(gray:CGFloat(seed >> 24)/255,alpha:1)
                ctx.fill(CGRect(x:x,y:y,width:8,height:1))
            }
        }
        let full = try XCTUnwrap(ctx.makeImage())
        let top = try XCTUnwrap(full.cropping(to:CGRect(x:0,y:0,width:96,height:180)).flatMap(ScrollStrip.init))
        let next = try XCTUnwrap(full.cropping(to:CGRect(x:0,y:107,width:96,height:180)).flatMap(ScrollStrip.init))
        XCTAssertEqual(top.displacement(to:top),0)
        XCTAssertEqual(top.displacement(to:next),107)
        XCTAssertNil(next.displacement(to:top))
    }
}

final class SmartDoubleClickTests: XCTestCase {
    @MainActor func testSecondClickAfterCanvasReplacementCompletesHoveredWindow() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:320,height:240,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let region = CGRect(x:20,y:20,width:200,height:140)
        let view = SelectionView(image:try XCTUnwrap(context.makeImage()),size:CGSize(width:320,height:240),windows:[region])
        let panel = SelectionPanel(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        panel.contentView = view
        let point = view.convert(CGPoint(x:80,y:80),to:nil)
        func click(_ type: NSEvent.EventType, _ time: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:time,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        var captures = [NSImage]()
        view.onFinish = { image,_ in if let image { captures.append(image) } }
        view.mouseDown(with:try click(.leftMouseDown,1))
        view.mouseUp(with:try click(.leftMouseUp,1.01))
        XCTAssertTrue(view.editing)
        XCTAssertTrue(view.toolbarScroll.isHidden)
        XCTAssertTrue(captures.isEmpty)
        panel.sendEvent(try click(.leftMouseDown,1 + NSEvent.doubleClickInterval/2))
        XCTAssertEqual(captures.map { $0.size },[region.size])
        XCTAssertTrue(view.toolbarScroll.isHidden)

        view.reselect()
        view.mouseDown(with:try click(.leftMouseDown,2))
        view.mouseUp(with:try click(.leftMouseUp,2.01))
        XCTAssertTrue(view.toolbarScroll.isHidden)
        RunLoop.current.run(until:Date(timeIntervalSinceNow:NSEvent.doubleClickInterval + 0.1))
        XCTAssertFalse(view.toolbarScroll.isHidden)
        XCTAssertEqual(captures.count,1)
    }
}
