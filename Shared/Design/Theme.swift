// Sources/Design/Theme.swift — frozen design tokens: palette, accents, density, glass (spec §3)
//
// RETHEME 4 — "Volar Paper" (2026-08-19, specs/009-light-mode-list-v2/design.md). Supersedes
// RETHEME 3 "Volar Graphite" on every color VALUE; token NAMES are unchanged yet again (71 call
// sites across 26 files keep compiling untouched — see design.md §2). Two real changes:
//
// 1. LIGHT MODE EXISTS NOW. Every `VolarColor` static let (and every `VolarAccent` case) is a
//    dynamic color that resolves differently under light vs. dark appearance, via
//    `NSColor(name:dynamicProvider:)` on macOS / `UIColor { traits in }` on iOS (`Shared/` is
//    compiled by both `Volar` and `VolarIOS`, so both branches must be correct — see the
//    `Color(volarLight:dark:)` initializer below). `veil(_:)` is the load-bearing case: it flips
//    from a white film (dark) to a BLACK film (light) so the ~70 call sites that build hover
//    tints / chip fills / progress tracks out of `veil(x)` still read correctly on a white page.
//    Previously this file was dark-only ("no light variant exists" — that claim is now false).
//
// 2. THE ACCENT IS MINT (anh Khôi chốt 2026-08-20, sau khi review sáu ứng viên xanh dựng thành
//    mẫu UI thật). `VolarAccent.indigo` (the default; the name is a persisted misnomer, unchanged
//    for wire/settings compatibility) resolves to Apple's `systemMint` INCREASED-CONTRAST family:
//    `#0C817B` light / `#66D4CF` dark. Nó thắng vì hai lý do đo được, không phải vì đẹp hơn:
//      - Đây là màu xanh DUY NHẤT vượt 4.5:1 trên nền trắng (4.73:1). Mọi xanh tươi khác —
//        systemGreen #34C759 (2.22), systemMint thường #00C7BE (2.12), systemTeal #30B0C7 (2.57),
//        accent green của macOS #62BA46 (2.43) — đều chết ở light mode. Dark mode không phải chỗ
//        khó: cả sáu đều 7–11:1 trên `#1C1C1E`.
//      - Nó lệch 42° sắc độ khỏi `done` (#248A3D, 135°). Hai ứng viên systemGreen lệch 0°, tức
//        "đang mời bấm" và "đã xong" thành cùng một hue — với bản tăng tương phản thì trùng khít
//        cả mã màu. Chọn mint là `done` được giữ nguyên, không phải dời đi đâu.
//    Purple (RETHEME 4, `#8944AB`/`#BF5AF2`) chưa từng được build trên Mac lần nào nên không có gì
//    để tiếc. Mint quay lại đúng hệ màu của logo Volar — câu hỏi "vẽ lại logo theo tím hay giữ mint
//    tách khỏi UI" treo trong backlog 009 tự trả lời.
//    Luật "one saturated color on screen at a time" không đổi: một thanh 3px + một chip nhỏ, không
//    bao giờ là mảng đặc lớn (xem `nowSurface`). `instrument` (ice-blue readout accent) vẫn retired
//    — nó bằng `textSec` (no color).
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    /// Constructs a `Color` from a 24-bit RGB literal (e.g. `0xFF6B6B`), always going through
    /// the exact `Color(.sRGB, red:green:blue:opacity:)` initializer the token spec calls for.
    /// Centralizing the hex math here (instead of hand-computing decimals at each call site)
    /// keeps every token numerically exact. NOT dynamic — kept as-is for the one remaining
    /// caller outside this file (`AmbientBackground.swift`'s still-dark-only weather scenes,
    /// which design.md §9 explicitly defers: "chưa được xét trên nền trắng → backlog").
    init(volar hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Dynamic color: resolves to `lightHex`/`lightOpacity` under a light appearance and
    /// `darkHex`/`darkOpacity` under dark, re-resolving live if the user (or the app, via
    /// `NSApp.appearance`/`overrideUserInterfaceStyle`) flips appearance at runtime. This is the
    /// single mechanism the whole light-mode pass rides on (design.md §2): every `VolarColor`
    /// token below changes VALUE only through this initializer, so no call site anywhere in the
    /// app has to change. `Shared/` is compiled by both the AppKit (macOS) and UIKit (iOS)
    /// targets, so both branches below must stay correct.
    init(volarLight lightHex: UInt32, lightOpacity: Double = 1, dark darkHex: UInt32, darkOpacity: Double = 1) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(volar: darkHex, opacity: darkOpacity)
                : NSColor(volar: lightHex, opacity: lightOpacity)
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(volar: darkHex, opacity: darkOpacity)
                : UIColor(volar: lightHex, opacity: lightOpacity)
        })
        #else
        self.init(volar: darkHex, opacity: darkOpacity)
        #endif
    }
}

#if canImport(AppKit)
private extension NSColor {
    /// Same hex math as `Color(volar:opacity:)`, for building the two fixed endpoints a dynamic
    /// `NSColor` picks between.
    convenience init(volar hex: UInt32, opacity: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: opacity
        )
    }
}
#elseif canImport(UIKit)
private extension UIColor {
    /// Same hex math as `Color(volar:opacity:)`, for building the two fixed endpoints a dynamic
    /// `UIColor` picks between.
    convenience init(volar hex: UInt32, opacity: Double) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: opacity
        )
    }
}
#endif

/// Base palette — ink + text + priority/status tokens. As of RETHEME 4 ("Volar Paper",
/// design.md §3) every token here is a dynamic light+dark color built via `Color(volarLight:dark:)`
/// above; values are Apple's own system-gray/system-color hex, not hand-invented, per design.md §1
/// ("Ink lấy theo thang xám hệ thống của Apple, không tự bịa hex").
enum VolarColor {
    // --- Ink / depth — Apple system-gray ramp (design.md §3.1) ---
    /// Base bg, deepest. `#FFFFFF` light / `#1C1C1E` dark (Apple systemGray6 dark) — NOT the old
    /// `#0F0F11`, which is darker than any Apple window background and was why every low-alpha
    /// veil on top of it used to read as invisible (design.md §0).
    static let bg = Color(volarLight: 0xFFFFFF, dark: 0x1C1C1E)
    /// Raised surface, one step up from `bg`. NOTE: name predates the retheme.
    static let surface = Color(volarLight: 0xF2F2F7, dark: 0x232326)
    /// Raised surface, higher. Selected-row fill (§5.3), input / hover panel.
    static let surfaceHi = Color(volarLight: 0xE5E5EA, dark: 0x2C2C2E)
    /// Row background. Now fully transparent in BOTH modes (design.md §3.1, §5.1) — List v2 rows
    /// carry no background of their own; `cardHover`/`surfaceHi` are the only fills a row ever
    /// gets, and only on hover/selection. Kept as a token (not deleted) so the ~handful of call
    /// sites that reference `VolarColor.card` don't need to change.
    static let card = Color.clear
    /// The one surface fill that actually shows on an unselected row: a hover tint. Low alpha
    /// reads clearly now because it's the ONLY fill on the page (design.md §0/§5.2).
    static let cardHover = Color(volarLight: 0x000000, lightOpacity: 0.05, dark: 0xFFFFFF, darkOpacity: 0.06)
    /// Hairline between sections (not between every row — §5.1 drops per-row hairlines entirely).
    static let border = Color(volarLight: 0x000000, lightOpacity: 0.10, dark: 0xFFFFFF, darkOpacity: 0.10)
    /// Stronger hairline / focus outline.
    static let borderHi = Color(volarLight: 0x000000, lightOpacity: 0.18, dark: 0xFFFFFF, darkOpacity: 0.18)

    /// One-off translucent film at an arbitrary strength, for the ~70 places across the views that
    /// need a fill/stroke between two named tokens (hover tints, chip backgrounds, progress-track
    /// fills). THE load-bearing token of the whole light-mode pass (design.md §2): it inverts
    /// polarity by appearance — black film in light mode, white film in dark — so none of those 70
    /// call sites need to change to keep working on a white background. Prefer a named token when
    /// one fits — this exists so a view never has to reach back for `Color.white` directly.
    static func veil(_ opacity: Double) -> Color {
        Color(volarLight: 0x000000, lightOpacity: opacity, dark: 0xFFFFFF, darkOpacity: opacity)
    }

    // --- Text (design.md §3.2) ---
    /// Primary. Contrast vs `bg` ≈ 16:1 light / ≈15:1 dark — AAA both.
    static let textPri = Color(volarLight: 0x1C1C1E, dark: 0xF2F2F7)
    /// Secondary. Contrast vs `bg` ≈ 5:1 light / ≈6:1 dark — AA. Header-section label color as of
    /// List v2 (§5.4) — `textMut` is no longer used for headers.
    static let textSec = Color(volarLight: 0x6E6E73, dark: 0x98989D)
    /// Tertiary / muted. Contrast vs `bg` ≈ 3:1 light / ≈4:1 dark — intentionally BELOW body-text
    /// AA (tertiary/de-emphasized labels only, never body copy, never a section header).
    static let textMut = Color(volarLight: 0x8E8E93, dark: 0x7C7C80)

    // --- Priority / status dots & badges (design.md §3.5) ---
    // No red, ever, for status/badges (anti-shame rule) — `destruct` below is the one exception,
    // reserved for the irreversible Delete action itself, not a judgment on the user.
    /// High priority — muted clay/terracotta, deliberately NOT alarm red.
    static let high = Color(volarLight: 0xC04A26, dark: 0xFF9F6B)
    /// Medium priority — muted warm brown/taupe, between `high` and `low`.
    static let med = Color(volarLight: 0x8A6D3B, dark: 0xD9B77A)
    /// Low priority — neutral gray film, same polarity-inverting formula as `veil(_:)`.
    static let low = Color(volarLight: 0x000000, lightOpacity: 0.28, dark: 0xFFFFFF, darkOpacity: 0.30)
    /// Destructive action (e.g. Delete). Apple systemRed accessible light / systemRed dark — the
    /// standard macOS destructive-affordance red. Distinct from the "never red for
    /// overdue/badges" anti-shame rule: that rule governs task-status badges, not an irreversible
    /// system action button.
    static let destruct = Color(volarLight: 0xD70015, dark: 0xFF453A)
    /// Success. Apple systemGreen accessible light / systemGreen dark.
    static let done = Color(volarLight: 0x248A3D, dark: 0x30D158)

    // MARK: - NOW / spotlight tokens (design.md §3.4)

    /// The NOW row's 3px accent bar + "NOW" chip fill. Same mint as `VolarAccent.indigo.solid`
    /// on purpose — the app has exactly ONE saturated hue (design.md §1), and NOW is the one place
    /// that hue is allowed to be a small, dense mark. Never a large fill — see `nowSurface`.
    static let nowAccent = Color(volarLight: 0x0C817B, dark: 0x66D4CF)
    /// Hover state of the NOW chip.
    static let nowAccentSoft = Color(volarLight: 0x12A199, dark: 0x8FE3DF)
    /// Pressed/deep state.
    static let nowAccentDeep = Color(volarLight: 0x0A6B66, dark: 0x3FB8B2)
    /// NEW token (design.md §3.4/§5.3) — the NOW row's background. NOT `nowAccent` at full
    /// strength: a large saturated fill would break the "one saturated point on screen" rule, and
    /// `textPri` has to stay fully legible on top of it. This is `nowAccent` pha (mixed) ~8% into
    /// `bg`, so the row reads as "marked" while all the saturation stays in the 3px bar + chip.
    static let nowSurface = Color(volarLight: 0xE9F6F5, dark: 0x16302E)
    /// The spotlight pool's inner glow (`SpotlightBackground` below).
    static let nowGlow = Color(volarLight: 0x0C817B, lightOpacity: 0.08, dark: 0x66D4CF, darkOpacity: 0.20)
    /// The spotlight pool's outer falloff.
    static let nowGlowSoft = Color(volarLight: 0x0C817B, lightOpacity: 0.04, dark: 0x66D4CF, darkOpacity: 0.10)
    /// NOW-specific focus ring / hairline accent (e.g. chip border).
    static let nowRing = Color(volarLight: 0x0C817B, lightOpacity: 0.45, dark: 0x66D4CF, darkOpacity: 0.55)

    // MARK: - Instrument tokens (design.md §1: "ice blue `instrument` bỏ")

    /// Instrument readout accent (WIP counter, timers, step counts). Used to be ice blue
    /// (`#86B9FF`); retired per design.md §1 — instruments are unstyled text now, same color as
    /// any other secondary label.
    static let instrument = textSec
    /// Dimmed instrument mark (dashed dependency chips etc).
    static let instrumentDim = textMut

    /// Calm neutral "needs rescheduling" tone. What overdue uses INSTEAD of red (anti-shame rule).
    /// Intentionally the same value as `textSec` — a neutral label, not a colored badge.
    static let reschedule = textSec
}

/// One accent family's four derived roles (`VOLAR_ACCENTS.*`).
struct Accent: Sendable {
    let solid: Color
    let hover: Color
    let surface: Color
    let glow: Color
}

/// Selectable accent families (`VOLAR_ACCENTS`). Default is `.indigo`, whose NAME is now a
/// misnomer kept for wire/settings compatibility (it is persisted by rawValue): as of RETHEME 4 it
/// resolves to Apple's systemMint accessible family (the app's one saturated hue, see the `.indigo`
/// case below), used sparingly (a 3px bar, a small chip), never a large fill.
///
/// `.teal`/`.amber`/`.magenta` keep their original dark-mode hue unchanged and gain a light-mode
/// pair computed by lowering HSL lightness ~25% at the same hue/saturation (design.md §3.3: "opt-
/// in, không đáng tốn thời gian tinh chỉnh" — these are user-selectable alternates, not the
/// default, so the light values are a mechanical hue-preserving derivation, not hand-tuned). The
/// old note about `.teal` sitting "uncomfortably close to mint" no longer applies: mint has left
/// the UI entirely (design.md §9 — it tự tan, "resolves itself", once nothing else on screen is
/// mint).
enum VolarAccent: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case indigo, teal, amber, magenta

    var id: String { rawValue }

    var accent: Accent {
        switch self {
        case .indigo:
            // Apple systemMint, INCREASED-CONTRAST variant (anh Khôi chốt 2026-08-20 — xem ghi chú
            // §2 đầu file). #00C7BE (systemMint thường) chỉ đạt 2.12:1 trên trắng, không dùng làm
            // chữ/icon được ở light mode; #0C817B đạt 4.73:1, và nhãn TRẮNG trên nền nó cũng 4.73:1
            // nên nút đặc không cần luật riêng cho từng chế độ.
            let solid = Color(volarLight: 0x0C817B, dark: 0x66D4CF)
            let hover = Color(volarLight: 0x0A6B66, dark: 0x8FE3DF)
            let surface = Color(volarLight: 0x0C817B, lightOpacity: 0.10, dark: 0x66D4CF, darkOpacity: 0.16)
            let glow = Color(volarLight: 0x0C817B, lightOpacity: 0.30, dark: 0x66D4CF, darkOpacity: 0.40)
            return Accent(solid: solid, hover: hover, surface: surface, glow: glow)
        case .teal:
            // Dark hue unchanged (#3DBFAF / #63D6C7); light pair = same hue/sat, L × 0.75.
            let solid = Color(volarLight: 0x2E8F83, dark: 0x3DBFAF)
            let hover = Color(volarLight: 0x31BAA8, dark: 0x63D6C7)
            return Accent(solid: solid, hover: hover, surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .amber:
            // Dark hue unchanged (#D9853D / #E9A165); light pair = same hue/sat, L × 0.75.
            let solid = Color(volarLight: 0xAE6322, dark: 0xD9853D)
            let hover = Color(volarLight: 0xDB751F, dark: 0xE9A165)
            return Accent(solid: solid, hover: hover, surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .magenta:
            // Dark hue unchanged (#D16BC0 / #E38BD4); light pair = same hue/sat, L × 0.75.
            let solid = Color(volarLight: 0xB538A0, dark: 0xD16BC0)
            let hover = Color(volarLight: 0xD141B9, dark: 0xE38BD4)
            return Accent(solid: solid, hover: hover, surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        }
    }
}

/// Row/section spacing presets (`VOLAR_DENSITY`). Default is `.comfy`. Unchanged by RETHEME 4
/// (color-only pass) except `rowGap`, which List v2 (design.md §5.1) drops toward zero so rows sit
/// flush against each other now that they carry no per-row background/border of their own.
enum Density: Sendable, Equatable, Hashable {
    case cozy, comfy, roomy

    var rowPadY: CGFloat {
        switch self {
        case .cozy: return 5
        case .comfy: return 8
        case .roomy: return 12
        }
    }

    /// design.md §5.1: `0 / 0 / 2` — rows sit sat against each other; only hairlines between
    /// sections separate content now, not per-row gaps.
    var rowGap: CGFloat {
        switch self {
        case .cozy: return 0
        case .comfy: return 0
        case .roomy: return 2
        }
    }

    var sectionGap: CGFloat {
        switch self {
        case .cozy: return 14
        case .comfy: return 18
        case .roomy: return 26
        }
    }
}

/// Glass/material intensity presets (`VOLAR_GLASS`). Default is `.standard`. Unchanged by
/// RETHEME 4 (color-only pass) — `bg` opacity is layered over whichever `Material` these resolve
/// to, and since `bg` is now dynamic light/dark, so is every material-backed surface using it.
enum GlassLevel: Sendable, Equatable, Hashable {
    case subtle, standard, heavy

    /// CSS `backdrop-filter: blur()` radius from the prototype — kept for documentation/fidelity
    /// even though SwiftUI's system `Material`s don't take an explicit blur radius parameter.
    var blur: CGFloat {
        switch self {
        case .subtle: return 14
        case .standard: return 24
        case .heavy: return 36
        }
    }

    /// Opacity of the `VolarColor.bg` tint layered over the system material.
    var bgOpacity: Double {
        switch self {
        case .subtle: return 1.00
        case .standard: return 0.97
        case .heavy: return 0.80
        }
    }

    /// Nearest system `Material` for each intensity (native-first per §6 — no custom blur
    /// implementation). More blur/opacity in the prototype maps to a heavier material.
    var material: Material {
        switch self {
        case .subtle: return .ultraThinMaterial
        case .standard: return .thinMaterial
        case .heavy: return .thickMaterial
        }
    }
}

// MARK: - Fonts & numeric fidelity helpers

extension Font {
    /// Convenience matching the prototype's default system font stack (`--ui`); SwiftUI's
    /// `.system` font already resolves to SF Pro on macOS, so no custom font registration is
    /// needed.
    static func volar(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The prototype's `--mono` instrument face (`ui-monospace, SFMono-Regular, Menlo, …`).
    /// Reserved for instrument readouts: WIP counter, timers, step counts, estimates — NOT
    /// general UI copy. SwiftUI's `.system(design: .monospaced)` resolves to SF Mono on macOS,
    /// matching the prototype's stack head (`ui-monospace`/`SFMono-Regular`).
    static func volarMono(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// `fontVariantNumeric: tabular-nums` equivalent (§6 fidelity mapping).
    func volarTabularNumbers() -> some View {
        monospacedDigit()
    }
}

/// Shared motion curves so every interaction feels like one system. Spring-based for a soft,
/// premium feel. NEVER use `.repeatForever` on a MenuBarExtra/NSStatusItem-hosted view. Durations
/// unchanged by the retheme — all four are already state-change-only and ≤380ms, consistent with
/// the Studio Dark motion rule ("minimal, state-change only, ≤300ms-ish, no looping/breathing").
enum VolarMotion {
    /// Hover / active / selection feedback — snappy but soft.
    static let hover = Animation.spring(response: 0.26, dampingFraction: 0.82)
    /// Press-down feedback — quick.
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.72)
    /// List insert / remove / reorder.
    static let list = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Capture-state cross-fades / banners.
    static let state = Animation.easeInOut(duration: 0.20)
}

// MARK: - Spotlight primitive (design.md §3.4)

/// The reusable radial pool + vignette-into-shadow that sits behind exactly ONE (the active/NOW)
/// task. Code unchanged by RETHEME 4 (design.md §8: "SpotlightBackground giữ nguyên code, chỉ ăn
/// theo token mới") — it just reads `nowGlow`/`nowGlowSoft`/`bg`, which are now the purple/light-
/// dark tokens above instead of mint/graphite-only ones. Two layers, matching the prototype 1:1:
///   1. `.pool` — a soft radial glow (`nowGlow` → `nowGlowSoft` → clear), blurred.
///   2. `.vignette` — a radial overlay that settles the pool's edges into `bg` shadow, live per
///      appearance since `bg` itself is now dynamic.
/// UNVERIFIED: not build-checked on this machine (Windows, no Xcode) — `RadialGradient`,
/// `ZStack`, and `.blur(radius:)` are all macOS 10.15+ SwiftUI API, so this should compile
/// cleanly on the macOS 14 floor, but the composited visual result hasn't been rendered/verified.
struct SpotlightBackground: ViewModifier {
    /// When `false`, renders nothing — so a view can conditionally spotlight only the active task
    /// (`isActive: task.id == appState.activeTaskID`, wired up by the view layer later) without an
    /// `if`/`else` at every call site.
    var isActive: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if isActive {
                        RadialGradient(
                            colors: [VolarColor.nowGlow, VolarColor.nowGlowSoft, Color.clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 260
                        )
                        .blur(radius: 6)
                    }
                }
                .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if isActive {
                        RadialGradient(
                            colors: [Color.clear, VolarColor.bg.opacity(0.45)],
                            center: UnitPoint(x: 0.5, y: 0.32),
                            startRadius: 140,
                            endRadius: 320
                        )
                    }
                }
                .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Applies the NOW spotlight pool + vignette behind this view. Intended for exactly one
    /// (the NOW) task container at a time — the app has one saturated hue and one spotlight
    /// (design.md §1).
    func volarSpotlight(isActive: Bool = true) -> some View {
        modifier(SpotlightBackground(isActive: isActive))
    }
}
