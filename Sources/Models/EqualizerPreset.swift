import Foundation

enum EqualizerPreset: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case bassBoost = 1
    case soft = 2
    case dynamic = 3
    case clear = 4
    case trebleBoost = 5

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: "Normal"
        case .bassBoost: "Bass Boost"
        case .soft: "Soft"
        case .dynamic: "Dynamic"
        case .clear: "Clear"
        case .trebleBoost: "Treble Boost"
        }
    }

    var iconName: String {
        switch self {
        case .off: "slider.horizontal.3"
        case .bassBoost: "speaker.wave.3"
        case .soft: "cloud"
        case .dynamic: "bolt"
        case .clear: "sparkles"
        case .trebleBoost: "speaker.wave.1"
        }
    }
}
