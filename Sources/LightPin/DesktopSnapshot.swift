import AppKit
import ScreenCaptureKit

/// Capture the composited desktop, including real shadows cast onto other windows.
/// LightPin's windows are hidden by prepareSession before this is called.
enum DesktopSnapshot {
    @available(macOS 26.0, *)
    static func capture(rect: CGRect, scale: CGFloat) async throws -> CGImage {
        let config = SCScreenshotConfiguration()
        config.width = Int((rect.width*scale).rounded())
        config.height = Int((rect.height*scale).rounded())
        config.showsCursor = false
        config.ignoreShadows = false
        config.ignoreClipping = false
        config.includeChildWindows = true
        config.dynamicRange = .sdr
        config.displayIntent = .local
        let result = try await SCScreenshotManager.captureScreenshot(rect: rect, configuration: config)
        guard let image = result.sdrImage else { throw CocoaError(.fileReadUnknown) }
        return image
    }
    static func capture(display: SCDisplay, scale: CGFloat) async throws -> CGImage {
        let rect = CGDisplayBounds(display.displayID)
        if #available(macOS 26.0, *) { return try await capture(rect: rect, scale: scale) }
        // Older systems use an unfiltered full-display capture as well.
        let config = SCStreamConfiguration()
        config.width = Int((rect.width*scale).rounded()); config.height = Int((rect.height*scale).rounded())
        config.showsCursor = false; config.ignoreShadowsDisplay = false; config.ignoreGlobalClipDisplay = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }
}
