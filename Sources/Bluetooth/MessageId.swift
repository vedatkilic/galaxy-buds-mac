import Foundation

enum MessageId: UInt8, Sendable {
    case resp = 81
    case reset = 80

    case debugGetAllData = 38
    case debugBuildInfo = 40
    case debugSerialNumber = 41

    case statusUpdated = 96
    case extendedStatusUpdated = 97

    // Buds → host: reports the full EQ preset band-curve table plus the stored
    // custom band gains (id 137 is the reverse direction). Requested on demand.
    case customEqualizeRecv = 105

    case setAmbientMode = 128
    case ambientVolume = 132
    case equalizer = 134
    case managerInfo = 136
    case setTouchAndHoldNoiseControls = 121
    case lockTouchpad = 144
    case setTouchpadOption = 146

    // Sound & ANC detail settings.
    case setCallPathControl = 110            // ambient during calls (inverted bool)
    case setAncWithOneEarbud = 111
    case setDetectConversations = 122
    case setDetectConversationsDuration = 123
    case customizeAmbientSound = 130
    case noiseReductionLevel = 131           // ANC strength Low/High
    case setSidetone = 139

    case findMyEarbudsStart = 160
    case findMyEarbudsStop = 161
    case muteEarbud = 162                   // [leftMuted, rightMuted]
    case findMyEarbudsOnWearingStart = 166  // ring while a bud is worn

    case checkFitOfEarbuds = 157         // start [1] / stop [0]
    case checkFitResult = 158            // buds → host: [leftResult, rightResult]

    case updateTime = 167
    case noiseControlsUpdate = 119  // buds → host: ANC changed on the earbud
    case noiseControls = 120        // host → buds: set ANC/Ambient/Off/Adaptive
    case pairingMode = 114

    // Multipoint / Seamless Connection. The wire value is inverted: 0 = enabled,
    // 1 = disabled (matches the upstream protocol and the extended-status field).
    case setSeamlessConnection = 175

    // Custom 9-band equalizer (Buds4 Pro). Send payload [bandCount, band0..band8]
    // with each band a signed byte (-10..+10); then select the custom preset via
    // the EQUALIZER message with value 7 (custom index 6 + 1).
    case customEqualize = 137
}
