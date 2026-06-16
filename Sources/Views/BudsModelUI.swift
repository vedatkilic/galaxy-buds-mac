import SwiftUI

/// Presentation helpers for `BudsModel` kept in the view layer so the model
/// stays free of SwiftUI. Provides a per-model accent colour, a release-year
/// subtitle, and a capability badge for the selection cards.
extension BudsModel {
    /// A representative accent colour per model — loosely mirrors Samsung's
    /// signature colourway for each generation. Gives every model a distinct
    /// visual identity in the picker and dashboard.
    var tint: Color {
        switch self {
        case .buds: return Color(red: 0.40, green: 0.78, blue: 0.95)        // arctic blue
        case .budsPlus: return Color(red: 0.45, green: 0.55, blue: 0.95)    // blue
        case .budsLive: return Color(red: 0.80, green: 0.55, blue: 0.30)    // mystic bronze
        case .budsPro: return Color(red: 0.50, green: 0.45, blue: 0.85)     // phantom violet
        case .buds2: return Color(red: 0.55, green: 0.80, blue: 0.70)       // olive/green
        case .buds2Pro: return Color(red: 0.42, green: 0.45, blue: 0.55)    // graphite
        case .budsFe: return Color(red: 0.55, green: 0.70, blue: 0.95)      // graphite blue
        case .budsCore: return Color(red: 0.50, green: 0.52, blue: 0.58)    // gray
        case .buds3: return Color(red: 0.70, green: 0.72, blue: 0.78)       // silver
        case .buds3Pro: return Color(red: 0.62, green: 0.66, blue: 0.74)    // silver
        case .buds3Fe: return Color(red: 0.55, green: 0.78, blue: 0.90)     // light blue
        case .buds4: return Color(red: 0.66, green: 0.70, blue: 0.78)       // silver
        case .buds4Pro: return Color(red: 0.36, green: 0.52, blue: 0.78)    // blue-silver
        }
    }

    /// Short marketing year used as a card subtitle.
    var releaseYear: String {
        switch self {
        case .buds: return "2019"
        case .budsPlus: return "2020"
        case .budsLive: return "2020"
        case .budsPro: return "2021"
        case .buds2: return "2021"
        case .buds2Pro: return "2022"
        case .budsFe: return "2023"
        case .budsCore: return "2024"
        case .buds3: return "2024"
        case .buds3Pro: return "2024"
        case .buds3Fe: return "2025"
        case .buds4: return "2025"
        case .buds4Pro: return "2025"
        }
    }

    /// Selection-card capability badge, or nil when there's nothing notable.
    var capabilityBadge: String? {
        if supportsAdaptiveANC { return "Adaptive ANC" }
        if supportsANC { return "ANC" }
        return nil
    }
}
