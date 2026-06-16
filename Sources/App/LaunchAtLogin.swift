import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for the "Launch at login" toggle. Lets the
/// app register itself as a login item so it's always present in the menu bar
/// (a prerequisite for auto-connecting when the buds connect).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters the app as a login item. Errors are logged rather
    /// than thrown — registration can fail for an unsigned/ad-hoc build run
    /// outside /Applications.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
