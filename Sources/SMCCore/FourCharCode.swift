import Foundation

public enum FourCharCode {
    public static func make(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else {
            throw SMCError.invalidKey(string)
        }

        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    public static func unchecked(_ string: String) -> UInt32 {
        guard let value = try? make(string) else {
            preconditionFailure("SMC four character codes must be exactly four bytes")
        }
        return value
    }

    public static func string(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        return bytes.map { byte in
            if byte == 0 {
                return " "
            }
            if (0x20...0x7e).contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                return String(Character(scalar))
            }
            return "?"
        }.joined()
    }

    public static func normalizedStrings(_ value: UInt32) -> Set<String> {
        [string(value), string(value.byteSwapped)]
    }
}
