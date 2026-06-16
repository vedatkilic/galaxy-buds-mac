import Foundation

enum NoiseControlMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case anc = 1
    case ambient = 2
    case adaptive = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .anc: "Noise Cancelling"
        case .ambient: "Ambient Sound"
        case .adaptive: "Adaptive"
        }
    }

    var iconName: String {
        switch self {
        case .off: "speaker.slash"
        case .anc: "ear.badge.waveform"
        case .ambient: "ear"
        case .adaptive: "waveform"
        }
    }

    var shortName: String {
        switch self {
        case .off: "Off"
        case .anc: "ANC"
        case .ambient: "Ambient"
        case .adaptive: "Adaptive"
        }
    }
}
