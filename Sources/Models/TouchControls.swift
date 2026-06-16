import Foundation

/// Touch-and-hold action assignable per earbud. Raw values are the on-wire
/// bytes from GalaxyBudsClient's `StandardTouchMap` (Buds3/4 Pro).
enum TouchHoldAction: Int, CaseIterable, Identifiable, Sendable {
    case voiceAssistant = 1
    case noiseControl = 2
    case volume = 3
    case spotify = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .voiceAssistant: "Voice assistant"
        case .noiseControl: "Noise control"
        case .volume: "Volume"
        case .spotify: "Spotify"
        }
    }
}

/// Which noise-control modes the touch-and-hold gesture cycles through. Raw
/// values are the on-wire per-side mask bytes used by `SET_TOUCH_AND_HOLD_
/// NOISE_CONTROLS` (id 121).
enum NoiseControlCycle: Int, CaseIterable, Identifiable, Sendable {
    case ancAmbient = 0x08
    case ancOff = 0x0C
    case ambientOff = 0x04

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .ancAmbient: "ANC / Ambient"
        case .ancOff: "ANC / Off"
        case .ambientOff: "Ambient / Off"
        }
    }
}
