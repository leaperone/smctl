import AppKit

/// Draws the stacked menu bar layout as a template image: macOS tints it for the
/// menu bar appearance, and one image replaces any number of subviews.
public enum MenuBarRenderer {
    static var labelFont: NSFont { .systemFont(ofSize: 7.5, weight: .semibold) }
    static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .semibold) }
    static let rowHeight: CGFloat = 10.5
    static let height: CGFloat = 22
    static let labelGap: CGFloat = 3
    static let columnGap: CGFloat = 7
    static let iconGap: CGFloat = 4

    /// Widest value each item can show, so columns keep their width when a value
    /// grows from 999 to 1000 RPM and the menu bar does not shift.
    static func template(for item: MenuBarItem, value: String) -> String {
        switch item {
        case .cpu, .gpu: return "188°"
        case .fan: return value.hasSuffix("%") ? "100%" : "8888"
        case .power: return "88.8W"
        }
    }

    /// Entries in columns of two rows; a lone entry is centred vertically.
    public static func stackedImage(entries: [MenuBarState.Entry], symbol: String?) -> NSImage {
        let columns = stride(from: 0, to: entries.count, by: 2).map { Array(entries[$0..<min($0 + 2, entries.count)]) }
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]

        let icon = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        let iconWidth = icon.map { $0.size.width + (columns.isEmpty ? 0 : iconGap) } ?? 0

        let labelWidths = columns.map { column in
            column.map { ($0.label as NSString).size(withAttributes: labelAttributes).width }.max() ?? 0
        }
        let valueWidths = columns.map { column in
            column.map { entry in
                max(
                    (entry.value as NSString).size(withAttributes: valueAttributes).width,
                    (template(for: entry.item, value: entry.value) as NSString).size(withAttributes: valueAttributes).width
                )
            }.max() ?? 0
        }
        let columnWidths = zip(labelWidths, valueWidths).map { ceil($0 + labelGap + $1) }
        let width = ceil(iconWidth + columnWidths.reduce(0, +) + columnGap * CGFloat(max(0, columns.count - 1)))

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            var x: CGFloat = 0
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                x += iconWidth
            }
            for (index, column) in columns.enumerated() {
                let top = column.count == 1 ? (height - rowHeight) / 2 : (height - rowHeight * 2) / 2
                for (row, entry) in column.enumerated() {
                    let y = top + CGFloat(row) * rowHeight
                    let label = entry.label as NSString
                    let labelSize = label.size(withAttributes: labelAttributes)
                    // Align the small label's baseline with the value's.
                    let valueSize = (entry.value as NSString).size(withAttributes: valueAttributes)
                    label.draw(at: NSPoint(x: x, y: y + (valueSize.height - labelSize.height) - 1), withAttributes: labelAttributes)
                    let valueX = x + columnWidths[index] - valueSize.width
                    (entry.value as NSString).draw(at: NSPoint(x: valueX, y: y - 1), withAttributes: valueAttributes)
                }
                x += columnWidths[index] + columnGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
