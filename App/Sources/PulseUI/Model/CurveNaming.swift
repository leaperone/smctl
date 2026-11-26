import Foundation
import PolicyEngine

/// Technical names and display labels for user curves. The technical name is
/// what the CLI and the TOML use (`pulse fan profile night-mode`); it is
/// derived once from the label and never changes afterwards, so renaming a
/// curve (its label) cannot break the active profile or SSH scripts.
public enum CurveNaming {
    /// `Night mode` → `night-mode`, `Été 2026!` → `ete-2026`. Never empty.
    public static func slug(_ label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        result = String(result.prefix(FanCurveSpec.maximumNameLength))
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "curve" : result
    }

    /// `base`, else `base-2`, `base-3`… avoiding `existing` and reserved names,
    /// always within the name length limit.
    public static func uniqueName(base: String, existing: Set<String>) -> String {
        let taken = existing.union(FanCurvePresets.reservedNames)
        let base = slug(base)
        if !taken.contains(base) { return base }
        var index = 2
        while true {
            let suffix = "-\(index)"
            let stem = String(base.prefix(FanCurveSpec.maximumNameLength - suffix.count))
            let candidate = (stem.hasSuffix("-") ? String(stem.dropLast()) : stem) + suffix
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// `Balanced` → `Balanced copy`, then `Balanced copy 2`…
    public static func copyLabel(_ label: String, existing: Set<String>) -> String {
        let first = "\(label) copy"
        if !existing.contains(first) { return clamp(first) }
        var index = 2
        while existing.contains("\(label) copy \(index)") { index += 1 }
        return clamp("\(label) copy \(index)")
    }

    /// A label, trimmed to one line within the length limit; nil when blank.
    public static func cleanLabel(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : clamp(line)
    }

    static func clamp(_ label: String) -> String {
        String(label.prefix(FanCurveSpec.maximumLabelLength))
    }
}
