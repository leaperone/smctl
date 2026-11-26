import Foundation
import SMCtlProtocol
import Testing
@testable import PulseUI

@MainActor
struct SafetyAlertsTests {
    static let tripReason = "temperature Tp0E 112.3C held at/above safety ceiling 110.0C for 2 consecutive checks"

    func telemetry(profile: String, latched: Bool) throws -> TelemetryDTO {
        var telemetry = try SampleService(profile: profile).telemetry()
        telemetry.safety = SafetyStateDTO(latched: latched, ceilingCelsius: 100, lastTripReason: latched ? Self.tripReason : nil)
        return telemetry
    }

    @Test func oneEventPerTransition() throws {
        var tracker = SafetyAlertTracker()
        #expect(tracker.update(try telemetry(profile: "night", latched: false)) == nil, "launch: no event")
        #expect(tracker.update(try telemetry(profile: "night", latched: false)) == nil)
        // The trip switches the daemon to auto in the same tick.
        #expect(tracker.update(try telemetry(profile: "auto", latched: true)) == .engaged(reason: Self.tripReason, interruptedProfile: "night"))
        #expect(tracker.update(try telemetry(profile: "auto", latched: true)) == nil, "still latched: no repeat")
        #expect(tracker.update(try telemetry(profile: "auto", latched: false)) == .released(interruptedProfile: "night"))
        #expect(tracker.update(try telemetry(profile: "auto", latched: false)) == nil)
    }

    @Test func noAlertForALatchFoundAtLaunch() throws {
        var tracker = SafetyAlertTracker()
        #expect(tracker.update(try telemetry(profile: "auto", latched: true)) == nil)
        #expect(tracker.update(try telemetry(profile: "auto", latched: false)) == .released(interruptedProfile: nil))
    }

    @Test func automaticIsNotAProfileToResume() throws {
        var tracker = SafetyAlertTracker()
        _ = tracker.update(try telemetry(profile: "auto", latched: false))
        #expect(tracker.update(try telemetry(profile: "auto", latched: true)) == .engaged(reason: Self.tripReason, interruptedProfile: nil))
    }

    @Test func messages() {
        let title = { (name: String) in name.capitalized }
        let engaged = SafetyMessage.make(.engaged(reason: Self.tripReason, interruptedProfile: "night"), title: title)
        #expect(engaged.title == "Temperature limit reached")
        #expect(engaged.body == "Tp0E reached 112 °C (limit 110 °C). Pulse handed the fans back to macOS. Night is paused.")
        #expect(engaged.resumeProfile == nil)

        let blind = SafetyMessage.make(.engaged(reason: "no readable temperature sensors while fans are under manual control", interruptedProfile: nil), title: title)
        #expect(blind.body == "No temperature sensor could be read. Pulse handed the fans back to macOS.")

        let unknown = SafetyMessage.make(.engaged(reason: "something new", interruptedProfile: nil), title: title)
        #expect(unknown.body == "Pulse handed the fans back to macOS.")

        let released = SafetyMessage.make(.released(interruptedProfile: "night"), title: title)
        #expect(released.resumeProfile == "night")
        #expect(released.body.contains("Resume Night"))
        #expect(SafetyMessage.make(.released(interruptedProfile: nil), title: title).resumeProfile == nil)
    }

    @Test func notifierRespectsTheSetting() {
        let sink = RecordingSink()
        let store = PulseStore(service: SampleService(profile: "night"), fallback: nil)
        let notifier = SafetyNotifier(store: store, sink: sink)
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SettingsKey.safetyNotifications)
        defer { defaults.set(saved, forKey: SettingsKey.safetyNotifications) }

        defaults.set(false, forKey: SettingsKey.safetyNotifications)
        store.emitSafetyEvent(.released(interruptedProfile: nil))
        #expect(sink.messages.isEmpty)
        defaults.set(true, forKey: SettingsKey.safetyNotifications)
        store.emitSafetyEvent(.released(interruptedProfile: nil))
        #expect(sink.messages.count == 1)
        _ = notifier
    }
}

@MainActor
private final class RecordingSink: SafetyMessageSink {
    var messages: [SafetyMessage] = []
    func post(_ message: SafetyMessage) { messages.append(message) }
}
