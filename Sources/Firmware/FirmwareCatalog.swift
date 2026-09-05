import Foundation

/// One firmware build listed by the community archive.
struct FirmwareRelease: Decodable, Identifiable, Sendable {
    let buildName: String
    let model: String
    let year: Int?
    let month: Int?
    let revision: Int?

    var id: String { buildName }

    /// "April 2026 · rev 2" — the archive exposes no changelog, so the build
    /// date is all we can show the user about what they're installing.
    var releaseDescription: String {
        var parts: [String] = []
        if let year, let month, (1...12).contains(month) {
            var components = DateComponents()
            components.year = year
            components.month = month
            if let date = Calendar(identifier: .gregorian).date(from: components) {
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("yMMMM")
                parts.append(formatter.string(from: date))
            }
        }
        if let revision {
            parts.append(String(localized: "revision") + " \(revision)")
        }
        return parts.joined(separator: " · ")
    }
}

enum FirmwareCatalogError: LocalizedError {
    case unsupportedModel
    case server(status: Int)
    case notFirmware

    var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return String(localized: "No firmware is published for this model.")
        case .server(let status):
            return String(localized: "The firmware archive couldn't be reached.") + " (\(status))"
        case .notFirmware:
            return String(localized: "The download wasn't a firmware image.")
        }
    }
}

/// Reads the community firmware archive that mirrors Samsung's builds. Samsung
/// publishes no public API of its own, so this is the same source
/// GalaxyBudsClient uses.
struct FirmwareCatalog: Sendable {
    private static let base = URL(string: "https://fw.timschneeberger.me/v3")!

    /// Firmware images run into the megabytes over a slow link, so allow a
    /// generous per-request window rather than the 60s default.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Every build published for the model, newest first.
    func releases(for model: BudsModel) async throws -> [FirmwareRelease] {
        guard let name = model.firmwareArchiveName else { throw FirmwareCatalogError.unsupportedModel }
        let url = Self.base.appending(path: "firmware").appending(path: name)
        let (data, response) = try await Self.session.data(from: url)
        try Self.check(response)
        let releases = try JSONDecoder().decode([FirmwareRelease].self, from: data)
        return releases.sorted { $0.buildName > $1.buildName }
    }

    func download(_ release: FirmwareRelease) async throws -> Data {
        let url = Self.base
            .appending(path: "firmware")
            .appending(path: "download")
            .appending(path: release.buildName)
        let (data, response) = try await Self.session.data(from: url)
        try Self.check(response)
        guard data.count > 16 else { throw FirmwareCatalogError.notFirmware }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FirmwareCatalogError.server(status: http.statusCode)
        }
    }
}

extension BudsModel {
    /// The archive's identifier for this model. Matches the upstream `Models`
    /// enum names the API is keyed by.
    var firmwareArchiveName: String? {
        switch self {
        case .buds: "Buds"
        case .budsPlus: "BudsPlus"
        case .budsLive: "BudsLive"
        case .budsPro: "BudsPro"
        case .buds2: "Buds2"
        case .buds2Pro: "Buds2Pro"
        case .budsFe: "BudsFe"
        case .budsCore: "BudsCore"
        case .buds3: "Buds3"
        case .buds3Pro: "Buds3Pro"
        case .buds3Fe: "Buds3Fe"
        case .buds4: "Buds4"
        case .buds4Pro: "Buds4Pro"
        }
    }
}

/// Samsung build names end in three base-36-ish version characters (e.g.
/// `R640XXU0AZD2`), ordered by this alphabet. Comparing those three positions
/// is how the official app decides whether a build is newer.
enum FirmwareVersion {
    private static let order = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// True when `candidate` is strictly newer than `current`. Returns false
    /// whenever either version can't be interpreted — refusing to offer an
    /// update is the safe answer, since a wrong "newer" verdict flashes a
    /// downgrade.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard current.count == 12, candidate.count == 12 else { return false }
        let currentSuffix = Array(current.suffix(3))
        let candidateSuffix = Array(candidate.suffix(3))
        for index in 0..<3 {
            guard let currentRank = order.firstIndex(of: currentSuffix[index]),
                  let candidateRank = order.firstIndex(of: candidateSuffix[index])
            else { return false }
            if currentRank != candidateRank { return currentRank < candidateRank }
        }
        return false
    }
}
