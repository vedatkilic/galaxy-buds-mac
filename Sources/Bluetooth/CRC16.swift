import Foundation

enum CRC16 {
    static func ccitt(_ data: Data) -> UInt16 {
        // CRC-16/CCITT, polynomial 0x1021, initial value 0x0000 (matches the
        // Galaxy Buds firmware / GalaxyBudsClient). A non-zero seed makes the
        // buds silently reject every outgoing command.
        var crc: UInt16 = 0x0000
        for byte in data {
            crc = crc ^ UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }
}
