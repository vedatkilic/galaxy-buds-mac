import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let bluetooth = BluetoothManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
