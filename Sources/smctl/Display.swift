import ArgumentParser
import DisplayDDC
import Foundation

// MARK: - DDC display access

/// MCCS luminance is a `0...maxValue` range, not universally `0...100`. Most panels
/// report max 100, but writing "50" to a panel whose max is 255 lands at ~20%. Convert
/// in both directions so the CLI's percent interface is honest on every display.
enum DDCLuminance {
    static func rawValue(percent: Int, maximum: Int) -> UInt16 {
        let maximum = maximum > 0 ? maximum : 100
        return UInt16(clamping: Int((Double(maximum) * Double(percent) / 100).rounded()))
    }

    static func percent(raw: Int, maximum: Int) -> Int {
        let maximum = maximum > 0 ? maximum : 100
        return Int((Double(raw) * 100 / Double(maximum)).rounded())
    }
}

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
        var displays: [ExternalDisplay] = []
        for i in 0..<count {
            var raw = infos[i]
            // Only list displays that actually resolve an external DDC port. The
            // built-in panel and virtual displays expose a UUID/location but cannot be
            // controlled over DDC, so listing them just makes `--display` ambiguous.
            guard ddcDisplayHasExternalService(&raw) != 0 else { continue }
            displays.append(ExternalDisplay(
                index: displays.count + 1,
                name: raw.productName.map { $0.takeUnretainedValue() as String } ?? "Unknown Display",
                uuid: raw.uuid.map { $0.takeUnretainedValue() as String } ?? "",
                raw: raw
            ))
        }
        return displays
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
        let before = try DisplayControl.read(service, UInt8(DDC_VCP_LUMINANCE))
        let range = max(1, Int(before.maxValue))
        var reading = before

        if let value {
            guard (0...100).contains(value) else {
                throw ValidationError("Brightness must be between 0 and 100.")
            }
            try DisplayControl.write(
                service,
                UInt8(DDC_VCP_LUMINANCE),
                DDCLuminance.rawValue(percent: value, maximum: range)
            )
            reading = try DisplayControl.read(service, UInt8(DDC_VCP_LUMINANCE))
            let reported = DDCLuminance.percent(raw: Int(reading.curValue), maximum: range)
            if abs(reported - value) > 1 {
                FileHandle.standardError.write(Data("warning: display reports \(reported)% after writing \(value)%\n".utf8))
            }
        }

        let percent = DDCLuminance.percent(raw: Int(reading.curValue), maximum: range)
        if json {
            print(try CLIJSON.encodeString(Reading(
                display: target.name, uuid: target.uuid,
                brightness: percent, max: range)))
        } else {
            print(percent)
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
