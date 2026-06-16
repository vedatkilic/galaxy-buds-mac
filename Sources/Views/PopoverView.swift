import SwiftUI

/// Root of the detail window. Shows the connect wizard until a device is
/// connected, then the detailed dashboard. (The menu-bar popover handles the
/// compact quick view separately.)
struct PopoverView: View {
    @Bindable var bluetooth: BluetoothManager

    var body: some View {
        Group {
            if bluetooth.isConnected {
                DashboardView(bluetooth: bluetooth)
            } else {
                WizardView(bluetooth: bluetooth) {}
            }
        }
        .focusEffectDisabled() // no focus ring on auto-focused default buttons
    }
}
