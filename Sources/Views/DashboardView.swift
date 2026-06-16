import SwiftUI

/// The detailed window shown when connected — a Galaxy Wear-style layout: a
/// hero with the earbud illustration, circular battery gauges, a node-based
/// noise-control selector, ANC strength, auto-switch, and a grouped settings
/// list. "Sound & ANC" pushes to a sub-page.
struct DashboardView: View {
    @Bindable var bluetooth: BluetoothManager
    @State private var showSoundAnc = false
    @State private var showEarbudControls = false
    @State private var showFindMyEarbuds = false
    @State private var showAbout = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var status: BudsStatus { bluetooth.status }
    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }
    private var supportsAnc: Bool { bluetooth.connectedModel?.supportsANC == true }

    var body: some View {
        if showSoundAnc {
            SoundAncView(bluetooth: bluetooth) { showSoundAnc = false }
        } else if showEarbudControls {
            EarbudControlsView(bluetooth: bluetooth) { showEarbudControls = false }
        } else if showFindMyEarbuds {
            FindMyEarbudsView(bluetooth: bluetooth) { showFindMyEarbuds = false }
        } else if showAbout {
            AboutView(bluetooth: bluetooth) { showAbout = false }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    settingsList
                }
                .padding(16)
            }
            .frame(width: 440, height: 600)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(tint)

            VStack(spacing: 2) {
                Text(verbatim: bluetooth.connectedName
                     ?? bluetooth.connectedModel?.rawValue ?? "Galaxy Buds")
                    .font(.system(size: 17, weight: .semibold))
                if bluetooth.connectedName != nil {
                    Text(verbatim: bluetooth.connectedModel?.rawValue ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 30) {
                CircularBatteryGauge(level: status.batteryLeft, label: "Left", diameter: 76)
                CircularBatteryGauge(level: status.batteryRight, label: "Right", diameter: 76)
            }

            if bluetooth.connectedModel?.supportsCaseBattery == true, status.batteryCase > 0 {
                Text("Case \(status.batteryCase)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if supportsAnc {
                nodeSelector
                Divider()
                ancStrengthRow
                if bluetooth.connectedModel?.supportsDetectConversations == true {
                    Divider()
                    autoSwitchRow
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var nodeModes: [NoiseControlMode] {
        bluetooth.connectedModel?.supportsAdaptiveANC == true
            ? [.off, .ambient, .adaptive, .anc] : [.off, .ambient, .anc]
    }

    private var nodeSelector: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 2)
                    .padding(.horizontal, 28)
                HStack(spacing: 0) {
                    ForEach(nodeModes) { mode in
                        node(mode).frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(nodeModes) { mode in
                    Text(LocalizedStringKey(mode.shortName))
                        .font(.system(size: 10,
                                      weight: status.noiseControlMode == mode ? .semibold : .regular))
                        .foregroundStyle(status.noiseControlMode == mode ? tint : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 4)
    }

    private func node(_ mode: NoiseControlMode) -> some View {
        let selected = status.noiseControlMode == mode
        return Button(action: { bluetooth.setNoiseControl(mode) }) {
            ZStack {
                Circle()
                    .fill(selected ? tint : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Color.secondary.opacity(selected ? 0 : 0.3), lineWidth: 0.5))
                Image(systemName: mode.iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var ancStrengthRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANC strength").font(.system(size: 13))
            HStack(spacing: 10) {
                Text("Low").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { status.ancLevelHigh ? 1.0 : 0.0 },
                    set: { bluetooth.setAncLevelHigh($0 >= 0.5) }
                ), in: 0...1, step: 1)
                Text("High").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var autoSwitchRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto switch to ambient sound").font(.system(size: 13))
                Text("During conversations")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { status.detectConversations },
                set: { bluetooth.setDetectConversations($0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: - Settings list

    private var settingsList: some View {
        VStack(spacing: 14) {
            if supportsAnc {
                group {
                    navRow(icon: "ear.badge.waveform", title: "Sound & ANC") { showSoundAnc = true }
                    Divider()
                    navRow(icon: "hand.tap", title: "Earbud controls") { showEarbudControls = true }
                }
            }
            group {
                row(icon: "slider.horizontal.3", title: "Equalizer") {
                    Menu {
                        ForEach(EqualizerPreset.allCases) { preset in
                            Button { bluetooth.setEqualizer(preset) } label: {
                                Text(LocalizedStringKey(preset.displayName))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(status.equalizerPreset.displayName))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            group {
                navRow(icon: "bell.badge", title: "Find earbuds") { showFindMyEarbuds = true }
                Divider()
                navRow(icon: "info.circle", title: "About") { showAbout = true }
            }
            group {
                row(icon: "power", title: "Launch at login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { launchAtLogin = $0; LaunchAtLogin.set($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            group {
                Button(action: { bluetooth.disconnect() }) {
                    HStack(spacing: 12) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 17)).foregroundStyle(.red).frame(width: 22)
                        Text("Disconnect").font(.system(size: 14)).foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Building blocks

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func row<Trailing: View>(
        icon: String, title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
            Text(title).font(.system(size: 14))
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
    }

    private func navRow(icon: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(icon: icon, title: title) {
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
