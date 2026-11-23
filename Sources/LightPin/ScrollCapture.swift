import AppKit
import ScreenCaptureKit

/// Samples columns across each row while preserving the exact vertical pixel scale.
struct ScrollStrip {
    let width = 48
    let height: Int
    let rows: [UInt8]

    init?(_ image: CGImage) {
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 48, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: image.height))
            return true
        }
        guard ok else { return nil }
        rows = pixels
    }

    func displacement(to next: Self) -> Int? {
        guard height == next.height, height >= 32 else { return nil }
        let overlap = max(24, height / 5)
        var best = Double.infinity, runnerUp = Double.infinity, offset = 0
        for d in 0...(height - overlap) {
            var total = 0, count = 0
            for y in stride(from: 0, to: height-d, by: max(1,(height-d)/48)) {
                for x in stride(from: 2, to: width-2, by: 2) {
                    total += abs(Int(rows[(y+d)*width+x]) - Int(next.rows[y*width+x]))
                    count += 1
                }
            }
            let score = Double(total)/Double(count)
            if d == 0 && score < 0.4 { return 0 }
            if score < best { runnerUp = best; best = score; offset = d }
            else { runnerUp = min(runnerUp,score) }
        }
        return best < 5 && runnerUp-best > 0.15 ? offset : nil
    }
}

@MainActor
final class ScrollCapture: NSObject {
    let panel = NSPanel(contentRect: NSRect(x:0,y:0,width:480,height:58),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
    let status = NSTextField(labelWithString:"向下滚动，内容将自动拼接")
    let filter: SCContentFilter
    let config = SCStreamConfiguration()
    let scale: CGFloat
    var parts: [CGImage]
    var previous: ScrollStrip
    var task: Task<Void,Never>?
    private var finishing = false
    private var reachedLimit = false
    private var mayFinishPartial = false
    private lazy var finishButton = button("完成", target:self, action:#selector(done))
    var onFinish: ((NSImage?) -> Void)?
    init?(first: CGImage, rect: CGRect, screen: NSScreen, display: SCDisplay, excluded: [SCRunningApplication]) {
        guard let strip = ScrollStrip(first), first.height >= 32, first.width * first.height < 24_000_000 else { return nil }
        previous = strip; parts = [first]; scale = screen.backingScaleFactor
        filter = SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
        super.init()
        config.sourceRect = rect; config.width = first.width; config.height = first.height; config.showsCursor = false
        panel.title = "区域滚动截图"; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let row = NSStackView(views:[status, finishButton,button("取消",target:self,action:#selector(cancel))])
        row.edgeInsets = NSEdgeInsets(top:8,left:10,bottom:8,right:10)
        panel.contentView = row
        panel.setFrameTopLeftPoint(NSPoint(x:screen.visibleFrame.midX-panel.frame.width/2,y:screen.visibleFrame.maxY))
    }
    func start() {
        task = Task {
            while !Task.isCancelled && !reachedLimit {
                _ = await sample()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func sample() async -> Bool {
        do {
            let frame = try await SCScreenshotManager.captureImage(contentFilter:filter, configuration:config)
            guard !Task.isCancelled else { return false }
            guard let current = ScrollStrip(frame), let offset = previous.displacement(to:current) else {
                status.stringValue = "画面未对齐，请向上回滚一点"
                return false
            }
            mayFinishPartial = false
            finishButton.title = "完成"
            if offset > 0 {
                let height = parts.reduce(offset) { $0 + $1.height }
                guard height * frame.width <= 24_000_000 else {
                    reachedLimit = true
                    status.stringValue = "已达上限，可完成已拼接部分"
                    return true
                }
                // Detach the strip so a small scroll does not retain a full screenshot.
                guard let tail = frame.cropping(to:CGRect(x:0,y:frame.height-offset,width:frame.width,height:offset)),
                      let ctx = CGContext(data:nil,width:frame.width,height:offset,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(tail,in:CGRect(x:0,y:0,width:frame.width,height:offset))
                guard let strip = ctx.makeImage() else { return false }
                parts.append(strip)
                previous = current
            }
            status.stringValue = "自动拼接中 · " + String(parts.reduce(0) { $0 + $1.height }) + " px"
            return true
        } catch {
            if !Task.isCancelled { status.stringValue = "暂未读到画面，正在重试" }
            return false
        }
    }

    @objc func cancel() { onFinish?(nil) }

    @objc func done() {
        guard !finishing else { return }
        finishing = true
        let pending = task
        pending?.cancel()
        task = Task {
            await pending?.value
            guard !Task.isCancelled else { return }
            if !reachedLimit && !mayFinishPartial {
                let matched = await sample()
                guard !Task.isCancelled else { return }
                if !matched {
                    finishing = false
                    mayFinishPartial = true
                    finishButton.title = "完成已拼接部分"
                    start()
                    return
                }
            }
            export()
            finishing = false
        }
    }

    private func export() {
        let width = parts[0].width, height = parts.reduce(0) { $0+$1.height }
        guard let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { status.stringValue = "内存不足，无法合成"; return }
        var y = height
        for part in parts {
            y -= part.height
            ctx.draw(part,in:CGRect(x:0,y:y,width:width,height:part.height))
        }
        guard let result = ctx.makeImage() else { return }
        onFinish?(NSImage(cgImage:result,size:NSSize(width:CGFloat(width)/scale,height:CGFloat(height)/scale)))
    }
}
