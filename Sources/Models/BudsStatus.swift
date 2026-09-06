import Foundation

@Observable
final class BudsStatus: @unchecked Sendable {
    var batteryLeft: Int = 0
    var batteryRight: Int = 0
    var batteryCase: Int = 0

    /// Derived from placement — the payload carries no charging flag, and a
    /// bud only charges inside the case. The case itself gives no signal about
    /// whether *it* is plugged in, so there is deliberately no equivalent for it.
    var isLeftCharging: Bool = false
    var isRightCharging: Bool = false

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
    var ancLevel: Int = 0                    // ANC strength, 0-based step
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

    // Connection
    /// Samsung Seamless Connection (Bluetooth multipoint between two hosts).
    var seamlessConnectionEnabled: Bool = false

    var equalizerPreset: EqualizerPreset = .off
    /// Per-band gains for the custom 9-band equalizer (Buds4 Pro). Each band is
    /// a signed value in -10...+10. Index 0 = lowest band, 8 = highest.
    var customEqualizerBands: [Int] = Array(repeating: 0, count: 9)
    var customEqualizerEnabled: Bool = false
    /// Per-preset band curves reported by the device via CUSTOM_EQUALIZE_RECV.
    /// Used to visualise each preset's shape on the graph. Index 0 = Normal,
    /// 1 = Bass Boost, … matching EqualizerPreset (excluding .custom). Each
    /// entry is 9 signed gains. Empty until the device responds.
    var presetEqualizerCurves: [[Int]] = []
    var touchpadLocked: Bool = false

    var deviceColor: DeviceColor = .black

    enum Placement: Int, Sendable {
        case unknown = 0
        case wearing = 1
        case notWearing = 2
        case inCase = 3
        case inClosedCase = 4

        /// Open or closed, the bud is on the charging pins either way.
        var isInCase: Bool { self == .inCase || self == .inClosedCase }
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
