import Foundation

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case invalidKey(String)
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case badCommand
    case notFound
    case keySizeMismatch
    case notPrivileged
    case smcResult(UInt8)
    case malformedData(key: String, type: String, expected: Int, actual: Int)
    case writeVerificationFailed(key: String, expected: [UInt8], actual: [UInt8])

    public var description: String {
        switch self {
        case .invalidKey(let key):
            return "Invalid SMC key '\(key)'"
        case .serviceNotFound:
            return "AppleSMC service was not found"
        case .openFailed(let code):
            return "IOServiceOpen failed: \(code)"
        case .callFailed(let code):
            return "IOConnectCallStructMethod failed: \(code)"
        case .badCommand:
            return "SMC returned SmcBadCommand (0x82)"
        case .notFound:
            return "SMC key was not found (0x84)"
        case .keySizeMismatch:
            return "SMC returned SmcKeySizeMismatch (0x87)"
        case .notPrivileged:
            return "SMC operation is not privileged"
        case .smcResult(let result):
            return "SMC returned result 0x\(String(result, radix: 16))"
        case .malformedData(let key, let type, let expected, let actual):
            return "SMC key \(key) type \(type) expected \(expected) bytes, got \(actual)"
        case .writeVerificationFailed(let key, let expected, let actual):
            let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
            let actualHex = actual.map { String(format: "%02x", $0) }.joined()
            return "SMC write verification failed for \(key): expected \(expectedHex), read back \(actualHex)"
        }
    }

    static func fromSMCResult(_ result: UInt8) -> SMCError? {
        switch result {
        case 0:
            return nil
        case 0x82:
            return .badCommand
        case 0x84:
            return .notFound
        case 0x87:
            return .keySizeMismatch
        default:
            return .smcResult(result)
        }
    }

    static func fromKernReturn(_ code: kern_return_t) -> SMCError {
        if code == kIOReturnNotPrivileged {
            return .notPrivileged
        }
        return .callFailed(code)
    }
}
