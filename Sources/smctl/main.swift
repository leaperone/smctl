import ArgumentParser
import Foundation
import SMCCore

@main
struct SMCtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smctl",
        abstract: "Mac hardware control utility.",
        subcommands: [Sensors.self]
    )
}

struct Sensors: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sensors",
        abstract: "Read SMC sensors without requiring root."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Refresh every second until interrupted.")
    var watch = false

    func run() throws {
        let reader = SensorReader(backend: try SMCConnection())

        repeat {
            let snapshot = reader.snapshot()
            if json {
                printJSON(snapshot)
            } else {
                if watch {
                    clearScreen()
                }
                printHuman(snapshot)
            }

            if watch {
                fflush(stdout)
                sleep(1)
            }
        } while watch
    }

    private func printJSON(_ snapshot: SensorSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot), let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    }

    private func printHuman(_ snapshot: SensorSnapshot) {
        print("smctl sensors  \(ISO8601DateFormatter().string(from: snapshot.timestamp))")
        print("")

        print("Temperatures")
        if snapshot.temperatures.isEmpty {
            print("  No readable temperature keys found.")
        } else {
            var currentGroup = ""
            for reading in snapshot.temperatures {
                if reading.group != currentGroup {
                    currentGroup = reading.group
                    print("  \(currentGroup)")
                }
                print("    \(reading.key)  \(format(reading.celsius, digits: 1)) C")
            }
        }

        print("")
        print("Fans")
        if snapshot.fans.isEmpty {
            print("  No fans reported by SMC.")
        } else {
            for fan in snapshot.fans {
                let actual = rpm(fan.actualRPM)
                let target = rpm(fan.targetRPM)
                let minimum = rpm(fan.minimumRPM)
                let maximum = rpm(fan.maximumRPM)
                let mode = fan.mode ?? "unknown"
                print("  Fan \(fan.index): actual \(actual), target \(target), min \(minimum), max \(maximum), mode \(mode)")
            }
        }

        print("")
        print("Battery")
        printReadings(snapshot.battery)

        print("")
        print("Power")
        printReadings(snapshot.power)
    }

    private func printReadings(_ readings: [NamedReading]) {
        if readings.isEmpty {
            print("  No readable keys found.")
            return
        }

        for reading in readings {
            if let value = reading.value {
                let suffix = reading.unit.map { " \($0)" } ?? ""
                print("  \(reading.name) (\(reading.key)): \(format(value, digits: 2))\(suffix)")
            } else if let rawBytes = reading.rawBytes {
                let hex = rawBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("  \(reading.name) (\(reading.key)): \(hex)")
            }
        }
    }

    private func rpm(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }
        return "\(format(value, digits: 0)) RPM"
    }

    private func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func clearScreen() {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
    }
}
