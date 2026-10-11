// Sources/Design/IOSPalette.swift — iOS companion design tokens (feature 011, contract §2, D-A/D-B).
// Values: design/ios-companion/SPEC.md token table. Theme.swift is NOT edited; shared views keep VolarColor.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

enum IOSPalette {
    static let bg = Color(volar: 0x0E0F11)
    static let bg2 = Color(volar: 0x131417)
    static let surface = Color(volar: 0x232326)
    static let surfaceHi = Color(volar: 0x2C2C2E)
    static let border = Color(volar: 0xFFFFFF, opacity: 0.10)
    static let borderHi = Color(volar: 0xFFFFFF, opacity: 0.18)
    static let fg = Color(volar: 0xF2F2F7)
    static let fg2 = Color(volar: 0xA0A4AA)
    static let fg3 = Color(volar: 0x74787E)
    static let mint = Color(volar: 0x66D4CF)
    static let mintSoft = Color(volar: 0x8FE3DF)
    static let mintSur = Color(volar: 0x66D4CF, opacity: 0.14)
    static let mintGlow = Color(volar: 0x66D4CF, opacity: 0.30)
    static let onMint = Color(volar: 0x06201F)
    static let high = Color(volar: 0xFF9F6B)
    static let med = Color(volar: 0xD9B77A)
    static let done = Color(volar: 0x30D158)
    static let destruct = Color(volar: 0xFF453A)

    /// The only gradient allowed: top mintSoft -> bottom mint (primary button).
    static let primaryGradient = LinearGradient(colors: [mintSoft, mint], startPoint: .top, endPoint: .bottom)
    /// rgba(14,15,17,0.92)
    static let tabBarBg = Color(volar: 0x0E0F11, opacity: 0.92)
}

enum IOSFont {
    /// Geist (static TTFs in Resources/Fonts). Missing file -> SwiftUI falls back to the system font.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist-" + suffix(weight, bold: "Bold"), size: size)
    }
    /// Geist Mono. Only Regular/Medium/SemiBold are bundled; heavier weights map to SemiBold.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("GeistMono-" + suffix(weight, bold: "SemiBold"), size: size)
    }
    private static func suffix(_ w: Font.Weight, bold: String) -> String {
        switch w {
        case .medium: return "Medium"
        case .semibold: return "SemiBold"
        case .bold, .heavy, .black: return bold
        default: return "Regular"
        }
    }

    // Named roles. Tracking is applied by callers via `.tracking(...)` using the constants below.
    static let screenTitle = ui(30, .semibold)
    static let nowTitle = ui(30, .semibold)      // callers add .lineSpacing(4)
    static let sectionLabel = mono(12, .semibold) // callers add .textCase(.uppercase)
    static let rowTitle = ui(16, .medium)
    static let body = ui(15)
    static let meta = ui(13)
    static let chip = mono(13)
    static let button = ui(16, .semibold)
    static let nowChip = mono(11, .semibold)

    static let screenTitleTracking: CGFloat = -0.6
    static let nowTitleTracking: CGFloat = -0.75
    static let sectionTracking: CGFloat = 0.72
    static let nowChipTracking: CGFloat = 1.1
}

enum IOSLayout {
    static let screenPadH: CGFloat = 22
    static let cardRadius: CGFloat = 14
    static let sheetRadius: CGFloat = 28
    static let buttonRadius: CGFloat = 14
    static let primaryHeight: CGFloat = 52
    static let secondaryHeight: CGFloat = 48
    static let fabSize: CGFloat = 64
    static let minTouch: CGFloat = 44
}
