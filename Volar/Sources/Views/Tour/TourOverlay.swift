// Sources/Views/Tour/TourOverlay.swift — the first-run guided coach-mark tour's visual layer: a
// dimmed scrim over the REAL main window with a spotlight hole cut around whichever control the
// current `TourStop` teaches, a mint/accent ring around that hole, and a tooltip card with
// dots + Skip/Back/Next (or, on the final stop, the calendar-connect actions).
//
// Mounted by `TodayView.body` inside a `GeometryReader`, gated on `appState.tourActive`:
//   .overlayPreferenceValue(TourAnchorKey.self) { anchors in
//       if appState.tourActive {
//           GeometryReader { proxy in TourOverlay(anchors: anchors, proxy: proxy) }
//       }
//   }
// `anchors` is every `.tourAnchor(_:)`-tagged view's bounds (Sidebar's capture button + key
// badges, TodayView's task-list column, the two "Start focus"/"Focus" buttons), already resolved
// into ONE dictionary by `TourAnchorKey.reduce` by the time it reaches this mount point. `proxy` is
// this same `GeometryReader`'s own coordinate space — `proxy[anchor]` (not `anchor` alone) is what
// actually turns an `Anchor<CGRect>` into a concrete `CGRect` usable for `.position`/sizing math.
import SwiftUI

struct TourOverlay: View {
    let anchors: [TourAnchorID: Anchor<CGRect>]
    let proxy: GeometryProxy

    @Environment(AppState.self) private var appState: AppState
    @FocusState private var isFocused: Bool

    /// Same alias convention as `Sidebar`/`TodayView`/`FocusOverlay`/`OnboardingView` — every
    /// color in this file traces back through here to `Theme.swift`, never a literal hex.
    private var accent: Accent { appState.accent.accent }

    // MARK: - Sizing constants

    private static let cardWidth: CGFloat = 300
    /// Estimated rendered height of the tooltip card, used ONLY to POSITION it (`cardOrigin`
    /// below) — never to constrain its actual layout, so a wrong guess can never crop content, it
    /// can only shift the card a few points off from perfectly centered under/above the hole.
    /// // UNVERIFIED: not measured on a Mac (no Xcode/Swift toolchain on this machine) — a rough
    /// guess at title + ~2-line body + a dots/Skip/Back/Next footer row at this card's ~300pt
    /// width; the final stop's calendar UI adds another row or two, which this same rough estimate
    /// also has to cover (a few points of drift there, not a crop, per the note above).
    private static let estimatedCardHeight: CGFloat = 200
    /// How far the card sits from the spotlight hole (above or below it).
    private static let cardGap: CGFloat = 14
    /// Keeps the card's edges off the window's own edges regardless of where the anchor sits.
    private static let cardMargin: CGFloat = 16
    /// How far the spotlight hole/ring extend past the anchored element's own bounds — "a little
    /// breathing room around the real control," not a tight outline glued to its exact pixels.
    private static let holeOutset: CGFloat = 6

    var body: some View {
        ZStack {
            scrimWithHole
            if let rect = resolvedRect {
                ring(for: rect)
            }
            cardLayer
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .animation(VolarMotion.state, value: appState.tourStepIndex)
        // Keyboard support mirrors `FocusOverlay.swift`'s exact convention: `.focusable()` +
        // `.focusEffectDisabled()` (no visible focus ring on this fullscreen surface) + a
        // `@FocusState` flipped true on appear so Esc/Return are captured immediately without the
        // user having to click into the overlay first.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            appState.endTour()
            return .handled
        }
        .onKeyPress(.return) {
            advance()
            return .handled
        }
    }

    // MARK: - Anchor resolution

    /// Resolves the current stop's spotlight rect, in THIS overlay's own coordinate space
    /// (`proxy`): try the primary `anchor` first, then `fallbackAnchor` if the primary never
    /// rendered this run (see `TourStop.anchor`'s doc comment for why the "focus" stop is the one
    /// that actually needs this — its primary button only exists once a task is NOW-eligible).
    /// `nil` means "no real element to point at" — either the stop genuinely has none (the
    /// calendar stop) or, defensively, neither anchor resolved even though one was expected; either
    /// way `TourOverlay` degrades to a centered, hole-less card rather than crashing.
    private var resolvedRect: CGRect? {
        guard let stop = appState.tourStop else { return nil }
        if let id = stop.anchor, let anchor = anchors[id] {
            return proxy[anchor]
        }
        if let id = stop.fallbackAnchor, let anchor = anchors[id] {
            return proxy[anchor]
        }
        return nil
    }

    private func advance() {
        appState.tourNext()
    }

    // MARK: - Scrim + spotlight hole

    /// The dimmed backdrop with a hole punched around `resolvedRect`, if there is one. Uses
    /// `.blendMode(.destinationOut)` inside a `.compositingGroup()` — the standard SwiftUI
    /// "spotlight mask" idiom: the punch shape's own fill color is irrelevant (only its alpha
    /// coverage matters for a destination-out composite), so it's left unstyled rather than adding
    /// a `.fill(...)` that would do nothing but suggest otherwise.
    ///
    /// `.contentShape(Rectangle())` + an empty `.onTapGesture {}` make the WHOLE scrim — including
    /// the punched-out hole — swallow clicks. That is deliberate, not an oversight: the hole is a
    /// visual spotlight only, not a literal window back into the live app. Letting a click through
    /// the hole would let the user, say, start a real voice capture or toggle a real task mid-tour,
    /// which the tour's own Skip/Back/Next state has no way to account for.
    private var scrimWithHole: some View {
        ZStack {
            VolarColor.bg.opacity(0.78)
            if let rect = resolvedRect {
                let hole = rect.insetBy(dx: -Self.holeOutset, dy: -Self.holeOutset)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .blendMode(.destinationOut)
                    .allowsHitTesting(false)
            }
        }
        .compositingGroup()
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// The accent ring + soft glow traced around the same hole the scrim just cut — drawn OUTSIDE
    /// `scrimWithHole`'s own `.compositingGroup()` so its stroke/shadow paint normally instead of
    /// also being subject to the destination-out blend. `appState.accent.accent`, never a literal
    /// hex (hard project rule — every color in this file traces back to `Theme.swift`).
    private func ring(for rect: CGRect) -> some View {
        let hole = rect.insetBy(dx: -Self.holeOutset, dy: -Self.holeOutset)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(accent.solid, lineWidth: 1.5)
            .frame(width: hole.width, height: hole.height)
            .position(x: hole.midX, y: hole.midY)
            .shadow(color: accent.glow, radius: 14)
            .allowsHitTesting(false)
    }

    // MARK: - Card placement

    /// Pure placement helper (no `AppState`/environment reads) so `Tests/TourFlowTests.swift` can
    /// exercise the clamping behavior directly, without a live view hierarchy: `rect == nil` (the
    /// calendar stop) centers the card in `bounds`; otherwise the card sits `cardGap` below the
    /// hole when there's room beneath it (`rect.maxY` in the top 60% of the window), or above it
    /// otherwise — horizontally centered on the hole's midpoint, then clamped on both axes so it
    /// never renders partially off-window at any anchor position (including one flush against an
    /// edge/corner). `cardSize` is `TourOverlay`'s own `(cardWidth, estimatedCardHeight)` constants
    /// in production; tests pass their own sizes to probe edge cases directly.
    ///
    /// Returns the card's TOP-LEFT origin (not a center point) — `cardLayer` below converts that
    /// to the center `.position(_:)` itself expects, since `CGPoint`-as-origin is the more natural
    /// unit for both this function's own math (rect-relative placement) and its test assertions
    /// (`x >= margin`, `x + cardSize.width <= bounds.width - margin`, etc.).
    static func cardOrigin(for rect: CGRect?, cardSize: CGSize, in bounds: CGSize) -> CGPoint {
        guard let rect else {
            let x = (bounds.width - cardSize.width) / 2
            let y = (bounds.height - cardSize.height) / 2
            return CGPoint(x: x, y: y)
        }

        let placeBelow = rect.maxY < bounds.height * 0.6
        let y = placeBelow ? rect.maxY + cardGap : rect.minY - cardGap - cardSize.height
        let x = rect.midX - cardSize.width / 2

        return CGPoint(x: clamp(x, extent: cardSize.width, in: bounds.width), y: clamp(y, extent: cardSize.height, in: bounds.height))
    }

    /// Clamps a single-axis origin so `[value, value + extent]` stays inside `[margin, total -
    /// margin]`. If the window is smaller than `extent + 2*margin` (a degenerate case no real
    /// window at this app's `minWidth: 820, minHeight: 560` floor should ever hit, but the math
    /// must not blow up on a preview/test-supplied tiny `bounds`), the margin requirement is
    /// dropped and the card is simply centered on this axis instead of clamped into an inverted
    /// (max < min) range.
    private static func clamp(_ value: CGFloat, extent: CGFloat, in total: CGFloat) -> CGFloat {
        let idealMin = cardMargin
        let idealMax = total - extent - cardMargin
        guard idealMax >= idealMin else { return (total - extent) / 2 }
        return min(max(value, idealMin), idealMax)
    }

    @ViewBuilder
    private var cardLayer: some View {
        if let stop = appState.tourStop {
            let size = CGSize(width: Self.cardWidth, height: Self.estimatedCardHeight)
            let origin = Self.cardOrigin(for: resolvedRect, cardSize: size, in: proxy.size)
            card(for: stop)
                .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        }
    }

    // MARK: - Tooltip card

    private func card(for stop: TourStop) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stop.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VolarColor.textPri)
                .fixedSize(horizontal: false, vertical: true)

            Text(stop.body)
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textSec)
                .fixedSize(horizontal: false, vertical: true)

            if stop.isFinal {
                calendarSection
            }

            footer(for: stop)
        }
        .padding(16)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(VolarColor.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VolarColor.borderHi, lineWidth: 0.5)
        )
    }

    /// Progress dots — same capsule-dot idiom as `OnboardingView.stepDots` (active = wide filled
    /// pill in the accent color, inactive = a small neutral dot), just reading `TourStop.all`'s
    /// count/`appState.tourStepIndex` instead of `OnboardingView`'s own 1...3 step range.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(TourStop.all.indices, id: \.self) { index in
                Capsule()
                    .fill(index == appState.tourStepIndex ? accent.solid : VolarColor.veil(0.15))
                    .frame(width: index == appState.tourStepIndex ? 18 : 6, height: 6)
            }
        }
        .animation(VolarMotion.hover, value: appState.tourStepIndex)
    }

    /// Dots, then Skip/Back/Next. Skip and Back are unconditional-by-position (Skip always
    /// present, Back only once `tourStepIndex > 0`) even on the final stop — where the footer's
    /// trailing slot is filled by the calendar-connect actions (`calendarSection`) instead of a
    /// "Next →" button, per the contract's fixed footer layout. Skip and the final stop's own
    /// "Maybe later"/"Finish" end up calling the exact same `appState.endTour()` in that case,
    /// which is an intentional, harmless duplication (footer shape stays identical across all four
    /// stops) rather than a bug.
    private func footer(for stop: TourStop) -> some View {
        HStack(spacing: 10) {
            dots
            Spacer(minLength: 8)
            Button("Skip") { appState.endTour() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
            if appState.tourStepIndex > 0 {
                Button("Back") { appState.tourBack() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
            }
            if !stop.isFinal {
                nextButton
            }
        }
    }

    private var nextButton: some View {
        primaryButton("Next \u{2192}") { advance() }
    }

    // MARK: - Final stop: calendar connect (contract with agent B's `CalendarAccess.swift`)

    /// Drives entirely off `appState.calendarAccess.status` — the live EventKit access state agent
    /// B's `CalendarAccess` owns (`Sources/Integrations/CalendarAccess.swift`). No case here ever
    /// renders red for a denied/restricted state (hard project rule, "no red for status") — that
    /// state gets the same calm neutral copy/coloring as every other non-error informational line
    /// in this app.
    @ViewBuilder
    private var calendarSection: some View {
        switch appState.calendarAccess.status {
        case .notDetermined:
            HStack(spacing: 8) {
                primaryButton("Enable Calendar") {
                    // FIX 6: routes through `AppState.enableCalendarAccess()` (awaits the real
                    // EventKit prompt, then immediately reconciles the calendar mirror) instead of
                    // calling `calendarAccess.requestAccess()` directly — a fresh grant here must
                    // take effect right away rather than waiting for some later task edit to
                    // trigger the first `reconcile(tasks:)` call.
                    Task { await appState.enableCalendarAccess() }
                }
                secondaryButton("Maybe later") { appState.endTour() }
            }
        case .granted:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(VolarColor.done).frame(width: 6, height: 6)
                    Text("Calendar connected \u{00B7} \(appState.calendarAccess.calendarCount) calendar\(appState.calendarAccess.calendarCount == 1 ? "" : "s")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textSec)
                }
                primaryButton("Finish") { appState.endTour() }
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 10) {
                Text("Calendar access is off. You can turn it on in System Settings.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    secondaryButton("Open System Settings") { appState.calendarAccess.openSystemSettings() }
                    primaryButton("Finish") { appState.endTour() }
                }
            }
        case .unavailable:
            primaryButton("Finish") { appState.endTour() }
        }

        if let error = appState.calendarAccess.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textMut)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared button styles (small/local — this card's own footer + calendar row only)

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(VolarColor.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09) — xem
                // `Sidebar.swift`'s `SectionHeaderRow`. Đây là nút đi tiếp của guided tour, tức thứ
                // người dùng MỚI bấm trong vài phút đầu tiên: một nút không ăn click ở đây là ấn
                // tượng đầu tiên về app.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(accent.solid)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .volarHairline(cornerRadius: 8)
    }
}

// MARK: - Previews

/// Builds a fresh, never-seen-the-tour `AppState`, fast-forwards it to `stepIndex` via the real
/// `tourNext()` (not by poking `tourStepIndex` directly — there is no way to from outside this
/// file, and there shouldn't be), and mounts `TourOverlay` with an EMPTY anchor map. An empty map
/// means every stop's `resolvedRect` is `nil` here — every preview below renders the calendar
/// stop's "no anchor" centered-card layout regardless of which stop is selected, since previews
/// have no real `Sidebar`/`TodayView` chrome to anchor against. Good enough to review the card/
/// scrim/footer content and the calendar-status branches; the anchored hole/ring geometry itself
/// needs the real window (see `docs/mac-verify-checklist.md`'s manual verification steps).
@MainActor
private func previewOverlay(stepIndex: Int) -> some View {
    let state = AppState()
    state.startTourIfNeeded()
    for _ in 0..<stepIndex { state.tourNext() }
    return GeometryReader { proxy in
        TourOverlay(anchors: [:], proxy: proxy)
    }
    .environment(state)
    .frame(width: 900, height: 600)
    .background(VolarColor.bg)
}

#Preview("Stop 1 — capture") {
    previewOverlay(stepIndex: 0)
}

#Preview("Stop 4 — calendar (not determined)") {
    previewOverlay(stepIndex: 3)
}
