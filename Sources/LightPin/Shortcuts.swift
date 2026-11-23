import AppKit
import Carbon

struct KeyBinding: Codable, Equatable {
    var id: UInt32
    var key: UInt32
    var modifiers: UInt32
    var enabled = true
    static let defaults: [KeyBinding] = [18, 19].enumerated().map {
        KeyBinding(id: UInt32($0.offset + 1), key: UInt32($0.element), modifiers: UInt32(controlKey | optionKey))
    }
    var actionName: String { [1: "控制窗口", 2: "截图"][id] ?? "未知" }
    var label: String {
        var value = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { value += symbol }
        }
        return value + Self.keyNames[key, default: "Key \(key)"]
    }
    static let keyNames: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",36:"Return",51:"Delete",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
    static let functionKeys: Set<UInt32> = [96,97,98,99,100,101,103,109,111,118,120,122]
    static func validationError(_ bindings: [KeyBinding]) -> String? {
        guard bindings.map(\.id).sorted() == [1,2] else { return "快捷键动作配置不完整。" }
        var seen = Set<String>()
        for b in bindings where b.enabled {
            guard keyNames[b.key] != nil, b.modifiers & ~UInt32(controlKey | optionKey | shiftKey | cmdKey) == 0 else { return "不支持的按键。" }
            guard b.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || functionKeys.contains(b.key) else { return "请包含 Control、Option 或 Command，或使用 F1–F12。" }
            guard seen.insert("\(b.key):\(b.modifiers)").inserted else { return "\(b.label) 被设置给了多个动作。" }
        }
        return nil
    }
    static func load(from defaults: UserDefaults = .standard) -> [KeyBinding] {
        let data = defaults.data(forKey: "shortcuts.v3") ?? defaults.data(forKey: "shortcuts.v2")
        guard let data, let decoded = try? JSONDecoder().decode([KeyBinding].self, from: data) else { return Self.defaults }
        return migrated(decoded)
    }
    static func migrated(_ decoded: [KeyBinding]) -> [KeyBinding] {
        let retained = decoded.filter { $0.id == 1 || $0.id == 2 }
        guard validationError(retained) == nil else { return Self.defaults }
        return retained.sorted { $0.id < $1.id }
    }
    static func save(_ value: [KeyBinding], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "shortcuts.v3"); defaults.removeObject(forKey: "shortcuts.v2") }
    }
}

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onPress: ((UInt32) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { keys.onPress?(id.id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func clear() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll() }
    // Caller keeps the saved configuration unchanged until every registration succeeds.
    func install(_ bindings: [KeyBinding]) -> [String] {
        clear()
        var failures: [String] = []
        var symbolic: Unmanaged<CFArray>?
        let systemKeys: [[String: Any]]
        if CopySymbolicHotKeys(&symbolic) == noErr, let array = symbolic?.takeRetainedValue() { systemKeys = (array as? [[String: Any]]) ?? [] }
        else { systemKeys = [] }
        for b in bindings where b.enabled {
            if systemKeys.contains(where: { ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == b.key && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == b.modifiers }) {
                failures.append("\(b.actionName)：\(b.label) 已被 macOS 系统快捷键使用"); continue
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(b.key, b.modifiers, EventHotKeyID(signature: 0x4C50494E, id: b.id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) }
            else { failures.append("\(b.actionName)：\(b.label)（错误 \(result)）") }
        }
        return failures
    }
    deinit { clear(); if let handler { RemoveEventHandler(handler) } }
}

final class KeyRecorder: NSButton {
    var binding: KeyBinding
    var recording = false
    init(binding: KeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        title = binding.label; bezelStyle = .rounded; target = self; action = #selector(begin)
        widthAnchor.constraint(equalToConstant: 185).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc func begin() { window?.makeFirstResponder(self); recording = true; title = "请按快捷键… Esc 取消" }
    override func resignFirstResponder() -> Bool { recording = false; title = binding.label; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording, window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = binding.label; return }
        var modifiers: UInt32 = 0
        for (flag, mask): (NSEvent.ModifierFlags, Int) in [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { modifiers |= UInt32(mask) }
        }
        let key = UInt32(event.keyCode)
        guard KeyBinding.keyNames[key] != nil, modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || KeyBinding.functionKeys.contains(key) else { NSSound.beep(); return }
        binding.key = key; binding.modifiers = modifiers; title = binding.label; recording = false
    }
}

final class ShortcutSettings: NSWindowController, NSWindowDelegate {
    var recorders: [KeyRecorder] = []
    var checks: [NSButton] = []
    let status = NSTextField(wrappingLabelWithString: "点击按键框后输入组合键。设置窗口打开时，全局快捷键暂停。")
    var apply: (([KeyBinding]) -> String?)?
    var onClose: (() -> Void)?
    init(bindings: [KeyBinding]) {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 530, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "快捷键设置"; w.isReleasedWhenClosed = false
        super.init(window: w); w.delegate = self
        let root = SurfaceStack(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24); w.contentView = root
        let heading = NSTextField(labelWithString: "全局快捷键")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        root.addArrangedSubview(NSStackView(views: [icon, heading]))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for binding in bindings {
            let check = NSButton(checkboxWithTitle: binding.actionName, target: nil, action: nil)
            check.state = binding.enabled ? .on : .off
            check.widthAnchor.constraint(equalToConstant: 235).isActive = true
            let recorder = KeyRecorder(binding: binding)
            checks.append(check); recorders.append(recorder)
            root.addArrangedSubview(NSStackView(views: [check, recorder]))
        }
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        let saveButton = button("保存并生效", target: self, action: #selector(save))
        saveButton.bezelColor = .systemTeal
        let footer = NSStackView(views: [button("恢复默认", target: self, action: #selector(reset)), NSView(), saveButton])
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: status.widthAnchor).isActive = true
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func reset() {
        for (i, b) in KeyBinding.defaults.enumerated() { recorders[i].binding = b; recorders[i].title = b.label; recorders[i].recording = false; checks[i].state = .on }
        status.stringValue = "已恢复默认，请点击保存。"
    }
    @objc func save() {
        window?.makeFirstResponder(nil)
        let bindings = recorders.enumerated().map { i, recorder -> KeyBinding in
            var b = recorder.binding; b.enabled = checks[i].state == .on; return b
        }
        if let error = KeyBinding.validationError(bindings) ?? apply?(bindings) { status.stringValue = error; return }
        close() // Re-register the saved bindings immediately via windowWillClose.
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
