import Foundation
import os

/// In-memory ring buffer of timestamped diagnostic lines, exported by the About
/// page's "Copy diagnostics" button.
///
/// The app writes no log files, which makes connection failures on hardware we
/// can't reproduce impossible to diagnose from a bug report. Everything the
/// connection path learns (SDP records, chosen RFCOMM channel, attempt timings)
/// lands here so a reporter can paste it into an issue.
///
/// Thread-safe: the connection path logs from a detached resolve thread as well
/// as the main actor.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    /// Keeps the buffer bounded; a connect attempt logs ~20 lines, so this holds
    /// many sessions' worth without growing unbounded over days of uptime.
    private let capacity = 400

    private let lock = NSLock()
    private var lines: [String] = []
    private let started = Date()

    /// Mirrored to the unified log so the trail survives a crash and can be read
    /// with `log show --predicate 'subsystem == "com.nivorbit.galaxybuds"'` when a
    /// reporter can't reach the About page.
    private let logger = Logger(subsystem: "com.nivorbit.galaxybuds", category: "connection")

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    func log(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        let line = "[\(formatter.string(from: Date()))] \(text)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
    }

    /// The full report: an environment header plus the buffered lines, ready to
    /// paste into a GitHub issue.
    func export(deviceSummary: String) -> String {
        lock.lock()
        let body = lines.joined(separator: "\n")
        lock.unlock()

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        return """
            Galaxy Buds for Mac \(version) (\(build))
            macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
            Uptime \(Int(Date().timeIntervalSince(started)))s
            \(deviceSummary)

            \(body)
            """
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
