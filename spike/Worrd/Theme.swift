import AppKit
import SwiftUI

/// Palette lifted from the HTML prototype: warm paper in light mode, warm charcoal in dark.
enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let surface = dynamic(
        NSColor(srgbRed: 0.988, green: 0.984, blue: 0.973, alpha: 1),
        NSColor(srgbRed: 0.125, green: 0.125, blue: 0.122, alpha: 1)
    )
    static let surface2 = dynamic(
        NSColor(srgbRed: 0.965, green: 0.961, blue: 0.945, alpha: 1),
        NSColor(srgbRed: 0.157, green: 0.157, blue: 0.153, alpha: 1)
    )
    static let text = dynamic(
        NSColor(srgbRed: 0.094, green: 0.098, blue: 0.090, alpha: 1),
        NSColor(srgbRed: 0.949, green: 0.945, blue: 0.925, alpha: 1)
    )
    static let secondary = dynamic(
        NSColor(srgbRed: 0.314, green: 0.322, blue: 0.302, alpha: 1),
        NSColor(srgbRed: 0.753, green: 0.745, blue: 0.714, alpha: 1)
    )
    static let muted = dynamic(
        NSColor(srgbRed: 0.443, green: 0.447, blue: 0.420, alpha: 1),
        NSColor(srgbRed: 0.604, green: 0.596, blue: 0.561, alpha: 1)
    )
    static let accent = dynamic(
        NSColor(srgbRed: 0.180, green: 0.420, blue: 0.310, alpha: 1),
        NSColor(srgbRed: 0.560, green: 0.765, blue: 0.639, alpha: 1)
    )
    static let amber = dynamic(
        NSColor(srgbRed: 0.596, green: 0.400, blue: 0.114, alpha: 1),
        NSColor(srgbRed: 0.839, green: 0.643, blue: 0.349, alpha: 1)
    )
    static let hairline = dynamic(
        NSColor(white: 0, alpha: 0.09),
        NSColor(white: 1, alpha: 0.10)
    )
    static let accentSoft = dynamic(
        NSColor(srgbRed: 0.180, green: 0.420, blue: 0.310, alpha: 0.08),
        NSColor(srgbRed: 0.560, green: 0.765, blue: 0.639, alpha: 0.12)
    )
    static let amberSoft = dynamic(
        NSColor(srgbRed: 0.596, green: 0.400, blue: 0.114, alpha: 0.08),
        NSColor(srgbRed: 0.839, green: 0.643, blue: 0.349, alpha: 0.12)
    )

    /// The same surface as an AppKit color, for snapshot compositing.
    static var surfaceNSColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.125, green: 0.125, blue: 0.122, alpha: 1)
                : NSColor(srgbRed: 0.988, green: 0.984, blue: 0.973, alpha: 1)
        }
    }
}
