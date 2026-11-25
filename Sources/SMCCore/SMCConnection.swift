import Darwin
import Foundation
import IOKit
import ProductIdentity

public final class SMCConnection: SMCWriteBackend, @unchecked Sendable {
    private static let selector: UInt32 = 2
    private static let commandReadValue: UInt8 = 5
    private static let commandWriteValue: UInt8 = 6
    private static let commandGetKeyByIndex: UInt8 = 8
    private static let commandReadKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private let queue = DispatchQueue(label: "\(ProductIdentity.logSubsystem).smc-connection")
    /// Key size/type never change while the system runs; caching them halves the
    /// IOKit round trips of every read and write. Only successful lookups are cached.
    private var keyInfoCache: [String: SMCKeyInfo] = [:]
    private let keyInfoLock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw SMCError.openFailed(result)
        }
    }

    deinit {
        if connection != 0 {
            _ = queue.sync {
                IOServiceClose(connection)
            }
        }
    }

    public func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoLock.withLock({ keyInfoCache[key] }) {
            return cached
        }
        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.data8 = Self.commandReadKeyInfo
        let info = try call(input).keyInfo
        keyInfoLock.withLock { keyInfoCache[key] = info }
        return info
    }

    public func readValue(_ key: String) throws -> SMCReadValue {
        let info = try readKeyInfo(key)

        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.keyInfo = info
        input.data8 = Self.commandReadValue

        let output = try call(input)
        let bytes = output.bytesArray(prefix: Int(info.dataSize))
        return SMCReadValue(key: key, info: info, bytes: bytes)
    }

    public func enumerateKeys(limit: Int? = nil) throws -> [String] {
        let countValue = try readValue("#KEY")
        guard let count = countValue.decoded?.doubleValue else {
            return []
        }

        let maxCount = min(Int(count), limit ?? Int(count))
        return (0..<maxCount).compactMap { index in
            var input = SMCParamStruct()
            input.data8 = Self.commandGetKeyByIndex
            input.data32 = UInt32(index)
            do {
                let output = try call(input)
                return FourCharCode.string(output.key)
            } catch {
                return nil
            }
        }
    }

    public func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)

        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.keyInfo = info
        input.data8 = Self.commandWriteValue
        input.bytes = SMCParamStruct.byteTuple32(bytes)

        _ = try call(input)
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var mutableInput = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = queue.sync {
            withUnsafePointer(to: &mutableInput) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    IOConnectCallStructMethod(
                        connection,
                        Self.selector,
                        inputPointer,
                        MemoryLayout<SMCParamStruct>.stride,
                        outputPointer,
                        &outputSize
                    )
                }
            }
        }

        guard result == KERN_SUCCESS else {
            throw SMCError.fromKernReturn(result)
        }

        if let error = SMCError.fromSMCResult(output.result) {
            throw error
        }

        return output
    }
}
