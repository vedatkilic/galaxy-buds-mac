import SwiftUI

/// Dedicated equalizer page. A preset chooser (Normal/Bass Boost/.../Custom)
/// drives a 9-band vertical-bar graph. Presets show the device-reported curve
/// (read-only); Custom is fully draggable. Custom curves persist across
/// reconnects/restarts via UserDefaults.
struct EqualizerView: View {
    @Bindable var bluetooth: BluetoothManager
    let onBack: () -> Void

    private var status: BudsStatus { bluetooth.status }
    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }

    private let frequencies = ["63", "125", "250", "500", "1k",
                               "2k", "4k", "8k", "16k"]

    /// Whether the user is on the custom preset (bars are draggable).
    private var isCustom: Bool { status.equalizerPreset == .custom }

    /// The 9 band values to display right now: the user's custom curve when
    /// Custom is active, otherwise the device-reported curve for the selected
    /// preset (falling back to flat if the device hasn't reported yet).
    private var displayBands: [Int] {
        if isCustom { return padded(status.customEqualizerBands) }
        let idx = status.equalizerPreset.rawValue
        if idx < status.presetEqualizerCurves.count {
            return padded(status.presetEqualizerCurves[idx])
        }
        return Array(repeating: 0, count: 9)
    }

    /// The graph is a fixed 9-band control, but the device reports its own band
    /// count in CUSTOM_EQUALIZE_RECV. Pad or truncate so indexing a bar is
    /// always safe, whatever the firmware sends.
    private func padded(_ bands: [Int]) -> [Int] {
        (0..<9).map { bands.indices.contains($0) ? bands[$0] : 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    presetSection
                    graphSection
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
            Text("Equalizer").font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    // MARK: - Preset

    private var presetSection: some View {
        section("Preset") {
            row("Mode") {
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
    }

    // MARK: - Graph

    private var graphSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<9, id: \.self) { i in
                    eqBar(for: i)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 230)
            .padding(.horizontal, 4)

            HStack(spacing: 16) {
                if isCustom && displayBands.contains(where: { $0 != 0 }) {
                    Button {
                        bluetooth.setCustomEqualizer(bands: Array(repeating: 0, count: 9))
                    } label: {
                        Text("Reset to flat")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
                if !isCustom {
                    Text("Preset curve (read-only)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// A single vertical bar. The fill height encodes the band gain, clamped to
    /// 0…10 on either side of the centre line. A drag handle sits at the gain
    /// level; dragging it vertically adjusts the value in integer steps. Only
    /// draggable when the Custom preset is active.
    private func eqBar(for index: Int) -> some View {
        let value = displayBands[index]
        let barWidth: CGFloat = 16
        let halfHeight: CGFloat = 95 // distance from centre to top/bottom

        return VStack(spacing: 4) {
            // Value label fixed at the very top — never overlaps the bar fill.
            Text("\(value >= 0 ? "+" : "")\(value)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(value != 0 ? (isCustom ? tint : .secondary) : .secondary)
                .monospacedDigit()
                .frame(height: 12)

            ZStack(alignment: .center) {
                // Track background (full height)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: barWidth, height: halfHeight * 2)

                // Fill from centre to the gain value
                fillShape(value: value, halfHeight: halfHeight)
                    .frame(width: barWidth)

                // Centre line
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: barWidth + 6, height: 1)

                // Drag handle (dimmed for read-only presets)
                Circle()
                    .fill(isCustom ? tint : Color.secondary.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    .offset(y: CGFloat(-value) / 10 * halfHeight)
            }
            .frame(height: halfHeight * 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isCustom else { return }
                        let normalized = (halfHeight - gesture.location.y) / halfHeight
                        let stepped = Int((normalized * 10).rounded())
                        let clamped = max(-10, min(10, stepped))
                        if clamped != status.customEqualizerBands[index] {
                            bluetooth.setCustomEqualizerBand(index, value: clamped)
                        }
                    }
            )

            Text(frequencies[index])
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// The filled portion from the centre line to the current gain. Dimmed for
    /// read-only presets so the custom curve stands out when active.
    @ViewBuilder
    private func fillShape(value: Int, halfHeight: CGFloat) -> some View {
        let height = abs(CGFloat(value)) / 10 * halfHeight
        let opacity = isCustom ? 0.55 : 0.3
        if value >= 0 {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(opacity))
                .frame(height: max(2, height))
                .offset(y: -height / 2)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(opacity))
                .frame(height: max(2, height))
                .offset(y: height / 2)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
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
        _ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
    }
}
