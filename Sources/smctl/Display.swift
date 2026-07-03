import ArgumentParser
import DisplayDDC
import Foundation

// MARK: - DDC display access

/// External display reachable over DDC/CI. `raw` keeps the retained CFString
/// fields from the C layer alive; smctl is a one-shot process, so they are
/// never released.
struct ExternalDisplay {
    let index: Int
    let name: String
    let uuid: String
    let raw: DDCDisplayInfo
}

enum DisplayControl {
    static func onlineDisplays() -> [ExternalDisplay] {
        var infos = [DDCDisplayInfo](repeating: DDCDisplayInfo(), count: Int(DDC_MAX_DISPLAYS))
        let count = Int(ddcCopyOnlineDisplayInfos(&infos, DDC_MAX_DISPLAYS))
        return (0..<count).map { i in
            ExternalDisplay(
                index: i + 1,
                name: infos[i].productName.map { $0.takeUnretainedValue() as String } ?? "Unknown Display",
                uuid: infos[i].uuid.map { $0.takeUnretainedValue() as String } ?? "",
                raw: infos[i]
            )
        }
    }

    static func resolve(_ selector: String?, in displays: [ExternalDisplay]) throws -> ExternalDisplay {
        guard !displays.isEmpty else {
            throw ValidationError("No external display found.")
        }
        guard let selector else {
            if displays.count == 1 { return displays[0] }
            let list = displays.map { "  [\($0.index)] \($0.name) (\($0.uuid))" }.joined(separator: "\n")
            throw ValidationError("Multiple displays connected; pick one with --display <index|uuid>:\n\(list)")
        }
        if let index = Int(selector) {
            guard let match = displays.first(where: { $0.index == index }) else {
                throw ValidationError("No display with index \(index). See 'smctl display list'.")
            }
            return match
        }
        guard let match = displays.first(where: { $0.uuid.caseInsensitiveCompare(selector) == .orderedSame }) else {
            throw ValidationError("No display with UUID \(selector). See 'smctl display list'.")
        }
        return match
    }

    static func avService(for display: ExternalDisplay) throws -> IOAVService {
        var raw = display.raw
        guard let service = ddcCopyDisplayAVService(&raw) else {
            throw ValidationError("Display \(display.index) (\(display.name)) has no DDC-capable connection.")
        }
        return service.takeRetainedValue()
    }

    static func read(_ service: IOAVService, _ code: UInt8) throws -> DDCValue {
        var value = DDCValue()
        let err = ddcRead(service, code, &value)
        guard err == kIOReturnSuccess else {
            throw ValidationError("DDC read failed: \(String(cString: mach_error_string(err)))")
        }
        return value
    }

    static func write(_ service: IOAVService, _ code: UInt8, _ value: UInt16) throws {
        let err = ddcWrite(service, code, value)
        guard err == kIOReturnSuccess else {
            throw ValidationError("DDC write failed: \(String(cString: mach_error_string(err)))")
        }
    }
}

// MARK: - Commands

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Control external displays over DDC/CI.",
        subcommands: [DisplayList.self, DisplayBrightness.self, DisplayPower.self]
    )
}

struct DisplayList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List external displays."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    private struct Entry: Codable {
        let index: Int
        let name: String
        let uuid: String
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
    }

    func run() throws {
        let displays = DisplayControl.onlineDisplays()
        if json {
            let entries = displays.map {
                Entry(index: $0.index, name: $0.name, uuid: $0.uuid,
                      vendor: $0.raw.vendor, model: $0.raw.model, serial: $0.raw.serial)
            }
            print(try CLIJSON.encodeString(entries))
            return
        }
        if displays.isEmpty {
            print("No external display found.")
            return
        }
        for display in displays {
            print("[\(display.index)] \(display.name) (\(display.uuid))")
        }
    }
}

struct DisplayBrightness: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightness",
        abstract: "Get or set display brightness (DDC luminance)."
    )

    @Argument(help: "New brightness (0-100). Omit to read the current value.")
    var value: Int?

    @Option(name: .customLong("display"), help: "Display index or UUID (see 'smctl display list').")
    var display: String?

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    private struct Reading: Codable {
        let display: String
        let uuid: String
        let brightness: Int
        let max: Int
    }

    func run() throws {
        let target = try DisplayControl.resolve(display, in: DisplayControl.onlineDisplays())
        let service = try DisplayControl.avService(for: target)

        if let value {
            guard (0...100).contains(value) else {
                throw ValidationError("Brightness must be between 0 and 100.")
            }
            try DisplayControl.write(service, UInt8(DDC_VCP_LUMINANCE), UInt16(value))
            let after = try DisplayControl.read(service, UInt8(DDC_VCP_LUMINANCE))
            if after.curValue != value {
                FileHandle.standardError.write(Data("warning: display reports \(after.curValue) after writing \(value)\n".utf8))
            }
        }

        let reading = try DisplayControl.read(service, UInt8(DDC_VCP_LUMINANCE))
        if json {
            print(try CLIJSON.encodeString(Reading(
                display: target.name, uuid: target.uuid,
                brightness: Int(reading.curValue), max: Int(reading.maxValue))))
        } else {
            print(reading.curValue)
        }
    }
}

struct DisplayPower: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Get or set display power over DDC (the display stays in the macOS layout while off)."
    )

    enum State: String, ExpressibleByArgument, CaseIterable {
        case on
        case off

        var vcpValue: UInt16 { self == .on ? 1 : 4 }
    }

    @Argument(help: "'on' or 'off'. Omit to read the current state.")
    var state: State?

    @Option(name: .customLong("display"), help: "Display index or UUID (see 'smctl display list').")
    var display: String?

    func run() throws {
        let target = try DisplayControl.resolve(display, in: DisplayControl.onlineDisplays())
        let service = try DisplayControl.avService(for: target)

        guard let state else {
            let reading = try DisplayControl.read(service, UInt8(DDC_VCP_POWER_MODE))
            print(reading.curValue == 1 ? "on" : "off")
            return
        }

        try DisplayControl.write(service, UInt8(DDC_VCP_POWER_MODE), state.vcpValue)

        // Panels take a few seconds to change power state; poll before judging.
        for _ in 0..<5 {
            sleep(1)
            if let reading = try? DisplayControl.read(service, UInt8(DDC_VCP_POWER_MODE)),
               reading.curValue == Int(state.vcpValue) {
                print("\(target.name): \(state.rawValue)")
                if state == .off {
                    print("Wake it with: smctl display power on --display \(target.index)")
                }
                return
            }
        }
        FileHandle.standardError.write(Data("warning: could not confirm power state over DDC; check the display\n".utf8))
    }
}
