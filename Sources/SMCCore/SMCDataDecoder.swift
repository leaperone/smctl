import Foundation

public enum SMCDecodedValue: Equatable, Codable {
    case number(Double)
    case unsigned(UInt32)
    case bytes([UInt8])

    public var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .unsigned(let value):
            return Double(value)
        case .bytes:
            return nil
        }
    }
}

public enum SMCDataDecoder {
    public static func decode(key: String, bytes: [UInt8], dataType: UInt32) throws -> SMCDecodedValue {
        let types = FourCharCode.normalizedStrings(dataType)

        if types.contains("flt ") || types.contains("flt") {
            try require(bytes, count: 4, key: key, type: "flt")
            let bitPattern = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return .number(Double(Float(bitPattern: bitPattern)))
        }

        if types.contains("fpe2") {
            try require(bytes, count: 2, key: key, type: "fpe2")
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return .number(Double(raw) / 4.0)
        }

        if types.contains("sp78") {
            try require(bytes, count: 2, key: key, type: "sp78")
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let signed = Int16(bitPattern: raw)
            return .number(Double(signed) / 256.0)
        }

        if types.contains("ui8 ") || types.contains("ui8") {
            try require(bytes, count: 1, key: key, type: "ui8")
            return .unsigned(UInt32(bytes[0]))
        }

        if types.contains("ui16") {
            try require(bytes, count: 2, key: key, type: "ui16")
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return .unsigned(UInt32(raw))
        }

        if types.contains("ui32") {
            try require(bytes, count: 4, key: key, type: "ui32")
            let raw = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            return .unsigned(raw)
        }

        return .bytes(bytes)
    }

    private static func require(_ bytes: [UInt8], count: Int, key: String, type: String) throws {
        guard bytes.count >= count else {
            throw SMCError.malformedData(key: key, type: type, expected: count, actual: bytes.count)
        }
    }
}
