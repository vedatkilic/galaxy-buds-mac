import AppKit

@main
@MainActor
enum Main {
    // Strong reference: NSApplication.delegate is weak, so the delegate
    // must be retained for the lifetime of the process.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // .accessory = menu-bar-only app, no Dock icon (AirPods-like). The popover
        // and detail window are still surfaced via NSApp.activate().
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
