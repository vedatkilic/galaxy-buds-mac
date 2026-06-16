import SwiftUI

/// The compact popover shown from the menu-bar icon — an AirPods-in-Control-
/// Center style quick view. Detailed controls live behind the "Settings…"
/// button, which opens the detail window.
struct MenuPopoverView: View {
    @Bindable var bluetooth: BluetoothManager
    let openDetail: () -> Void

    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }

    var body: some View {
        VStack(spacing: 16) {
            if bluetooth.isConnected {
                connected
            } else {
                disconnected
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .focusEffectDisabled() // no focus ring on the auto-focused default button
    }

    private var connected: some View {
        VStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bluetooth.connectedModel?.rawValue ?? "Galaxy Buds")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 28) {
                CircularBatteryGauge(level: bluetooth.status.batteryLeft, label: "Left", diameter: 76)
                CircularBatteryGauge(level: bluetooth.status.batteryRight, label: "Right", diameter: 76)
            }

            if bluetooth.connectedModel?.supportsANC == true {
                listenMode
                if bluetooth.status.noiseControlMode == .anc {
                    ancStrength
                }
            }

            equalizerRow

            Button(action: openDetail) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Settings…")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private var listenMode: some View {
        let modes: [NoiseControlMode] =
            bluetooth.connectedModel?.supportsAdaptiveANC == true
            ? [.off, .ambient, .adaptive, .anc]
            : [.off, .ambient, .anc]
        return HStack(spacing: 2) {
            ForEach(modes) { mode in
                let selected = bluetooth.status.noiseControlMode == mode
                Button(action: { bluetooth.setNoiseControl(mode) }) {
                    VStack(spacing: 3) {
                        Image(systemName: mode.iconName).font(.system(size: 15))
                        Text(LocalizedStringKey(mode.shortName)).font(.system(size: 9))
                    }
                    .foregroundStyle(selected ? tint : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    private var ancStrength: some View {
        HStack(spacing: 10) {
            Text("ANC strength").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Low").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { bluetooth.status.ancLevelHigh ? 1.0 : 0.0 },
                set: { bluetooth.setAncLevelHigh($0 >= 0.5) }
            ), in: 0...1, step: 1)
            Text("High").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var equalizerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Equalizer").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(EqualizerPreset.allCases) { preset in
                    Button { bluetooth.setEqualizer(preset) } label: {
                        Text(LocalizedStringKey(preset.displayName))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(bluetooth.status.equalizerPreset.displayName))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var disconnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Buds Connected").font(.headline)
            Text("Connect your Galaxy Buds to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: openDetail) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}
