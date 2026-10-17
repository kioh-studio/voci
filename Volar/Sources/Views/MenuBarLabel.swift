// Sources/Views/MenuBarLabel.swift — the actual MenuBarExtra label, ported from
// `design/volar-extras.jsx`'s `VolarMenuBar`. Three states driven by AppState: idle (plain mic),
// listening (`captureState == .recording`, accent mic + "REC"), and focus lock (`focusActive`,
// mic + accent dot + truncated active-task title + mono countdown). Kept compact for the actual
// menu-bar bar (no glass panel / fake system icons — those were only there to stage the artboard
// in the prototype).
import Foundation
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        // Badge "⏳ N" (số việc đang giao cho Claude) đã bỏ cùng tính năng delegation 2026-08-22,
        // nên ở đây không còn gì để ghép cạnh nội dung chính nữa.
        Group {
            if appState.focusActive {
                focusLockContent
            } else if appState.captureState == .recording {
                listeningContent
            } else {
                idleContent
            }
        }
        .onAppear {
            (NSApp.delegate as? AppDelegate)?.openMainWindow = { openWindow(id: "main") }
        }
    }

    // MARK: - Idle

    // Studio Dark: calm/quiet at rest — muted secondary-text tone rather than a raw white, so the
    // idle glyph recedes in the menu bar instead of reading as "on". UNVERIFIED (not rendered).
    /// Idle — mic, plus the NOW task's title when there is one (backlog "Đường vào Volar" [I6]).
    ///
    /// The menu bar is the one surface that is always on screen, so it is the cheapest possible
    /// answer to "what am I doing" — no hotkey, no window, no app switch. Reads
    /// `dashboardActiveTask`, the SAME property `focusLockContent` below and `TodayView`'s hero card
    /// read, so the bar can never name a different task than the app does.
    ///
    /// Deliberately NOT `nowAccent`: the mint spotlight is reserved for the one NOW task *inside*
    /// the app (Theme.swift's file header — "if two things on a screen are mint, one of them is
    /// wrong"), and the menu bar already spends it on the focus-lock state. Idle stays secondary
    /// text. Truncated at the same 120pt `focusLockContent` uses — the menu bar is contested space
    /// and a long title must never push other apps' items off the bar.
    private var idleContent: some View {
        HStack(spacing: 5) {
            VolarIcon(.mic, size: 14, color: VolarColor.textSec, weight: .regular)
            if let title = appState.dashboardActiveTask?.title {
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(VolarColor.textSec)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    // MARK: - Listening

    // Recording/capture indicator — intentionally still driven by `appState.accent` (the user's
    // selectable accent, preserved binding), NOT the reserved `nowAccent` spotlight: this badge
    // means "capturing audio", not "this is the NOW task". Only the font face moves to the
    // `volarMono` instrument token for Studio Dark fidelity. UNVERIFIED (not rendered).
    private var listeningContent: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(accentColors.glow)
                    .frame(width: 16, height: 16)
                    .opacity(0.3)
                    .blur(radius: 3)
                VolarIcon(.mic, size: 14, color: accentColors.solid, weight: .semibold)
            }
            Text("REC")
                .font(Font.volarMono(size: 10.5, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .tracking(0.3)
        }
    }

    // MARK: - Focus lock

    // This IS the single NOW/active task, so the small lock badge (mic + dot) is the one place in
    // the menu bar allowed to carry the reserved warm `nowAccent` — used sparingly on the badge
    // only, never washed across the title. The title itself stays calm/legible primary text; the
    // countdown is an instrument readout (mono face, cool `instrument` tone) per Theme.swift's own
    // "timers" example under §05. No looping/breathing animation added — static only, per the
    // historical AppKit layout-thrash removal. UNVERIFIED (not rendered).
    private var focusLockContent: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                VolarIcon(.mic, size: 14, color: VolarColor.nowAccent, weight: .semibold)
                Circle()
                    .fill(VolarColor.nowAccent)
                    .frame(width: 6, height: 6)
                    // Was `Color.black.opacity(0.5)` — went invisible/wrong-polarity in light mode
                    // (a status item's effective NSAppearance follows the *system menu bar*, and
                    // `veil()` resolves through that same dynamic-NSColor mechanism, so it separates
                    // the dot from the mic glyph correctly on both a light and a dark bar). No
                    // `.clipShape` on this Circle, so `.stroke` (not `.strokeBorder`) stays correct —
                    // the fill already IS the shape's bounds.
                    .overlay(Circle().stroke(VolarColor.veil(0.5), lineWidth: 0.5))
                    .shadow(color: VolarColor.nowGlow, radius: 3)
                    .offset(x: 2, y: 2)
            }

            if let title = appState.dashboardActiveTask?.title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)

                Text("\u{00B7}")
                    .font(.system(size: 11))
                    .foregroundStyle(VolarColor.textMut)
            }

            Text(timerLabel)
                .font(Font.volarMono(size: 11, weight: .medium))
                .foregroundStyle(VolarColor.instrument)
                .monospacedDigit()
        }
    }

    private var timerLabel: String {
        let seconds = max(appState.focusSecondsLeft, 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

// NOTE (light-mode pass, specs/009): the two `Color.black` backgrounds below are Xcode-canvas-only
// preview backdrops, not shipped UI — `MenuBarLabel`'s real `body` has no `.background` of its own
// at all; NSStatusItem draws it directly onto the system menu bar, whose color is OS-controlled and
// independent of the app's own light/dark appearance. Left as `Color.black` deliberately (approximates
// the traditional dark menu bar this label was designed against) rather than swapped for a
// `VolarColor` token, since a token would just track the *app's* appearance, not the bar's — out of
// scope for the light-mode retheme.
#Preview("Idle") {
    MenuBarLabel()
        .environment(AppState())
        .padding()
        .background(Color.black)
}

#Preview("Focus lock") {
    let appState = AppState()
    appState.focusActive = true
    appState.focusSecondsLeft = 2538
    return MenuBarLabel()
        .environment(appState)
        .padding()
        .background(Color.black)
}
