import Foundation
@preconcurrency import IOBluetooth
@preconcurrency import CoreBluetooth
import Combine

@Observable
@MainActor
final class BluetoothManager: NSObject, @unchecked Sendable {
    var isConnected = false
    var isScanning = false
    var discoveredDevices: [DiscoveredDevice] = []
    var connectedModel: BudsModel?
    /// The user's custom Bluetooth name for the device (e.g. "Vedat's Buds4 Pro").
    var connectedName: String?
    var status = BudsStatus()
    var connectionError: String?
    var bluetoothReady = false

    struct DiscoveredDevice: Identifiable, Sendable {
        let id: String
        let name: String
        let address: String
        let device: IOBluetoothDevice

        nonisolated init(device: IOBluetoothDevice) {
            self.id = device.addressString ?? UUID().uuidString
            self.name = device.name ?? "Unknown"
            self.address = device.addressString ?? ""
            self.device = device
        }
    }

    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var receiveBuffer = Data()
    private var connectedDevice: IOBluetoothDevice?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var centralManager: CBCentralManager?
    private var pendingScan = false
    private var connectTimeoutTask: Task<Void, Never>?

    // Auto-connect: connects to an already-paired Galaxy Buds automatically on
    // launch and whenever one connects to the Mac later.
    private var autoConnectArmed = false
    private var connectNotification: IOBluetoothUserNotification?
    private var autoConnectShouldNotify = false
    private var suppressAutoConnect = false
    private var lastAutoAttempt: Date?
    private let autoConnectCooldown: TimeInterval = 15
    /// While true, connection failures don't surface an error (auto-connect
    /// attempts shouldn't pop error UI when the buds are simply away).
    private var silentConnect = false
    /// Invoked when an auto-connect (triggered by a device connecting) succeeds,
    /// so the UI can surface the panel — an AirPods-like pop-up on connect.
    var onAutoConnected: (@MainActor () -> Void)?

    /// Instantiates CoreBluetooth to trigger the system Bluetooth permission
    /// prompt and to gate IOBluetooth access. On modern macOS,
    /// `IOBluetoothDevice.pairedDevices()` routes through CoreBluetooth and
    /// aborts the process if accessed before authorization — so nothing
    /// IOBluetooth-related may run until `centralManagerDidUpdateState` reports
    /// `.poweredOn`.
    /// Arms auto-connect and primes Bluetooth permission. Once authorized, the
    /// manager connects to any already-connected paired Galaxy Buds and listens
    /// for future connections.
    func startAutoConnect() {
        autoConnectArmed = true
        primeBluetoothPermission()
        if bluetoothReady { armConnectNotifications() }
    }

    private func armConnectNotifications() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
        attemptAutoConnect(notify: false)
    }

    @objc nonisolated func deviceDidConnect(
        _ notification: IOBluetoothUserNotification!,
        device: IOBluetoothDevice!
    ) {
        let name = device?.name ?? ""
        Task { @MainActor in
            guard self.isGalaxyBudsName(name), !self.isConnected else { return }
            self.attemptAutoConnect(notify: true)
        }
    }

    /// Connects to the first already-connected, paired Galaxy Buds, if any.
    private func attemptAutoConnect(notify: Bool) {
        guard bluetoothReady, !isConnected, rfcommChannel == nil else { return }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in paired where device.isConnected() && isGalaxyBudsName(device.name ?? "") {
            autoConnectShouldNotify = notify
            let model = BudsModel.detect(from: device.name ?? "") ?? .buds4Pro
            connect(to: DiscoveredDevice(device: device), model: model)
            return
        }
    }

    func primeBluetoothPermission() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func startScanning() {
        isScanning = true
        discoveredDevices = []
        connectionError = nil

        primeBluetoothPermission()

        // Defer the actual IOBluetooth work until CoreBluetooth is authorized
        // and powered on; otherwise the process is killed by TCC.
        if bluetoothReady {
            performScan()
        } else {
            pendingScan = true
        }
    }

    private func performScan() {
        let inq = IOBluetoothDeviceInquiry(delegate: self)
        inq?.updateNewDeviceNames = true
        inq?.searchType = kIOBluetoothDeviceSearchClassic.rawValue
        inquiry = inq
        inq?.start()

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired {
                let name = device.name ?? ""
                if isGalaxyBudsName(name) {
                    let discovered = DiscoveredDevice(device: device)
                    if !discoveredDevices.contains(where: { $0.address == discovered.address }) {
                        discoveredDevices.append(discovered)
                    }
                }
            }
        }
    }

    func stopScanning() {
        inquiry?.stop()
        inquiry = nil
        isScanning = false
    }

    func connect(to device: DiscoveredDevice, model: BudsModel) {
        connectionError = nil
        connectedModel = model
        connectedName = device.name
        connectedDevice = device.device
        startConnectTimeout()

        let target = device.device
        let uuidString = model.serviceUUID

        // Resolve the RFCOMM channel off the main thread: this ensures the
        // baseband link is up and performs/polls the SDP query (which can take
        // up to ~2s). The actual channel is then opened back on the main thread
        // so its data callbacks bind to the always-pumping main run loop.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let channelId = self.resolveChannel(target: target, uuidString: uuidString)
            await MainActor.run {
                if let channelId {
                    self.connectViaRFCOMM(device: target, channelId: channelId)
                } else {
                    self.failConnect(String(
                        localized: "Couldn't find the Galaxy Buds control service. Try removing and re-pairing the earbuds in System Settings → Bluetooth."))
                }
            }
        }
    }

    /// Ensures the baseband connection, runs an SDP query, and polls for the
    /// model's SPP service record to read its advertised RFCOMM channel. Mirrors
    /// GalaxyBudsClient's macOS approach (query all records, then look up by
    /// UUID — UUID-filtered SDP queries silently fail since Ventura). Runs on a
    /// background thread; returns nil if the channel can't be resolved.
    private nonisolated func resolveChannel(
        target: IOBluetoothDevice,
        uuidString: String
    ) -> BluetoothRFCOMMChannelID? {
        if !target.isConnected() {
            target.openConnection()
        }

        let uuidBytes = uuidStringToBytes(uuidString)
        let uuid = IOBluetoothSDPUUID(bytes: uuidBytes, length: uuidBytes.count)

        // Try cached SDP first, then force a fresh query and poll for ~2.5s.
        if let channel = rfcommChannel(on: target, uuid: uuid) {
            return channel
        }
        _ = target.performSDPQuery(nil)
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.1)
            if let channel = rfcommChannel(on: target, uuid: uuid) {
                return channel
            }
        }
        return nil
    }

    private nonisolated func rfcommChannel(
        on target: IOBluetoothDevice,
        uuid: IOBluetoothSDPUUID
    ) -> BluetoothRFCOMMChannelID? {
        guard let record = target.getServiceRecord(for: uuid) else { return nil }
        var channelId: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelId) == kIOReturnSuccess else { return nil }
        return channelId
    }

    func disconnect() {
        rfcommChannel?.close()
        rfcommChannel = nil
        connectedDevice?.closeConnection()
        connectedDevice = nil
        isConnected = false
        connectedModel = nil
        connectedName = nil
        // Hold off auto-reconnect briefly after a manual disconnect, then allow
        // it again (e.g. the user takes the buds out and puts them back).
        suppressAutoConnect = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.suppressAutoConnect = false
        }
    }

    /// Polled (~every 2s) by the app: connects to an already-connected paired
    /// Galaxy Buds. More reliable than IOBluetooth connect notifications, which
    /// don't fire dependably on all macOS versions.
    func pollAutoConnect() {
        guard autoConnectArmed, bluetoothReady, !isConnected,
              rfcommChannel == nil, !suppressAutoConnect else { return }
        // IOBluetooth `isConnected()` is unreliable for these buds (returns false
        // even while connected), so we can't gate on it. Instead, attempt the
        // connection on a cooldown — it succeeds when the buds are reachable and
        // fails quietly (silentConnect) when they're away.
        if let last = lastAutoAttempt, Date().timeIntervalSince(last) < autoConnectCooldown {
            return
        }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: { isGalaxyBudsName($0.name ?? "") })
        else { return }

        lastAutoAttempt = Date()
        silentConnect = true
        autoConnectShouldNotify = true
        let model = BudsModel.detect(from: device.name ?? "") ?? .buds4Pro
        connect(to: DiscoveredDevice(device: device), model: model)
    }

    func sendMessage(_ message: SppMessage) {
        guard let channel = rfcommChannel else { return }

        let legacy = connectedModel?.usesLegacyProtocol ?? false
        var encoded = message.encode(legacy: legacy)
        let length = UInt16(encoded.count)

        encoded.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            channel.writeSync(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                length: length
            )
        }
    }

    func setNoiseControl(_ mode: NoiseControlMode) {
        let msg = SppMessage(
            messageId: .noiseControls,
            payload: Data([UInt8(mode.rawValue)])
        )
        sendMessage(msg)
        // Reflect immediately; the buds also echo via NOISE_CONTROLS_UPDATE.
        status.noiseControlMode = mode
    }

    func setAmbientSound(enabled: Bool) {
        let msg = SppMessage(
            messageId: .setAmbientMode,
            payload: Data([enabled ? 1 : 0])
        )
        sendMessage(msg)
    }

    func setAmbientVolume(_ volume: Int) {
        let msg = SppMessage(
            messageId: .ambientVolume,
            payload: Data([UInt8(volume)])
        )
        sendMessage(msg)
        status.ambientSoundVolume = volume
    }

    /// Sets ANC strength. Buds4 Pro exposes a Low/High toggle, not a free slider.
    func setAncLevelHigh(_ high: Bool) {
        sendMessage(SppMessage(messageId: .noiseReductionLevel, payload: Data([high ? 1 : 0])))
        status.ancLevelHigh = high
    }

    func setNoiseControlWithOneEarbud(_ enabled: Bool) {
        sendMessage(SppMessage(messageId: .setAncWithOneEarbud, payload: Data([enabled ? 1 : 0])))
        status.ncWithOneEarbud = enabled
    }

    /// Customizes ambient sound: per-side volume (0...2) and tone (0=low,1=mid,
    /// 2=high). Payload is [enabled, left, right, tone].
    func setCustomAmbient(enabled: Bool, left: Int, right: Int, tone: Int) {
        let payload = Data([
            enabled ? 1 : 0, UInt8(left), UInt8(right), UInt8(tone),
        ])
        sendMessage(SppMessage(messageId: .customizeAmbientSound, payload: payload))
        status.ambientCustomEnabled = enabled
        status.ambientCustomLeft = left
        status.ambientCustomRight = right
        status.ambientTone = tone
    }

    func setDetectConversations(_ enabled: Bool) {
        sendMessage(SppMessage(messageId: .setDetectConversations, payload: Data([enabled ? 1 : 0])))
        status.detectConversations = enabled
    }

    /// Conversation-detect timeout: 0 = 5s, 1 = 10s, 2 = 15s.
    func setDetectConversationsDuration(_ duration: Int) {
        sendMessage(SppMessage(
            messageId: .setDetectConversationsDuration, payload: Data([UInt8(duration)])))
        status.detectConversationsDuration = duration
    }

    func setSidetone(_ enabled: Bool) {
        sendMessage(SppMessage(messageId: .setSidetone, payload: Data([enabled ? 1 : 0])))
        status.sidetone = enabled
    }

    /// Ambient sound during calls. The wire value is inverted: enabled → 0.
    func setAmbientDuringCalls(_ enabled: Bool) {
        sendMessage(SppMessage(messageId: .setCallPathControl, payload: Data([enabled ? 0 : 1])))
        status.ambientDuringCalls = enabled
    }

    func setEqualizer(_ preset: EqualizerPreset) {
        // Modern models (Buds3/4 Pro) expect a single byte: 0 = off, else
        // preset+1. Our EqualizerPreset raw values already match that wire scale
        // (off=0, bassBoost=1 … trebleBoost=5).
        let msg = SppMessage(
            messageId: .equalizer,
            payload: Data([UInt8(preset.rawValue)])
        )
        sendMessage(msg)
        status.equalizerPreset = preset
    }

    func setTouchpadLock(_ locked: Bool) {
        // Buds3/4 Pro expect 7 bytes: [!lockAll, tap, double, triple, hold,
        // doubleCall, holdCall] — byte 0 is inverted. Lock everything → all 0;
        // unlock → all 1.
        let value: UInt8 = locked ? 0 : 1
        let payload = Data([UInt8](repeating: value, count: 7))
        sendMessage(SppMessage(messageId: .lockTouchpad, payload: payload))
        status.touchpadLocked = locked
    }

    /// Sets the touch-and-hold action per earbud (id 146, payload [left, right]).
    func setTouchHoldActions(left: TouchHoldAction, right: TouchHoldAction) {
        let payload = Data([UInt8(left.rawValue), UInt8(right.rawValue)])
        sendMessage(SppMessage(messageId: .setTouchpadOption, payload: payload))
        status.touchHoldLeft = left
        status.touchHoldRight = right
    }

    /// Sets which noise-control modes the hold gesture cycles, per side
    /// (id 121, payload [leftMask, rightMask]).
    func setNoiseControlCycle(left: NoiseControlCycle, right: NoiseControlCycle) {
        let payload = Data([UInt8(left.rawValue), UInt8(right.rawValue)])
        sendMessage(SppMessage(messageId: .setTouchAndHoldNoiseControls, payload: payload))
        status.noiseCycleLeft = left
        status.noiseCycleRight = right
    }

    func findMyBuds(start: Bool) {
        let messageId: MessageId
        if start {
            // While a bud is worn, newer models ignore the plain start message
            // and require the "ring while wearing" variant (id 166).
            let worn = status.isLeftWearing || status.isRightWearing
            messageId = worn ? .findMyEarbudsOnWearingStart : .findMyEarbudsStart
        } else {
            messageId = .findMyEarbudsStop
        }
        sendMessage(SppMessage(messageId: messageId))
    }

    /// Silences one earbud while the find tone plays (id 162, [left, right]).
    func setMuteEarbud(left: Bool, right: Bool) {
        sendMessage(SppMessage(
            messageId: .muteEarbud, payload: Data([left ? 1 : 0, right ? 1 : 0])))
    }

    func requestStatusUpdate() {
        let msg = SppMessage(messageId: .extendedStatusUpdated)
        sendMessage(msg)
    }

    /// Requests software version (DEBUG_GET_ALL_DATA) and serial numbers.
    func requestAboutInfo() {
        sendMessage(SppMessage(messageId: .debugGetAllData))
        sendMessage(SppMessage(messageId: .debugSerialNumber))
    }

    /// Starts/stops the earbud fit (seal) test. Results arrive via id 158.
    /// Clears the previous result on start; keeps it on stop so the user can
    /// read the final result.
    func setFitTest(active: Bool) {
        if active {
            status.fitLeft = .unknown
            status.fitRight = .unknown
        }
        sendMessage(SppMessage(messageId: .checkFitOfEarbuds, payload: Data([active ? 1 : 0])))
    }

    // MARK: - Private

    private func connectViaRFCOMM(device: IOBluetoothDevice, channelId: BluetoothRFCOMMChannelID) {
        var channel: IOBluetoothRFCOMMChannel?
        // Async open on the main thread so the channel's data/open callbacks
        // bind to the main run loop. The init status is unreliable on macOS, so
        // success is confirmed via `rfcommChannelOpenComplete` or by polling
        // `isOpen` below.
        _ = device.openRFCOMMChannelAsync(
            &channel,
            withChannelID: channelId,
            delegate: self
        )
        self.rfcommChannel = channel
        self.connectedDevice = device

        // Fallback: openRFCOMMChannelAsync can both lie about its status and, on
        // some macOS builds, never fire the completion delegate. Poll isOpen.
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if self.isConnected { return }
                if self.rfcommChannel?.isOpen() == true {
                    self.markConnected()
                    return
                }
            }
        }
    }

    /// Idempotent: completes the connection exactly once regardless of whether
    /// the open delegate or the isOpen poll detects success first.
    private func markConnected() {
        guard !isConnected, rfcommChannel != nil else { return }
        cancelConnectTimeout()
        silentConnect = false
        isConnected = true
        stopScanning()
        sendInitialHandshake()
        if autoConnectShouldNotify {
            autoConnectShouldNotify = false
            onAutoConnected?()
        }
    }

    /// Aborts the in-flight connection. Surfaces an error only for manual
    /// connects; auto-connect attempts fail quietly.
    private func failConnect(_ message: String) {
        cancelConnectTimeout()
        rfcommChannel?.close()
        rfcommChannel = nil
        let silent = silentConnect
        silentConnect = false
        if !silent { connectionError = message }
    }

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, !self.isConnected else { return }
            self.failConnect(String(
                localized: "Connection timed out. The earbuds may not be exposing the control channel right now."))
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func sendInitialHandshake() {
        let resp = SppMessage(messageId: .resp, payload: Data([0]))
        sendMessage(resp)

        let managerInfo = SppMessage(
            messageId: .managerInfo,
            payload: Data([1, 1, 0, 1])
        )
        sendMessage(managerInfo)

        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let tz = TimeZone.current.secondsFromGMT() / 3600

        var timePayload = Data()
        let year = UInt16(components.year ?? 2024)
        timePayload.append(UInt8(year & 0xFF))
        timePayload.append(UInt8(year >> 8))
        timePayload.append(UInt8(components.month ?? 1))
        timePayload.append(UInt8(components.day ?? 1))
        timePayload.append(UInt8(components.hour ?? 0))
        timePayload.append(UInt8(components.minute ?? 0))
        timePayload.append(UInt8(components.second ?? 0))
        timePayload.append(UInt8(bitPattern: Int8(tz)))

        let timeMsg = SppMessage(messageId: .updateTime, payload: timePayload)
        sendMessage(timeMsg)
    }

    private func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        while let message = extractMessage() {
            handleMessage(message)
        }
    }

    private func extractMessage() -> SppMessage? {
        guard receiveBuffer.count >= 5 else { return nil }
        let base = receiveBuffer.startIndex
        let preamble = receiveBuffer[base]

        // The frame length must come from the header's size field, NOT from
        // searching for the postamble byte — payload bytes (serials, versions)
        // can equal the postamble (0xDD/0xEE/0xCC) and would truncate the frame.
        let size: Int
        switch preamble {
        case 0xFE:                       // legacy: payload size at byte[2]
            size = Int(receiveBuffer[base + 2])
        case 0xFD, 0xFC:                 // standard / smep: 10-bit size in header
            let header = Int(receiveBuffer[base + 1]) | (Int(receiveBuffer[base + 2]) << 8)
            size = header & 0x3FF
        default:
            receiveBuffer.removeFirst()
            return extractMessage()
        }

        // Frame = preamble(1) + header(2) + size(msgId+payload+crc) + postamble(1).
        let frameLength = size + 4
        guard frameLength >= 5, receiveBuffer.count >= frameLength else { return nil }

        let frame = Data(receiveBuffer[base..<(base + frameLength)])
        let message = SppMessage.decode(frame)
        receiveBuffer = Data(receiveBuffer[(base + frameLength)...])
        if message == nil {
            return extractMessage()
        }
        return message
    }

    private func handleMessage(_ message: SppMessage) {
        switch message.messageId {
        case .statusUpdated:
            parseStatusUpdate(message.payload)
        case .extendedStatusUpdated:
            parseExtendedStatusUpdate(message.payload)
            let ack = SppMessage(messageId: .resp, payload: Data([message.messageId.rawValue, 0]))
            sendMessage(ack)
        case .noiseControlsUpdate:
            // Pushed when the user changes ANC on the earbud itself.
            if !message.payload.isEmpty,
               let mode = NoiseControlMode(rawValue: Int(message.payload[0])) {
                status.noiseControlMode = mode
            }
        case .debugGetAllData:
            parseGetAllData(message.payload)
        case .debugSerialNumber:
            parseSerialNumber(message.payload)
        case .checkFitResult:
            parseFitResult(message.payload)
        default:
            break
        }
    }

    /// Software version for Buds3/4 Pro: 20 ASCII bytes at offset 2, nulls stripped.
    private func parseGetAllData(_ payload: Data) {
        guard payload.count >= 22 else { return }
        let bytes = payload[(payload.startIndex + 2)..<(payload.startIndex + 22)]
        let filtered = bytes.filter { $0 != 0 }
        status.softwareVersion = String(decoding: filtered, as: UTF8.self)
    }

    /// Left/right serial numbers: 11 ASCII bytes each.
    private func parseSerialNumber(_ payload: Data) {
        guard payload.count >= 22 else { return }
        func ascii(_ range: Range<Int>) -> String {
            let slice = payload[(payload.startIndex + range.lowerBound)..<(payload.startIndex + range.upperBound)]
            return String(decoding: slice.filter { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
        status.serialLeft = ascii(0..<11)
        status.serialRight = ascii(11..<22)
    }

    private func parseFitResult(_ payload: Data) {
        guard payload.count >= 2 else { return }
        status.fitLeft = BudsStatus.FitResult(rawValue: Int(payload[0])) ?? .unknown
        status.fitRight = BudsStatus.FitResult(rawValue: Int(payload[1])) ?? .unknown
    }

    private func parseStatusUpdate(_ payload: Data) {
        guard payload.count >= 3 else { return }
        status.batteryLeft = Int(payload[0])
        status.batteryRight = Int(payload[1])
    }

    private func parseExtendedStatusUpdate(_ payload: Data) {
        let isLegacy = connectedModel?.usesLegacyProtocol ?? false

        if isLegacy {
            parseLegacyExtendedStatus(payload)
        } else {
            parseModernExtendedStatus(payload)
        }
    }

    private func parseLegacyExtendedStatus(_ payload: Data) {
        guard payload.count >= 13 else { return }
        status.batteryLeft = Int(payload[2])
        status.batteryRight = Int(payload[3])
        status.isCoupled = payload[4] != 0
        status.mainConnection = BudsStatus.MainConnection(rawValue: Int(payload[5])) ?? .right

        let wearing = payload[6]
        status.isLeftWearing = (wearing & 0x01) != 0
        status.isRightWearing = (wearing & 0x10) != 0

        status.ambientSoundEnabled = payload[7] != 0
        status.ambientVoiceFocus = payload[8] != 0
        status.ambientSoundVolume = Int(payload[9])

        let eqEnabled = payload[10] != 0
        if eqEnabled {
            status.equalizerPreset = EqualizerPreset(rawValue: Int(payload[11])) ?? .off
        } else {
            status.equalizerPreset = .off
        }

        status.touchpadLocked = (payload[12] & 0x0F) != 0
    }

    private func parseModernExtendedStatus(_ payload: Data) {
        guard payload.count >= 14 else { return }
        status.batteryLeft = Int(payload[2])
        status.batteryRight = Int(payload[3])
        status.isCoupled = payload[4] != 0
        status.mainConnection = BudsStatus.MainConnection(rawValue: Int(payload[5])) ?? .right

        let placement = payload[6]
        status.placementLeft = BudsStatus.Placement(rawValue: Int(placement >> 4)) ?? .unknown
        status.placementRight = BudsStatus.Placement(rawValue: Int(placement & 0x0F)) ?? .unknown
        status.isLeftWearing = status.placementLeft == .wearing
        status.isRightWearing = status.placementRight == .wearing

        status.batteryCase = Int(payload[7])
        status.ambientSoundEnabled = payload[8] != 0
        status.ambientVoiceFocus = payload[9] != 0

        // payload[9] = EQ on SppNew models (0=off, 1..5 = preset+1), payload[12]
        // = noise control mode (0=Off,1=ANC,2=Ambient,3=Adaptive), per
        // GalaxyBudsClient's decoder.
        status.equalizerPreset = EqualizerPreset(rawValue: Int(payload[9])) ?? .off
        status.noiseControlMode = NoiseControlMode(rawValue: Int(payload[12])) ?? .off

        // payload[14] requires at least 15 bytes; older firmware sends fewer.
        if payload.count > 14 {
            status.deviceColor = BudsStatus.DeviceColor(rawValue: Int(payload[14] & 0x0F)) ?? .black
        }

        parseSoundAndAncDetails(payload)
    }

    /// Reads the Sound & ANC detail fields from the Buds3/4 Pro extended-status
    /// payload (offsets per GalaxyBudsClient's `>= Buds3 Pro` decoder path).
    /// Each offset is guarded since older firmware sends shorter payloads.
    private func parseSoundAndAncDetails(_ payload: Data) {
        func byte(_ i: Int) -> Int? { payload.count > i ? Int(payload[i]) : nil }

        if let v = byte(23) { status.ambientSoundVolume = v }
        if let v = byte(26) { status.detectConversations = v == 1 }
        if let v = byte(27) { status.detectConversationsDuration = min(v, 2) }
        if let v = byte(29) { status.ambientCustomEnabled = v == 1 }
        if let v = byte(30) {
            status.ambientCustomLeft = (v >> 4) & 0x0F
            status.ambientCustomRight = v & 0x0F
        }
        if let v = byte(31) { status.ambientTone = v }
        if let v = byte(32) { status.ncWithOneEarbud = v == 1 }
        if let v = byte(33) { status.sidetone = v == 1 }
        if let v = byte(34) { status.ambientDuringCalls = v == 0 } // inverted

        // payload[10] bit 7 (inverted) = touchpad lock; payload[11] nibbles =
        // per-side hold action; payload[21] bits = noise-control cycle subset.
        if let v = byte(10) { status.touchpadLocked = (v & 0x80) == 0 }
        if let v = byte(11) {
            if let l = TouchHoldAction(rawValue: (v >> 4) & 0x0F) { status.touchHoldLeft = l }
            if let r = TouchHoldAction(rawValue: v & 0x0F) { status.touchHoldRight = r }
        }
        if let v = byte(21) {
            status.noiseCycleRight = cycle(amb: v & 1 != 0, off: v & 4 != 0, anc: v & 8 != 0)
            status.noiseCycleLeft = cycle(amb: v & 16 != 0, off: v & 64 != 0, anc: v & 128 != 0)
        }
    }

    private func cycle(amb: Bool, off: Bool, anc: Bool) -> NoiseControlCycle {
        if anc && off { return .ancOff }
        if amb && off { return .ambientOff }
        return .ancAmbient
    }

    private nonisolated func isGalaxyBudsName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("galaxy buds") || lower.contains("buds")
    }

    private nonisolated func uuidStringToBytes(_ uuidString: String) -> [UInt8] {
        let hex = uuidString.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                self.bluetoothReady = true
                if self.pendingScan {
                    self.pendingScan = false
                    self.performScan()
                }
                if self.autoConnectArmed {
                    self.armConnectNotifications()
                }
            case .unauthorized:
                self.bluetoothReady = false
                self.isScanning = false
                self.pendingScan = false
                self.connectionError = String(
                    localized: "Bluetooth permission denied. Allow BudsApp under System Settings → Privacy & Security → Bluetooth.")
            case .poweredOff:
                self.bluetoothReady = false
                self.isScanning = false
                self.connectionError = String(localized: "Bluetooth is off. Please turn it on.")
            default:
                self.bluetoothReady = false
            }
        }
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension BluetoothManager: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        Task { @MainActor in
            // The status is unreliable on macOS, so trust isOpen() too.
            if error == kIOReturnSuccess || rfcommChannel?.isOpen() == true {
                self.rfcommChannel = rfcommChannel
                self.markConnected()
            }
            // On a genuine failure, the isOpen poll/timeout in connectViaRFCOMM
            // surfaces the error; don't fail here on a lying status.
        }
    }

    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let receivedData = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor in
            self.handleReceivedData(receivedData)
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor in
            self.isConnected = false
            self.rfcommChannel = nil
        }
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate

extension BluetoothManager: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryDeviceFound(
        _ sender: IOBluetoothDeviceInquiry!,
        device: IOBluetoothDevice!
    ) {
        guard let device else { return }
        let name = device.name ?? ""
        guard isGalaxyBudsName(name) else { return }

        let discovered = DiscoveredDevice(device: device)
        Task { @MainActor in
            if !self.discoveredDevices.contains(where: { $0.address == discovered.address }) {
                self.discoveredDevices.append(discovered)
            }
        }
    }

    nonisolated func deviceInquiryComplete(
        _ sender: IOBluetoothDeviceInquiry!,
        error: IOReturn,
        aborted: Bool
    ) {
        Task { @MainActor in
            self.isScanning = false
        }
    }
}
