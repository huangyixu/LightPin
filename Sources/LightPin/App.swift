import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var closingEventMonitor: Any?
    var home: NSWindowController?
    var keys: HotKeys?
    var hiddenWindows: [NSWindow] = []
    var historyStack: NSStackView?
    var bindings = KeyBinding.load()
    var settings: ShortcutSettings?
    var captureSession: CaptureSession?
    var capturePermission = CapturePermissionState()
    private let loginSwitch = NSSwitch()
    private lazy var approvalButton = button("前往系统设置批准…", target: self, action: #selector(openLoginSettings))
    private var changingLoginItem = false
    var captureButton: NSButton?
    var shortcutHint: NSTextField?
    let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LightPin/Captures", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeMenu()
        installWindowClosing()
        installStatusItem()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenFromAnotherCopy(_:)), name: Notification.Name("local.lightpin.showHome"), object: nil)
        let keys = HotKeys(); self.keys = keys
        keys.onPress = { [weak self] id in
            guard let self else { return }
            guard self.captureSession == nil else { return }
            switch id { case 1: self.showHome(); case 2: self.capture(); default: break }
        }
        let shortcutFailures = keys.install(bindings)
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let backgroundLaunch = loginLaunch || SMAppService.mainApp.status == .enabled
        if !backgroundLaunch { showHome() }
        if !backgroundLaunch && !shortcutFailures.isEmpty { showError("以下快捷键被其他应用占用：\(shortcutFailures.joined(separator: "、"))。请在“快捷键设置”中修改；目前仍可使用控制窗口中的按钮。") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showHome(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let closingEventMonitor { NSEvent.removeMonitor(closingEventMonitor) }
        captureSession?.finish(nil)
    }
    @objc func reopenFromAnotherCopy(_ notification: Notification) {
        guard captureSession == nil else { return }
        showHome()
    }
    func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "LightPin 截图")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "LP" }
            button.toolTip = "LightPin：点击打开控制窗口，右键打开快捷菜单"
            button.target = self; button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let item = statusItem else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, action) in [("打开控制窗口", #selector(showHome)), ("快捷键设置…", #selector(showSettings)), ("截图", #selector(capture))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self; menu.addItem(entry)
            }
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 LightPin", action: #selector(quit), keyEquivalent: "")
            quit.target = self; menu.addItem(quit)
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else if captureSession == nil { showHome() }
    }
    func installWindowClosing() {
        guard closingEventMonitor == nil else { return }
        closingEventMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
            guard WindowClosing.isShortcut(event) else { return event }
            // Runs before text fields and the shortcut recorder can consume Command-W.
            WindowClosing.close(NSApp.keyWindow)
            return nil
        }
    }
    @objc func closeActiveWindow() { WindowClosing.close(NSApp.keyWindow) }
    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 LightPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fileItem = NSMenuItem(title:"文件",action:nil,keyEquivalent:"")
        let fileMenu = NSMenu(title:"文件")
        let closeItem = NSMenuItem(title:"关闭窗口",action:#selector(closeActiveWindow),keyEquivalent:"w")
        closeItem.target = self; fileMenu.addItem(closeItem); fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }
    @objc func showHome() {
        if home == nil { buildHome() }
        refreshLoginItem()
        refreshHistory()
        NSApp.activate(ignoringOtherApps: true)
        home?.showWindow(nil); home?.window?.makeKeyAndOrderFront(nil)
    }
    func buildHome() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 590), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "LightPin"; w.isReleasedWhenClosed = false
        let root = SurfaceStack(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        w.contentView = root
        let title = NSTextField(labelWithString: "LightPin")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let quitButton = button("退出应用 ⌘Q", target: self, action: #selector(quit))
        quitButton.keyEquivalent = "q"; quitButton.keyEquivalentModifierMask = [.command]
        quitButton.toolTip = "完全退出 LightPin，释放全局快捷键"
        quitButton.identifier = NSUserInterfaceItemIdentifier("quitApplication")
        let spacer = NSView()
        let brand = NSImageView(image: NSApp.applicationIconImage)
        brand.widthAnchor.constraint(equalToConstant: 60).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let heading = NSStackView(views: [brand, title, spacer, quitButton])
        root.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        let captureB = button("截图", target: self, action: #selector(capture))
        captureButton = captureB
        captureB.bezelColor = .systemTeal
        let open = button("打开图片…", target: self, action: #selector(openImage))
        let actions = NSStackView(views: [captureB, open])
        root.addArrangedSubview(actions)
        let hint = NSTextField(labelWithString: "")
        hint.textColor = .secondaryLabelColor
        shortcutHint = hint
        let shortcuts = NSStackView(views: [hint, NSView(), button("快捷键设置…", target: self, action: #selector(showSettings))])
        root.addArrangedSubview(shortcuts)
        shortcuts.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        updateShortcutLabels()
        loginSwitch.target = self
        loginSwitch.action = #selector(changeLoginItem)
        loginSwitch.setAccessibilityLabel("登录时启动 LightPin")
        let loginRow = NSStackView(views: [NSTextField(labelWithString: "登录时启动 LightPin"), NSView(), approvalButton, loginSwitch])
        root.addArrangedSubview(loginRow)
        loginRow.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        refreshLoginItem()
        let section = NSTextField(labelWithString: "最近截图")
        section.font = .systemFont(ofSize: 17, weight: .semibold)
        let historyHeader = NSStackView(views: [section, NSView(), button("打开文件夹", target: self, action: #selector(revealHistory))])
        root.addArrangedSubview(historyHeader)
        historyHeader.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        let history = NSStackView(); history.orientation = .vertical; history.alignment = .leading; history.spacing = 8
        history.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        history.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = history; historyStack = history
        history.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        root.addArrangedSubview(NSStackView(views: [button("屏幕录制设置", target: self, action: #selector(openPermissions)), button("权限问题修复…", target: self, action: #selector(showPermissionHelp))]))
        w.center(); home = NSWindowController(window: w)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if home != nil { refreshLoginItem() }
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        approvalButton.isHidden = status != .requiresApproval
        loginSwitch.state = status == .enabled ? .on : .off
        loginSwitch.isEnabled = !changingLoginItem && status != .requiresApproval
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func changeLoginItem() {
        guard !changingLoginItem else { return }
        let enable = loginSwitch.state == .on
        changingLoginItem = true
        loginSwitch.isEnabled = false
        Task {
            defer {
                changingLoginItem = false
                refreshLoginItem()
            }
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                if SMAppService.mainApp.status != .requiresApproval {
                    showError("无法更改登录启动设置。\n\(error.localizedDescription)")
                }
            }
        }
    }

    func shortcutLabel(_ id: UInt32) -> String {
        guard let b = bindings.first(where: { $0.id == id }), b.enabled else { return "未启用" }; return b.label
    }
    func updateShortcutLabels() {
        captureButton?.title = "截图  " + shortcutLabel(2)
        shortcutHint?.stringValue = "控制窗口：" + shortcutLabel(1)
    }
    @objc func showSettings() {
        guard captureSession == nil else { return }
        if let settings, settings.window?.isVisible == true { NSApp.activate(ignoringOtherApps: true); settings.window?.makeKeyAndOrderFront(nil); return }
        keys?.clear()
        let controller = ShortcutSettings(bindings: bindings)
        controller.apply = { [weak self] value in
            guard let self else { return "应用已退出。" }
            let failures = self.keys?.install(value) ?? []
            self.keys?.clear() // Continue recording safely until the settings window closes.
            guard failures.isEmpty else { return "注册失败，原配置未更改：\n" + failures.joined(separator: "；") }
            self.bindings = value; KeyBinding.save(value); self.updateShortcutLabels(); return nil
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            let failures = self.keys?.install(self.bindings) ?? []
            if !failures.isEmpty { showError("快捷键注册失败：" + failures.joined(separator: "；")) }
        }
        settings = controller; NSApp.activate(ignoringOtherApps: true); controller.showWindow(nil)
    }
    func prepareSession() -> CaptureSession {
        let previousApp = NSWorkspace.shared.frontmostApplication
        hiddenWindows = NSApp.windows.filter { $0.isVisible }; hiddenWindows.forEach { $0.orderOut(nil) }
        let session = CaptureSession(); captureSession = session
        session.onFinish = { [weak self] image, action in
            guard let self else { return }
            self.captureSession = nil
            self.hiddenWindows.forEach { $0.orderFront(nil) }; self.hiddenWindows.removeAll()
            if let image {
                self.storeCapture(image)
                if action == .copy { copyImage(image) }
            }
            previousApp?.activate(options: [])
        }
        return session
    }
    @objc func capture() {
        guard captureSession == nil else { return }
        if capturePermission.requiresUserRecovery { showPermissionHelp(); return }
        // ScreenCaptureKit is the authority. A stale CoreGraphics preflight must
        // not prevent a valid ScreenCaptureKit grant from being used.
        let session = prepareSession()
        Task {
            do { try await Task.sleep(nanoseconds: 60_000_000); try await session.start() }
            catch {
                session.finish(nil); self.showHome()
                self.capturePermission.record(error)
                if self.capturePermission.requiresUserRecovery { self.showPermissionHelp() }
                else { showError("截图失败：\(error.localizedDescription)") }
            }
        }
    }
    func storeCapture(_ image: NSImage) {
        do {
            try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
            guard let data = image.pngData else { throw CocoaError(.fileWriteUnknown) }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let file = formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6) + ".png"
            try data.write(to: historyURL.appendingPathComponent(file), options: .atomic)
            refreshHistory()
        } catch { showError("截图可继续编辑，但历史保存失败：\(error.localizedDescription)") }
    }
    func edit(_ image: NSImage) {
        guard captureSession == nil else { return }
        let session = prepareSession()
        do { try session.startImage(image) }
        catch { session.finish(nil); showError(error.localizedDescription) }
    }
    @objc func openImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) { edit(image) }
    }
    func refreshHistory() {
        guard let stack = historyStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let files = ((try? FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(30)
        if files.isEmpty { stack.addArrangedSubview(NSTextField(labelWithString: "还没有截图，点击截图按钮或使用已配置的快捷键。")) }
        for url in files {
            let b = button(url.deletingPathExtension().lastPathComponent, target: self, action: #selector(openHistory(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(url.lastPathComponent)
            stack.addArrangedSubview(b)
        }
    }
    @objc func openHistory(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let image = NSImage(contentsOf: historyURL.appendingPathComponent(name)) else { return }
        edit(image)
    }
    @objc func revealHistory() {
        do { try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true); NSWorkspace.shared.open(historyURL) }
        catch { showError(error.localizedDescription) }
    }
    @objc func showPermissionHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "已打开权限，但仍无法截图？"
        alert.informativeText = "系统可能仍保留旧版本的授权。请先退出旧副本，将当前应用放到固定位置，再在屏幕录制设置中删除旧的 LightPin 条目，重新添加并开启当前应用，最后退出重开。\n\n当前运行位置：\n" + Bundle.main.bundleURL.path + "\n\n若仍无效，可选择重置，仅清除此应用的屏幕录制授权。处理后点击‘重新尝试’才会再次调用截图接口。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "已处理，重新尝试")
        alert.addButton(withTitle: "重置此应用授权…")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openPermissions()
        case .alertSecondButtonReturn: capturePermission.retryRequested(); capture()
        case .alertThirdButtonReturn: confirmPermissionReset()
        default: break
        }
    }
    func confirmPermissionReset() {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "重置 LightPin 的屏幕录制授权并退出？"
        alert.informativeText = "只清除 local.lightpin.app 的屏幕录制授权，不影响其他应用。重置后请重新打开当前应用，按截图快捷键，并在系统设置中重新允许。系统要求时，再退出并重开一次。"
        alert.addButton(withTitle: "重置并退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", "local.lightpin.app"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                if process.terminationStatus == 0 { NSApp.terminate(nil) }
                else { showError("系统未能重置授权。请在屏幕录制设置中删除 LightPin 条目，再重新添加当前应用。") }
            }
        }
        do { try process.run() } catch { showError(error.localizedDescription) }
    }
    @objc func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}
