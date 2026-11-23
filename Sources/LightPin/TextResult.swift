import AppKit

final class TextResultController: NSWindowController {
    let textView = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "")
    let provider: any TranslationProvider
    init(text: String, provider: any TranslationProvider) {
        self.provider = provider
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "识别文字"; w.isReleasedWhenClosed = false
        super.init(window: w)
        let root = SurfaceStack(); root.orientation = .vertical; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        w.contentView = root
        let label = NSTextField(wrappingLabelWithString: "文字在本机识别，可编辑后复制。翻译接口已预留，尚未连接在线服务。")
        root.addArrangedSubview(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.string = text; textView.font = .systemFont(ofSize: 16)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = textView
        root.addArrangedSubview(scroll)
        root.addArrangedSubview(NSStackView(views: [button("复制文字", target: self, action: #selector(copyText)), button("翻译（未接入）", target: self, action: #selector(translate))]))
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        root.addArrangedSubview(status)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textView.string, forType: .string) }
    @objc func translate() {
        Task {
            do { textView.string = try await provider.translate(textView.string, sourceLanguage: nil, targetLanguage: "zh-Hans") }
            catch { status.stringValue = error.localizedDescription }
        }
    }
}
