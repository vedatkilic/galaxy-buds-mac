import Foundation

struct SppMessage: Sendable {
    let messageId: MessageId
    let payload: Data
    let isResponse: Bool

    init(messageId: MessageId, payload: Data = Data(), isResponse: Bool = false) {
        self.messageId = messageId
        self.payload = payload
        self.isResponse = isResponse
    }

    func encode(legacy: Bool) -> Data {
        if legacy {
            return encodeLegacy()
        }
        return encodeStandard()
    }

    private func encodeLegacy() -> Data {
        var data = Data()
        let payloadSize = 1 + payload.count + 2 // msgId + payload + CRC
        data.append(0xFE)
        data.append(isResponse ? 1 : 0)
        data.append(UInt8(payloadSize))
        data.append(messageId.rawValue)
        data.append(payload)

        var crcData = Data([messageId.rawValue])
        crcData.append(payload)
        let crc = CRC16.ccitt(crcData)
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8(crc >> 8))

        data.append(0xEE)
        return data
    }

    private func encodeStandard() -> Data {
        var data = Data()
        let payloadSize = 1 + payload.count + 2 // msgId + payload + CRC

        var header: UInt16 = UInt16(payloadSize) & 0x3FF
        if isResponse {
            header |= 0x1000
        }

        data.append(0xFD)
        data.append(UInt8(header & 0xFF))
        data.append(UInt8(header >> 8))
        data.append(messageId.rawValue)
        data.append(payload)

        var crcData = Data([messageId.rawValue])
        crcData.append(payload)
        let crc = CRC16.ccitt(crcData)
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8(crc >> 8))

        data.append(0xDD)
        return data
    }

    static func decode(_ data: Data) -> SppMessage? {
        guard data.count >= 5 else { return nil }

        let preamble = data[data.startIndex]

        switch preamble {
        case 0xFE:
            return decodeLegacy(data)
        case 0xFD:
            return decodeStandard(data)
        case 0xFC:
            return decodeSmep(data)
        default:
            return nil
        }
    }

    private static func decodeLegacy(_ data: Data) -> SppMessage? {
        guard data.count >= 6 else { return nil }
        let base = data.startIndex
        guard data[base] == 0xFE, data[data.endIndex - 1] == 0xEE else { return nil }

        let isResponse = data[base + 1] == 1
        guard let msgId = MessageId(rawValue: data[base + 3]) else { return nil }

        let payloadSize = Int(data[base + 2])
        let payloadEnd = base + 3 + payloadSize - 2
        let payloadStart = base + 4

        let payload: Data
        if payloadEnd > payloadStart {
            payload = Data(data[payloadStart..<payloadEnd])
        } else {
            payload = Data()
        }

        return SppMessage(messageId: msgId, payload: payload, isResponse: isResponse)
    }

    private static func decodeStandard(_ data: Data) -> SppMessage? {
        guard data.count >= 7 else { return nil }
        let base = data.startIndex
        guard data[base] == 0xFD, data[data.endIndex - 1] == 0xDD else { return nil }

        let header = UInt16(data[base + 1]) | (UInt16(data[base + 2]) << 8)
        let isResponse = (header & 0x1000) != 0

        guard let msgId = MessageId(rawValue: data[base + 3]) else { return nil }

        let totalPayloadSize = Int(header & 0x3FF) // includes msgId + payload + CRC
        let payloadDataSize = totalPayloadSize - 3 // subtract msgId(1) + CRC(2)

        let payloadStart = base + 4
        let payload: Data
        if payloadDataSize > 0, payloadStart + payloadDataSize <= data.endIndex - 3 {
            payload = Data(data[payloadStart..<(payloadStart + payloadDataSize)])
        } else {
            payload = Data()
        }

        return SppMessage(messageId: msgId, payload: payload, isResponse: isResponse)
    }

    private static func decodeSmep(_ data: Data) -> SppMessage? {
        guard data.count >= 7 else { return nil }
        let base = data.startIndex
        guard data[base] == 0xFC, data[data.endIndex - 1] == 0xCC else { return nil }

        let header = UInt16(data[base + 1]) | (UInt16(data[base + 2]) << 8)
        let isResponse = (header & 0x1000) != 0

        guard let msgId = MessageId(rawValue: data[base + 3]) else { return nil }

        let totalPayloadSize = Int(header & 0x3FF)
        let payloadDataSize = totalPayloadSize - 3

        let payloadStart = base + 4
        let payload: Data
        if payloadDataSize > 0, payloadStart + payloadDataSize <= data.endIndex - 3 {
            payload = Data(data[payloadStart..<(payloadStart + payloadDataSize)])
        } else {
            payload = Data()
        }

        return SppMessage(messageId: msgId, payload: payload, isResponse: isResponse)
    }
}
