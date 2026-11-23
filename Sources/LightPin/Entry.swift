import AppKit
@main
struct LightPinEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.accessory)
            do { try runSmokeCheck(directory: CommandLine.arguments[index + 1]) }
            catch { fputs("Smoke check failed: \(error)\n", stderr); exit(1) }
            return
        }
        // Finder may launch an older unpacked copy. Keep only one active instance.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.lightpin.app")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.lightpin.showHome"), object: nil, userInfo: nil, deliverImmediately: true)
            running.activate(options: [])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
