import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showPanelNotification = Notification.Name("com.nivorbit.budsapp.showPanel")

    private var statusBarController: StatusBarController?
    private let bluetooth = BluetoothManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy (same bundle id) is already running,
        // hand off to it and quit. Two instances would fight over the one RFCOMM
        // channel to the buds and show duplicate menu-bar icons.
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: me.bundleIdentifier ?? "")
            .filter { $0 != me }
        if let existing = others.first {
            // Tell the already-running copy to surface its panel, then quit.
            existing.activate(options: [])
            DistributedNotificationCenter.default().postNotificationName(
                Self.showPanelNotification, object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        // Let a re-launch (which hands off here and quits) re-open our panel.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showPanelNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusBarController?.showPanel() }
        }
        // An accessory app has no menu bar of its own, so install a minimal main
        // menu purely to wire up the standard ⌘Q quit key equivalent.
        setupMainMenu()
        let controller = StatusBarController(bluetooth: bluetooth)
        statusBarController = controller
        // Pop the panel up when the buds connect while we're running — an
        // AirPods-like appearance.
        bluetooth.onAutoConnected = { [weak controller] in controller?.showPanel() }
        // Prime permission and auto-connect to an already-connected Galaxy Buds.
        bluetooth.startAutoConnect()
        // Defer the launch panel so the status item is laid out first; otherwise
        // it anchors to a not-yet-positioned button and appears detached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.statusBarController?.showPanel()
        }
        startObservingStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusBarController?.showPanel()
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "Quit Galaxy Buds"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func startObservingStatus() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bluetooth.pollAutoConnect()
                self.statusBarController?.updateIcon(
                    connected: self.bluetooth.isConnected,
                    batteryLeft: self.bluetooth.status.batteryLeft,
                    batteryRight: self.bluetooth.status.batteryRight
                )
            }
        }
    }
}
