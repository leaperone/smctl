import Foundation

public typealias SMCByteTuple20 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public typealias SMCByteTuple32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public struct SMCVersion {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0

    public init() {}
}

public struct SMCKeyInfo: Codable, Equatable {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init(dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.dataAttributes = dataAttributes
    }

    public var dataTypeString: String {
        FourCharCode.string(dataType)
    }
}

public struct SMCParamStruct {
    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData: SMCByteTuple20 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
    public var keyInfo = SMCKeyInfo()
    // Explicit padding: SMCKeyInfo is 9 bytes (size), but the C ABI pads it to 12.
    // Swift packs the next field at offset 37 without this, breaking the kernel contract
    // (result must sit at offset 40, total struct size 80).
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCByteTuple32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}

    public func bytesArray(prefix count: Int? = nil) -> [UInt8] {
        let allBytes = withUnsafeBytes(of: bytes) { rawBuffer in
            Array(rawBuffer)
        }

        if let count {
            return Array(allBytes.prefix(count))
        }

        return allBytes
    }
}

public enum SMCParamStructLayout {
    public static let stride = MemoryLayout<SMCParamStruct>.stride
    public static let size = MemoryLayout<SMCParamStruct>.size
}
