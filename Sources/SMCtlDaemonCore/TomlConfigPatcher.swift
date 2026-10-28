import Foundation

/// Minimal, comment-preserving TOML editor for the scalar keys the daemon owns.
///
/// The daemon must persist policy changes (`battery.limit`, `fan.profile`, …) without
/// destroying the parts of the file it does not own: comments, unknown keys, and the
/// user-authored `[[fan.curves]]` / `[[alert]]` tables. TOMLKit is a decoder, not a
/// round-trip parser, so rewriting the decoded model would lose all of that.
///
/// This patcher therefore edits the existing text in place: it replaces the value of
/// known `key = value` lines inside known `[section]` tables (keeping indentation and
/// trailing comments), appends missing keys at the end of their section, and appends
/// missing sections at the end of the document. Everything else is left byte-for-byte
/// untouched. Only bare keys are recognized; quoted/dotted keys are never modified.
enum TomlConfigPatcher {
    struct SectionUpdate: Equatable {
        var name: String
        var values: [(key: String, literal: String)]

        init(name: String, values: [(key: String, literal: String)]) {
            self.name = name
            self.values = values
        }

        static func == (lhs: SectionUpdate, rhs: SectionUpdate) -> Bool {
            lhs.name == rhs.name
                && lhs.values.map(\.key) == rhs.values.map(\.key)
                && lhs.values.map(\.literal) == rhs.values.map(\.literal)
        }
    }

    /// Returns `text` with `sections` applied. The result always ends in a newline.
    static func patch(text: String, sections: [SectionUpdate]) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        for section in sections {
            guard let headerIndex = lines.firstIndex(where: { headerName($0) == section.name }) else {
                if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    lines.append("")
                }
                lines.append("[\(section.name)]")
                lines.append(contentsOf: section.values.map { "\($0.key) = \($0.literal)" })
                continue
            }

            let end = sectionEnd(after: headerIndex, in: lines)
            var missing: [(key: String, literal: String)] = []
            for (key, literal) in section.values {
                if let index = (headerIndex + 1..<end).first(where: { keyName(lines[$0]) == key }) {
                    lines[index] = replacingValue(in: lines[index], literal: literal)
                } else {
                    missing.append((key, literal))
                }
            }
            guard !missing.isEmpty else { continue }

            // Insert before the section's trailing blank lines so the file keeps its shape.
            var insertAt = end
            while insertAt > headerIndex + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(contentsOf: missing.map { "\($0.key) = \($0.literal)" }, at: insertAt)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// TOML basic-string literal for a Swift string (quotes, backslashes, control chars).
    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private static func headerName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        guard !inner.hasPrefix("[") else { return nil }  // [[array of tables]]
        return String(inner).trimmingCharacters(in: .whitespaces)
    }

    private static func sectionEnd(after headerIndex: Int, in lines: [String]) -> Int {
        var index = headerIndex + 1
        while index < lines.count, headerName(lines[index]) == nil, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[[") {
            index += 1
        }
        return index
    }

    private static func keyName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return key
    }

    private static func replacingValue(in line: String, literal: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        let head = line[...equals]
        let tail = line[line.index(after: equals)...]
        var updated = String(head) + " " + literal
        if let comment = trailingComment(in: tail) {
            updated += "  " + comment
        }
        return updated
    }

    /// The `# ...` comment of a TOML value, ignoring `#` inside quoted strings.
    private static func trailingComment(in tail: Substring) -> String? {
        var inDouble = false
        var inSingle = false
        var escaped = false
        for index in tail.indices {
            let character = tail[index]
            if inDouble {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inDouble = false
                }
                continue
            }
            if inSingle {
                if character == "'" {
                    inSingle = false
                }
                continue
            }
            switch character {
            case "\"": inDouble = true
            case "'": inSingle = true
            case "#": return String(tail[index...])
            default: break
            }
        }
        return nil
    }
}
