import SwiftUI

struct PlannerTheme {
    let dark: Bool

    private func color(_ night: UInt32, _ day: UInt32) -> Color {
        let value = dark ? night : day
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    // One palette on Mac and iPhone. The light one is 纸面: warm paper, ink-dark text, violet only for
    // times, today and the one action that matters.
    var paper: Color { color(0x24232a, 0xf7f5f0) }
    /// The document on the Mac: white in the light look (the page you write on; the sidebar and toolbar keep the
    /// paper colour around it), one surface with everything else in the dark look.
    var sheet: Color { color(0x24232a, 0xffffff) }
    /// Beside the white page in the light look: the contents sidebar, a neutral grey (not the warm paper, which
    /// next to pure white reads as a second, mismatched white).
    var sidebar: Color { color(0x24232a, 0xf6f6f4) }
    /// The formatting toolbar's pill: a light grey on the white page, the old surface in the dark look.
    var toolbar: Color { dark ? surface.opacity(0.8) : Color(red: 0.957, green: 0.957, blue: 0.949) }
    /// The hairline above each day in the document.
    var dayRule: Color { color(0x34323c, 0xececea) }
    var surface: Color { color(0x2c2a34, 0xefece6) }
    var ink: Color { color(0xf4f0f6, 0x1f1d24) }
    var quiet: Color { color(0xbbb5c5, 0x8a8592) }
    var accent: Color { color(0xc4b4ff, 0x7a5ce0) }
    var onAccent: Color { color(0x211942, 0xffffff) }
    var wash: Color { color(0x403655, 0xece6fb) }
    var line: Color { color(0x3b3844, 0xe4e0d8) }
    var field: Color { color(0x2b2932, 0xffffff) }
    var block: Color { color(0x352d46, 0xf1edfb) }
    var blockEdge: Color { color(0x9883c6, 0xa69bd0) }
    var calendarEdge: Color { color(0x9a8c83, 0xb6aca4) }
}


enum DesktopAppearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "纸面")
        case .dark: String(localized: "深色")
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
