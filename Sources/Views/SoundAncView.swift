import SwiftUI

/// Detailed Sound & ANC settings, presented as a System Settings-style grouped
/// list pushed in from the dashboard. Gated controls only appear for models
/// that support them.
struct SoundAncView: View {
    @Bindable var bluetooth: BluetoothManager
    let onBack: () -> Void

    private var status: BudsStatus { bluetooth.status }
    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    noiseSection
                    ambientSection
                    if bluetooth.connectedModel?.supportsDetectConversations == true {
                        conversationsSection
                    }
                    callsSection
                }
                .padding(18)
            }
        }
        .frame(width: 440, height: 560)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Sound & ANC")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            // Balances the back button so the title stays centered.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    // MARK: - Sections

    private var noiseSection: some View {
        section("Noise cancelling") {
            row("ANC strength") {
                Picker("", selection: Binding(
                    get: { status.ancLevelHigh ? 1 : 0 },
                    set: { bluetooth.setAncLevelHigh($0 == 1) }
                )) {
                    Text("Low").tag(0)
                    Text("High").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            toggleRow("Noise control with one earbud",
                      isOn: status.ncWithOneEarbud) { bluetooth.setNoiseControlWithOneEarbud($0) }
        }
    }

    private var ambientSection: some View {
        section("Ambient sound") {
            row("Ambient volume") {
                volumeSlider(value: status.ambientSoundVolume) { bluetooth.setAmbientVolume($0) }
            }
            Divider()
            toggleRow("Customize ambient sound",
                      isOn: status.ambientCustomEnabled) {
                bluetooth.setCustomAmbient(enabled: $0, left: status.ambientCustomLeft,
                                           right: status.ambientCustomRight, tone: status.ambientTone)
            }
            if status.ambientCustomEnabled {
                Divider()
                row("Left") {
                    volumeSlider(value: status.ambientCustomLeft) {
                        bluetooth.setCustomAmbient(enabled: true, left: $0,
                                                   right: status.ambientCustomRight, tone: status.ambientTone)
                    }
                }
                Divider()
                row("Right") {
                    volumeSlider(value: status.ambientCustomRight) {
                        bluetooth.setCustomAmbient(enabled: true, left: status.ambientCustomLeft,
                                                   right: $0, tone: status.ambientTone)
                    }
                }
                Divider()
                row("Tone") {
                    Picker("", selection: Binding(
                        get: { status.ambientTone },
                        set: { bluetooth.setCustomAmbient(enabled: true, left: status.ambientCustomLeft,
                                                          right: status.ambientCustomRight, tone: $0) }
                    )) {
                        Text("Low").tag(0)
                        Text("Mid").tag(1)
                        Text("High").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var conversationsSection: some View {
        section("Conversations") {
            toggleRow("Detect conversations",
                      isOn: status.detectConversations) { bluetooth.setDetectConversations($0) }
            if status.detectConversations {
                Divider()
                row("Duration") {
                    Picker("", selection: Binding(
                        get: { status.detectConversationsDuration },
                        set: { bluetooth.setDetectConversationsDuration($0) }
                    )) {
                        Text("5s").tag(0)
                        Text("10s").tag(1)
                        Text("15s").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var callsSection: some View {
        section("Calls") {
            toggleRow("Sidetone (own voice)",
                      isOn: status.sidetone) { bluetooth.setSidetone($0) }
            Divider()
            toggleRow("Ambient sound during calls",
                      isOn: status.ambientDuringCalls) { bluetooth.setAmbientDuringCalls($0) }
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    private func row<Trailing: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
    }

    private func toggleRow(
        _ title: LocalizedStringKey,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> some View {
        row(title) {
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// A 3-stop (0...2) volume slider.
    private func volumeSlider(value: Int, action: @escaping (Int) -> Void) -> some View {
        Slider(
            value: Binding(get: { Double(value) }, set: { action(Int($0.rounded())) }),
            in: 0...2, step: 1
        )
        .frame(width: 140)
    }
}
