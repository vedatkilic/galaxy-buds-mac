import AppKit
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
            } else if bluetooth.handedOffToPhone {
                handedOff
            } else {
                disconnected
            }
            footer
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
                    Text(verbatim: bluetooth.connectedName
                         ?? bluetooth.connectedModel?.rawValue ?? "Galaxy Buds")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            batteries

            if bluetooth.connectedModel?.supportsANC == true {
                listenMode
                ancStrength
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

    /// Per-earbud charge plus the case, each on its own dial. The case reports
    /// only while the buds are sitting in it, so it shows "—" the rest of the
    /// time rather than a misleading 0%.
    private var batteries: some View {
        let status = bluetooth.status
        let showCase = bluetooth.connectedModel?.supportsCaseBattery == true
        return HStack(spacing: showCase ? 12 : 28) {
            CircularBatteryGauge(
                level: status.batteryLeft, label: "Left",
                present: status.batteryLeft > 0, charging: status.isLeftCharging,
                diameter: showCase ? 66 : 76)
            CircularBatteryGauge(
                level: status.batteryRight, label: "Right",
                present: status.batteryRight > 0, charging: status.isRightCharging,
                diameter: showCase ? 66 : 76)
            if showCase {
                CircularBatteryGauge(
                    level: status.batteryCase, label: "Case",
                    present: status.batteryCase > 0, diameter: 66)
            }
        }
    }

    private var listenMode: some View {
        ListenModePicker(
            modes: bluetooth.connectedModel?.listenModes ?? [],
            selection: bluetooth.status.noiseControlMode,
            tint: tint
        ) { bluetooth.setNoiseControl($0) }
    }

    /// Strength only means anything while ANC is the active mode — adaptive
    /// picks its own. Dimmed rather than hidden so switching modes doesn't
    /// resize the panel under the pointer.
    private var ancStrength: some View {
        let active = bluetooth.status.noiseControlMode == .anc
        return HStack(spacing: 10) {
            Text("ANC strength").font(.system(size: 11)).foregroundStyle(.secondary)
            AncStrengthStepper(
                level: bluetooth.status.ancLevel,
                count: bluetooth.connectedModel?.ancLevelCount ?? 2,
                tint: tint
            ) { bluetooth.setAncLevel($0) }
        }
        .disabled(!active)
        .opacity(active ? 1 : 0.4)
    }

    private var equalizerRow: some View {
        // Models with the full custom EQ UI expose the .custom preset here; older
        // models only see the fixed presets (Normal/Bass Boost/…/Treble Boost).
        let supportsCustom = bluetooth.connectedModel?.supportsCustomEqualizer == true
        let presets: [EqualizerPreset] = supportsCustom
            ? EqualizerPreset.allCases
            : EqualizerPreset.allCases.filter { $0 != .custom }
        return HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Equalizer").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(presets) { preset in
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

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 10) {
                if bluetooth.isConnected && !bluetooth.handedOffToPhone {
                    Button {
                        bluetooth.handOffToPhone()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "iphone").font(.system(size: 13))
                            Text("To phone").font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Send audio to phone")
                }

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "power").font(.system(size: 13))
                        Text("Quit").font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Shown while the buds are intentionally handed off to the phone: audio
    /// + control are both down, and auto-reconnect is suppressed.
    private var handedOff: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 36))
                .foregroundStyle(tint)
            VStack(spacing: 3) {
                Text(verbatim: bluetooth.connectedName
                     ?? bluetooth.connectedModel?.rawValue ?? "Galaxy Buds")
                    .font(.system(size: 15, weight: .semibold))
                Text("Audio on phone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                bluetooth.reclaimFromPhone()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                    Text("Connect on Mac")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 10)
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
