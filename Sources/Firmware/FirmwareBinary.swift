import Foundation

/// One flashable region of a Samsung firmware image. The header table lists
/// every segment up front; the buds later ask for them one at a time by id.
struct FirmwareSegment: Sendable {
    let id: Int
    let crc32: UInt32
    let position: Int
    let size: Int
    let data: Data
}

enum FirmwareParseError: LocalizedError {
    case tooShort
    case badMagic
    case emptyImage
    case noSegments
    case truncatedSegment(id: Int)

    var errorDescription: String? {
        switch self {
        case .tooShort, .truncatedSegment:
            return String(localized: "The firmware file is incomplete.")
        case .badMagic:
            return String(localized: "This file isn't Galaxy Buds firmware.")
        case .emptyImage, .noSegments:
            return String(localized: "The firmware file contains no data.")
        }
    }
}

/// A parsed Samsung `.bin` firmware image.
///
/// Layout is little-endian throughout: a `0xCAFECAFE` magic, the total size,
/// the segment count, then one 16-byte descriptor per segment (id, CRC32,
/// absolute offset, size). The image's own CRC32 is the final four bytes.
struct FirmwareBinary: Sendable {
    static let magic: UInt32 = 0xCAFE_CAFE
    /// Internal Samsung debug builds ("BCOM"), which are not meant for retail
    /// hardware and must never be flashed.
    static let debugMagic: UInt32 = 0x4243_4F4D

    let buildName: String
    let totalSize: Int
    let crc32: UInt32
    let segments: [FirmwareSegment]

    init(data: Data, buildName: String) throws {
        guard data.count >= 16 else { throw FirmwareParseError.tooShort }
        self.buildName = buildName

        var cursor = 0
        func readUInt32() -> UInt32 {
            defer { cursor += 4 }
            return data.withUnsafeBytes { raw -> UInt32 in
                var value: UInt32 = 0
                for offset in (0..<4).reversed() {
                    value = (value << 8) | UInt32(raw[cursor + offset])
                }
                return value
            }
        }

        let magic = readUInt32()
        guard magic != Self.debugMagic else { throw FirmwareParseError.badMagic }
        guard magic == Self.magic else { throw FirmwareParseError.badMagic }

        totalSize = Int(readUInt32())
        guard totalSize > 0 else { throw FirmwareParseError.emptyImage }

        let segmentCount = Int(readUInt32())
        guard segmentCount > 0, segmentCount <= 255 else { throw FirmwareParseError.noSegments }
        // Each descriptor is four 32-bit fields; the CRC32 trailer is 4 more.
        guard data.count >= 12 + segmentCount * 16 + 4 else { throw FirmwareParseError.tooShort }

        var parsed: [FirmwareSegment] = []
        parsed.reserveCapacity(segmentCount)
        for _ in 0..<segmentCount {
            let id = Int(readUInt32())
            let segmentCrc = readUInt32()
            let position = Int(readUInt32())
            let size = Int(readUInt32())
            guard position >= 0, size >= 0, position + size <= data.count else {
                throw FirmwareParseError.truncatedSegment(id: id)
            }
            let start = data.startIndex + position
            parsed.append(FirmwareSegment(
                id: id,
                crc32: segmentCrc,
                position: position,
                size: size,
                data: Data(data[start..<(start + size)])
            ))
        }
        segments = parsed

        cursor = data.count - 4
        crc32 = readUInt32()
    }

    func segment(id: Int) -> FirmwareSegment? {
        segments.first { $0.id == id }
    }

    /// The table sent in FOTA_OPEN: the image CRC32, the segment count, then a
    /// (id, size, crc32) triple per segment. The buds use it to plan the
    /// transfer and to verify each segment as it lands.
    func serializeTable() -> Data {
        var payload = Data()
        payload.append(littleEndian: crc32)
        payload.append(UInt8(segments.count))
        for segment in segments {
            payload.append(UInt8(segment.id))
            payload.append(littleEndian: UInt32(segment.size))
            payload.append(littleEndian: segment.crc32)
        }
        return payload
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
}
