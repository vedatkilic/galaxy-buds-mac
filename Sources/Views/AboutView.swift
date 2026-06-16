import SwiftUI

/// "About" / diagnostics page: software version, serial numbers, and the earbud
/// fit (seal) test. Requests the info on appear.
struct AboutView: View {
    @Bindable var bluetooth: BluetoothManager
    let onBack: () -> Void

    @State private var fitTestActive = false

    private var status: BudsStatus { bluetooth.status }
    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }
    private var supportsFitTest: Bool { bluetooth.connectedModel?.supportsAdaptiveANC == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    infoSection
                    if supportsFitTest { fitTestSection }
                }
                .padding(18)
            }
        }
        .frame(width: 440, height: 560)
        .onAppear { bluetooth.requestAboutInfo() }
        .onDisappear { if fitTestActive { bluetooth.setFitTest(active: false) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { if fitTestActive { bluetooth.setFitTest(active: false) }; onBack() }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("About").font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    private var infoSection: some View {
        section("Device") {
            infoRow("Model", value: bluetooth.connectedModel?.rawValue ?? "Galaxy Buds")
            Divider()
            infoRow("Software version", value: status.softwareVersion.isEmpty ? "—" : status.softwareVersion)
            Divider()
            infoRow("Left serial", value: status.serialLeft.isEmpty ? "—" : status.serialLeft)
            Divider()
            infoRow("Right serial", value: status.serialRight.isEmpty ? "—" : status.serialRight)
        }
    }

    private var fitTestSection: some View {
        section("Earbud fit test") {
            VStack(spacing: 14) {
                Text("Put both earbuds in and start the test to check the seal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 24) {
                    fitResult("Left", result: status.fitLeft)
                    fitResult("Right", result: status.fitRight)
                }

                Button(action: toggleFitTest) {
                    Text(fitTestActive ? "Stop" : "Check earbud fit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(fitTestActive ? .red : tint)
            }
            .padding(.vertical, 12)
        }
    }

    private func fitResult(_ label: LocalizedStringKey, result: BudsStatus.FitResult) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon(result))
                .font(.system(size: 26))
                .foregroundStyle(color(result))
            Text(text(result))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color(result))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleFitTest() {
        fitTestActive.toggle()
        bluetooth.setFitTest(active: fitTestActive)
    }

    private func icon(_ r: BudsStatus.FitResult) -> String {
        switch r {
        case .good: "checkmark.circle.fill"
        case .bad: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    private func color(_ r: BudsStatus.FitResult) -> Color {
        switch r {
        case .good: .green
        case .bad: .orange
        case .failed: .red
        case .unknown: .secondary
        }
    }

    private func text(_ r: BudsStatus.FitResult) -> LocalizedStringKey {
        switch r {
        case .good: "Good seal"
        case .bad: "Adjust fit"
        case .failed: "Test failed"
        case .unknown: "—"
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

    private func infoRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 11)
    }
}
