import Foundation
import SMCtlProtocol

/// Curves are in percent and each fan maps them onto its own range, so the RPM
/// axis (drawn for the first fan) needs a note when the other fans differ, as on
/// a MacBook Pro (1200–5779 and 1200–6241 RPM).
public enum FanRangeNote {
    public static func text(fans: [FanStatusDTO]) -> String? {
        guard let first = fans.first, fans.count > 1 else { return nil }
        let others = fans.dropFirst().filter { $0.minimumRPM != first.minimumRPM || $0.maximumRPM != first.maximumRPM }
        guard !others.isEmpty else { return nil }
        let ranges = others.map { "Fan \($0.index + 1) runs the same % on \(range($0))" }.joined(separator: ", ")
        return "RPM of Fan \(first.index + 1). \(ranges)."
    }

    private static func range(_ fan: FanStatusDTO) -> String {
        "\(Format.rpm(fan.minimumRPM))–\(Format.rpm(fan.maximumRPM)) RPM"
    }
}
