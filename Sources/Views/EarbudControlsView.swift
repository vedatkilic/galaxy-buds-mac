import SwiftUI

/// "Earbud controls" detail page: touch-and-hold action per side, the noise-
/// control cycle subset when that action is Noise control, and the touchpad
/// lock. Single/double/triple tap are fixed by the firmware, so they're not
/// shown as reassignable.
struct EarbudControlsView: View {
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
                    holdSection
                    lockSection
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
            Text("Earbud controls").font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    private var holdSection: some View {
        section("Touch and hold") {
            holdRow("Left", action: status.touchHoldLeft) {
                bluetooth.setTouchHoldActions(left: $0, right: status.touchHoldRight)
            }
            if status.touchHoldLeft == .noiseControl {
                Divider()
                cycleRow("Left cycle", cycle: status.noiseCycleLeft) {
                    bluetooth.setNoiseControlCycle(left: $0, right: status.noiseCycleRight)
                }
            }
            Divider()
            holdRow("Right", action: status.touchHoldRight) {
                bluetooth.setTouchHoldActions(left: status.touchHoldLeft, right: $0)
            }
            if status.touchHoldRight == .noiseControl {
                Divider()
                cycleRow("Right cycle", cycle: status.noiseCycleRight) {
                    bluetooth.setNoiseControlCycle(left: status.noiseCycleLeft, right: $0)
                }
            }
        }
    }

    private var lockSection: some View {
        section("Touchpad") {
            row("Touchpad lock") {
                Toggle("", isOn: Binding(
                    get: { status.touchpadLocked },
                    set: { bluetooth.setTouchpadLock($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func holdRow(
        _ title: LocalizedStringKey, action: TouchHoldAction,
        set: @escaping (TouchHoldAction) -> Void
    ) -> some View {
        row(title) {
            Menu {
                ForEach(TouchHoldAction.allCases) { option in
                    Button { set(option) } label: { Text(LocalizedStringKey(option.displayName)) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(action.displayName))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func cycleRow(
        _ title: LocalizedStringKey, cycle: NoiseControlCycle,
        set: @escaping (NoiseControlCycle) -> Void
    ) -> some View {
        row(title) {
            Menu {
                ForEach(NoiseControlCycle.allCases) { option in
                    Button { set(option) } label: { Text(LocalizedStringKey(option.displayName)) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(cycle.displayName))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
