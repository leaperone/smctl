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

/// Byte order of multi-byte SMC integer types (ui16/ui32/si16/si32).
///
/// Apple Silicon SMC stores integers little-endian; Intel SMC stores them
/// big-endian. Verified on M2 (B0AV as little-endian matches the
/// AppleSmartBattery IOKit voltage within a few mV; big-endian decodes to
/// garbage). `flt` is always little-endian IEEE 754, and the legacy
/// fixed-point types (fpe2/sp78) are Intel-era formats defined big-endian.
public enum SMCIntegerByteOrder: Sendable {
    case little
    case big

    public static var platform: SMCIntegerByteOrder {
        #if arch(arm64)
        return .little
        #else
        return .big
        #endif
    }
}

public enum SMCDataDecoder {
    public static func decode(
        key: String,
        bytes: [UInt8],
        dataType: UInt32,
        integerByteOrder: SMCIntegerByteOrder = .platform
    ) throws -> SMCDecodedValue {
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

        if types.contains("si8 ") || types.contains("si8") {
            try require(bytes, count: 1, key: key, type: "si8")
            return .number(Double(Int8(bitPattern: bytes[0])))
        }

        if types.contains("ui16") {
            try require(bytes, count: 2, key: key, type: "ui16")
            return .unsigned(UInt32(uint16(bytes, integerByteOrder)))
        }

        if types.contains("si16") {
            try require(bytes, count: 2, key: key, type: "si16")
            return .number(Double(Int16(bitPattern: uint16(bytes, integerByteOrder))))
        }

        if types.contains("ui32") {
            try require(bytes, count: 4, key: key, type: "ui32")
            return .unsigned(uint32(bytes, integerByteOrder))
        }

        if types.contains("si32") {
            try require(bytes, count: 4, key: key, type: "si32")
            return .number(Double(Int32(bitPattern: uint32(bytes, integerByteOrder))))
        }

        return .bytes(bytes)
    }

    private static func uint16(_ bytes: [UInt8], _ order: SMCIntegerByteOrder) -> UInt16 {
        switch order {
        case .big:
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        case .little:
            return UInt16(bytes[1]) << 8 | UInt16(bytes[0])
        }
    }

    private static func uint32(_ bytes: [UInt8], _ order: SMCIntegerByteOrder) -> UInt32 {
        switch order {
        case .big:
            return UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        case .little:
            return UInt32(bytes[3]) << 24
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[0])
        }
    }

    private static func require(_ bytes: [UInt8], count: Int, key: String, type: String) throws {
        guard bytes.count >= count else {
            throw SMCError.malformedData(key: key, type: type, expected: count, actual: bytes.count)
        }
    }
}
