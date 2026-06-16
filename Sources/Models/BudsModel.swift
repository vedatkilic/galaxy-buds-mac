import Foundation

enum BudsModel: String, CaseIterable, Identifiable, Sendable {
    case buds = "Galaxy Buds"
    case budsPlus = "Galaxy Buds+"
    case budsLive = "Galaxy Buds Live"
    case budsPro = "Galaxy Buds Pro"
    case buds2 = "Galaxy Buds2"
    case buds2Pro = "Galaxy Buds2 Pro"
    case budsFe = "Galaxy Buds FE"
    case budsCore = "Galaxy Buds Core"
    case buds3 = "Galaxy Buds3"
    case buds3Pro = "Galaxy Buds3 Pro"
    case buds3Fe = "Galaxy Buds3 FE"
    case buds4 = "Galaxy Buds4"
    case buds4Pro = "Galaxy Buds4 Pro"

    var id: String { rawValue }

    /// Best-effort model inference from the Bluetooth advertised name (e.g.
    /// "Galaxy Buds4 Pro (1A2B)"). More specific names are matched before their
    /// prefixes so "Buds4 Pro" wins over "Buds4", and "Pro/FE" win over base.
    /// Returns nil when the name doesn't look like any known model.
    static func detect(from name: String) -> BudsModel? {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
        // Ordered most-specific first.
        let table: [(needle: String, model: BudsModel)] = [
            ("buds4pro", .buds4Pro),
            ("buds4", .buds4),
            ("buds3fe", .buds3Fe),
            ("buds3pro", .buds3Pro),
            ("buds3", .buds3),
            ("buds2pro", .buds2Pro),
            ("buds2", .buds2),
            ("budspro", .budsPro),
            ("budslive", .budsLive),
            ("budsfe", .budsFe),
            ("budscore", .budsCore),
            ("buds+", .budsPlus),
            ("budsplus", .budsPlus),
            ("buds", .buds),
        ]
        for entry in table where normalized.contains(entry.needle) {
            return entry.model
        }
        return nil
    }

    var serviceUUID: String {
        switch self {
        case .buds:
            return "00001102-0000-1000-8000-00805f9b34fd"
        case .budsPlus, .budsLive, .budsPro:
            return "00001101-0000-1000-8000-00805f9b34fb"
        default:
            return "2e73a4ad-332d-41fc-90e2-16bef06523f2"
        }
    }

    var usesLegacyProtocol: Bool {
        self == .buds
    }

    var supportsANC: Bool {
        switch self {
        case .budsPro, .buds2Pro, .buds3, .buds3Pro, .buds3Fe, .buds4, .buds4Pro:
            return true
        default:
            return false
        }
    }

    var supportsCaseBattery: Bool {
        self != .buds
    }

    var supportsAdaptiveANC: Bool {
        switch self {
        case .buds3Pro, .buds4Pro:
            return true
        default:
            return false
        }
    }

    /// Whether the model can auto-switch to ambient sound when you talk.
    var supportsDetectConversations: Bool {
        switch self {
        case .budsPro, .buds2Pro, .buds3Pro, .buds4Pro:
            return true
        default:
            return false
        }
    }

    var maxAmbientVolume: Int {
        switch self {
        case .buds:
            return 5
        default:
            return 4
        }
    }

    /// SF Symbol for the model's icon. "airpodspro" reads cleanly as an earbud
    /// and exists on all supported macOS versions; per-model distinction comes
    /// from the accent colour (`tint`) rather than the glyph.
    var iconName: String {
        "airpodspro"
    }
}
