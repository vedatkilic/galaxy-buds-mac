import SwiftUI

struct WizardView: View {
    @Bindable var bluetooth: BluetoothManager
    let onComplete: () -> Void

    @State private var step: WizardStep = .welcome
    @State private var selectedModel: BudsModel = .buds4Pro
    @State private var selectedDevice: BluetoothManager.DiscoveredDevice?

    enum WizardStep: Int, CaseIterable {
        case welcome
        case selectModel
        case scanning
        case connecting
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator

            Divider()

            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .selectModel:
                    selectModelStep
                case .scanning:
                    scanningStep
                case .connecting:
                    connectingStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440, height: 560)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(WizardStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "airpodspro")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            Text("Welcome to BudsApp")
                .font(.title.bold())

            Text("Connect your Samsung Galaxy Buds\nfor battery info, ANC controls, and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)

            Spacer()

            Button(action: { step = .selectModel }) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Select Model

    /// The flagship/newest models shown as featured cards; everything else
    /// lives in the dropdown below (newest first).
    private var featuredModels: [BudsModel] {
        [.buds4Pro, .buds4, .buds3Pro, .buds3]
    }

    private var olderModels: [BudsModel] {
        BudsModel.allCases.reversed().filter { !featuredModels.contains($0) }
    }

    private var selectModelStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Select Your Model")
                    .font(.title2.bold())
                Text("Pick your Galaxy Buds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 22)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                ForEach(featuredModels) { model in
                    modelCard(model)
                }
            }
            .padding(.horizontal, 24)

            // Native dropdown for the remaining models — keeps the picker
            // compact instead of a long scroll. A Menu (not Picker) lets us show
            // a placeholder when the current selection is a featured model.
            HStack(spacing: 8) {
                Text("Other models")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(olderModels) { model in
                        Button(model.rawValue) { selectedModel = model }
                    }
                } label: {
                    // Separate branches so the placeholder localizes (a String
                    // in a ternary uses Text's non-localizing initializer) while
                    // the model name stays verbatim.
                    Group {
                        if olderModels.contains(selectedModel) {
                            Text(verbatim: selectedModel.rawValue)
                        } else {
                            Text("Choose a model…")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(olderModels.contains(selectedModel)
                                     ? .primary : .secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 190)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Text("Selected: \(selectedModel.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: {
                    step = .scanning
                    bluetooth.startScanning()
                }) {
                    Text("Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private func modelCard(_ model: BudsModel) -> some View {
        let isSelected = selectedModel == model
        return Button(action: { selectedModel = model }) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(model.tint.opacity(isSelected ? 0.24 : 0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: model.iconName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(model.tint)
                }

                Text(model.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(model.releaseYear)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let badge = model.capabilityBadge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(model.tint.opacity(0.18))
                            )
                            .foregroundStyle(model.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? model.tint.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? model.tint : Color.secondary.opacity(0.18),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scanning

    private var scanningStep: some View {
        VStack(spacing: 16) {
            Text("Looking for Galaxy Buds...")
                .font(.title2.bold())
                .padding(.top, 20)

            if bluetooth.isScanning {
                ProgressView()
                    .controlSize(.large)
                    .padding()
            }

            if let error = bluetooth.connectionError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }

            if bluetooth.discoveredDevices.isEmpty && !bluetooth.isScanning
                && bluetooth.connectionError == nil {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No devices found")
                        .foregroundStyle(.secondary)
                    Text("Make sure your buds are in pairing mode\nor already paired with this Mac.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(bluetooth.discoveredDevices) { device in
                        deviceRow(device)
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: bluetooth.discoveredDevices.count) { _, _ in
                // Auto-select the model inferred from the first discovered
                // device so the picker reflects the actual connected buds.
                if let first = bluetooth.discoveredDevices.first,
                   let detected = BudsModel.detect(from: first.name) {
                    selectedModel = detected
                }
            }

            Spacer()

            HStack {
                Button("Rescan") {
                    bluetooth.startScanning()
                }
                .controlSize(.large)

                Spacer()

                Button("Back") {
                    bluetooth.stopScanning()
                    step = .selectModel
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private func deviceRow(_ device: BluetoothManager.DiscoveredDevice) -> some View {
        // Prefer the model inferred from the device's own advertised name; only
        // fall back to the manual picker when the name isn't recognizable.
        let model = BudsModel.detect(from: device.name) ?? selectedModel
        return Button(action: {
            selectedModel = model
            selectedDevice = device
            step = .connecting
            bluetooth.connect(to: device, model: model)
        }) {
            HStack {
                ZStack {
                    Circle()
                        .fill(model.tint.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: model.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(model.tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body.bold())
                    Text(model.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connecting

    private var connectingStep: some View {
        VStack(spacing: 20) {
            Spacer()

            if bluetooth.isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.multicolor)

                Text("Connected!")
                    .font(.title.bold())

                Text("Your \(selectedModel.rawValue) is ready.")
                    .foregroundStyle(.secondary)

                Button(action: onComplete) {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
            } else if let error = bluetooth.connectionError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)

                Text("Connection Failed")
                    .font(.title.bold())

                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    step = .scanning
                    bluetooth.startScanning()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .controlSize(.large)

                Text("Connecting to \(selectedDevice?.name ?? "device")...")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
