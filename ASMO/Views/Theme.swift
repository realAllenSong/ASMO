import SwiftUI

struct PlannerTheme {
    let dark: Bool

    private func color(_ night: UInt32, _ day: UInt32) -> Color {
        let value = dark ? night : day
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    // One palette on Mac and iPhone, from the icon: warm paper and ink, and vermilion (the sun) only for times,
    // today and the one action that matters. The dark look is warm ink, not a violet grey.
    var paper: Color { color(0x22201e, 0xf7f5f0) }
    /// The document on the Mac: white in the light look (the page you write on; the sidebar and toolbar keep the
    /// paper colour around it), one surface with everything else in the dark look.
    var sheet: Color { color(0x22201e, 0xffffff) }
    /// Beside the white page in the light look: the contents sidebar, a neutral grey (not the warm paper, which
    /// next to pure white reads as a second, mismatched white).
    var sidebar: Color { color(0x22201e, 0xf6f5f2) }
    /// The formatting toolbar's pill: a light grey on the white page, the old surface in the dark look.
    var toolbar: Color { dark ? surface.opacity(0.8) : Color(red: 0.957, green: 0.954, blue: 0.945) }
    /// The hairline above each day in the document.
    var dayRule: Color { color(0x353130, 0xedebe7) }
    var surface: Color { color(0x2c2927, 0xefece6) }
    var ink: Color { color(0xf3efe9, 0x1f1c1a) }
    var quiet: Color { color(0xb6aea5, 0x8b857e) }
    var accent: Color { color(0xf2876a, 0xc63c1f) }
    var onAccent: Color { color(0x2a120c, 0xffffff) }
    var wash: Color { color(0x47302a, 0xfbe9e3) }
    var line: Color { color(0x3c3835, 0xe5e1d9) }
    var field: Color { color(0x2b2826, 0xffffff) }
    var block: Color { color(0x3d2c27, 0xfbede8) }
    var blockEdge: Color { color(0xc98a78, 0xe0a593) }
    /// The 「标紫」 colour for words (kept violet now that the accent is vermilion).
    var violet: Color { color(0xc4b4ff, 0x7a5ce0) }
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
