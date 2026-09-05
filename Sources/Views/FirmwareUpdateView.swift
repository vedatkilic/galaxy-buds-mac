import SwiftUI

/// Firmware update page: checks the community archive for a newer build,
/// downloads it, and hands it to `FirmwareUpdater` to flash.
///
/// Flashing is the one irreversible thing this app can do to the hardware, so
/// the page only ever offers a strictly newer build, refuses to start on low
/// battery, and states plainly what must not happen during the transfer.
struct FirmwareUpdateView: View {
    @Bindable var bluetooth: BluetoothManager
    let onBack: () -> Void

    /// Samsung's own updater refuses below half charge, and a bud that dies
    /// mid-flash is the way these get bricked.
    private static let minimumBattery = 50

    private enum Check: Equatable {
        case idle
        case checking
        case upToDate
        case available(FirmwareRelease)
        case failed(String)

        static func == (lhs: Check, rhs: Check) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate): true
            case let (.available(a), .available(b)): a.buildName == b.buildName
            case let (.failed(a), .failed(b)): a == b
            default: false
            }
        }
    }

    @State private var check: Check = .idle
    @State private var isDownloading = false
    @State private var confirming: FirmwareRelease?

    private var status: BudsStatus { bluetooth.status }
    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }
    private var updater: FirmwareUpdater { bluetooth.firmware }

    private var batteryTooLow: Bool {
        min(status.batteryLeft, status.batteryRight) < Self.minimumBattery
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    installedSection
                    if updater.isRunning || isTerminal {
                        transferSection
                    } else {
                        availableSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 440, height: 560)
        .confirmationDialog(
            "Install this firmware?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Install firmware", role: .destructive) {
                if let release = confirming { install(release) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Keep both earbuds in the case with the lid open, keep your Mac nearby, and don't quit the app. Interrupting a firmware update can leave the earbuds unusable.")
        }
    }

    private var isTerminal: Bool {
        updater.phase == .finished || isFailed
    }

    private var isFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
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
            .disabled(updater.isRunning)
            Spacer()
            Text("Firmware").font(.system(size: 15, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(14)
    }

    // MARK: - Installed

    private var installedSection: some View {
        section("Installed") {
            infoRow("Current version", value: status.softwareVersion.isEmpty ? "—" : status.softwareVersion)
        }
    }

    // MARK: - Available

    @ViewBuilder
    private var availableSection: some View {
        section("Update") {
            VStack(spacing: 14) {
                switch check {
                case .idle:
                    Text("Firmware comes from a community archive of Samsung's official builds, not from Samsung directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    checkButton

                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking for updates…").font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .upToDate:
                    resultRow(
                        icon: "checkmark.circle.fill", color: .green,
                        text: Text("Your earbuds are up to date."))
                    checkButton

                case .available(let release):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(release.buildName)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        if !release.releaseDescription.isEmpty {
                            Text(release.releaseDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if batteryTooLow {
                        resultRow(
                            icon: "exclamationmark.triangle.fill", color: .orange,
                            text: Text("Charge both earbuds before updating — each needs at least half its battery."))
                    }

                    Button {
                        confirming = release
                    } label: {
                        HStack(spacing: 6) {
                            if isDownloading { ProgressView().controlSize(.small) }
                            Text(isDownloading ? "Downloading…" : "Install update")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(tint)
                    .disabled(batteryTooLow || isDownloading || !bluetooth.isConnected)

                case .failed(let message):
                    resultRow(icon: "exclamationmark.triangle.fill", color: .red, text: Text(message))
                    checkButton
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var checkButton: some View {
        Button("Check for updates") { Task { await runCheck() } }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!bluetooth.isConnected || status.softwareVersion.isEmpty)
    }

    // MARK: - Transfer

    @ViewBuilder
    private var transferSection: some View {
        section("Update") {
            VStack(spacing: 14) {
                switch updater.phase {
                case .preparing:
                    progressRow(label: "Preparing…", value: nil)
                case .sending(let fraction):
                    progressRow(label: "Sending firmware…", value: fraction)
                case .installing(let percent):
                    progressRow(label: "Installing…", value: Double(percent) / 100)
                case .finished:
                    resultRow(
                        icon: "checkmark.circle.fill", color: .green,
                        text: Text("Firmware sent. The earbuds are installing it and will reconnect on their own."))
                    doneButton
                case .failed(let message):
                    resultRow(icon: "exclamationmark.triangle.fill", color: .red, text: Text(message))
                    doneButton
                case .idle:
                    EmptyView()
                }

                if updater.isRunning {
                    Text("Don't quit the app or move the earbuds away from your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var doneButton: some View {
        Button("Done") {
            updater.reset()
            check = .idle
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private func progressRow(label: LocalizedStringKey, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13))
            if let value {
                ProgressView(value: value).tint(tint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Takes a `Text` so callers can pass either a localized literal or an
    /// already-localized runtime message (an error from the catalog or updater).
    private func resultRow(icon: String, color: Color, text: Text) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            text.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func runCheck() async {
        guard let model = bluetooth.connectedModel else { return }
        check = .checking
        do {
            let releases = try await FirmwareCatalog().releases(for: model)
            let current = status.softwareVersion
            let newest = releases.first { FirmwareVersion.isNewer($0.buildName, than: current) }
            check = newest.map(Check.available) ?? .upToDate
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    private func install(_ release: FirmwareRelease) {
        isDownloading = true
        Task {
            defer { isDownloading = false }
            do {
                let data = try await FirmwareCatalog().download(release)
                let binary = try FirmwareBinary(data: data, buildName: release.buildName)
                guard bluetooth.isConnected else {
                    check = .failed(String(localized: "The earbuds disconnected."))
                    return
                }
                updater.start(binary: binary, channelMtu: bluetooth.channelMtu)
            } catch {
                check = .failed(error.localizedDescription)
            }
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
