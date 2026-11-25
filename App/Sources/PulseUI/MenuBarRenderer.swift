import AppKit

/// What one frame of the menu bar item shows.
public struct MenuBarDrawing: Equatable, Sendable {
    public var icon: MenuBarIcon
    public var layout: MenuBarLayout
    public var entries: [MenuBarState.Entry]
    /// Temperature colouring the pulse dot.
    public var heatCelsius: Double?
    /// 0 at rest, 1 at the peak of a heartbeat.
    public var beat: Double
    /// The safety guard engaged: a warning replaces the icon.
    public var latched: Bool
    /// SF Symbol for the fan icon (`fan` or `fan.fill`).
    public var fanSymbol: String

    public init(icon: MenuBarIcon, layout: MenuBarLayout, entries: [MenuBarState.Entry], heatCelsius: Double?,
                beat: Double = 0, latched: Bool = false, fanSymbol: String = "fan") {
        self.icon = icon
        self.layout = layout
        self.entries = entries
        self.heatCelsius = heatCelsius
        self.beat = beat
        self.latched = latched
        self.fanSymbol = fanSymbol
    }

    /// The coloured dot needs a non-template image; everything else is
    /// monochrome and tinted by macOS for the menu bar appearance.
    public var isTemplate: Bool { latched || icon != .pulse }
}

/// Draws the whole menu bar item (icon and readings) as one image, centred on
/// cap-height metrics so digits sit visually in the middle of the bar.
public enum MenuBarRenderer {
    static let height: CGFloat = 22
    static let iconGap: CGFloat = 5
    static let columnGap: CGFloat = 8
    static let labelGap: CGFloat = 3
    static let rowGap: CGFloat = 3.5

    static var inlineFont: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium) }
    static var labelFont: NSFont { .systemFont(ofSize: 7.5, weight: .semibold) }
    static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .semibold) }

    /// Width reserved for each icon, constant across beats so nothing shifts.
    static func iconSlot(_ icon: MenuBarIcon) -> CGFloat {
        switch icon {
        case .pulse: return 14
        case .heartbeat: return 20
        case .fan: return 17
        case .none: return 0
        }
    }

    /// Widest value each item can show, so columns keep their width when a value
    /// grows from 999 to 1000 RPM.
    static func template(for item: MenuBarItem, value: String) -> String {
        switch item {
        case .cpu, .gpu: return "188°"
        case .fan: return value.hasSuffix("%") ? "100%" : "8888"
        case .power: return "88.8W"
        }
    }

    public static func heatColor(_ celsius: Double?) -> NSColor {
        guard let celsius else { return .systemGray }
        switch celsius {
        case ..<60: return .systemGreen
        case ..<80: return .systemYellow
        case ..<95: return .systemOrange
        default: return .systemRed
        }
    }

    public static func image(_ drawing: MenuBarDrawing) -> NSImage {
        let icon = drawing.latched && drawing.icon == .none ? .fan : drawing.icon
        let readings = layoutReadings(drawing)
        let iconWidth = iconSlot(icon)
        let gap = iconWidth > 0 && readings.width > 0 ? iconGap : 0
        let width = ceil(max(1, iconWidth + gap + readings.width))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            // Drawn lazily with the menu bar's appearance current, so label
            // colours resolve correctly for every status item replica.
            let ink: NSColor = drawing.isTemplate ? .black : .labelColor
            if drawing.latched {
                drawSymbol("exclamationmark.triangle.fill", in: NSRect(x: 0, y: 0, width: iconWidth, height: height), color: ink)
            } else {
                switch icon {
                case .pulse: drawPulseDot(slot: iconWidth, beat: drawing.beat, color: heatColor(drawing.heatCelsius))
                case .heartbeat: drawHeartbeat(slot: iconWidth, beat: drawing.beat, color: ink)
                case .fan: drawSymbol(drawing.fanSymbol, in: NSRect(x: 0, y: 0, width: iconWidth, height: height), color: ink)
                case .none: break
                }
            }
            readings.draw(iconWidth + gap, ink)
            return true
        }
        image.isTemplate = drawing.isTemplate
        return image
    }

    // MARK: Icons

    static func drawPulseDot(slot: CGFloat, beat: Double, color: NSColor) {
        let center = NSPoint(x: slot / 2, y: height / 2)
        let beat = CGFloat(min(1, max(0, beat)))
        if beat > 0 {
            // A soft halo that swells with the beat.
            let halo = 8 + 5 * beat
            color.withAlphaComponent(0.35 * beat).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - halo / 2, y: center.y - halo / 2, width: halo, height: halo)).fill()
        }
        let diameter = 8 + 2.5 * beat
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)).fill()
    }

    /// The trace from the app icon: flat, small bump, sharp spike, small bump, flat.
    static func drawHeartbeat(slot: CGFloat, beat: Double, color: NSColor) {
        let beat = CGFloat(min(1, max(0, beat)))
        let mid = height / 2
        let spike = 5 + 1.5 * beat
        let points: [(CGFloat, CGFloat)] = [
            (0, 0), (4.5, 0), (6, -1.6), (7.5, 0), (8.6, 0), (10, -spike), (11.6, spike * 0.9), (13, 0),
            (14.4, 0), (15.6, -1.2), (16.8, 0), (slot, 0)
        ]
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: mid + points[0].1))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: point.0, y: mid + point.1))
        }
        path.lineWidth = 1.6 + 0.4 * beat
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) else { return }
        let size = symbol.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        // Tint the symbol: draw it, then fill with the colour using it as a mask.
        NSGraphicsContext.saveGraphicsState()
        symbol.draw(in: target)
        color.set()
        target.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Readings

    struct Readings {
        var width: CGFloat
        var draw: (_ x: CGFloat, _ ink: NSColor) -> Void
    }

    /// Point at which to draw `font` text so its baseline sits at `baseline`
    /// (flipped coordinates: the line box starts `ascender` above the baseline).
    static func origin(x: CGFloat, baseline: CGFloat, font: NSFont) -> NSPoint {
        NSPoint(x: x, y: baseline - font.ascender)
    }

    static func layoutReadings(_ drawing: MenuBarDrawing) -> Readings {
        let entries = drawing.entries
        guard !entries.isEmpty else { return Readings(width: 0) { _, _ in } }

        if drawing.layout == .inline {
            let font = inlineFont
            let labelled = entries.filter { $0.item == .cpu || $0.item == .gpu }.count > 1
            let text = entries.map { labelled && ($0.item == .cpu || $0.item == .gpu) ? "\($0.label) \($0.value)" : $0.value }
                .joined(separator: "  ")
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            // Digits and capitals centred: baseline half a cap height below the middle.
            let baseline = (height + font.capHeight) / 2
            return Readings(width: width) { x, ink in
                (text as NSString).draw(at: origin(x: x, baseline: baseline, font: font), withAttributes: [.font: font, .foregroundColor: ink])
            }
        }

        let labelFont = labelFont
        let valueFont = valueFont
        let columns = stride(from: 0, to: entries.count, by: 2).map { Array(entries[$0..<min($0 + 2, entries.count)]) }
        let labelWidths = columns.map { $0.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0 }
        let valueWidths = columns.map { column in
            column.map { entry in
                max((entry.value as NSString).size(withAttributes: [.font: valueFont]).width,
                    (template(for: entry.item, value: entry.value) as NSString).size(withAttributes: [.font: valueFont]).width)
            }.max() ?? 0
        }
        let columnWidths = zip(labelWidths, valueWidths).map { ceil($0 + labelGap + $1) }
        let width = columnWidths.reduce(0, +) + columnGap * CGFloat(columns.count - 1)
        // Two rows of cap-height glyphs separated by rowGap, centred as a block.
        let cap = valueFont.capHeight
        let blockTop = (height - (2 * cap + rowGap)) / 2
        let baselines = [blockTop + cap, blockTop + 2 * cap + rowGap]
        let singleBaseline = (height + cap) / 2

        return Readings(width: width) { startX, ink in
            var x = startX
            for (index, column) in columns.enumerated() {
                for (row, entry) in column.enumerated() {
                    let baseline = column.count == 1 ? singleBaseline : baselines[row]
                    (entry.label as NSString).draw(at: origin(x: x, baseline: baseline, font: labelFont),
                                                   withAttributes: [.font: labelFont, .foregroundColor: ink.withAlphaComponent(0.75)])
                    let valueWidth = (entry.value as NSString).size(withAttributes: [.font: valueFont]).width
                    (entry.value as NSString).draw(at: origin(x: x + columnWidths[index] - valueWidth, baseline: baseline, font: valueFont),
                                                   withAttributes: [.font: valueFont, .foregroundColor: ink])
                }
                x += columnWidths[index] + columnGap
            }
        }
    }
}
