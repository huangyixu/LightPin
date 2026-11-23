import AppKit

@MainActor
enum WindowClosing {
    static func isShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "w" &&
        event.modifierFlags.intersection([.command,.shift,.option,.control]) == [.command]
    }
    static func close(_ window: NSWindow?) {
        guard let window else { return }
        if let panel = window as? NSSavePanel { panel.cancel(nil); return }
        if window.sheetParent != nil {
            NSApp.endSheet(window,returnCode:NSApplication.ModalResponse.cancel.rawValue); window.orderOut(nil); return
        }
        if NSApp.modalWindow === window {
            NSApp.abortModal(); window.orderOut(nil); return
        }
        window.performClose(nil)
    }
}
