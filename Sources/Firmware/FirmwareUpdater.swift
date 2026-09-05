import Foundation

/// Drives a firmware transfer over the SPP control channel.
///
/// The buds run the show: the host opens a session with the segment table, and
/// from then on answers whatever the device asks for — an MTU, a segment to
/// start, a range of chunks — until the device reports it has copied and
/// verified the image. The host never pushes data unprompted.
@Observable
@MainActor
final class FirmwareUpdater {
    enum Phase: Equatable {
        case idle
        /// FOTA_OPEN sent; waiting for the device to accept the session.
        case preparing
        /// Streaming segments; `fraction` is 0...1 of the image sent.
        case sending(fraction: Double)
        /// All data delivered; the buds are writing it to flash.
        case installing(percent: Int)
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        switch phase {
        case .preparing, .sending, .installing: true
        case .idle, .finished, .failed: false
        }
    }

    /// Sends one message to the buds. Injected by `BluetoothManager`.
    var send: ((SppMessage) -> Void)?
    /// Fired once the transfer ends, with `true` when the device accepted the
    /// image. The link must be re-established afterwards either way: the buds
    /// reboot into the new firmware on their own.
    var onFinished: ((Bool) -> Void)?

    /// Ceiling from the protocol; the device proposes its own value and we take
    /// the smaller of the two (further capped by the RFCOMM channel's MTU).
    private static let maxMtu = 650
    private static let sessionTimeout: TimeInterval = 20
    private static let stallTimeout: TimeInterval = 60

    private var binary: FirmwareBinary?
    private var mtu = 0
    private var mtuCeiling = FirmwareUpdater.maxMtu
    private var currentSegmentId = 0
    private var watchdog: Task<Void, Never>?

    // MARK: - Control

    /// Begins the transfer. `channelMtu` is the RFCOMM channel's own limit; the
    /// negotiated chunk size stays under it so no frame is dropped mid-flight.
    func start(binary: FirmwareBinary, channelMtu: Int) {
        guard !isRunning else { return }
        self.binary = binary
        // A frame costs 7 bytes of SPP framing plus the 4-byte fragment header
        // that rides in front of every chunk.
        mtuCeiling = max(64, min(Self.maxMtu, channelMtu - 11))
        mtu = 0
        currentSegmentId = 0
        phase = .preparing
        DiagnosticsLog.shared.log(
            "fota: opening session for \(binary.buildName), \(binary.segments.count) segments, \(binary.totalSize) bytes, mtu ceiling \(mtuCeiling)")
        send?(SppMessage(messageId: .fotaOpen, payload: binary.serializeTable()))
        armWatchdog(Self.sessionTimeout, reason: String(
            localized: "The earbuds didn't start the update."))
    }

    func cancel() {
        guard isRunning else { return }
        finish(success: false, message: String(localized: "The update was cancelled."))
    }

    /// The control channel dropped mid-transfer. Anything already written to the
    /// buds is incomplete, so the transfer has to be reported as failed.
    func connectionLost() {
        guard isRunning else { return }
        finish(success: false, message: String(
            localized: "The earbuds disconnected during the update."))
    }

    // MARK: - Device messages

    func handle(_ message: SppMessage) {
        guard isRunning, let binary else { return }
        switch message.messageId {
        case .fotaOpen:
            handleSession(message.payload)
        case .fotaControl:
            handleControl(message.payload)
        case .fotaDownloadData:
            handleDataRequest(message.payload, binary: binary)
        case .fotaUpdate:
            handleUpdate(message.payload)
        case .fotaResult:
            handleResult(message.payload)
        default:
            break
        }
    }

    private func handleSession(_ payload: Data) {
        guard let code = payload.first else { return }
        DiagnosticsLog.shared.log("fota: session result \(code)")
        guard code == 0 else {
            finish(success: false, message: String(
                localized: "The earbuds refused to start the update.") + " (\(code))")
            return
        }
        armWatchdog(Self.sessionTimeout, reason: String(
            localized: "The earbuds stopped responding while preparing."))
    }

    private func handleControl(_ payload: Data) {
        guard payload.count >= 3 else { return }
        let controlId = payload[payload.startIndex]
        let parameter = Int(payload[payload.startIndex + 1]) | (Int(payload[payload.startIndex + 2]) << 8)

        switch controlId {
        case 0: // the device proposes an MTU
            mtu = max(1, min(parameter, mtuCeiling))
            DiagnosticsLog.shared.log("fota: mtu proposed \(parameter), using \(mtu)")
            reply(controlId: 0, parameter: mtu)
        case 1: // the device is ready for a segment
            currentSegmentId = parameter
            DiagnosticsLog.shared.log("fota: ready for segment \(parameter)")
            reply(controlId: 1, parameter: parameter)
        default:
            DiagnosticsLog.shared.log("fota: unknown control id \(controlId)")
            return
        }
        armWatchdog(Self.stallTimeout, reason: String(
            localized: "The earbuds stopped responding during the update."))
    }

    private func reply(controlId: Int, parameter: Int) {
        var payload = Data([UInt8(controlId)])
        payload.append(littleEndian: UInt16(truncatingIfNeeded: parameter))
        send?(SppMessage(messageId: .fotaControl, payload: payload, isResponse: true))
    }

    /// The device asks for `count` chunks starting at `offset` within the
    /// current segment; each is answered as its own fragment frame.
    private func handleDataRequest(_ payload: Data, binary: FirmwareBinary) {
        guard payload.count >= 5, mtu > 0 else { return }
        let base = payload.startIndex
        let offset = Int(payload[base]) | (Int(payload[base + 1]) << 8)
            | (Int(payload[base + 2]) << 16) | (Int(payload[base + 3] & 0x7F) << 24)
        let isNak = (payload[base + 3] & 0x80) != 0
        let count = Int(payload[base + 4])

        guard let segment = binary.segment(id: currentSegmentId) else {
            finish(success: false, message: String(
                localized: "The earbuds asked for a part the firmware doesn't contain."))
            return
        }
        if isNak {
            // The device re-requests a range it didn't like; resending from the
            // stated offset is the recovery the protocol expects.
            DiagnosticsLog.shared.log("fota: NAK, resending segment \(currentSegmentId) from \(offset)")
        }

        phase = .sending(fraction: fractionSent(segment: segment, offset: offset, binary: binary))

        for index in 0..<count {
            let chunkOffset = offset + mtu * index
            guard chunkOffset < segment.size else { break }
            let isLast = chunkOffset + mtu >= segment.size
            let chunkSize = isLast ? segment.size - chunkOffset : mtu

            // Header is the offset, with the top bit set on every chunk that is
            // *not* the segment's last one.
            var header = UInt32(chunkOffset) & 0x7FFF_FFFF
            if !isLast { header |= 0x8000_0000 }

            var body = Data()
            body.append(littleEndian: header)
            let start = segment.data.startIndex + chunkOffset
            body.append(segment.data[start..<(start + chunkSize)])

            send?(SppMessage(
                messageId: .fotaDownloadData, payload: body,
                isResponse: true, isFragment: true))
        }
        armWatchdog(Self.stallTimeout, reason: String(
            localized: "The earbuds stopped responding during the update."))
    }

    /// Progress from the device's own position, which survives NAKs and
    /// retransmits better than counting bytes we've pushed.
    private func fractionSent(segment: FirmwareSegment, offset: Int, binary: FirmwareBinary) -> Double {
        let precedingBytes = binary.segments
            .prefix { $0.id != segment.id }
            .reduce(0) { $0 + $1.size }
        let total = max(binary.totalSize, precedingBytes + segment.size)
        guard total > 0 else { return 0 }
        return min(1, Double(precedingBytes + offset) / Double(total))
    }

    private func handleUpdate(_ payload: Data) {
        guard payload.count >= 2 else { return }
        let base = payload.startIndex
        let updateId = payload[base]
        let value = Int(payload[base + 1])
        let resultCode = payload.count >= 3 ? Int(payload[base + 2]) : 0

        switch updateId {
        case 0:
            phase = .installing(percent: min(100, max(0, value)))
            armWatchdog(Self.stallTimeout, reason: String(
                localized: "The earbuds stopped responding while installing."))
        case 1:
            send?(SppMessage(messageId: .fotaUpdate, payload: Data([1]), isResponse: true))
            DiagnosticsLog.shared.log("fota: state change \(value), result \(resultCode)")
            if value == 0 {
                finish(success: true, message: nil)
            } else {
                finish(success: false, message: String(
                    localized: "The earbuds couldn't install the firmware.") + " (\(resultCode))")
            }
        default:
            break
        }
    }

    private func handleResult(_ payload: Data) {
        send?(SppMessage(messageId: .fotaResult, payload: Data([1]), isResponse: true))
        let result = payload.first.map(Int.init) ?? -1
        let errorCode = payload.count >= 2 ? Int(payload[payload.startIndex + 1]) : 0
        DiagnosticsLog.shared.log("fota: result \(result), error \(errorCode)")
        if result == 0 {
            finish(success: true, message: nil)
        } else {
            finish(success: false, message: String(
                localized: "The earbuds couldn't verify the firmware.") + " (\(errorCode))")
        }
    }

    // MARK: - Private

    private func armWatchdog(_ seconds: TimeInterval, reason: String) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.finish(success: false, message: reason)
        }
    }

    private func finish(success: Bool, message: String?) {
        watchdog?.cancel()
        watchdog = nil
        binary = nil
        mtu = 0
        phase = success ? .finished : .failed(message ?? String(localized: "The update failed."))
        DiagnosticsLog.shared.log("fota: finished, success=\(success) \(message ?? "")")
        onFinished?(success)
    }

    /// Clears a terminal state so the page can be used again.
    func reset() {
        guard !isRunning else { return }
        phase = .idle
    }
}
