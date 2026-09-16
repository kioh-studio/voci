// Sources/Views/FocusOverlay.swift — fullscreen one-task Focus mode overlay
import SwiftUI

/// Default focus-session length, seconds — mirrors `AppState`'s own `25 * 60` default and the
/// prototype's `totalSecs` prop (there is no separate "total" stored on `AppState`, so this view
/// re-derives the progress fraction against the same constant `startFocus()`/`endFocus()` use).
private let focusTotalSeconds = 25 * 60

/// Fixed "always-dark" ink for content painted directly on the scrim `overlayContent` draws
/// (`Rectangle().fill(.ultraThinMaterial).overlay(...)` below). DECISION (this task, 2026-08-19,
/// per anh Khôi's spec 009 light-mode pass): the scrim itself stays a dark film in BOTH
/// light and dark system appearance — Focus mode is "tắt đèn để tập trung," and a pale scrim
/// doesn't serve that. That means anything drawn ON it must NOT use `VolarColor.textPri`/
/// `.textSec`/`.textMut`/`.border`/`.veil(_:)`/`.high`/`.med`/`.low`/`.bg` — those are dynamic as
/// of RETHEME 4 and flip polarity in light mode (`textPri` goes near-BLACK, `veil`/`border` go
/// near-BLACK film) which on a still-dark scrim means invisible text/chrome. These constants
/// mirror the exact hex values `VolarColor`'s DARK branch resolves to (`Shared/Design/Theme.swift`)
/// — i.e. this screen keeps looking exactly like it did before light mode existed, pinned instead
/// of accidentally inherited. Deliberately NOT applied to popover content (its own
/// appearance-following `.popover` chrome, never drawn on this scrim) — that one genuinely needs
/// to track the real system appearance, unlike everything else in this tree.
///
/// `SwitchBreakdownSuggestionBanner`
/// below (shared verbatim with `TodayView`'s NOW hero card) used to be a real gap here: pinning
/// their `VolarColor.*` ink to this enum would've fixed them on this scrim but broken them on
/// `TodayView`'s normal, appearance-following panel. Opus's follow-up (2026-08-19) closed that gap
/// a different way — `FocusOverlay.body` now sets `.environment(\.colorScheme, .dark)` on the
/// whole subtree, so those four banners' own dynamic tokens resolve to their dark branch here
/// without any code of theirs changing, while still resolving normally (light or dark) inside
/// `TodayView`, which never sees this override.
///
/// ponytail: `FocusInk` is now theoretically redundant with that `.environment` override — every
/// `VolarColor.*` in this subtree already resolves dark on its own. Kept anyway because this repo
/// has no Swift toolchain to build/verify on (Windows-authored, blind) and `.environment(\.colorScheme, .dark)`
/// has never been run once. Pinned constants are the floor that can't be undone by a framework
/// mechanism behaving unexpectedly; the `.environment` override is what actually closes the
/// four-banner gap. Delete `FocusInk` (revert call sites to `VolarColor.*`) only after a Mac build
/// visually confirms Focus mode still reads correctly with the system in light mode.
private enum FocusInk {
    static let text = Color(volar: 0xF2F2F7)      // == VolarColor.textPri, dark branch
    static let textSec = Color(volar: 0x98989D)   // == VolarColor.textSec, dark branch
    static let textMut = Color(volar: 0x7C7C80)   // == VolarColor.textMut, dark branch
    static let high = Color(volar: 0xFF9F6B)      // == VolarColor.high, dark branch
    static let med = Color(volar: 0xD9B77A)       // == VolarColor.med, dark branch
    static let low = Color.white.opacity(0.30)    // == VolarColor.low, dark branch (white film)
    static let border = Color.white.opacity(0.10) // == VolarColor.border, dark branch
    /// == `VolarColor.veil(_:)`'s dark branch (white film at `opacity`).
    static func veil(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
    static let scrim = Color(volar: 0x1C1C1E)     // == VolarColor.bg, dark branch
}

/// Fullscreen "one task" focus overlay — ports `volar-focus.jsx`'s `VolarFocusOverlay`. Reads all
/// state from `AppState` via the environment (frozen contracts, spec §4) instead of taking props:
/// the app only ever has one `AppState` instance, injected at the scene root.
///
/// FIX B: display-only — the 1s countdown itself is now owned by `AppState` (`focusTimer`/
/// `focusTick()`, started from `startFocus()`), not this view. It used to own a `Timer.publish`
/// ticker locally, which stopped firing the instant this overlay's window closed (e.g. the user
/// switched away), freezing `focusSecondsLeft` and the menu-bar countdown, and never auto-ending
/// the session. This view now just reads `appState.focusSecondsLeft` like any other stored value.
struct FocusOverlay: View {
    @Environment(AppState.self) private var appState: AppState
    @FocusState private var isFocused: Bool

    private var accent: Accent { appState.accent.accent }

    var body: some View {
        let openTasks = appState.openTasks

        Group {
            if openTasks.isEmpty {
                // Mirrors the JSX `if (!task) return null;` guard.
                EmptyView()
            } else {
                let clampedIndex = min(max(appState.focusIndex, 0), openTasks.count - 1)
                overlayContent(task: openTasks[clampedIndex], openTasks: openTasks, index: clampedIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            goToPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            goToNext()
            return .handled
        }
        // Opus, 2026-08-19 follow-up: pins the WHOLE overlay subtree — including the four banners
        // shared with `TodayView` (`SwitchBreakdownSuggestionBanner`, plus every `VolarColor.*` anywhere in this
        // tree) — to the dark branch, regardless of the system's actual light/dark setting. This
        // is the framework's own built-in "on-scrim vs on-panel" context switch: SwiftUI resolves
        // every dynamic `Color`/`NSColor` against `\.colorScheme`, so overriding it here (outermost
        // modifier, applies to the whole subtree) makes those same banners keep resolving normally
        // when `TodayView` renders them — this override never reaches that call site. Cheaper than
        // threading an `onScrim` flag through both files. See `FocusInk`'s doc comment below for
        // why the pinned constants stay anyway.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Layout

    private func overlayContent(task: TaskItem, openTasks: [TaskItem], index: Int) -> some View {
        ZStack {
            // Heavy dark glass: `.ultraThinMaterial` + a dark tint layered on top. Pinned to
            // `FocusInk.scrim` (a fixed dark hex), NOT the dynamic `VolarColor.bg` token — `bg`
            // turns WHITE in light mode as of RETHEME 4, which would turn "tắt đèn để tập trung"
            // into a bright wash instead of a dark one. See `FocusInk`'s doc comment above for the
            // full reasoning; `FullScreenTakeoverWindow.swift` pins the same way for the same
            // reason.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(FocusInk.scrim.opacity(0.78))

            VStack(spacing: 0) {
                Text(appState.focusPaused ? "Paused" : "Focus")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.98) // 0.18em @ 11pt
                    .textCase(.uppercase)
                    .foregroundStyle(FocusInk.textMut) // on the scrim — pinned ink, see `FocusInk`
                    .padding(.bottom, 10)

                Text(formattedTime(appState.focusSecondsLeft))
                    .font(Font.volarMono(size: 76, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(timerColor)
                    .opacity(appState.focusPaused ? 0.45 : 1)
                    .shadow(color: timerColor.opacity(0.27), radius: 40)
                    .animation(VolarMotion.hover, value: appState.focusPaused)

                progressHairline
                    .padding(.top, 20)

                taskInfo(task)
                    .padding(.top, 40)

                focusPrimaryActions(task)
                    .padding(.top, 26)

                // FR-030: the one-time "want to split this up?" invite, whenever one's pending —
                // shared with `TodayView`'s hero card (same `AppState.switchBreakdownSuggestion`),
                // see `SwitchBreakdownSuggestionBanner` at the bottom of this file.
                if let suggestion = appState.switchBreakdownSuggestion {
                    SwitchBreakdownSuggestionBanner(task: suggestion)
                        .padding(.top, 18)
                }

            }

            VStack {
                HStack {
                    Spacer()
                    topRightButtons
                }
                Spacer()
                bottomNav(openTasks: openTasks, index: index)
            }
            .padding(14)
        }
    }

    private var progressHairline: some View {
        let total: CGFloat = 240
        let frac = min(max(Double(appState.focusSecondsLeft) / Double(focusTotalSeconds), 0), 1)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(FocusInk.veil(0.10)) // on the scrim — pinned ink, see `FocusInk`
                .frame(width: total, height: 2)
            RoundedRectangle(cornerRadius: 1)
                .fill(timerColor)
                .frame(width: total * frac, height: 2)
        }
        .animation(.linear(duration: 1), value: appState.focusSecondsLeft)
    }

    private func taskInfo(_ task: TaskItem) -> some View {
        VStack(spacing: 10) {
            Text(task.title)
                .font(.system(size: 23, weight: .medium))
                .tracking(-0.345) // -0.015em @ 23pt
                .multilineTextAlignment(.center)
                .foregroundStyle(FocusInk.text) // on the scrim — pinned ink, see `FocusInk`

            HStack(spacing: 8) {
                Circle().fill(priorityColor(task.priority)).frame(width: 5, height: 5)
                Text(priorityLabel(task.priority))
                if let dur = task.durationLabel {
                    Text("·").opacity(0.4)
                    Text(dur)
                        .font(Font.volarMono(size: 12))
                        .monospacedDigit()
                }
                if let badge = task.timeBadge {
                    Text("·").opacity(0.4)
                    Text(badge)
                        .font(Font.volarMono(size: 12))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(FocusInk.textSec) // on the scrim — pinned ink, see `FocusInk`

            // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain here — this block through
            // `switchButton` below has not been compiled, run, or seen on screen. Needs a Mac visual
            // pass (see final report's verify checklist) before shipping.
            //
            // Re-entry context (FR-030's "last step, resume note, transcript" list): whatever this
            // task already carries resurfaces here every time it's the one in focus — including the
            // moment you come back to it after switching away — so you can pick the thread back up.
            // Uses only data `TaskItem` already has (`sourceTranscript`/`resumeNote`/`parentId`-
            // linked children); no new field. Shown unconditionally whenever present, not gated
            // behind a "was this specifically switched away" flag — there is no such flag to gate on
            // without new state, and showing real context is harmless on a first visit too.
            if let progress = stepProgress(for: task) {
                (
                    Text("\(progress.done)").font(Font.volarMono(size: 11.5).monospacedDigit())
                    + Text(" of ").font(.system(size: 11.5))
                    + Text("\(progress.total)").font(Font.volarMono(size: 11.5).monospacedDigit())
                    + Text(" steps done").font(.system(size: 11.5))
                )
                    .foregroundStyle(FocusInk.textMut) // on the scrim — pinned ink, see `FocusInk`
            }
            // 2026-09-06: this line used to only DISPLAY `resumeNote`, and nothing anywhere in the
            // app ever wrote it — so it was always empty. It is now the field you type it into,
            // right where you are when you have to drop the task. `.id(task.id)` rebuilds the
            // field (and its draft) when Switch/prev/next hands focus to a different task.
            ResumeNoteField(task: task)
                .id(task.id)
            if let transcript = task.sourceTranscript, !transcript.isEmpty {
                Text("\u{201C}\(transcript)\u{201D}")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(FocusInk.textMut) // on the scrim — pinned ink, see `FocusInk`
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 40)
    }

    /// Breakdown-step progress for a task with children ("N of M steps done"), or `nil` when it has
    /// none — derived entirely from existing data (`TaskItem.parentId`/`status`), no new field.
    private func stepProgress(for task: TaskItem) -> (done: Int, total: Int)? {
        let children = appState.tasks.filter { $0.parentId == task.id }
        guard !children.isEmpty else { return nil }
        return (children.filter(\.done).count, children.count)
    }

    /// "Mark done" và "Switch" cạnh nhau, ngang hàng. Nút "Stuck?" thứ ba đã bỏ (anh Khôi
    /// 2026-08-22: "cái này vô dụng quá") — cùng toàn bộ ba banner và cái picker của nó.
    private func focusPrimaryActions(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            markDoneButton(task)
            switchButton
        }
    }

    private func markDoneButton(_ task: TaskItem) -> some View {
        Button {
            appState.completeFocusTask(task.id)
        } label: {
            HStack(spacing: 8) {
                // Hardcoded `.white`, not a token — intentional: this icon/text sits on
                // `accent.solid`'s own filled pill, not directly on the scrim, and `accent.solid`'s
                // light+dark variants are both tuned in `Theme.swift` to hit ≥6:1 contrast with
                // white text specifically, so white text stays correct in either appearance.
                VolarIcon(.check, size: 13, color: .white, weight: .semibold)
                Text("Mark done")
            }
            .font(.system(size: 13, weight: .medium))
            .tracking(-0.065) // -0.005em @ 13pt
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(accent.solid)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: accent.glow.opacity(0.25), radius: 24, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Switch ("đổi gió") — equal in standing to "Mark done" right next to it, never a menu item.
    /// Deliberately plain/neutral styling (no accent fill, no icon, no red): this is a completely
    /// normal thing to tap, not a warning or an admission of anything. Disabled (not hidden) when
    /// there's genuinely nowhere else to send focus, matching `bottomNav`'s existing prev/next
    /// disabled-at-the-bound convention right below.
    private var switchButton: some View {
        Button {
            appState.switchFocusTask()
        } label: {
            Text("Switch")
                .font(.system(size: 13, weight: .medium))
                .tracking(-0.065) // -0.005em @ 13pt
                .foregroundStyle(FocusInk.text) // on the scrim — pinned ink, see `FocusInk`
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                // `.background` below is chained on the Button, outside this label — without this,
                // the tappable region is just the text glyphs, not the full padded/bordered pill
                // that's visibly the button (luật 2026-08-09, clickable-area-covers-visible-area).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(FocusInk.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(appState.canSwitchFocusTask ? 1 : 0.4)
        .disabled(!appState.canSwitchFocusTask)
        .help("Move on to something else — this task isn't done, it just steps out for now.")
    }

    private var topRightButtons: some View {
        HStack(spacing: 6) {
            FocusRoundBtn(
                icon: appState.focusPaused ? .play : .pause,
                title: appState.focusPaused ? "Resume" : "Pause"
            ) {
                appState.toggleFocusPause()
            }
            FocusRoundBtn(icon: .x, title: "End session") {
                appState.endFocus()
            }
        }
    }

    private func bottomNav(openTasks: [TaskItem], index: Int) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                FocusRoundBtn(icon: .back, title: "Previous task (←)", disabled: index <= 0) {
                    goToPrevious()
                }
                Text("\(index + 1) of \(openTasks.count)")
                    .font(Font.volarMono(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(FocusInk.textSec) // on the scrim — pinned ink, see `FocusInk`
                    .frame(minWidth: 52)
                FocusRoundBtn(icon: .chevron, title: "Next task (→)", disabled: index >= openTasks.count - 1) {
                    goToNext()
                }
            }
            (
                Text("\(openTasks.count)").font(Font.volarMono(size: 11).monospacedDigit())
                + Text(" task\(openTasks.count == 1 ? "" : "s") left today").font(.system(size: 11))
            )
                .foregroundStyle(FocusInk.textMut) // on the scrim — pinned ink, see `FocusInk`
        }
    }

    // MARK: - Behavior

    private func goToPrevious() {
        appState.focusIndex = max(0, appState.focusIndex - 1)
    }

    private func goToNext() {
        let lastIndex = max(appState.openTasks.count - 1, 0)
        appState.focusIndex = min(lastIndex, appState.focusIndex + 1)
    }

    private func formattedTime(_ seconds: Int) -> String {
        let clamped = max(seconds, 0)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// The 76pt countdown digits, on the scrim — `.high`/`.med` pinned via `FocusInk` (see its doc
    /// comment) since the dynamic `VolarColor` versions swing toward near-black in light mode.
    /// `accent.solid` (the calm-state branch) is deliberately left DYNAMIC, not pinned: it's a
    /// saturated mint in both appearances (`#0C817B` light / `#66D4CF` dark, `Theme.swift`), so
    /// it never approaches the near-black-on-near-black failure this file is guarding against —
    /// only its vividness shifts slightly with system appearance, which is a minor, out-of-scope
    /// polish item, not a legibility bug.
    private var timerColor: Color {
        let s = appState.focusSecondsLeft
        if s <= 60 { return FocusInk.high }
        if s <= 300 { return FocusInk.med }
        return accent.solid
    }

    private func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: return FocusInk.high
        case .medium: return FocusInk.med
        case .low: return FocusInk.low
        }
    }

    private func priorityLabel(_ priority: Priority) -> String {
        switch priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// Small round glass icon button used for the pause/stop and prev/next controls. Private to this
/// file — ported from `volar-focus.jsx`'s `FocusRoundBtn`.
/// The "where I left off" line — read-only `Text` before 2026-09-06. Writes on Enter or when the
/// field loses focus, never per keystroke, so a store-backed `setResumeNote` (which reloads
/// `tasks`) can't run on every character.
private struct ResumeNoteField: View {
    @Environment(AppState.self) private var appState: AppState
    let task: TaskItem
    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("Where you left off\u{2026}", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(FocusInk.textMut) // on the scrim — pinned ink, see `FocusInk`
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .focused($editing)
            .onAppear { draft = task.resumeNote ?? "" }
            .onSubmit { appState.setResumeNote(task.id, draft) }
            .onChange(of: editing) { _, isEditing in
                if !isEditing { appState.setResumeNote(task.id, draft) }
            }
            .padding(.top, 2)
    }
}

private struct FocusRoundBtn: View {
    let icon: VolarIconName
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    init(icon: VolarIconName, title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // Hardcoded `Color.white`, not a token — correct as-is: this round button always sits
            // directly on `FocusOverlay`'s dark scrim (topRightButtons/bottomNav), never on a
            // light panel, so it needs the same fixed-bright treatment as `FocusInk` right above —
            // it just doesn't need the enum since this is the file's only caller.
            VolarIcon(icon, size: 12, color: Color.white.opacity(0.7), weight: .regular)
                .frame(width: 30, height: 30)
                // `.background`/`.overlay` below are chained on the Button, outside this label —
                // without this, the tappable region is just the icon glyph, not the full 30x30
                // circle that's visibly the button (luật 2026-08-09).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering && !disabled ? FocusInk.veil(0.12) : FocusInk.veil(0.06))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(FocusInk.veil(0.10), lineWidth: 0.5))
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(title)
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// FR-030's one-time "this looks like more than one step — split it up?" invite, shown after a
/// task's (never-displayed) `switchAwayCount` first crosses the threshold
/// (`AppState.maybeOfferBreakdown`). Deliberately NOT `private` — both `FocusOverlay` and
/// `TodayView`'s hero card render the exact same banner off the exact same
/// `AppState.switchBreakdownSuggestion`, so the copy/behavior can't drift between the two places
/// Switch is offered.
///
/// A single plain question, not a comment on the user: no "you keep avoiding this", no streak, no
/// red/warning styling. Declining ("Not now") just closes it — `AppState.switchBreakdownOffered`
/// already recorded this task as offered the moment the banner appeared, so it never asks again for
/// this task, even on a 4th/5th switch.
///
/// This view deliberately keeps DYNAMIC `VolarColor` tokens (not `FocusInk`) because `TodayView`'s
/// hero card above also renders it on a normal, appearance-following surface — pinning ink here to
/// suit `FocusOverlay`'s dark scrim would've broken it there. GAP CLOSED (Opus follow-up,
/// 2026-08-19): `FocusOverlay.body` now sets `.environment(\.colorScheme, .dark)` on its whole
/// subtree, so when THIS view renders inside `FocusOverlay` its `VolarColor.*` tokens (including
/// the "Split it up" button's `textPri`) resolve against the dark branch automatically, same as
/// everywhere else on that scrim — no change needed here. When `TodayView` renders this same view,
/// no such override is in effect, so it still tracks the real system appearance there. See
/// `FocusInk`'s doc comment in this file for why the pinned constants stay as a build-unverified
/// fallback regardless.
struct SwitchBreakdownSuggestionBanner: View {
    @Environment(AppState.self) private var appState: AppState
    let task: TaskItem

    var body: some View {
        HStack(spacing: 10) {
            Text("\u{201C}\(task.title)\u{201D} looks like it might be more than one step. Split it up?")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Not now") {
                appState.dismissSwitchBreakdownSuggestion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(VolarColor.textMut)

            Button("Split it up") {
                appState.acceptSwitchBreakdownSuggestion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(VolarColor.textPri)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
