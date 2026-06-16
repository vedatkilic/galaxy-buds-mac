import Foundation

@Observable
final class BudsStatus: @unchecked Sendable {
    var batteryLeft: Int = 0
    var batteryRight: Int = 0
    var batteryCase: Int = 0

    var isLeftCharging: Bool = false
    var isRightCharging: Bool = false
    var isCaseCharging: Bool = false

    var isLeftWearing: Bool = false
    var isRightWearing: Bool = false

    var placementLeft: Placement = .unknown
    var placementRight: Placement = .unknown

    var isCoupled: Bool = false
    var mainConnection: MainConnection = .right

    var ambientSoundEnabled: Bool = false
    var ambientSoundVolume: Int = 0
    var ambientVoiceFocus: Bool = false

    var noiseControlMode: NoiseControlMode = .off

    // Sound & ANC detail settings (Buds3/4 Pro).
    var ancLevelHigh: Bool = false           // ANC strength Low/High
    var ncWithOneEarbud: Bool = false        // allow noise control with one bud
    var ambientCustomEnabled: Bool = false   // customize ambient per side
    var ambientCustomLeft: Int = 1           // 0...2
    var ambientCustomRight: Int = 1          // 0...2
    var ambientTone: Int = 1                 // 0=low,1=mid,2=high
    var detectConversations: Bool = false
    var detectConversationsDuration: Int = 0 // 0=5s,1=10s,2=15s
    var sidetone: Bool = false               // own voice during calls
    var ambientDuringCalls: Bool = false     // call path control

    // Earbud touch controls (Buds3/4 Pro).
    var touchHoldLeft: TouchHoldAction = .noiseControl
    var touchHoldRight: TouchHoldAction = .noiseControl
    var noiseCycleLeft: NoiseControlCycle = .ancAmbient
    var noiseCycleRight: NoiseControlCycle = .ancAmbient

    // About / Diagnostics.
    var softwareVersion: String = ""
    var serialLeft: String = ""
    var serialRight: String = ""
    var fitLeft: FitResult = .unknown
    var fitRight: FitResult = .unknown

    enum FitResult: Int, Sendable {
        case bad = 0
        case good = 1
        case failed = 2
        case unknown = 99
    }

    var equalizerPreset: EqualizerPreset = .off
    var touchpadLocked: Bool = false

    var deviceColor: DeviceColor = .black

    enum Placement: Int, Sendable {
        case unknown = 0
        case wearing = 1
        case notWearing = 2
        case inCase = 3
        case inClosedCase = 4
    }

    enum MainConnection: Int, Sendable {
        case right = 0
        case left = 1
    }

    enum DeviceColor: Int, Sendable {
        case black = 0
        case white = 1
        case pink = 2
        case blue = 3
        case gold = 4
        case gray = 5
        case green = 6
        case purple = 7
        case violet = 8
        case silver = 9

        var displayName: String {
            switch self {
            case .black: "Black"
            case .white: "White"
            case .pink: "Pink"
            case .blue: "Blue"
            case .gold: "Gold"
            case .gray: "Gray"
            case .green: "Green"
            case .purple: "Purple"
            case .violet: "Violet"
            case .silver: "Silver"
            }
        }
    }
}
