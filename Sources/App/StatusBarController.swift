import AppKit
import SwiftUI

/// Owns the menu-bar status item, the compact quick panel, and the detail
/// window. Clicking the menu-bar icon toggles a borderless panel that drops
/// straight down from the icon (no popover arrow, like the native AirPods
/// menu); the panel's "Settings…" button opens the detail window.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var detailWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private let bluetooth: BluetoothManager

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            applyIcon(to: button)
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func applyIcon(to button: NSStatusBarButton) {
        for name in ["airpodspro", "airpods", "headphones"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Galaxy Buds") {
                image.isTemplate = true
                button.image = image
                return
            }
        }
        button.title = "Buds"
    }

    // MARK: - Quick panel

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(
            rootView: MenuPopoverView(bluetooth: bluetooth) { [weak self] in
                self?.openDetailWindow()
            }
        )
        let panel = NSPanel(
            contentViewController: hosting
        )
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        return panel
    }

    /// Shown on launch / reopen so the user can find the app even if the
    /// menu-bar icon is hard to spot.
    func showPanel() {
        guard panel?.isVisible != true else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFront(nil)
        installOutsideClickMonitor()
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Drops the panel straight down from the status item, flush under the menu
    /// bar and horizontally centred on the icon (clamped to the screen).
    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 360)
        panel.setContentSize(size)

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonRect.midX - size.width / 2
        if let frame = screen?.visibleFrame {
            x = min(max(frame.minX + 8, x), frame.maxX - size.width - 8)
        }
        let y = buttonRect.minY - size.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Detail window

    func openDetailWindow() {
        closePanel()
        if detailWindow == nil {
            let root = PopoverView(bluetooth: bluetooth)
                .frame(width: 440, height: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = []
            let win = NSWindow(contentViewController: hosting)
            win.title = "Galaxy Buds"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.backgroundColor = .windowBackgroundColor
            win.setContentSize(NSSize(width: 440, height: 600))
            win.center()
            detailWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    func updateIcon(connected: Bool, batteryLeft: Int, batteryRight: Int) {
        guard let button = statusItem?.button else { return }
        button.title = connected ? " \(min(batteryLeft, batteryRight))%" : ""
    }

    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
