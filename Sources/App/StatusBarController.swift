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

    private static let autosaveName = "GalaxyBudsStatusItem"

    private func setupStatusItem() {
        // Clear any remembered "hidden" state before the item reads it. Earlier
        // builds allowed the item to be removed from the menu bar, and macOS
        // persists that choice — which left the app with no entry point at all,
        // since the status item is the only one it has.
        clearRememberedHiddenState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Deliberately not `.removalAllowed`: a stray ⌘-drag off the menu bar
        // would leave the user with no way back into the app.
        statusItem?.autosaveName = Self.autosaveName
        statusItem?.isVisible = true
        if let button = statusItem?.button {
            applyIcon(to: button)
            button.action = #selector(togglePanel)
            button.target = self
        }
        // On notched Macs the item is sometimes parked at the default far-right
        // slot instead of being given a real position; re-asserting visibility
        // on a later runloop forces a re-layout. Never toggle it off to do so —
        // that value is persisted, so being killed mid-toggle is one more way
        // the icon can disappear for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.statusItem?.isVisible = true
            self?.logStatusItemState()
        }
    }

    /// Removes the persisted visibility flags an earlier `.removalAllowed`
    /// build could leave set to 0. Position autosave lives under separate keys
    /// and is untouched.
    private func clearRememberedHiddenState() {
        let defaults = UserDefaults.standard
        for key in ["NSStatusItem Visible \(Self.autosaveName)",
                    "NSStatusItem VisibleCC \(Self.autosaveName)"]
        where defaults.object(forKey: key) != nil && !defaults.bool(forKey: key) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Records whether the item actually made it into the menu bar. An item
    /// that exists but is never placed leaves the app unreachable, and the
    /// difference is invisible from the outside — so it belongs in the log a
    /// bug report carries.
    private func logStatusItemState() {
        guard let item = statusItem else {
            DiagnosticsLog.shared.log("status item: missing")
            return
        }
        let button = item.button
        DiagnosticsLog.shared.log(
            "status item: visible=\(item.isVisible) "
            + "image=\(button?.image != nil) "
            + "buttonFrame=\(button.map { NSStringFromRect($0.frame) } ?? "nil") "
            + "window=\(button?.window.map { NSStringFromRect($0.frame) } ?? "nil")")
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
        // Movable as a safety net: the panel normally drops straight under the
        // menu-bar icon, but when the icon isn't where it should be the panel
        // has to stay reachable rather than stranded.
        panel.isMovableByWindowBackground = true
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

    /// Positions the panel just under the menu-bar icon, but always clamped to be
    /// fully on-screen — so it's reachable even when the icon is hidden behind
    /// the notch or off the edge of a full menu bar.
    private func positionPanel(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 360)
        panel.setContentSize(size)

        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let anchor = statusItemAnchor() {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
        } else {
            // No usable status button — fall back to top-centre of the screen.
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8)
        }
        origin.x = min(max(frame.minX + 8, origin.x), frame.maxX - size.width - 8)
        origin.y = min(max(frame.minY + 8, origin.y), frame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// The status button's rect on screen, but only when it is genuinely sitting
    /// in a menu bar. An item macOS never placed still hands back a window, at
    /// an origin nowhere near the top of the screen — anchoring to that is what
    /// dropped the panel into a corner where it couldn't be moved.
    private func statusItemAnchor() -> NSRect? {
        guard statusItem?.isVisible == true,
              let button = statusItem?.button,
              let window = button.window
        else { return nil }

        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard rect.width > 0, rect.height > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              // The menu bar is the top ~40pt strip, taller on notched Macs.
              rect.minY >= screen.frame.maxY - 40
        else { return nil }
        return rect
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
        let battery = connected ? "\(min(batteryLeft, batteryRight))%" : ""
        if button.image != nil {
            // The SF Symbol is always visible; show battery beside it when connected.
            button.title = battery.isEmpty ? "" : " \(battery)"
        } else {
            // No symbol available on this OS — keep a text label at all times so the
            // variable-length item never collapses to zero width and vanishes.
            button.title = battery.isEmpty ? "Buds" : "Buds \(battery)"
        }
    }

    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
