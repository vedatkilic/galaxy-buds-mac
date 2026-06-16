import SwiftUI

/// "Find My Earbuds" detail page: rings both earbuds and lets you silence one
/// side while searching for the other.
struct FindMyEarbudsView: View {
    @Bindable var bluetooth: BluetoothManager
    let onBack: () -> Void

    @State private var isRinging = false
    @State private var muteLeft = false
    @State private var muteRight = false

    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 22) {
                    ringControl
                    if isRinging { muteSection }
                }
                .padding(18)
            }
        }
        .frame(width: 440, height: 560)
        .onDisappear { stopRinging() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { stopRinging(); onBack() }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Find earbuds").font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    private var ringControl: some View {
        VStack(spacing: 18) {
            Image(systemName: isRinging ? "speaker.wave.3.fill" : "speaker.wave.2")
                .font(.system(size: 56))
                .foregroundStyle(isRinging ? tint : .secondary)
                .symbolEffect(.variableColor, isActive: isRinging)
                .padding(.top, 16)

            Text(isRinging
                 ? "Playing a sound on your earbuds."
                 : "Ring your earbuds to locate them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: toggleRinging) {
                Text(isRinging ? "Stop" : "Play sound")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isRinging ? .red : tint)
            .padding(.horizontal, 40)
        }
    }

    private var muteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mute").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) {
                muteRow("Left", isOn: $muteLeft)
                Divider()
                muteRow("Right", isOn: $muteRight)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func muteRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { isOn.wrappedValue = $0; bluetooth.setMuteEarbud(left: muteLeft, right: muteRight) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 10)
    }

    private func toggleRinging() {
        if isRinging {
            isRinging = false
            bluetooth.findMyBuds(start: false)
        } else {
            muteLeft = false
            muteRight = false
            isRinging = true
            bluetooth.findMyBuds(start: true)
        }
    }

    /// Used by Back / onDisappear to ensure the tone stops when leaving.
    private func stopRinging() {
        guard isRinging else { return }
        isRinging = false
        bluetooth.findMyBuds(start: false)
    }
}
