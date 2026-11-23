import AppKit

struct Mark {
    enum Kind: String, CaseIterable { case arrow = "箭头", rectangle = "矩形", ellipse = "圆形", pen = "画笔", text = "文字", redact = "色块覆盖", mosaic = "马赛克" }
    var id = UUID()
    var kind: Kind
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    var rect: CGRect { Geometry.rect(points.first ?? .zero, points.last ?? .zero) }
}

enum Geometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
    static func arrowHead(from a: CGPoint, to b: CGPoint, length: CGFloat) -> [CGPoint] {
        let angle = atan2(b.y-a.y, b.x-a.x)
        return [-CGFloat.pi/6, CGFloat.pi/6].map {
            CGPoint(x: b.x-length*cos(angle+$0), y: b.y-length*sin(angle+$0))
        }
    }
}

struct MarkHistory {
    private(set) var marks: [Mark] = []
    private var undone: [[Mark]] = []
    private var previous: [[Mark]] = []
    var canRedo: Bool { !undone.isEmpty }
    mutating func append(_ mark: Mark) { previous.append(marks); marks.append(mark); undone.removeAll() }
    mutating func replace(_ mark: Mark) {
        guard let i = marks.firstIndex(where: { $0.id == mark.id }) else { append(mark); return }
        let old = marks[i]
        guard old.text != mark.text || old.points != mark.points || old.fontSize != mark.fontSize || old.color != mark.color else { return }
        previous.append(marks); marks[i] = mark; undone.removeAll()
    }
    mutating func remove(id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        previous.append(marks); marks.removeAll { $0.id == id }; undone.removeAll()
    }
    mutating func undo() { if let state = previous.popLast() { undone.append(marks); marks = state } }
    mutating func rebase(from oldFrame: CGRect, imageSize oldSize: CGSize, to newFrame: CGRect, imageSize newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0, newFrame.width > 0, newFrame.height > 0 else { return }
        func transform(_ mark: Mark) -> Mark {
            var result = mark
            result.points = mark.points.map { point in
                CGPoint(x: (oldFrame.minX+point.x*oldFrame.width/oldSize.width-newFrame.minX)*newSize.width/newFrame.width,
                        y: (oldFrame.minY+point.y*oldFrame.height/oldSize.height-newFrame.minY)*newSize.height/newFrame.height)
            }
            return result
        }
        marks = marks.map(transform); undone = undone.map { $0.map(transform) }; previous = previous.map { $0.map(transform) }
    }
    mutating func redo() { if let state = undone.popLast() { previous.append(marks); marks = state } }
}

// Service implementations can be injected without coupling the editor to a vendor.
protocol TranslationProvider {
    var name: String { get }
    func translate(_ text: String, sourceLanguage: String?, targetLanguage: String) async throws -> String
}
struct UnconfiguredTranslationProvider: TranslationProvider {
    let name = "尚未配置"
    func translate(_ text: String, sourceLanguage: String?, targetLanguage: String) async throws -> String {
        throw TranslationError.notConfigured
    }
}
enum TranslationError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "翻译服务尚未接入。当前版本支持本机文字识别，不会向网络发送内容。" }
}

@MainActor
func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "LightPin"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}

@MainActor
func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

@MainActor
func copyImage(_ image: NSImage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// Explicit backing also makes offscreen window snapshots match the visible UI.
final class SurfaceStack: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
