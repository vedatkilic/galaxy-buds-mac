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
    /// True from the moment a connection attempt starts until it succeeds or
    /// fails. Guards against overlapping attempts (auto-connect racing the
    /// wizard) that would otherwise reset the timeout and clobber `silentConnect`.
    private var isConnecting = false
    /// Current auto-retry attempt (0 = first try). Connection failures trigger
    /// up to `maxConnectRetries` automatic retries before surfacing an error.
    private var connectRetryCount = 0
    private let maxConnectRetries = 2
    /// Watchdog for a *single* attempt. The previous shared timeout spanned all
    /// attempts, so it fired mid-retry and reported "timed out" before the
    /// retries had run. 35s is measured headroom: `openConnection` alone blocks
    /// up to ~15s before the ~8s SDP poll even starts, and anything tighter
    /// fails a device that was merely slow — which is how the old 12s shared
    /// timeout produced "connection timed out" on healthy hardware.
    private let attemptTimeout: TimeInterval = 35
    /// Ceiling on the whole connect, retries included: once passed, no further
    /// retry starts. Bounds the worst case at roughly one attempt beyond it.
    private let connectBudget: TimeInterval = 60
    private var connectDeadline = Date.distantPast
    /// Bumped per `connect()` so a timed-out attempt's stale resolve task can't
    /// resurrect a connection the manager has already moved past.
    private var connectGeneration = 0
    /// While true, the buds were intentionally handed off to the phone: the Mac
    /// drops the full Bluetooth link (A2DP audio + SPP control) so the buds fall
    /// back to the phone, and auto-reconnect is suppressed until the user
    /// requests it back. macOS exposes no API to drop only A2DP, so this is the
    /// only way to make the buds release the Mac's audio claim.
    var handedOffToPhone = false
    private var connectedDevice: IOBluetoothDevice?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var centralManager: CBCentralManager?
    private var pendingScan = false
    private var attemptTimeoutTask: Task<Void, Never>?

    // Auto-connect: connects to an already-paired Galaxy Buds automatically on
    // launch and whenever one connects to the Mac later.
    private var autoConnectArmed = false
    private var connectNotification: IOBluetoothUserNotification?
    private var autoConnectShouldNotify = false
    private var suppressAutoConnect = false
    private var lastAutoAttempt: Date?
    /// Last reason `pollAutoConnect` declined to run, so the 2s poll logs a
    /// change of state rather than the same line over and over.
    private var lastPollSkipReason: String?
    private let autoConnectCooldown: TimeInterval = 15
    /// While true, connection failures don't surface an error (auto-connect
    /// attempts shouldn't pop error UI when the buds are simply away).
    private var silentConnect = false
    /// Invoked when an auto-connect (triggered by a device connecting) succeeds,
    /// so the UI can surface the panel — an AirPods-like pop-up on connect.
    var onAutoConnected: (@MainActor () -> Void)?

    /// Firmware transfers ride the same control channel, so the manager owns the
    /// updater and forwards the device's FOTA messages to it.
    let firmware = FirmwareUpdater()

    override init() {
        super.init()
        firmware.send = { [weak self] message in self?.sendMessage(message) }
        firmware.onFinished = { [weak self] _ in self?.handleFirmwareTransferEnded() }
    }

    /// The buds reboot into the new firmware on their own once the transfer
    /// ends, so drop the stale link and let auto-connect pick them back up.
    private func handleFirmwareTransferEnded() {
        rfcommChannel?.close()
        rfcommChannel = nil
        connectedDevice?.closeConnection()
        isConnected = false
        isConnecting = false
        suppressAutoConnect = false
        lastAutoAttempt = nil
    }

    /// Largest single write the open channel accepts, 0 when disconnected.
    var channelMtu: Int { Int(rfcommChannel?.getMTU() ?? 0) }

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
        loadCustomEqualizer()
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
        guard bluetoothReady, !isConnected, rfcommChannel == nil, !isConnecting,
              !handedOffToPhone else { return }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in paired where device.isConnected() && isGalaxyBudsName(device.name ?? "") {
            autoConnectShouldNotify = notify
            let model = BudsModel.detect(from: device.name ?? "") ?? .buds4Pro
            connect(to: DiscoveredDevice(device: device), model: model, silent: true)
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

    func connect(to device: DiscoveredDevice, model: BudsModel, silent: Bool = false) {
        // Single in-flight attempt: a second connect (e.g. auto-connect racing
        // the wizard) must not reset the timeout or flip `silentConnect`, which
        // previously left the wizard stuck on "Connecting" forever. A foreground
        // (non-silent) request arriving mid-flight just promotes the in-flight
        // attempt to surface its result instead of failing quietly.
        if isConnecting {
            if !silent { silentConnect = false }
            return
        }
        isConnecting = true
        silentConnect = silent
        // Only a foreground connect clears a surfaced error. A silent
        // auto-connect used to clear it too, which flipped the wizard from
        // "Connection Failed" back to the spinner every cooldown and then back
        // again on the next timeout — the endless connect/fail loop in issue #2.
        // A silent attempt that actually succeeds clears the error in
        // `markConnected()` instead.
        if !silent { connectionError = nil }
        connectedModel = model
        connectedName = device.name
        connectedDevice = device.device
        connectRetryCount = 0
        connectDeadline = Date().addingTimeInterval(connectBudget)
        connectGeneration &+= 1
        DiagnosticsLog.shared.log(
            "connect: \(device.name) [\(device.address)] as \(model.rawValue), silent=\(silent)")
        attemptConnection(device: device, model: model)
    }

    /// Runs one connection attempt: resolves the RFCOMM channel off the main
    /// thread, then opens it on the main thread. On failure, retries up to
    /// `maxConnectRetries` times before giving up.
    private func attemptConnection(device: DiscoveredDevice, model: BudsModel) {
        let target = device.device
        let uuidStrings = model.serviceUUIDCandidates
        let generation = connectGeneration
        DiagnosticsLog.shared.log("attempt \(connectRetryCount + 1)/\(maxConnectRetries + 1) started")
        startAttemptTimeout(device: device, model: model, generation: generation)

        // Resolve the RFCOMM channel off the main thread: this ensures the
        // baseband link is up and performs/polls the SDP query (which can take
        // up to ~8s). The actual channel is then opened back on the main thread
        // so its data callbacks bind to the always-pumping main run loop.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let channelId = self.resolveChannel(target: target, uuidStrings: uuidStrings)
            await MainActor.run {
                guard self.isConnecting, self.connectGeneration == generation else { return }
                if let channelId {
                    self.connectViaRFCOMM(device: target, channelId: channelId)
                } else {
                    self.handleConnectFailure(device: device, model: model)
                }
            }
        }
    }

    /// Fails the *current attempt* (not the whole connect) once it overruns
    /// `attemptTimeout`, so `handleConnectFailure` can retry. Covers the whole
    /// attempt — SDP resolve and RFCOMM open alike; the open path previously had
    /// no failure route of its own when the channel never came up.
    private func startAttemptTimeout(
        device: DiscoveredDevice, model: BudsModel, generation: Int
    ) {
        attemptTimeoutTask?.cancel()
        attemptTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.attemptTimeout))
            guard !Task.isCancelled, self.isConnecting, !self.isConnected,
                  self.connectGeneration == generation else { return }
            DiagnosticsLog.shared.log("attempt timed out after \(Int(self.attemptTimeout))s")
            self.handleConnectFailure(device: device, model: model)
        }
    }

    private func cancelAttemptTimeout() {
        attemptTimeoutTask?.cancel()
        attemptTimeoutTask = nil
    }

    /// Handles a single connection attempt failure: retries automatically up to
    /// `maxConnectRetries` times (with a short backoff between tries) before
    /// surfacing the error to the user. Auto-connect (silent) attempts always
    /// fail quietly regardless of retry count.
    private func handleConnectFailure(device: DiscoveredDevice, model: BudsModel) {
        guard isConnecting else { return }
        cancelAttemptTimeout()
        // Retire the attempt: a resolve task still running for it must not open
        // a channel once the manager has moved on.
        connectGeneration &+= 1
        connectRetryCount += 1

        if connectRetryCount <= maxConnectRetries, Date() < connectDeadline {
            let generation = connectGeneration
            // Retry after a short backoff (1s, then 2s).
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.connectRetryCount))
                guard self.isConnecting, self.connectGeneration == generation else { return }
                self.attemptConnection(device: device, model: model)
            }
            return
        }
        DiagnosticsLog.shared.log("connect failed after \(connectRetryCount) attempt(s)")

        // All retries exhausted — surface the error (unless silent/auto-connect).
        failConnect(String(
            localized: "Couldn't connect after multiple tries. Make sure the earbuds aren't connected to another device, then try again."))
    }

    /// Ensures the baseband connection, runs an SDP query, and polls for the
    /// model's SPP service record to read its advertised RFCOMM channel. Mirrors
    /// GalaxyBudsClient's macOS approach (query all records, then look up by
    /// UUID — UUID-filtered SDP queries silently fail since Ventura). Runs on a
    /// background thread; returns nil if the channel can't be resolved.
    private nonisolated func resolveChannel(
        target: IOBluetoothDevice,
        uuidStrings: [String]
    ) -> BluetoothRFCOMMChannelID? {
        if !target.isConnected() {
            let started = Date()
            let result = target.openConnection()
            DiagnosticsLog.shared.log(String(
                format: "openConnection returned 0x%08x in %.1fs (connected=%@)",
                UInt32(bitPattern: result),
                Date().timeIntervalSince(started),
                target.isConnected() ? "yes" : "no"))
        }

        let uuids: [(string: String, uuid: IOBluetoothSDPUUID)] = uuidStrings.map { string in
            let bytes = uuidStringToBytes(string)
            return (string, IOBluetoothSDPUUID(bytes: bytes, length: bytes.count))
        }

        // Try cached SDP first, then force a fresh query and poll for ~8s.
        // The original 2.5s window was too short — the buds often take 3-5s to
        // expose their SPP service after the baseband link comes up, especially
        // when recovering from a phone multipoint session.
        if let match = firstChannel(on: target, uuids: uuids) {
            DiagnosticsLog.shared.log("SPP found in cached SDP: \(match.string) → rfcomm \(match.channel)")
            return match.channel
        }
        _ = target.performSDPQuery(nil)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.2)
            if let match = firstChannel(on: target, uuids: uuids) {
                DiagnosticsLog.shared.log("SPP found after SDP query: \(match.string) → rfcomm \(match.channel)")
                return match.channel
            }
        }
        DiagnosticsLog.shared.log(
            "no SPP record for \(uuidStrings.count) known UUIDs; device advertises: \(serviceRecordSummary(of: target))")
        return nil
    }

    /// First of the candidate UUIDs that resolves to an RFCOMM channel on the
    /// device. Probing all of them (rather than only the model's expected one)
    /// covers firmware revisions and Samsung's alternative mode, which publish
    /// the control channel under a different service record.
    private nonisolated func firstChannel(
        on target: IOBluetoothDevice,
        uuids: [(string: String, uuid: IOBluetoothSDPUUID)]
    ) -> (string: String, channel: BluetoothRFCOMMChannelID)? {
        for candidate in uuids {
            if let channel = rfcommChannel(on: target, uuid: candidate.uuid) {
                return (candidate.string, channel)
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

    /// Human-readable dump of the device's SDP records, logged when no known SPP
    /// UUID matches. This is the one piece of evidence that makes an otherwise
    /// unreproducible "can't connect" report actionable.
    private nonisolated func serviceRecordSummary(of target: IOBluetoothDevice) -> String {
        guard let records = target.services as? [IOBluetoothSDPServiceRecord], !records.isEmpty else {
            return "none"
        }
        return records.map { record in
            let name = record.getServiceName() ?? "unnamed"
            var channel: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channel) == kIOReturnSuccess else { return name }
            return "\(name) (rfcomm \(channel))"
        }.joined(separator: ", ")
    }

    func disconnect() {
        rfcommChannel?.close()
        rfcommChannel = nil
        connectedDevice?.closeConnection()
        connectedDevice = nil
        isConnected = false
        connectedModel = nil
        connectedName = nil
        isConnecting = false
        cancelAttemptTimeout()
        // Hold off auto-reconnect briefly after a manual disconnect, then allow
        // it again (e.g. the user takes the buds out and puts them back).
        suppressAutoConnect = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.suppressAutoConnect = false
        }
    }

    /// Hands the buds off to the phone: drops the full Bluetooth link (A2DP
    /// audio + SPP control) so the buds fall back to the phone for audio, and
    /// suppresses auto-reconnect until `reclaimFromPhone()` is called. This is
    /// the only way to make the buds release the Mac's audio claim, since macOS
    /// has no API to drop just the A2DP profile while keeping SPP.
    func handOffToPhone() {
        handedOffToPhone = true
        rfcommChannel?.close()
        rfcommChannel = nil
        connectedDevice?.closeConnection()
        isConnected = false
        isConnecting = false
        cancelAttemptTimeout()
    }

    /// Reclaims the buds on the Mac: clears the hand-off and immediately
    /// attempts to reconnect (control channel + audio).
    func reclaimFromPhone() {
        handedOffToPhone = false
        suppressAutoConnect = false
        lastAutoAttempt = nil
        pollAutoConnect()
    }

    /// Polled (~every 2s) by the app: connects to an already-connected paired
    /// Galaxy Buds. More reliable than IOBluetooth connect notifications, which
    /// don't fire dependably on all macOS versions.
    func pollAutoConnect() {
        guard autoConnectArmed, bluetoothReady, !isConnected,
              rfcommChannel == nil, !isConnecting, !suppressAutoConnect,
              !handedOffToPhone else {
            notePollSkip(
                !autoConnectArmed ? "auto-connect not armed"
                    : !bluetoothReady ? "Bluetooth not ready (permission or powered off)"
                    : isConnected ? "already connected"
                    : isConnecting ? "attempt in flight"
                    : suppressAutoConnect ? "suppressed after manual disconnect"
                    : handedOffToPhone ? "handed off to phone"
                    : "channel still open")
            return
        }
        notePollSkip(nil)
        // IOBluetooth `isConnected()` is unreliable for these buds (returns false
        // even while connected), so we can't gate on it. Instead, attempt the
        // connection on a cooldown — it succeeds when the buds are reachable and
        // fails quietly (silentConnect) when they're away.
        if let last = lastAutoAttempt, Date().timeIntervalSince(last) < autoConnectCooldown {
            return
        }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: { isGalaxyBudsName($0.name ?? "") })
        else {
            notePollSkip("no paired Galaxy Buds")
            return
        }

        lastAutoAttempt = Date()
        autoConnectShouldNotify = true
        let model = BudsModel.detect(from: device.name ?? "") ?? .buds4Pro
        connect(to: DiscoveredDevice(device: device), model: model, silent: true)
    }

    /// Logs a poll-skip reason once per change, keeping the 2s poll from
    /// flooding the diagnostics buffer with an unchanging line.
    private func notePollSkip(_ reason: String?) {
        guard reason != lastPollSkipReason else { return }
        lastPollSkipReason = reason
        if let reason {
            DiagnosticsLog.shared.log("auto-connect idle: \(reason)")
        }
    }

    func sendMessage(_ message: SppMessage) {
        guard let channel = rfcommChannel else { return }

        let legacy = connectedModel?.usesLegacyProtocol ?? false
        var encoded = message.encode(legacy: legacy)
        // RFCOMM rejects a single write larger than the channel MTU. Control
        // messages are tiny, but firmware chunks run right up against it, so
        // split on the boundary — the receiver reassembles from the frame's own
        // length field either way.
        let limit = max(1, Int(channel.getMTU()))

        encoded.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            var offset = 0
            while offset < ptr.count {
                let size = min(limit, ptr.count - offset)
                channel.writeSync(
                    baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                    length: UInt16(size)
                )
                offset += size
            }
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

    /// Toggles Samsung Seamless Connection (Bluetooth multipoint between two
    /// host devices). The wire value is inverted: 0 = enabled, 1 = disabled.
    func setSeamlessConnection(_ enabled: Bool) {
        sendMessage(SppMessage(
            messageId: .setSeamlessConnection, payload: Data([enabled ? 0 : 1])))
        status.seamlessConnectionEnabled = enabled
    }

    func setEqualizer(_ preset: EqualizerPreset) {
        if preset == .custom {
            // Custom preset: push the saved band table then select it. The
            // EQUALIZER wire value for custom is 7 (custom index 6 + 1).
            setCustomEqualizer(bands: status.customEqualizerBands)
            return
        }
        // Modern models (Buds3/4 Pro) expect a single byte: 0 = off, else
        // preset+1. Our EqualizerPreset raw values already match that wire scale
        // (off=0, bassBoost=1 … trebleBoost=5).
        let msg = SppMessage(
            messageId: .equalizer,
            payload: Data([UInt8(preset.rawValue)])
        )
        sendMessage(msg)
        status.equalizerPreset = preset
        status.customEqualizerEnabled = false
    }

    /// Sets the custom 9-band equalizer. Each band is a signed gain in -10...+10.
    /// Sends the band table (id 137) then selects the custom preset via the
    /// EQUALIZER message (value 7 = custom index 6 + 1), matching the upstream
    /// protocol verified against Buds4 Pro hardware. Persists the curve so it
    /// survives disconnects/restarts.
    func setCustomEqualizer(bands: [Int]) {
        let clamped = (0..<9).map { i in
            Int8(max(-10, min(10, bands.indices.contains(i) ? bands[i] : 0)))
        }
        var payload = Data([9]) // band count
        for band in clamped {
            payload.append(UInt8(bitPattern: band))
        }
        sendMessage(SppMessage(messageId: .customEqualize, payload: payload))
        sendMessage(SppMessage(messageId: .equalizer, payload: Data([7])))
        let intBands = clamped.map { Int($0) }
        status.customEqualizerBands = intBands
        status.customEqualizerEnabled = true
        status.equalizerPreset = .custom
        saveCustomEqualizer(intBands)
    }

    /// Updates a single custom EQ band in-place and re-pushes the table.
    func setCustomEqualizerBand(_ index: Int, value: Int) {
        var bands = status.customEqualizerBands
        guard bands.indices.contains(index) else { return }
        bands[index] = max(-10, min(10, value))
        setCustomEqualizer(bands: bands)
    }

    /// Asks the device for its full EQ preset band-curve table (id 105). The
    /// response is parsed in `parseCustomEqualizerData`. Used to visualise each
    /// preset's shape on the equalizer graph.
    func requestPresetCurves() {
        sendMessage(SppMessage(messageId: .customEqualizeRecv))
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
            for _ in 0..<100 {
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
        cancelAttemptTimeout()
        isConnecting = false
        silentConnect = false
        isConnected = true
        // A silent attempt no longer clears the error up front, so clear it here
        // once one actually succeeds.
        connectionError = nil
        DiagnosticsLog.shared.log(
            "connected to \(connectedName ?? "?") as \(connectedModel?.rawValue ?? "?"), channel mtu \(channelMtu)")
        stopScanning()
        sendInitialHandshake()
        // The software version gates the firmware update check, so read it as
        // soon as the link is up rather than only when About is opened.
        requestAboutInfo()
        // Fetch the device's EQ preset curves so the graph can visualise each
        // preset's shape. Best-effort: some firmware replies flat or not at all.
        if connectedModel?.supportsCustomEqualizer == true {
            requestPresetCurves()
        }
        // Force Seamless Connection on at connect: without multipoint enabled,
        // a paired phone claims the single bud link and the app can no longer
        // reach the buds. The user controls audio via hand-off instead.
        if connectedModel?.supportsSeamlessConnection == true {
            setSeamlessConnection(true)
        }
        if autoConnectShouldNotify {
            autoConnectShouldNotify = false
            onAutoConnected?()
        }
    }

    /// Aborts the in-flight connection. Surfaces an error only for manual
    /// connects; auto-connect attempts fail quietly.
    private func failConnect(_ message: String) {
        cancelAttemptTimeout()
        isConnecting = false
        rfcommChannel?.close()
        rfcommChannel = nil
        let silent = silentConnect
        silentConnect = false
        if !silent { connectionError = message }
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
        case .fotaOpen, .fotaControl, .fotaDownloadData, .fotaUpdate, .fotaResult:
            firmware.handle(message)
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
        case .customEqualizeRecv:
            parseCustomEqualizerData(message.payload)
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
        DiagnosticsLog.shared.log("software version: \(status.softwareVersion)")
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

    /// Parses the CUSTOM_EQUALIZE_RECV payload:
    ///   [presetCount][bandCount][(presetCount - 1) * bandCount preset table][bandCount custom gains]
    /// The flat first preset is omitted on the wire. Each gain is a signed byte.
    /// Populates `presetEqualizerCurves` (for the graph) and, if the custom
    /// block is present and non-flat, `customEqualizerBands`.
    private func parseCustomEqualizerData(_ payload: Data) {
        guard payload.count >= 2 else { return }
        let presetCount = Int(payload[0])
        let bandCount = Int(payload[1])
        guard bandCount > 0, presetCount >= 1 else { return }

        // Reconstruct the full preset table. Preset 0 (Normal) is flat and not
        // sent; presets 1…presetCount-1 follow at offset 2.
        var curves: [[Int]] = [Array(repeating: 0, count: bandCount)] // Normal
        let tableStart = 2
        for p in 1..<presetCount {
            let base = tableStart + (p - 1) * bandCount
            guard base + bandCount <= payload.count else { break }
            var bands: [Int] = []
            for i in 0..<bandCount {
                bands.append(Int(Int8(bitPattern: payload[base + i])))
            }
            curves.append(bands)
        }
        if !curves.isEmpty { status.presetEqualizerCurves = curves }

        // Custom band gains follow the preset table.
        let customStart = 2 + (presetCount - 1) * bandCount
        guard customStart + bandCount <= payload.count else { return }
        var custom: [Int] = []
        for i in 0..<bandCount {
            custom.append(Int(Int8(bitPattern: payload[customStart + i])))
        }
        // Only adopt the device's custom bands if they're non-flat AND the user
        // has no saved curve of their own (first-connect seeding).
        if !custom.allSatisfy({ $0 == 0 }), status.customEqualizerBands.allSatisfy({ $0 == 0 }) {
            // CUSTOM_EQUALIZE (send) and the EQ graph are both fixed at 9 bands,
            // so normalise here rather than letting a different firmware band
            // count reach the UI.
            status.customEqualizerBands = (0..<9).map {
                custom.indices.contains($0) ? custom[$0] : 0
            }
        }
    }

    // MARK: - Custom EQ persistence

    /// UserDefaults key for the persisted custom EQ band table.
    private let customEQKey = "com.nivorbit.budsapp.customEqualizerBands"

    /// Loads the saved custom EQ bands into `status`, if any. Called once on
    /// startup so the user's last custom curve survives reconnects/restarts.
    private func loadCustomEqualizer() {
        if let saved = UserDefaults.standard.array(forKey: customEQKey) as? [Int],
           saved.count == 9 {
            status.customEqualizerBands = saved
        }
    }

    private func saveCustomEqualizer(_ bands: [Int]) {
        UserDefaults.standard.set(bands, forKey: customEQKey)
    }

    private func parseStatusUpdate(_ payload: Data) {
        let isLegacy = connectedModel?.usesLegacyProtocol ?? false
        if isLegacy {
            // 1st-gen Buds: [earType, batteryL, batteryR, ...]
            guard payload.count >= 3 else { return }
            status.batteryLeft = Int(payload[1])
            status.batteryRight = Int(payload[2])
        } else {
            // Modern models: [revision, batteryL, batteryR, isCoupled, mainConn,
            // placement, batteryCase, ...] — note batteryL is at offset 1, NOT 0.
            // Reading offset 0 as batteryLeft was surfacing the firmware revision
            // (typically 1) as "1%" for the left bud.
            guard payload.count >= 3 else { return }
            status.batteryLeft = Int(payload[1])
            status.batteryRight = Int(payload[2])
        }
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
        // payload[8] = AdjustSoundSync on modern models. payload[9] = EQ preset
        // (0=off, 1..5 = preset+1, 7 = custom). payload[12] = noise control mode
        // (0=Off,1=ANC,2=Ambient,3=Adaptive). Per GalaxyBudsClient's decoder.
        let eqMode = Int(payload[9])
        if eqMode == 7 {
            status.equalizerPreset = .custom
            status.customEqualizerEnabled = true
        } else {
            status.equalizerPreset = EqualizerPreset(rawValue: eqMode) ?? .off
            status.customEqualizerEnabled = false
        }
        status.noiseControlMode = NoiseControlMode(rawValue: Int(payload[12])) ?? .off

        // Device color: the left earbud's colour sits as a little-endian Int16
        // at payload[14..16]. We only need the low byte to resolve our enum, and
        // older firmware may send fewer than 16 bytes.
        if payload.count >= 16 {
            let colorByte = payload[14]
            status.deviceColor = BudsStatus.DeviceColor(rawValue: Int(colorByte)) ?? .black
        }

        // payload[19] = Seamless Connection (inverted: 0 = enabled). Available
        // on every model from Buds Live onward; older firmware omits the field.
        if payload.count > 19 {
            status.seamlessConnectionEnabled = (payload[19] == 0)
        }

        parseSoundAndAncDetails(payload)
    }

    /// Reads the Sound & ANC detail fields from the Buds3/4 Pro extended-status
    /// payload. Offsets follow GalaxyBudsClient's `>= Buds3 Pro` decoder path
    /// (which differ from the BudsPro/Buds2Pro paths). Each offset is guarded
    /// since older firmware sends shorter payloads.
    private func parseSoundAndAncDetails(_ payload: Data) {
        func byte(_ i: Int) -> Int? { payload.count > i ? Int(payload[i]) : nil }

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

        // Buds3/4 Pro detail fields (revision-gated in the upstream decoder).
        if let v = byte(23) { status.ambientSoundVolume = v }
        // payload[24] = ANC strength (0 = Low, 1 = High).
        if let v = byte(24) { status.ancLevelHigh = v == 1 }
        if let v = byte(26) { status.detectConversations = v == 1 }
        if let v = byte(27) { status.detectConversationsDuration = min(v, 2) }
        // rev8+: one-earbud NC + ambient customisation.
        if let v = byte(32) { status.ncWithOneEarbud = v == 1 }
        if let v = byte(33) { status.ambientCustomEnabled = v == 1 }
        if let v = byte(34) {
            status.ambientCustomLeft = (v >> 4) & 0x0F
            status.ambientCustomRight = v & 0x0F
        }
        if let v = byte(35) { status.ambientTone = v }
        // rev9+: sidetone; rev10+: call path control (inverted).
        if let v = byte(36) { status.sidetone = v == 1 }
        if let v = byte(37) { status.ambientDuringCalls = v == 0 }
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
            DiagnosticsLog.shared.log("CoreBluetooth state: \(state.rawValue)")
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
        DiagnosticsLog.shared.log("rfcomm channel closed")
        Task { @MainActor in
            self.isConnected = false
            self.rfcommChannel = nil
            self.firmware.connectionLost()
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
