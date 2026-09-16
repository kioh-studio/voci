// Sources/Views/PopoverView.swift — 5-state quick-capture popover (spec §4/§5, volar-popover.jsx)
import SwiftUI
// T074: `TaskConflict` (contract C, `VolarCore/Sources/VolarCore/ConflictCheck.swift`, sibling-owned
// — not yet landed) is the only VolarCore symbol this file needs directly.
import VolarCore

/// Ported from `design/volar-popover.jsx`'s `VolarPopover`, driven entirely by
/// `appState.captureState` (`.idle/.recording/.parsing/.parsed/.saving/.done/.error`) instead of
/// the JSX's local/controlled `state` prop. Sizes itself to a fixed 340pt width internally, so
/// callers (the popover-hosting window/`NSPopover`, wired in Phase 3) just place this view.
///
/// Phase 3 (T024) reworks the confirm card for `ParsedTask` v2 (contracts/parsing-contract.md):
/// each present attribute renders as a dismissible chip; uncertain (<0.7 confidence) chips render
/// dashed with "?" and require an explicit tap to accept before they can be saved (constitution
/// II); `.taskDone` conditions below that bar show a task PICKER, never auto-attach; up to 10
/// tasks confirm as a compact set (still glance-and-dismiss — Enter saves all); a one-time sheet
/// gates the first cloud parse. All actual resolution/materialization lives in
/// `AppState.confirmSave()` (T025) — this file only renders `appState.confirmDrafts` and reports
/// taps back through `AppState`'s chip-interaction methods.
struct PopoverView: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var mounted = false

    private let width: CGFloat = 340

    var body: some View {
        let accent = appState.accent.accent

        VStack(alignment: .leading, spacing: 0) {
            hintRow(accent: accent)

            // Studio Dark: this inner group is the popover's one lit thing — the task actively
            // being captured/confirmed — so it (and only it) sits inside the warm spotlight pool.
            // `hintRow`/`errorActionsRow` stay outside, same as `menubar-now.html`'s `.pop-head`/
            // `.dock` sitting outside `.stage`. `showTranscript`'s condition (non-idle, non-error)
            // doubles as "is there a NOW thing to light right now".
            VStack(alignment: .leading, spacing: 0) {
                // Once the confirm card is up, the 42pt wave slot holds nothing (`showWave` is
                // recording/parsing only) except the `.done` check / `.error` copy — so it only
                // renders in the states that actually draw something there, instead of padding
                // the confirm panel with ~58pt of empty space.
                if showWave || appState.captureState == .done || appState.captureState == .error {
                    waveformSection(accent: accent)
                }

                // In `.parsed`/`.saving` this line is the first draft's title again ("+N more"),
                // which the card below repeats verbatim and editably — dead weight in the state
                // where the panel is at its tallest.
                if showTranscript && !showParsedCard {
                    transcriptSection()
                        .transition(.opacity)
                }

                if showParsedCard {
                    parsedCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showVoiceDoneCard {
                    voiceDoneCard(accent: accent)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Cycle-detection contract §3: BATCH-level, sits directly above `actionsRow`
                // (never inside `taskDraftCard`) because a cycle can span several drafts and so
                // belongs to none of their individual cards. Gated on the same `showActions`
                // lifetime as the row it sits above — `appState.confirmCycle` is only ever
                // non-nil while a batch is being confirmed.
                if showActions, let cycle = appState.confirmCycle {
                    cycleWarningRow(cycle)
                        .transition(.opacity)
                }

                if showActions {
                    actionsRow(accent: accent)
                        .transition(.opacity)
                }
            }
            .volarSpotlight(isActive: showTranscript)

            if appState.captureState == .error {
                errorActionsRow(accent: accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: width)
        .volarGlass(level: .heavy, cornerRadius: 18)
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 24)
        .scaleEffect(mounted ? 1 : 0.96)
        .opacity(mounted ? 1 : 0)
        .animation(VolarMotion.state, value: appState.captureState)
        .onAppear {
            // Appear animation: scale 0.96 -> 1 + fade, mirrors the JSX `mounted` flag flipped on
            // the next animation frame.
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                mounted = true
            }
        }
    }

    // MARK: - Visibility (mirrors JSX `showWave` / `showTranscript` / `showParsedCard` / `showActions`)

    private var showWave: Bool {
        appState.captureState == .recording || appState.captureState == .parsing
    }

    private var showTranscript: Bool {
        appState.captureState != .idle && appState.captureState != .error
    }

    private var showParsedCard: Bool {
        !showVoiceDoneCard
            && (appState.captureState == .parsed || appState.captureState == .saving || appState.captureState == .done)
            && !appState.confirmDrafts.isEmpty
    }

    private var showActions: Bool {
        !showVoiceDoneCard && (appState.captureState == .parsed || appState.captureState == .saving)
    }

    /// T036: a voice-done confirm (one-tap/disambiguation) or "no matching task" row is pending —
    /// mutually exclusive with the normal parsed-task confirm card / its Cancel+Save actions row,
    /// which render their own controls instead (`voiceDoneCard(accent:)`).
    private var showVoiceDoneCard: Bool {
        appState.voiceDoneConfirm != nil || appState.voiceDoneNoMatchTranscript != nil
    }

    // MARK: - Hint row

    private func hintRow(accent: Accent) -> some View {
        HStack(alignment: .center) {
            leftHint(accent: accent)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Kbd("Esc")
                Text("cancel").opacity(0.6)
            }
            .foregroundStyle(VolarColor.textMut)
        }
        .font(.system(size: 11.5))
        // FIX D: the hint row above promises "Esc cancel", but nothing actually had
        // `.keyboardShortcut(.cancelAction)` wired during `.recording`/`.parsing` — those two
        // states show no Cancel button at all (`actionsRow`/`errorActionsRow`'s own Esc-bound
        // Cancel/Dismiss buttons only ever render for `.parsed`/`.saving`/`.error`), so the
        // promised shortcut silently did nothing. A zero-size, invisible button carries the
        // shortcut instead of adding new visible chrome.
        .background(escCancelButton)
    }

    /// FIX D: invisible `.cancelAction`-bound button, mounted only while the hint row's "Esc
    /// cancel" copy has no other Cancel control backing it up.
    @ViewBuilder
    private var escCancelButton: some View {
        if appState.captureState == .recording || appState.captureState == .parsing {
            Button("") { appState.cancelCapture() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func leftHint(accent: Accent) -> some View {
        if let confirm = appState.voiceDoneConfirm {
            Text(confirm.candidates.count == 1 ? "Got it — confirm?" : "A few matches — pick one.")
                .foregroundStyle(VolarColor.textMut)
                .transition(.opacity)
        } else if appState.voiceDoneNoMatchTranscript != nil {
            Text("Didn't find a matching task.")
                .foregroundStyle(VolarColor.reschedule)
                .transition(.opacity)
        } else {
            leftHintByCaptureState(accent: accent)
        }
    }

    @ViewBuilder
    private func leftHintByCaptureState(accent: Accent) -> some View {
        switch appState.captureState {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 6) {
                PulsingDot(color: accent.solid)
                Text("Listening…")
            }
            .foregroundStyle(VolarColor.textMut)
            .transition(.opacity)
        case .parsing:
            Text("Parsing with AI…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .parsed:
            Text(appState.confirmDrafts.count > 1 ? "Looks right? Hit return to save all." : "Looks right? Hit return.")
                .foregroundStyle(VolarColor.textMut)
                .transition(.opacity)
        case .saving:
            Text("Saving…").foregroundStyle(accent.solid)
                .transition(.opacity)
        case .done:
            Text("Saved").foregroundStyle(VolarColor.done)
                .transition(.opacity)
        case .error:
            // `lineLimit` widened from the v1 2 lines to 3 — the cloud-consent explanation
            // (T024) runs longer than a typical capture-failure message; unrelated error copy
            // still fits comfortably within 3 lines.
            Text(appState.captureErrorDetail ?? "Didn't catch that.")
                .foregroundStyle(VolarColor.reschedule)
                .lineLimit(3)
                .transition(.opacity)
        }
    }

    // MARK: - Waveform / done check / error copy

    @ViewBuilder
    private func waveformSection(accent: Accent) -> some View {
        Group {
            if showWave {
                Waveform(
                    active: appState.captureState == .recording,
                    color: accent.solid,
                    glow: accent.glow,
                    bars: 32,
                    height: 42
                )
                .background(
                    // "Mic" breathing-glow affordance (menubar-now.html `.mic.live`) — active ONLY
                    // while `.recording` (never a resting loop), using the general/cool accent, not
                    // the reserved NOW amber ("nothing else warm").
                    MicBreathingGlow(isActive: appState.captureState == .recording, color: accent.glow)
                )
                .transition(.opacity)
            } else {
                HStack {
                    switch appState.captureState {
                    case .done:
                        ZStack {
                            Circle()
                                .fill(VolarColor.done)
                                .frame(width: 32, height: 32)
                                .shadow(color: VolarColor.done.opacity(0.5), radius: 24)
                            VolarIcon(.check, size: 18, color: VolarColor.bg, weight: .bold)
                        }
                        .transition(.opacity)
                    case .error:
                        // Matches the existing `pendingServerConsent` convention: this generic
                        // "Try again" placeholder is shown for every `.error` state, including
                        // consent prompts — unchanged from the pre-T024 behavior. Recolored off the
                        // destructive-red token onto the calm `reschedule` neutral (no red, anywhere).
                        Text("Try again")
                            .font(.system(size: 13))
                            .foregroundStyle(VolarColor.reschedule)
                            .transition(.opacity)
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .frame(height: 42)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Transcript

    private func transcriptSection() -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(transcriptText)
                .font(.system(size: 14.5))
                .lineSpacing(2)
                .foregroundStyle(appState.captureState == .recording ? VolarColor.textPri : VolarColor.textSec)
            if appState.captureState == .recording {
                BlinkingCaret(color: appState.accent.accent.solid)
            }
        }
        .frame(minHeight: 42, alignment: .topLeading)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// While `.recording`, the live streamed transcript from `SpeechCapture`. Otherwise, the
    /// first confirmed task's title stands in for it (multi-task: "+N more"), muted, matching the
    /// JSX's non-recording transcript styling.
    private var transcriptText: String {
        if appState.captureState == .recording {
            return appState.liveTranscript
        }
        guard let first = appState.confirmDrafts.first else { return appState.liveTranscript }
        let extra = appState.confirmDrafts.count - 1
        // `effectiveTitle` (not `task.title`) so this summary line reflects an in-progress edit
        // from the now-editable title field below, not the stale parser output.
        return extra > 0 ? "\(first.effectiveTitle)  +\(extra) more" : first.effectiveTitle
    }

    // MARK: - Parsed card (T024 — chips v2)

    /// Bounds `parsedCard()`'s scroll area (2026-07-28, confirm-list UI technical constraint:
    /// "long lists must scroll"). Comfortably fits 2-3 drafts with their new checkbox/duplicate/
    /// condition rows unscrolled on a typical display; a full 10-task batch (`TaskStore.
    /// maxBatchSize`) scrolls inside this instead of pushing the panel (`CapturePanelController`,
    /// out of this task's allowed files — see its own `fitToContent` doc comment) past the bottom
    /// of the screen. // UNVERIFIED: no Swift/Xcode on this machine to confirm `NSHostingView.
    /// fittingSize` measures a bounded `ScrollView` the way this assumes (see that same doc
    /// comment's own note on exactly this risk) — verify on Mac with a 4-5 task batch.
    private static let parsedCardMaxHeight: CGFloat = 300

    /// One `VStack` holding every confirmed draft's chip set, separated by hairlines when there's
    /// more than one (multi-task confirm: a compact reviewable set, still glance-and-dismiss).
    /// Wrapped in a `ScrollView` (2026-07-28) — previously a bare `VStack` with no scroll affordance
    /// at all, which was fine while a batch was short but had no ceiling for a full ≤10-task batch.
    private func parsedCard() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(appState.confirmDrafts.enumerated()), id: \.element.id) { offset, draft in
                    if offset > 0 {
                        Rectangle().fill(VolarColor.border).frame(height: 0.5)
                    }
                    taskDraftCard(draft, isPrimary: offset == 0)
                }
                // task_refs_v1 (2026-08-02): confirm-card updates to EXISTING tasks, one compact
                // card per `ConfirmUpdateDraft`, below every new-task draft — same hairline
                // separator this `ForEach` already uses between drafts. Renders nothing at all when
                // `appState.confirmUpdateDrafts` is empty (the common case, and every case before
                // this feature existed), so the no-reference path stays pixel-identical.
                confirmUpdateSection()
            }
            .padding(12)
        }
        .frame(maxHeight: Self.parsedCardMaxHeight)
        .background(VolarColor.card)
        .overlay(
            // NOW focus ring — this card is the one thing about to be saved (Enter), so its border
            // takes the reserved amber ring instead of the neutral hairline.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 6)
    }

    /// `isPrimary` (the first draft) is the NOW task — its title carries the one warm accent this
    /// popover uses. Any additional batched drafts (multi-task confirm) stay neutral, so there's
    /// still exactly one lit focal point even when several tasks are being saved together.
    ///
    /// 2026-07-28 (confirm-list UI, Việc 1): the whole card dims (`.opacity`) when `!draft.
    /// isIncluded` — readable and every control still tappable (SwiftUI `.opacity` never disables
    /// hit-testing, unlike `.disabled`/`allowsHitTesting(false)`), so unticking is a glance-and-
    /// reversible decision rather than the old destructive per-task "x" (`showRemove`/`removeDraft`,
    /// removed alongside this — that was the only call site for either).
    private func taskDraftCard(_ draft: ConfirmDraft, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                inclusionCheckbox(draft)
                // T-title-edit: was a read-only `Text(draft.task.title)` — now editable in place,
                // writing through `AppState.updateDraftTitle(_:forDraft:)` (never `task.title`
                // itself; see `ConfirmDraft`'s doc comment). `.textFieldStyle(.plain)` + no
                // background/border keeps the exact look the `Text` had.
                //
                // Wraps like the `Text` it replaced (up to 3 lines) — voice-parsed titles are
                // long, and a title you cannot read is a title you cannot check before saving.
                //
                // That costs work to keep "Enter saves": a vertical-axis TextField turns Return into
                // a newline and never calls `.onSubmit`, and a focused TextField also swallows the
                // Save button's `.keyboardShortcut(.defaultAction)` (`actionsRow`). So Return is
                // intercepted here with `.onKeyPress` (macOS 14+, this app's floor) BEFORE the field
                // can insert it, and `.handled` stops it going further. `.onSubmit` is kept as well:
                // it costs nothing and still fires if this ever runs as a single-line field.
                //
                // UNVERIFIED, and the one thing to check first if Enter misbehaves: whether
                // `.onKeyPress` sees Return ahead of the text-editing system at all. If it does not,
                // Enter will insert a newline instead of saving — `effectiveTitle` strips newlines
                // so a stray one can never reach the saved task, and the fallback is to drop
                // `axis:`/`lineLimit` and go back to a single-line field, where `.onSubmit` alone is
                // known to work.
                TextField(
                    "",
                    text: Binding(
                        get: { draft.effectiveTitle },
                        set: { appState.updateDraftTitle($0, forDraft: draft.id) }
                    ),
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isPrimary ? VolarColor.nowAccentSoft : VolarColor.textPri)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onKeyPress(.return) {
                        appState.confirmSave()
                        return .handled
                    }
                    .onSubmit { appState.confirmSave() }
                Spacer(minLength: 4)
            }
            NotesEditorControl(draft: draft, appState: appState)
            attributeChips(draft)
            conditionRows(draft)
            // task_refs_v1 (2026-08-02): extra `.taskDone`/`.afterDate` conditions merged onto THIS
            // draft by a sibling draft's update reference (`ConfirmDraft.refConditions`) — a
            // SEPARATE section from `conditionRows` above (different array, own index space), but
            // same visual language, right below it.
            refConditionRows(draft)
            duplicateHintRow(draft)
            overdueAdvisoryRow(draft)
            calendarConflictRow(draft)
            conflictAdvisoryRow(draft)
        }
        .opacity(draft.isIncluded ? 1 : 0.45)
    }

    /// Việc 1's checkbox — ticked by default (`ConfirmDraft.isIncluded` defaults `true`), shown on
    /// EVERY draft (even a single-draft batch — the user may still want to bail on the one task
    /// without dismissing the whole popover). A small custom control rather than SwiftUI's native
    /// `Toggle`/checkbox styles, matching this card's existing convention of hand-built chip/pill
    /// affordances (`Chip`, `dependencyPicker`'s dashed pill) rather than stock controls.
    private func inclusionCheckbox(_ draft: ConfirmDraft) -> some View {
        Button {
            appState.setDraftIncluded(draft.id, !draft.isIncluded)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(draft.isIncluded ? VolarColor.done.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(draft.isIncluded ? VolarColor.done : VolarColor.border, lineWidth: 1)
                    )
                if draft.isIncluded {
                    VolarIcon(.check, size: 9, color: VolarColor.done, weight: .bold)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .padding(.top, 2) // optically aligns with the title's first line, not its full 1-3 line height
    }

    /// T-overdue (2026-07-28): the confirm card's one-tap fix for a deadline the parser resolved
    /// to an instant already in the past at capture time (`ConfirmDraft.overdueSuggestion`,
    /// computed client-side/deterministically — see that field's doc comment). Same calm register
    /// as `conflictAdvisoryRow` right below (no red, no exclamation mark, never blocking — `Enter`
    /// still saves regardless), but unlike that row, THIS one gets a real quick-action: "was this
    /// overdue" and "what's a sane +1-day fix" are both plain `Date`/`Calendar` math with one
    /// obviously-right answer, which is exactly the property `conflictAdvisoryRow`'s conflicts
    /// DON'T have (see its own updated comment below). Two SEPARATE tap targets, deliberately not
    /// one shared `onTapGesture` the way `conflictAdvisoryRow`/`duplicateHintRow`'s header text
    /// use: the text is dismiss-only (`.contentShape`/`.onTapGesture`, same convention as
    /// `conflictAdvisoryRow`), the action is a real `Button` — nesting a tap gesture and a button
    /// in the same hit-testing region risks the wrong one firing, so this keeps them structurally
    /// apart (`Spacer` between) rather than layered.
    @ViewBuilder
    private func overdueAdvisoryRow(_ draft: ConfirmDraft) -> some View {
        if let suggestion = draft.overdueSuggestion, !draft.overdueDismissed, !draft.dismissed.contains(.deadline) {
            HStack(alignment: .top, spacing: 6) {
                Text(overdueAdvisoryText(suggestion))
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.dismissOverdueSuggestion(forDraft: draft.id)
                    }
                Spacer(minLength: 4)
                Button {
                    appState.applyOverdueSuggestion(forDraft: draft.id)
                } label: {
                    Text("Move to \(suggestion.suggestedDeadline.formatted(date: .omitted, time: .shortened)) tomorrow")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(VolarColor.reschedule)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    /// "Was due 3 hours ago" — `RelativeDateTimeFormatter` (stable Foundation API, well below this
    /// app's macOS 14 floor) rather than hand-rolled duration math, so pluralization/locale come
    /// free. `.short` unit style keeps the calm, low-key tone this whole row already has (no
    /// "3 hours, 12 minutes" precision that would read as alarmed). Compares against a fresh
    /// `Date()` at render time, not the frozen capture-time `now` the suggestion itself was
    /// computed against — "how long ago" should keep ticking forward while the card sits on
    /// screen, unlike the suggestion's own past/future classification, which must NOT change
    /// mid-session (see `ConfirmDraft.overdueSuggestion`'s doc comment).
    private func overdueAdvisoryText(_ suggestion: OverdueSuggestion) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: suggestion.originalDeadline, relativeTo: Date())
        return "Was due \(relative)"
    }

    /// specs/010-calendar-and-hard-deadlines/design.md §2.4(a): the highest-value warning in the
    /// whole feature — catching "that's when Hạnh has a meeting" while the user is still looking
    /// at the confirm card is far cheaper than letting them discover it at 2:25. `ConfirmDraft.
    /// calendarConflict` is already a fully-formatted display string ("14:00–15:00 · Team sync"),
    /// computed once in `buildConfirmDrafts` — same "never recomputed per render" convention as
    /// `overdueSuggestion`/`conflicts` right above/below. Deliberately calm, same register as
    /// `overdueAdvisoryRow`: `textSec`, no icon, no dismiss action (there's nothing to fix from
    /// here — it's information, not a nudge with a one-tap resolution).
    @ViewBuilder
    private func calendarConflictRow(_ draft: ConfirmDraft) -> some View {
        if let calendarConflict = draft.calendarConflict {
            Text(calendarConflict)
                .font(.system(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .padding(.top, 2)
        }
    }

    /// T074: AT MOST ONE calm advisory line — never a dialog, never a red/shame color (FR-036),
    /// never blocking (`Enter` still saves regardless — this row has no bearing on `actionsRow`'s
    /// Save button at all). Tapping it only dismisses the row itself; it never auto-modifies the
    /// draft (constitution II). A real quick-action for THIS row's conflicts remains deliberately
    /// out of scope, same self-review call as before — a capacity/collision/dependency conflict has
    /// no single obviously-right alternative time to suggest the way an overdue deadline does
    /// (`overdueAdvisoryRow` above, "Move to tomorrow" — client-side `Date` math with one sane
    /// answer), so this row stays dismiss-only.
    @ViewBuilder
    private func conflictAdvisoryRow(_ draft: ConfirmDraft) -> some View {
        if let conflict = draft.conflicts.first, !draft.conflictDismissed {
            HStack(alignment: .top, spacing: 6) {
                Text(conflictAdvisoryText(conflict))
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.dismissConflictAdvisory(forDraft: draft.id)
            }
        }
    }

    /// One short, calm sentence per `TaskConflict` case (contract C) — no exclamation-mark alarm
    /// copy, matching the example in the task brief ("3 tasks already due tomorrow — add anyway?").
    private func conflictAdvisoryText(_ conflict: TaskConflict) -> String {
        switch conflict {
        case .deadlineCapacity(let existingCount, _, let windowEnd):
            let day = windowEnd.formatted(.dateTime.weekday(.wide))
            return "\(existingCount) task\(existingCount == 1 ? "" : "s") already due \(day) — add anyway?"
        case .deadlineCollision(_, let title):
            return "Clashes with \u{201C}\(title)\u{201D} — add anyway?"
        case .dependsOnBlocked(_, let title):
            return "Waiting on \u{201C}\(title)\u{201D}, which is overdue"
        case .competesWithFrog(_, let title):
            return "Competes with today's frog, \u{201C}\(title)\u{201D}"
        case .possibleDuplicate(_, let title, _):
            return "Looks similar to \u{201C}\(title)\u{201D} — add anyway?"
        }
    }

    /// 2026-07-28 (confirm-list UI, Việc 2): `draft.duplicateCandidates` as an "Add new" vs "use
    /// existing" choice — never a red/destructive color (this is a HINT, not an error, same
    /// reasoning as `conflictAdvisoryRow` immediately above) and never auto-picked (constitution
    /// II — `ConfirmDraft.duplicateResolution` starts, and stays until an explicit tap here, at
    /// `.addNew`). A candidate UUID that no longer resolves in `openTasks` (deleted mid-confirm) is
    /// silently skipped rather than rendering a blank row or crashing.
    @ViewBuilder
    private func duplicateHintRow(_ draft: ConfirmDraft) -> some View {
        let candidates: [DuplicateCandidate] = draft.duplicateCandidates.compactMap { id in
            appState.openTasks.first { $0.id == id }.map { DuplicateCandidate(id: $0.id, title: $0.title) }
        }
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Might already exist:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.reschedule)
                FlowLayout(spacing: 6) {
                    duplicateOptionPill(label: "Add new", isSelected: draft.duplicateResolution == .addNew) {
                        appState.setDuplicateResolution(draft.id, .addNew)
                    }
                    ForEach(candidates) { candidate in
                        duplicateOptionPill(
                            label: candidate.title,
                            isSelected: draft.duplicateResolution == .useExisting(candidate.id)
                        ) {
                            appState.setDuplicateResolution(draft.id, .useExisting(candidate.id))
                        }
                    }
                }
                // Not obvious what picking "use existing" actually does (it looks like a filter, not
                // a merge) — spell out the consequence in one calm line, same "state it, don't make
                // the user guess" reasoning as every other constitution-II surface in this file.
                if case .useExisting = draft.duplicateResolution {
                    Text(
                        "Won't create a new task — updates the existing one with what you just said "
                        + "instead, and adds these conditions to it."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(VolarColor.textMut)
                    .lineLimit(2)
                }
            }
            .padding(.top, 2)
        }
    }

    /// One pill in `duplicateHintRow`'s row — same capsule/selection language as `PaywallView.
    /// planCard` (stronger border + tinted fill when selected) adapted to this popover's smaller
    /// chip scale, rather than a new selection idiom.
    private func duplicateOptionPill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? VolarColor.textPri : VolarColor.textSec)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(isSelected ? VolarColor.instrumentDim.opacity(0.28) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
                        isSelected ? VolarColor.instrument : VolarColor.border,
                        lineWidth: isSelected ? 1 : 0.5
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Deadline / estimate / priority / reminder / recurrence / kind — every PRESENT attribute
    /// renders as a dismissible chip; absent ones render nothing (T024).
    @ViewBuilder
    private func attributeChips(_ draft: ConfirmDraft) -> some View {
        FlowLayout(spacing: 6) {
            // T-edit-deadline (2026-07-28): `DeadlineControl` owns ALL THREE deadline states —
            // present+editable chip, dismissed (renders nothing, unchanged from before), and
            // absent (a quiet "Add time" affordance) — see its own doc comment for why this is a
            // separate `View` struct rather than another branch inlined here (it needs its own
            // `@State` to own the popover-editor's presentation).
            DeadlineControl(draft: draft, appState: appState)
            // T-manual-edit (2026-07-29, manual-edit-contract.md §3): estimate/priority/reminder
            // chips are now tap-to-edit, same "own `View` struct so `.popover`/`Menu` state stays
            // per-draft" reasoning as `DeadlineControl` right above — see each control's own doc
            // comment for why it's `.popover` (estimate/reminder: a plain preset list, following
            // the contract's explicit per-field assignment) vs `Menu` (priority — `dependencyPicker`'s
            // convention, ~801). All three read `draft.effective*` (never `draft.task.*`) so a tap
            // edit actually shows up here instead of the stale parser value.
            EstimateControl(draft: draft, appState: appState)
            PriorityControl(draft: draft, appState: appState)
            ReminderControl(draft: draft, appState: appState)
            if let recurrence = draft.task.recurrence, !draft.dismissed.contains(.recurrence) {
                Chip(
                    // Retheme §2: a recurrence cadence ("Every 3d") is a measurement readout, same
                    // family as the estimate/reminder chips right below — mono, not prose.
                    label: recurrenceLabel(recurrence.value),
                    uncertain: recurrence.isUncertain,
                    accepted: draft.accepted.contains(.recurrence),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.recurrence, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.recurrence, forDraft: draft.id) }
                )
            }
            // `.task` is the default/absent case — only a non-default kind (`.review`) is a
            // "present" attribute worth a chip (T024: "kind" is in the dismissible-chip list).
            if draft.task.kind != .task, !draft.dismissed.contains(.kind) {
                Chip(
                    label: kindLabel(draft.task.kind),
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.kind, forDraft: draft.id) }
                )
            }
            // Mi-1 (constitution II): `followUpReview` used to silently materialize an extra
            // `.review` task with no confirm-card representation at all. Defaults ON (matching the
            // parser's signal) but glance-and-dismiss like every other chip — dismissing it here
            // is what `confirmSave` reads to skip creating the derived task.
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                Chip(
                    label: "+ Review after done",
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.followUpReview, forDraft: draft.id) }
                )
            }
            // T-disposition (2026-07-28, "làm ngay lập tức" disposition): distinct from `.deadline`
            // above — this is WHEN the user said they'd start, not when it's due.
            //
            // T-manual-edit (2026-07-29): the "deliberately NOT editable" call this comment used to
            // make is superseded — manual-edit-contract.md §3 explicitly puts `startTime` in the
            // same tap-to-edit set as the other three scalar chips (anh Khôi's 7-field list). Now a
            // `.popover`+`DatePicker` control, same shape as `DeadlineControl`, via `StartTimeControl`
            // below — `startTime` stays inert display-only data (`TaskItem.startTime`'s own doc
            // comment, unchanged by this edit: it still never drives ordering/eligibility/reminders
            // on its own), only HOW it's set changed.
            StartTimeControl(draft: draft, appState: appState)
        }
    }

    /// Every `ParsedCondition`, in order — `.taskDone` gets the constitution-II picker row;
    /// `.afterDate`/`.external` get an ordinary (dismissible, uncertain-gated) chip.
    @ViewBuilder
    private func conditionRows(_ draft: ConfirmDraft) -> some View {
        let visible = draft.task.conditions.indices.filter { !draft.dismissedConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.self) { index in
                    conditionRow(draft.task.conditions[index], index: index, draft: draft)
                }
            }
        }
    }

    @ViewBuilder
    private func conditionRow(_ condition: ParsedCondition, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 6) {
            Circle().fill(VolarColor.instrumentDim).frame(width: 5, height: 5)
            switch condition {
            case .taskDone(let titleQuery, let confidence):
                taskDoneRow(titleQuery: titleQuery, confidence: confidence, index: index, draft: draft)
            case .afterDate(let date, let confidence):
                Chip(
                    label: "After \(date.formatted(.dateTime.month().day()))",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    mono: true,
                    onAccept: { appState.acceptUncertainCondition(at: index, forDraft: draft.id) },
                    onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
                )
            case .external(let description, let confidence):
                Chip(
                    label: "Waiting: \(description)",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    onAccept: { appState.acceptUncertainCondition(at: index, forDraft: draft.id) },
                    onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
                )
            }
        }
    }

    /// `.taskDone`: if it was already auto-resolved (parser confidence >= 0.7 AND a confident
    /// fuzzy title match — `AppState.preResolveConditions`), render a normal solid chip naming
    /// the matched task. Otherwise this is exactly the constitution-II case — < 0.7, or no
    /// confident match — and it MUST NOT auto-attach: show the picker instead.
    @ViewBuilder
    private func taskDoneRow(titleQuery: String, confidence: Double, index: Int, draft: ConfirmDraft) -> some View {
        // FIX C: used to also require `confidence >= 0.7`, so an explicit LOW-confidence picker
        // choice (`resolveTaskDone`, constitution II's whole reason for existing) rendered no
        // feedback at all — the resolved chip only ever showed for the auto-resolved (>=0.7) path.
        // `draft.resolvedTaskDone[index]` alone is the correct gate: it's populated by BOTH
        // `preResolveConditions` (confident auto-match) AND the user's own explicit picker tap
        // (`AppState.resolveTaskDone`), and an unresolved condition is simply absent from it either
        // way (falls through to the picker below, unchanged).
        if let resolvedID = draft.resolvedTaskDone[index] {
            let title = appState.openTasks.first { $0.id == resolvedID }?.title ?? titleQuery
            Chip(
                label: "After: \(title)",
                uncertain: false,
                accepted: true,
                onAccept: nil,
                onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
            )
        } else if let targetDraftID = draft.intraBatchTaskDone[index] {
            intraBatchTaskDoneRow(targetDraftID: targetDraftID, titleQuery: titleQuery, index: index, draft: draft)
        } else {
            dependencyPicker(titleQuery: titleQuery, index: index, draft: draft)
        }
    }

    /// 2026-07-28 (confirm-list UI, Việc 3): renders a `.taskDone` resolved against ANOTHER DRAFT
    /// in this same batch (`ConfirmDraft.intraBatchTaskDone`), rather than an already-persisted
    /// task. Two sub-cases: the referenced draft is still ticked (`isIncluded`) — an ordinary
    /// resolved chip, same shape as the `resolvedTaskDone` branch above, just named off the sibling
    /// draft's own live title instead of an `openTasks` lookup; or it was UNTICKED after this
    /// condition pointed at it — that draft will not exist to depend on, and per this task's brief
    /// this must never be silently dropped for the user (constitution II), so it renders as an
    /// explicit warning instead, leaving the condition exactly as-is until the user acts (re-tick
    /// the source, or dismiss this condition themselves via the same "x").
    @ViewBuilder
    private func intraBatchTaskDoneRow(targetDraftID: ConfirmDraft.ID, titleQuery: String, index: Int, draft: ConfirmDraft) -> some View {
        if let target = appState.confirmDrafts.first(where: { $0.id == targetDraftID }) {
            if target.isIncluded {
                Chip(
                    label: "After: \(target.effectiveTitle)",
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
                )
            } else {
                HStack(spacing: 6) {
                    Text("Won't be created: \u{201C}\(target.effectiveTitle)\u{201D}")
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.reschedule)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        appState.dismissCondition(at: index, forDraft: draft.id)
                    } label: {
                        VolarIcon(.x, size: 9, color: VolarColor.textMut)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            // Unreachable today (drafts are never removed from `confirmDrafts` anymore — see
            // `taskDraftCard`'s doc comment), but falls back to the ordinary picker rather than
            // rendering a chip that points at nothing, in case that ever changes.
            dependencyPicker(titleQuery: titleQuery, index: index, draft: draft)
        }
    }

    /// The task PICKER constitution II mandates for a `.taskDone` below 0.7 confidence — a native
    /// `Menu` (not the custom `Chip`, which bundles its own dismiss button as a `Menu` label
    /// child; nesting a `Button` inside a `Menu`'s label doesn't reliably get its own tap target,
    /// so the dismiss "x" here is a sibling control instead). Two groups (2026-07-28, Việc 3):
    /// OTHER drafts in this same batch (excluding this card's own, and excluding any unticked one —
    /// it will never exist as a real task to depend on) come FIRST, since a single utterance that
    /// creates several linked tasks is the most likely reason a `.taskDone` condition shows up here
    /// at all; already-persisted `openTasks` follow, capped defensively at 100 — same bound the
    /// cloud contract uses — so this stays O(1) to render even at hundreds of tasks (self-review
    /// "performance"); `openTasks` only ever lists the user's own tasks (self-review "security" —
    /// no cross-user/global data).
    private func dependencyPicker(titleQuery: String, index: Int, draft: ConfirmDraft) -> some View {
        let siblingDrafts = appState.confirmDrafts.filter { $0.id != draft.id && $0.isIncluded }
        return HStack(spacing: 4) {
            Menu {
                Button("Skip — no dependency") {
                    appState.resolveTaskDone(at: index, to: nil, forDraft: draft.id)
                }
                if !siblingDrafts.isEmpty {
                    Divider()
                    Section("Task in this capture") {
                        ForEach(siblingDrafts) { sibling in
                            Button(sibling.effectiveTitle) {
                                appState.resolveTaskDoneToDraft(draft.id, conditionIndex: index, target: sibling.id)
                            }
                        }
                    }
                }
                if !appState.openTasks.isEmpty {
                    Divider()
                    Section("Existing tasks") {
                        ForEach(appState.openTasks.prefix(100)) { task in
                            Button(task.title) {
                                appState.resolveTaskDone(at: index, to: task.id, forDraft: draft.id)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("?").font(.system(size: 10, weight: .bold))
                    Text("After: \u{201C}\(titleQuery)\u{201D}")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VolarColor.instrument.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(VolarColor.instrumentDim, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                appState.dismissCondition(at: index, forDraft: draft.id)
            } label: {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - task_refs_v1 (2026-08-02): "update an existing task by voice"
    //
    // Two surfaces here: (1) `refConditionRows`, rendered on a NEW-task `ConfirmDraft`'s own card
    // right after `conditionRows` — the visible/dismissible trace of a sibling draft's update
    // reference having merged INTO this draft (`AppState.mergeUpdateIntoSibling`); (2)
    // `confirmUpdateSection`/`confirmUpdateCard` and everything below it — one compact card per
    // `ConfirmUpdateDraft`, rendered by `parsedCard()` below every new-task draft. Localization/
    // typography matches this file's existing convention exactly: inline English strings (checked
    // against every other chip label in this file — `dependencyPicker`'s "Skip — no dependency",
    // `duplicateHintRow`'s "Add new", etc. — none of this popover's copy is Vietnamese-first or a
    // localized key), same `Chip`/`Menu`-dashed-pill components, no new visual language.

    /// `ConfirmDraft.refConditions` — same visual shape as `conditionRow`'s `.taskDone`/`.afterDate`
    /// branches (a `Chip`, "After: <title>" / "After <date>"), just reading a different array/
    /// dismiss-set pair (`refConditions`/`dismissedRefConditions`, never `task.conditions`/
    /// `dismissedConditions` — see that field's own doc comment for why the two can't share an
    /// index space).
    @ViewBuilder
    private func refConditionRows(_ draft: ConfirmDraft) -> some View {
        let visible = draft.refConditions.indices.filter { !draft.dismissedRefConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.self) { index in
                    HStack(spacing: 6) {
                        Circle().fill(VolarColor.instrumentDim).frame(width: 5, height: 5)
                        switch draft.refConditions[index] {
                        case .taskDone(let targetDraftID):
                            let title = appState.confirmDrafts.first { $0.id == targetDraftID }?.effectiveTitle ?? "task"
                            Chip(
                                label: "After: \(title)",
                                uncertain: false, accepted: true, onAccept: nil,
                                onDismiss: { appState.dismissRefCondition(at: index, forDraft: draft.id) }
                            )
                        case .afterDate(let date):
                            Chip(
                                label: "After \(date.formatted(.dateTime.month().day()))",
                                uncertain: false, accepted: true, mono: true, onAccept: nil,
                                onDismiss: { appState.dismissRefCondition(at: index, forDraft: draft.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// `parsedCard()`'s task_refs_v1 addition — one card per NON-dismissed `ConfirmUpdateDraft`,
    /// each preceded by the SAME hairline separator `parsedCard()`'s own `ForEach` uses between
    /// new-task drafts, so the whole scroll region reads as one continuous list.
    @ViewBuilder
    private func confirmUpdateSection() -> some View {
        let visible = appState.confirmUpdateDrafts.filter { !$0.cardDismissed }
        ForEach(visible) { draft in
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
            confirmUpdateCard(draft)
        }
    }

    /// One `ConfirmUpdateDraft` card: header names the resolved target (`.existing`) or shows the
    /// picker (`.unresolved`/the unreachable-in-practice `.sibling` fallback — see
    /// `ConfirmUpdateDraft`'s own doc comment); body (diff rows + `addConditions` rows + the
    /// Accept/Reject action row) only renders once there IS a resolved target to show them against.
    ///
    /// Cursor pass (design-spec.md §4.1): this used to pair `updateHeaderContent` with a tiny
    /// header-corner "x" as the card's ONLY reject affordance (`AppState.
    /// dismissConfirmUpdateDraft`). That "x" is now `updateActionRow`'s full "Reject ⎋" button,
    /// wired to the exact same call — no `HStack`/`Spacer` needed here anymore since there's
    /// nothing left to sit beside the header.
    private func confirmUpdateCard(_ draft: ConfirmUpdateDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            updateHeaderContent(draft)
            if case .existing = draft.resolution {
                updateFieldChips(draft)
                updateConditionRows(draft)
                updateActionRow(draft)
            }
        }
    }

    @ViewBuilder
    private func updateHeaderContent(_ draft: ConfirmUpdateDraft) -> some View {
        switch draft.resolution {
        case .existing(let id):
            let title = appState.tasks.first { $0.id == id }?.title ?? draft.sourceTitleQuery
            Text("Update: \u{201C}\(title)\u{201D}")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(2)
        case .unresolved, .sibling:
            // `.sibling` is unreachable here in practice (`AppState.buildConfirmUpdateDrafts` never
            // constructs a `ConfirmUpdateDraft` for it — see that struct's own doc comment); falls
            // back to the SAME picker as `.unresolved` rather than rendering nothing, in case that
            // invariant is ever violated.
            updateTargetPicker(draft)
        }
    }

    /// The `.unresolved` picker — adapted from `dependencyPicker`'s exact `Menu`+dashed-pill
    /// pattern (native `Menu`, not `Chip`, for the same "a `Button` nested in a `Menu`'s label
    /// doesn't reliably get its own tap target" reason that method's own doc comment gives).
    /// Deliberately offers EXISTING open tasks only, not this batch's other new-task drafts the way
    /// `dependencyPicker`'s sibling group does — a sibling match already had its chance in
    /// `AppState.resolveTaskRefs`'s ladder (step 2) before this ever renders, so re-offering that
    /// same group here would just be a second, redundant shot at a match the ladder already tried
    /// and failed at the same 0.7 bar.
    private func updateTargetPicker(_ draft: ConfirmUpdateDraft) -> some View {
        Menu {
            Button("Skip") {
                appState.resolveUpdateTarget(draft.id, to: nil)
            }
            if !appState.openTasks.isEmpty {
                Divider()
                ForEach(appState.openTasks.prefix(100)) { task in
                    Button(task.title) {
                        appState.resolveUpdateTarget(draft.id, to: task.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("?").font(.system(size: 10, weight: .bold))
                Text("Update: \u{201C}\(draft.sourceTitleQuery)\u{201D}")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(VolarColor.instrument.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(VolarColor.instrumentDim, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Cursor pass (design-spec.md §4.1): one `DiffRow` per PRESENT, non-dismissed value-replacing
    /// field on an `.existing`-target `ConfirmUpdateDraft` — current task value (looked up live off
    /// `appState.tasks`, the SAME lookup the old "old → new" chip label used) struck through, above
    /// the proposed value highlighted sage. `notesAppend` is deliberately NOT a `DiffRow`: it
    /// APPENDS to the existing task's notes (`AppState.mergeNotesAppending`, see that field's own
    /// doc comment on `ConfirmUpdateDraft`) rather than replacing a value, so there is no "old"
    /// half to diff against — it keeps the plain additive `Chip` every other "+ …" attribute in this
    /// file already uses, unchanged from before this pass.
    @ViewBuilder
    private func updateFieldChips(_ draft: ConfirmUpdateDraft) -> some View {
        if case .existing(let existingID) = draft.resolution {
            let existing = appState.tasks.first { $0.id == existingID }
            VStack(alignment: .leading, spacing: 10) {
                if let deadline = draft.deadline, !draft.dismissed.contains(.deadline) {
                    updateDiffField(
                        label: "Deadline",
                        old: existing?.deadline.map(Self.formattedDateTime),
                        new: Self.formattedDateTime(deadline.value),
                        mono: true,
                        uncertain: deadline.isUncertain,
                        accepted: draft.accepted.contains(.deadline),
                        field: .deadline,
                        draft: draft
                    )
                }
                if let startTime = draft.startTime, !draft.dismissed.contains(.startTime) {
                    updateDiffField(
                        label: "Start",
                        old: existing?.startTime.map(Self.formattedDateTime),
                        new: Self.formattedDateTime(startTime.value),
                        mono: true,
                        uncertain: startTime.isUncertain,
                        accepted: draft.accepted.contains(.startTime),
                        field: .startTime,
                        draft: draft
                    )
                }
                if let priority = draft.priority, !draft.dismissed.contains(.priority) {
                    updateDiffField(
                        label: "Priority",
                        old: existing.map { Self.priorityLabel($0.priority.rawValue) },
                        new: Self.priorityLabel(priority.value),
                        mono: false,
                        uncertain: priority.isUncertain,
                        accepted: draft.accepted.contains(.priority),
                        field: .priority,
                        draft: draft
                    )
                }
                if let notes = draft.notesAppend, !draft.dismissed.contains(.notesAppend) {
                    Chip(
                        label: "+ note: \(notes.value)",
                        uncertain: notes.isUncertain,
                        accepted: draft.accepted.contains(.notesAppend),
                        onAccept: { appState.acceptUpdateField(.notesAppend, forDraft: draft.id) },
                        onDismiss: { appState.dismissUpdateField(.notesAppend, forDraft: draft.id) }
                    )
                }
            }
        }
    }

    /// Reuses this file's existing `.dateTime.month().day().hour().minute()` specifier — the SAME
    /// format the pre-`DiffRow` "old → new" chip label used — just applied once per side instead of
    /// once for a combined string, since `DiffRow` needs the two halves separately. Not a new
    /// formatter: same call, same output text, one Date at a time.
    private static func formattedDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    /// One `DiffRow` PLUS this card's own uncertain-accept / dismiss affordances — kept OUTSIDE
    /// `DiffRow` itself (that view stays a dumb, model-unaware label+old+new component per its own
    /// doc comment, with no `AppState` knowledge and no tap handling) so the `AppState` calls live
    /// here, with the rest of this card's wiring. `DiffRow`'s own `pending` flag (dashed border +
    /// "?", vs. the solid sage fill) is driven by the exact same `isUncertain`/`accepted` gate
    /// `resolvedUpdateValue` reads at Save time, so a still-pending row LOOKS pending; tapping it
    /// (while pending) or the bottom `updateActionRow`'s "Accept" both call the identical
    /// `AppState.acceptUpdateField` this chip already called before this pass — no new accept path,
    /// just a new look for the existing one. The trailing "x" is the same per-field
    /// `AppState.dismissUpdateField` the old `Chip` already exposed, preserved here so a user can
    /// still drop ONE changed field without rejecting the whole card (`updateActionRow`'s "Reject"
    /// is the coarser, whole-card version of that same dismiss).
    private func updateDiffField(
        label: String, old: String?, new: String, mono: Bool,
        uncertain: Bool, accepted: Bool, field: ConfirmUpdateDraft.Field, draft: ConfirmUpdateDraft
    ) -> some View {
        let pending = uncertain && !accepted
        return HStack(alignment: .top, spacing: 6) {
            DiffRow(label: label, oldValue: old, newValue: new, mono: mono, pending: pending)
                .contentShape(Rectangle())
                .onTapGesture {
                    if pending { appState.acceptUpdateField(field, forDraft: draft.id) }
                }
            Spacer(minLength: 4)
            Button {
                appState.dismissUpdateField(field, forDraft: draft.id)
            } label: {
                VolarIcon(.x, size: 8, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        }
    }

    /// Cursor-borrowed Accept/Reject action row (design-spec.md §4.1) for one `.existing`-target
    /// update card. "Reject ⎋" (ghost) is `AppState.dismissConfirmUpdateDraft` — the exact call
    /// this card's old header "x" already made, just a real labeled button now. "Accept ⏎" (primary,
    /// `appState.accent.accent` fill — NEVER mint; the diff card is not the single NOW task) bulk-
    /// marks every still-`pending` field on this card accepted in one tap, via the SAME
    /// `AppState.acceptUpdateField` each `updateDiffField` above already calls one at a time when
    /// tapped — a convenience on top of that identical per-field action, not a new one. If every
    /// field is already confident, Accept has nothing to do and is a harmless no-op.
    ///
    /// Neither button calls `AppState.confirmSave()` — that stays the ONE unmodified save path (the
    /// popover's own global Save button/Enter, `actionsRow`, unchanged by this pass), so nothing
    /// here can itself write a task to the store. No auto-commit (task_refs_v1 decision (b),
    /// frozen): this row only ever changes which fields WOULD be applied the next time the user
    /// hits the real Save button.
    private func updateActionRow(_ draft: ConfirmUpdateDraft) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.dismissConfirmUpdateDraft(draft.id)
            } label: {
                HStack(spacing: 6) {
                    Text("Reject").font(.system(size: 12, weight: .medium))
                    Kbd("⎋")
                }
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Button {
                acceptAllPendingUpdateFields(draft)
            } label: {
                HStack(spacing: 6) {
                    Text("Accept").font(.system(size: 12, weight: .medium))
                    Kbd("⏎")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            .buttonStyle(.plain)
            .background(appState.accent.accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(.top, 2)
    }

    /// Loops the SAME per-field `AppState.acceptUpdateField` `updateDiffField`'s own tap-to-accept
    /// already calls, once per PRESENT field that is both uncertain and not yet accepted — the
    /// bulk half of `updateActionRow`'s "Accept ⏎". No new `AppState` method, no save-path call.
    private func acceptAllPendingUpdateFields(_ draft: ConfirmUpdateDraft) {
        if let deadline = draft.deadline, deadline.isUncertain, !draft.accepted.contains(.deadline) {
            appState.acceptUpdateField(.deadline, forDraft: draft.id)
        }
        if let startTime = draft.startTime, startTime.isUncertain, !draft.accepted.contains(.startTime) {
            appState.acceptUpdateField(.startTime, forDraft: draft.id)
        }
        if let priority = draft.priority, priority.isUncertain, !draft.accepted.contains(.priority) {
            appState.acceptUpdateField(.priority, forDraft: draft.id)
        }
        if let notes = draft.notesAppend, notes.isUncertain, !draft.accepted.contains(.notesAppend) {
            appState.acceptUpdateField(.notesAppend, forDraft: draft.id)
        }
    }

    /// `ConfirmUpdateDraft.addConditions`, same visual shape as `conditionRow`'s `.taskDone`/
    /// `.afterDate` branches (and `refConditionRows` above) — "After: <title>" for a
    /// `.taskDoneNewTask` reference (resolved against `appState.confirmDrafts` by its 1-based
    /// index, same convention `AppState.confirmSave`'s own resolution uses), "After <date>" for
    /// `.afterDate`.
    @ViewBuilder
    private func updateConditionRows(_ draft: ConfirmUpdateDraft) -> some View {
        let visible = draft.addConditions.indices.filter { !draft.dismissedAddConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visible, id: \.self) { index in
                    HStack(spacing: 6) {
                        Circle().fill(VolarColor.instrumentDim).frame(width: 5, height: 5)
                        switch draft.addConditions[index] {
                        case .taskDoneNewTask(let refIndex):
                            let title = appState.confirmDrafts.indices.contains(refIndex - 1)
                                ? appState.confirmDrafts[refIndex - 1].effectiveTitle
                                : "task \(refIndex)"
                            Chip(
                                label: "After: \(title)",
                                uncertain: false, accepted: true, onAccept: nil,
                                onDismiss: { appState.dismissUpdateAddCondition(at: index, forDraft: draft.id) }
                            )
                        case .afterDate(let date):
                            Chip(
                                label: "After \(date.formatted(.dateTime.month().day()))",
                                uncertain: false, accepted: true, mono: true, onAccept: nil,
                                onDismiss: { appState.dismissUpdateAddCondition(at: index, forDraft: draft.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Voice-done confirm card (T036, contract A `VoiceDoneIntent`/`VoiceMatch`)

    /// Same card shell as `parsedCard()` (Studio Dark card background + the reserved NOW ring —
    /// this is, like the parsed-task card, the one thing about to be acted on) but a completely
    /// different body: a one-tap/one-word confirm for a single confident candidate, a bounded
    /// disambiguation list for several, or the "no matching task" state (constitution II: state
    /// zero-match, never guess — and never silently fall back to new-task capture without asking).
    @ViewBuilder
    private func voiceDoneCard(accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confirm = appState.voiceDoneConfirm {
                voiceDoneConfirmContent(confirm, accent: accent)
            } else if appState.voiceDoneNoMatchTranscript != nil {
                voiceDoneNoMatchContent(accent: accent)
            }
        }
        .padding(12)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.nowRing, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 6)
    }

    /// One confident candidate -> a single "Yes — <title>" one-tap/one-word button (glance-and-
    /// dismiss). Several -> a bounded (`prefix(10)`, matching the defensive cap already applied
    /// when `AppState.presentVoiceDoneConfirm` constructs this) tappable list — constitution II's
    /// disambiguation requirement, never an auto-pick.
    @ViewBuilder
    private func voiceDoneConfirmContent(_ confirm: VoiceDoneConfirm, accent: Accent) -> some View {
        Text(voiceDoneQuestion(confirm))
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(VolarColor.nowAccentSoft)
            .lineLimit(2)

        if confirm.candidates.count == 1, let only = confirm.candidates.first {
            HStack(spacing: 8) {
                voiceDoneDismissButton
                voiceDoneConfirmButton(title: voiceDoneOneTapLabel(confirm.action, title: only.title), accent: accent) {
                    appState.confirmVoiceDone(taskId: only.taskId)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(confirm.candidates.prefix(10), id: \.taskId) { match in
                    Button {
                        appState.confirmVoiceDone(taskId: match.taskId)
                    } label: {
                        Text(match.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(VolarColor.border, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.top, 2)
            voiceDoneDismissButton
        }
    }

    private func voiceDoneQuestion(_ confirm: VoiceDoneConfirm) -> String {
        // Từng có ba nhánh; `.delegate` đã bỏ cùng tính năng delegation (2026-08-22).
        let verb: String
        switch confirm.action {
        case .complete: verb = "Mark done"
        case .clearExternal: verb = "Clear"
        }
        if confirm.candidates.count == 1 {
            return "\(verb): \u{201C}\(confirm.candidates[0].title)\u{201D}?"
        }
        switch confirm.action {
        case .complete: return "Which task is done?"
        case .clearExternal: return "Which one cleared?"
        }
    }

    /// One-tap confirm button label.
    private func voiceDoneOneTapLabel(_ action: VoiceDoneAction, title: String) -> String {
        switch action {
        case .complete, .clearExternal: return "Yes — \(title)"
        }
    }

    /// Zero candidates but a done/clear phrase was clearly detected — states it plainly (no red/
    /// shame styling, FR-036) and offers the explicit capture-instead escape hatch, never a guess.
    @ViewBuilder
    private func voiceDoneNoMatchContent(accent: Accent) -> some View {
        Text("Didn't find a matching task for that.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(VolarColor.textSec)
            .lineLimit(2)
        HStack(spacing: 8) {
            voiceDoneDismissButton
            voiceDoneConfirmButton(title: "Capture as new task instead", accent: accent) {
                appState.captureVoiceDoneAsNewTask()
            }
        }
    }

    /// Accent-solid one-word/one-tap affirmative — matches `actionsRow`'s Save button styling
    /// (Studio Dark) so this card reads as the same family as the normal confirm card.
    private func voiceDoneConfirmButton(title: String, accent: Accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(accent.solid)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: accent.glow, radius: 10, x: 0, y: 4)
        .keyboardShortcut(.defaultAction)
    }

    /// Neutral "not this" / cancel — matches `actionsRow`'s Cancel button styling exactly.
    private var voiceDoneDismissButton: some View {
        Button {
            appState.dismissVoiceDoneConfirm()
        } label: {
            Text("Not this")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Chip label formatting
    //
    // T-manual-edit (2026-07-29): `fileprivate static` (was `private` instance methods) so the new
    // tap-to-edit control structs below (`PriorityControl`/`EstimateControl`/`ReminderControl`/
    // `StartTimeControl`) can share the SAME formatting `attributeChips` already used, instead of
    // duplicating it a second time the way `DeadlineControl.deadlineLabel`/`suggestedDefault` had
    // to (those are `static` on `DeadlineControl` itself, with no equivalent on `PopoverView` to
    // reuse). `static` costs nothing here — none of these read `self` — and keeps the label a
    // single source of truth for both the read-only chip and its own edit popover/menu.

    fileprivate static func priorityLabel(_ raw: Int) -> String {
        switch raw {
        case 1: return "High priority"
        case 2: return "Medium priority"
        case 3: return "Low priority"
        default: return "Priority \(raw)" // engine allows up to 4 (data-model.md); no crash on the edge value
        }
    }

    /// T-manual-edit (2026-07-29, manual-edit-contract.md §3): used to only ever count `offsets`,
    /// so a user who tapped `ReminderControl` to set an explicit cadence (`remindPeriod`) saw the
    /// chip's label sit there unchanged — a silent-looking edit. `remindPeriod` (when set) now wins
    /// the label the same way it already wins resolution (`ReminderRecord.derive`, contract §1.1:
    /// "remindPeriod thắng fractionsRemaining"); `repeatEvery`/plain-offset-count fall back exactly
    /// as before when there's no user-set cadence.
    fileprivate static func reminderLabel(_ policy: ReminderPolicy) -> String {
        if let remindPeriod = policy.remindPeriod {
            return "Every \(formattedReminderPeriod(remindPeriod))"
        }
        return policy.repeatEvery != nil ? "Custom reminders" : "\(policy.offsets.count) reminder\(policy.offsets.count == 1 ? "" : "s")"
    }

    /// Formats a `remindPeriod` (seconds) for both `reminderLabel` above and `ReminderControl`'s
    /// own preset list — "15m"/"30m"/"1h"/"2h"/"4h"/"1 day" for this control's fixed preset set
    /// (`ReminderControl.presets`); a non-preset value (should not occur through this UI today,
    /// nothing else writes `remindPeriod`) still degrades gracefully to whichever unit divides it
    /// evenly, else falls back to whole minutes.
    fileprivate static func formattedReminderPeriod(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes > 0, totalMinutes % (24 * 60) == 0 {
            let days = totalMinutes / (24 * 60)
            return days == 1 ? "1 day" : "\(days) days"
        }
        if totalMinutes > 0, totalMinutes % 60 == 0 {
            return "\(totalMinutes / 60)h"
        }
        return "\(totalMinutes)m"
    }

    private func recurrenceLabel(_ recurrence: Recurrence) -> String {
        switch recurrence {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .every(let days): return "Every \(days)d"
        }
    }

    private func kindLabel(_ kind: TaskKind) -> String {
        kind == .review ? "Review" : kind.rawValue.capitalized
    }

    /// T-disposition: "Starts now" when the parsed instant is within ~2 minutes of the current
    /// wall clock (the "làm ngay lập tức"/"right now" utterance this whole disposition case exists
    /// for — the confirm card is reviewed within seconds of speaking, so this window is generous,
    /// not tight), else a plain "Starts HH:mm" readout for anything further out. Reads `Date()`
    /// directly rather than threading a captured "now" through `ConfirmDraft` — this is a label
    /// formatter, not state, and re-evaluating it on each render is exactly as correct as any
    /// snapshot would be for a card that's on-screen for at most a few seconds.
    fileprivate static func startTimeLabel(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) <= 120
            ? "Starts now"
            : "Starts \(date.formatted(.dateTime.hour().minute()))"
    }

    /// Mirrors `TaskItem.durationLabel`'s formatting ("45 min" / "1 hr" / "1h 30m"); duplicated
    /// here (rather than reaching into `TaskItem`) because `ParsedTask` is a distinct, smaller
    /// pre-save value type and this file must not modify frozen Model files.
    fileprivate static func formattedDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(mins)m"
    }

    // MARK: - Dependency cycle (blocking)

    /// Cycle-detection contract §3. **This is a real ERROR, not an advisory** — deliberately NOT
    /// styled like `conflictAdvisoryRow`/`overdueAdvisoryRow` above (calm, dismiss-only, `Enter`
    /// still saves regardless). Read those two rows' doc comments: their whole design rests on
    /// dismissing being a legitimate "I saw this, proceeding anyway" choice, because the thing
    /// they're flagging (an overdue deadline, a scheduling clash) is still a perfectly valid task
    /// to save. A dependency cycle has no such "proceed anyway" — `A → B → C → A` means NONE of
    /// those tasks can ever become eligible (`VolarCore.findCycle`/`cyclePath`,
    /// `DependencyGraph.swift`), so saving it silently would write a permanently-stuck graph the
    /// user never agreed to. That's why this row has no tap-to-dismiss at all: the only way it
    /// goes away is `appState.confirmCycle` itself returning to `nil`, which only happens once one
    /// of the `removableEdges` buttons below is actually pressed (`AppState.dismissCondition`,
    /// re-evaluated by `AppState.recomputeConfirmCycle()`). `VolarColor.high` (not `.reschedule`,
    /// which those calm rows use) marks the escalation.
    @ViewBuilder
    private func cycleWarningRow(_ cycle: ConfirmCycle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dependency cycle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(VolarColor.high)
            // "A → B → C → A" — `cycle.titles` already arrives closed (first == last), per
            // `ConfirmCycle.titles`'s contract.
            Text(cycle.titles.joined(separator: " \u{2192} "))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VolarColor.high)
                .lineLimit(3)
            Text("None of these can ever start — each is waiting on the next.")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.high.opacity(0.85))
                .lineLimit(2)
            if !cycle.removableEdges.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cycle.removableEdges) { edge in
                        Button {
                            appState.dismissCondition(at: edge.conditionIndex, forDraft: edge.draftID)
                        } label: {
                            Text("Remove: \(edge.label)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(VolarColor.high)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(VolarColor.high.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VolarColor.high.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 10)
    }

    // MARK: - Actions (parsed / saving)

    private func actionsRow(accent: Accent) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.cancelCapture()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .keyboardShortcut(.cancelAction)

            Button {
                appState.confirmSave()
            } label: {
                Group {
                    if appState.captureState == .saving {
                        Spinner(color: accent.solid, size: 14)
                    } else {
                        HStack(spacing: 8) {
                            Text(saveLabel)
                            Text("↵").opacity(0.85).font(.system(size: 12))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(appState.captureState == .saving ? accent.surface : accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        appState.captureState == .saving ? accent.surface : VolarColor.veil(0.18),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: appState.captureState == .saving ? .clear : accent.glow, radius: 10, x: 0, y: 4)
            // 2026-07-28 (Việc 1): nothing to save once every draft is unticked — same disabled
            // treatment `.saving` already gets, so Enter can't fire a no-op save either.
            //
            // Cycle-detection contract §3: `appState.confirmCycle != nil` disables this button the
            // same way. `.disabled(true)` on a SwiftUI `Button` also suppresses its own
            // `.keyboardShortcut(.defaultAction)` below — so Enter genuinely can't fire a save
            // through THIS control while a cycle is unresolved, not just visually greyed out.
            // (The title `TextField`'s own `.onKeyPress(.return)`/`.onSubmit` a few hundred lines
            // up call `appState.confirmSave()` directly and are NOT gated here — that path's
            // safety net is `confirmSave()`'s own `guard confirmCycle == nil else { return }`,
            // contract §2, so a cycle still can't be saved through it even though the button
            // itself stays visually untouched from that code path.)
            .opacity(includedDraftCount == 0 || appState.confirmCycle != nil ? 0.5 : 1)
            .disabled(appState.captureState == .saving || includedDraftCount == 0 || appState.confirmCycle != nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 10)
    }

    /// 2026-07-28 (Việc 1): counts TICKED drafts only, not the whole batch — an unticked draft
    /// isn't going to be saved, so the button shouldn't claim it will. "Nothing selected" (rather
    /// than e.g. "Save 0 tasks") when every draft is unticked, paired with `actionsRow` disabling
    /// the button for that same count — see `includedDraftCount` below.
    private var saveLabel: String {
        switch includedDraftCount {
        case 0: return "Nothing selected"
        case 1: return "Save task"
        default: return "Save \(includedDraftCount) tasks"
        }
    }

    /// Single source of truth for "how many drafts will `confirmSave()` actually persist" —
    /// shared by `saveLabel` and `actionsRow`'s `.disabled` so the two can never drift (e.g. button
    /// text says "Save 2 tasks" while the button itself stays enabled/disabled for a different
    /// count).
    private var includedDraftCount: Int {
        appState.confirmDrafts.filter(\.isIncluded).count
    }

    // MARK: - Error retry / consent rows

    @ViewBuilder
    private func errorActionsRow(accent: Accent) -> some View {
        if appState.pendingServerConsent {
            dictationConsentActionsRow(accent: accent)
        } else if appState.pendingCloudConsent {
            cloudConsentActionsRow(accent: accent)
        } else {
            HStack(spacing: 8) {
                Button {
                    appState.cancelCapture()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(VolarColor.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VolarColor.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .keyboardShortcut(.cancelAction)

                Button {
                    appState.startCapture()
                } label: {
                    Text("Try again")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(accent.solid)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
    }

    /// Shown instead of the usual Dismiss/Try again pair when `appState.pendingServerConsent` —
    /// on-device recognition failed because Dictation is off. Offers the private fix (enable
    /// Dictation) alongside the explicit-consent escape hatch (Apple's servers); the warning copy
    /// itself lives in `AppState.captureErrorDetail`, surfaced above by `leftHint`.
    private func dictationConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 8) {
            Button {
                appState.openDictationSettings()
            } label: {
                Text("Open Dictation Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .keyboardShortcut(.defaultAction)

            Button {
                appState.useServerRecognition()
            } label: {
                Text("Use Apple servers instead (sends audio online)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.reschedule)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.top, 10)
    }

    /// Shown instead of Dismiss/Try again when `appState.pendingCloudConsent` — the ONE-TIME
    /// cloud-parse privacy opt-in (T024): the explanatory copy itself lives in
    /// `AppState.captureErrorDetail` (surfaced above by `leftHint`), making clear that only TEXT
    /// (never audio) would leave the device. Default action (Enter) is the privacy-preserving
    /// decline, matching constitution I's on-device-first bias when the user doesn't read closely.
    private func cloudConsentActionsRow(accent: Accent) -> some View {
        VStack(spacing: 8) {
            Button {
                appState.resolveCloudConsent(allow: false)
            } label: {
                Text("Keep parsing on-device only")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accent.solid)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VolarColor.veil(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .keyboardShortcut(.defaultAction)

            Button {
                appState.resolveCloudConsent(allow: true)
            } label: {
                Text("Allow cloud parsing (sends this text online)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.top, 10)
    }
}

// MARK: - Private subviews

/// Tiny mono key chip — local to the popover (distinct from `Components.swift`'s accent-aware
/// `KeyBadge`; this one is always the neutral "Esc" style from the JSX `Kbd`).
private struct Kbd: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(VolarColor.textSec)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(VolarColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A dismissible confirm-card attribute/condition chip (T024). Solid border for confident/present
/// values; dashed border + a leading "?" for uncertain (<0.7) values pending an explicit tap to
/// accept — tapping the body of an uncertain, not-yet-accepted chip accepts it (constitution II:
/// never silently committed). The trailing "x" always dismisses (removes) the attribute from what
/// gets saved — a one-way action; there's no undo affordance within a confirm session (the chip
/// simply stops rendering once its backing `AppState` state says "dismissed"/"resolved-away").
private struct Chip: View {
    let label: String
    var uncertain: Bool = false
    var accepted: Bool = false
    /// NEW — marks this chip as an "instrument readout" (a timer/estimate value, not a category)
    /// per foundations.html §05: renders `label` in `Font.volarMono`, tinted `.instrument` (cool),
    /// never the reserved NOW amber. Confidence styling (dashed border/"?" glyph) still wins when
    /// the value is uncertain — mono only changes the font/base color, not the accept affordance.
    var mono: Bool = false
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void
    /// T-edit-deadline (2026-07-28): fires on a tap ANYWHERE on the capsule body, but ONLY once
    /// the chip is no longer dashed (i.e. NOT `showsDashed` — either always-confident, or an
    /// uncertain value the user already accepted). Deliberately does not fire instead of/before
    /// `onAccept`: an uncertain value's first tap must keep meaning "accept this," exactly as
    /// today, so this is additive — every existing `Chip(...)` call site that leaves `onTap` at
    /// its `nil` default keeps its EXACT prior tap behavior (accept-if-dashed, otherwise nothing).
    /// The dismiss "x" below stays its own separate `Button`, untouched — nesting a `Button`
    /// inside a parent `.onTapGesture` is the pre-existing shape of this view (the "x" already had
    /// to coexist with `onAccept`'s capsule-wide gesture before this change), so adding a second
    /// capsule-wide behavior alongside it introduces no new conflict.
    var onTap: (() -> Void)?

    private var showsDashed: Bool { uncertain && !accepted }

    var body: some View {
        HStack(spacing: 5) {
            if showsDashed {
                Text("?").font(.system(size: 10, weight: .bold))
            }
            Text(label)
                .font(mono ? Font.volarMono(size: 11.5, weight: .medium) : .system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onDismiss) {
                VolarIcon(.x, size: 8, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(showsDashed ? VolarColor.textSec : (mono ? VolarColor.instrument : VolarColor.textPri))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(showsDashed ? Color.clear : (mono ? VolarColor.instrumentDim.opacity(0.16) : VolarColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
                showsDashed ? VolarColor.textMut : (mono ? VolarColor.instrumentDim : VolarColor.border),
                style: StrokeStyle(lineWidth: 0.5, dash: showsDashed ? [3, 2] : [])
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onTapGesture {
            if showsDashed {
                onAccept?()
            } else {
                onTap?()
            }
        }
    }
}

/// T-edit-deadline (2026-07-28, anh Khôi: "khi user ra task, có thể update time... của task" —
/// manual in-place fix on the confirm card, NOT a separate voice-edit feature): the confirm
/// card's tappable deadline control. Its OWN `View` struct (not another branch inside
/// `attributeChips`'s `@ViewBuilder` method) specifically so it can own the `@State` a
/// `.popover` presentation needs — `attributeChips` is called once per DRAFT from a plain
/// `FlowLayout` call, not a `ForEach` that would hand each call an identity-backed state slot of
/// its own, so a `@State` declared directly there would be shared/reset across every draft's
/// control instead of staying independent per draft.
///
/// `.popover` was chosen over a `Menu`-hosted `DatePicker` (the other option this task called out
/// to weigh, `dependencyPicker` above being this file's existing `Menu` convention): a `Menu`'s
/// content is backed by `NSMenu` on macOS, which is known to render interactive controls like
/// `DatePicker` unreliably (it expects a flat list of selectable rows, not another live control) —
/// `.popover` is the standard, reliable way to present an inline editor anchored to a specific
/// control on macOS, and every other "edit in place" surface on this card (the title `TextField`)
/// already edits inline rather than through a menu.
///
/// Renders exactly one of three things, covering every state `ConfirmDraft.effectiveDeadline`/
/// `dismissed` can be in:
///   - a deadline present and NOT dismissed -> the existing mono `Chip` (accept/dismiss UNCHANGED,
///     see `Chip.onTap`'s own doc comment), now also tappable to reopen this same editor;
///   - a deadline present but dismissed -> nothing, EXACTLY the prior behavior (dismiss still
///     wins; this control does not resurrect a dismissed chip via a side door);
///   - no deadline at all (`effectiveDeadline == nil`) -> a quiet, dashed-border "Add time"
///     affordance (never a full-size button — most cards have no deadline, and this must not add
///     visual weight to the common case).
private struct DeadlineControl: View {
    let draft: ConfirmDraft
    let appState: AppState
    @State private var showingPicker = false

    var body: some View {
        Group {
            if let deadline = draft.effectiveDeadline, !draft.dismissed.contains(.deadline) {
                // Deadline is a timer readout — mono instrument face, per foundations.html §05.
                Chip(
                    label: Self.deadlineLabel(for: deadline, draft: draft),
                    uncertain: deadline.isUncertain,
                    accepted: draft.accepted.contains(.deadline),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.deadline, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.deadline, forDraft: draft.id) },
                    onTap: { showingPicker = true }
                )
            } else if draft.effectiveDeadline == nil {
                Button {
                    showingPicker = true
                } label: {
                    HStack(spacing: 4) {
                        VolarIcon(.clock, size: 9, color: VolarColor.textMut)
                        Text("Add time")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(VolarColor.textMut)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(VolarColor.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                    )
                }
                .buttonStyle(.plain)
            }
            // The remaining case (present but dismissed) intentionally renders nothing — see this
            // struct's own doc comment.
        }
        .popover(isPresented: $showingPicker) {
            deadlinePopoverContent
        }
    }

    /// T-emergency-label (2026-07-29, anh Khôi chốt): a deadline `IntentRouter.
    /// applyStartTimeDerivation` derived from `startTime` now auto-commits on Save (0.75 confidence
    /// — see `ParsedTask.deadlineIsEstimated`'s own doc comment for the full story), so this chip
    /// can no longer rely on dashed/uncertain styling to tell the user "this time is a guess" — that
    /// styling means something else in this app entirely ("not committed yet, tap to accept"), and
    /// this value already commits. Instead: append a plain "· est" suffix, same mono/instrument
    /// chip, no border change. Suppressed the instant the user picks their own time through this
    /// same control's `DatePicker` (`editedDeadline != nil`) — at that point it's no longer a
    /// machine guess, it's exactly what the user chose, so the label reverts to plain.
    private static func deadlineLabel(for deadline: ParsedValue<Date>, draft: ConfirmDraft) -> String {
        let base = deadline.value.formatted(.dateTime.month().day().hour().minute())
        guard draft.task.deadlineIsEstimated, draft.editedDeadline == nil else { return base }
        return "\(base) · est"
    }

    /// The picker's binding reads/writes straight through `AppState`, same "no intermediate local
    /// `@State` to fall out of sync" shape as the title `TextField`'s own
    /// `Binding(get: { draft.effectiveTitle }, set: { appState.updateDraftTitle(...) })` above.
    /// `get`'s fallback (`Self.suggestedDefault`) is DISPLAY ONLY — `set` is only ever invoked by
    /// an actual user interaction with the control (SwiftUI never calls a `DatePicker` binding's
    /// `set` on appear), so opening this popover and dismissing it untouched leaves `editedDeadline`
    /// `nil` and the task exactly as un-deadlined as before (constitution II: nothing commits
    /// without an explicit user action).
    private var deadlinePopoverContent: some View {
        // No explicit `.datePickerStyle(...)` override (self-review "Swift-blind risk" — macOS's
        // exact non-graphical `DatePickerStyle` case name could not be verified from this
        // environment): `.automatic` is the default and resolves to a reasonably compact
        // date+time control on macOS without risking an unverified style-case name.
        DatePicker(
            "",
            selection: Binding(
                get: { draft.effectiveDeadline?.value ?? Self.suggestedDefault() },
                set: { appState.setDraftDeadline($0, forDraft: draft.id) }
            ),
            displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .padding(12)
        .fixedSize()
    }

    /// The picker's default when a draft has NO deadline yet — deliberately NOT a bare `Date()`
    /// ("right now" is almost never the deadline someone means to set): today at 18:00 if that's
    /// still ahead of `now`, else tomorrow at 09:00. `bySettingHour(_:minute:second:of:)` returning
    /// `nil` (should not happen for valid hour/minute values, but never force-unwrapped) falls back
    /// to `now`/`tomorrow` unchanged rather than crashing.
    private static func suggestedDefault(now: Date = Date(), calendar: Calendar = .current) -> Date {
        if let sixPM = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), sixPM > now {
            return sixPM
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// T-manual-edit (2026-07-29, manual-edit-contract.md §3): the confirm card's tappable ESTIMATE
/// control — same 3-state shape as `DeadlineControl` right above (present+editable / present-but-
/// dismissed-renders-nothing / absent-shows-"Add") and the same reason it's its own `View` struct
/// (owns `@State` for the `.popover`, which a plain `@ViewBuilder` method shared across every draft
/// in `attributeChips` cannot do per-draft). `.popover` + a flat preset list, per the contract's
/// explicit assignment (`estimate`/`startTime`/`reminder` → `.popover`; only `priority` → `Menu`,
/// see `PriorityControl` below) — NOT because a preset list has the same "`Menu` can't host a live
/// control" problem `DeadlineControl`'s `DatePicker` has (a flat list of buttons is exactly what
/// `NSMenu` is good at), but because the contract calls it out as a separate lane from `priority`
/// and this file has no standing to relitigate that split.
private struct EstimateControl: View {
    let draft: ConfirmDraft
    let appState: AppState
    @State private var showingPicker = false

    /// Fixed per the contract (§3) — not derived from anything, so no risk of an empty/degenerate
    /// list; `[5, 10, 15, 30, 45, 60, 90, 120, 180, 240]` minutes.
    private static let presets = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        Group {
            if let estimate = draft.effectiveEstimateMinutes, !draft.dismissed.contains(.estimate) {
                // Estimate is a duration readout — mono instrument face, unchanged from before.
                Chip(
                    label: PopoverView.formattedDuration(estimate.value),
                    uncertain: estimate.isUncertain,
                    accepted: draft.accepted.contains(.estimate),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.estimate, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.estimate, forDraft: draft.id) },
                    onTap: { showingPicker = true }
                )
            } else if draft.effectiveEstimateMinutes == nil {
                addPill(label: "Add estimate", icon: .clock) { showingPicker = true }
            }
            // Present-but-dismissed: renders nothing, same as `DeadlineControl` (dismiss wins).
        }
        .popover(isPresented: $showingPicker) {
            estimatePopoverContent
        }
    }

    /// Closes on selection (unlike `DeadlineControl`'s `DatePicker`, which stays open — a
    /// continuous control has no single "done" moment) since every row here is a single discrete
    /// choice: picking one IS the completed action, so there's nothing left for the popover to stay
    /// open for.
    private var estimatePopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.presets, id: \.self) { minutes in
                Button {
                    appState.setDraftEstimateMinutes(minutes, forDraft: draft.id)
                    showingPicker = false
                } label: {
                    Text(PopoverView.formattedDuration(minutes))
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textPri)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 120)
    }
}

/// T-manual-edit (2026-07-29): the confirm card's tappable PRIORITY control — per the contract's
/// explicit assignment (§3), this one is a `Menu` ("dùng khuôn `dependencyPicker`'s Menu, ~801"),
/// not a `.popover` like the other three. Deliberately does NOT reuse `Chip` as the `Menu`'s
/// `label` the way `EstimateControl`/`ReminderControl`/`StartTimeControl` reuse it as the `.popover`
/// anchor: `Chip` bundles its own dismiss "x" as an internal `Button`, and `dependencyPicker`
/// (~801, this file's one pre-existing `Menu` convention) already documents why nesting a `Button`
/// inside a `Menu`'s label doesn't reliably get its own tap target on macOS — so, matching that
/// precedent exactly, this hand-styles a `Chip`-equivalent trigger (same capsule/dashed-uncertain
/// look) as the `Menu` label and keeps the dismiss "x" as a sibling `Button`, same shape as
/// `dependencyPicker`'s own `Menu` + sibling "x".
///
/// One consequence of using `Menu` instead of `Chip.onTap`: there is no single "tap the capsule to
/// accept the guess as-is" gesture the way `Chip`'s own `onTapGesture`(`showsDashed` branch) gives
/// every other chip — opening the `Menu` and re-tapping the SAME (already-current) value is the
/// equivalent here. That still commits it (`AppState.setDraftPriority` pins confidence to 1.0 per
/// the contract's §1.1), it just costs one extra tap versus the single-tap accept every other chip
/// on this card has. Considered adding a leading "Keep as guessed" menu row to close that gap
/// one-for-one with `Chip.onAccept`, but skipped it: the value is ALREADY the top-of-list item the
/// user would tap to reconfirm, so a duplicate first row saying the same thing risked being more
/// confusing than the extra tap it would save.
private struct PriorityControl: View {
    let draft: ConfirmDraft
    let appState: AppState

    // `[Int]` rather than a `[(raw:label:)]` tuple array — a plain tuple isn't `Hashable`/
    // `Identifiable` (tuples can't conform to protocols; only nominal types can), so `ForEach`
    // below needs a real `Hashable` element for its `id:`. `PopoverView.priorityLabel(_:)` (shared
    // with the read-only chip formatting) supplies the label for each raw value instead.
    private static let priorities: [Int] = [1, 2, 3]

    private var isDashed: Bool {
        guard let priority = draft.effectivePriority else { return false }
        return priority.isUncertain && !draft.accepted.contains(.priority)
    }

    var body: some View {
        if let priority = draft.effectivePriority, !draft.dismissed.contains(.priority) {
            HStack(spacing: 4) {
                Menu {
                    menuItems
                } label: {
                    triggerLabel(text: PopoverView.priorityLabel(priority.value), dashed: isDashed)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    appState.dismissAttribute(.priority, forDraft: draft.id)
                } label: {
                    VolarIcon(.x, size: 8, color: VolarColor.textMut)
                }
                .buttonStyle(.plain)
            }
        } else if draft.effectivePriority == nil {
            Menu {
                menuItems
            } label: {
                addPillLabel(label: "Add priority", icon: .flag)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        // Present-but-dismissed: renders nothing, same as `DeadlineControl` (dismiss wins).
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(Self.priorities, id: \.self) { raw in
            Button(PopoverView.priorityLabel(raw)) {
                appState.setDraftPriority(raw, forDraft: draft.id)
            }
        }
    }

    /// Mirrors `Chip`'s own visual language (dashed border + leading "?" while uncertain and not
    /// yet accepted, solid capsule otherwise) by hand — see this struct's own doc comment for why
    /// `Chip` itself can't be reused as a `Menu` label here.
    private func triggerLabel(text: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            if dashed {
                Text("?").font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(dashed ? VolarColor.textSec : VolarColor.textPri)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
                dashed ? VolarColor.textMut : VolarColor.border,
                style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [3, 2] : [])
            )
        )
    }

    private func addPillLabel(label: String, icon: VolarIconName) -> some View {
        HStack(spacing: 4) {
            VolarIcon(icon, size: 9, color: VolarColor.textMut)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(VolarColor.textMut)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(VolarColor.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        )
    }
}

/// T-manual-edit (2026-07-29): the confirm card's tappable REMINDER-CADENCE control — same
/// `.popover` + flat-preset shape as `EstimateControl` above (see that struct's doc comment for why
/// `.popover`, not `Menu`, per the contract's explicit per-field split). Editing here writes
/// `editedRemindPeriod` (`AppState.setDraftRemindPeriod`), which `ConfirmDraft.
/// effectiveReminderOverride` (contract §1.1) folds into a full `ReminderPolicy` — base
/// `task.reminderOverride ?? .defaultPolicy` with ONLY `remindPeriod` swapped — so this control
/// never has to know about `offsets`/`fractionsRemaining` itself.
private struct ReminderControl: View {
    let draft: ConfirmDraft
    let appState: AppState
    @State private var showingPicker = false

    /// Fixed per the contract (§3): 15m / 30m / 1h / 2h / 4h / 1 day, expressed in seconds
    /// (`ReminderPolicy.remindPeriod`'s own unit).
    private static let presets: [TimeInterval] = [
        15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 24 * 60 * 60,
    ]

    var body: some View {
        Group {
            if let reminder = draft.effectiveReminderOverride, !draft.dismissed.contains(.reminder) {
                Chip(
                    // Retheme §2: reminder cadence ("Every 30m") is a measurement readout — same
                    // mono treatment `DeadlineControl`/`EstimateControl`/`StartTimeControl` already
                    // give their own chips; this one was the one gap.
                    label: PopoverView.reminderLabel(reminder.value),
                    uncertain: reminder.isUncertain,
                    accepted: draft.accepted.contains(.reminder),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.reminder, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.reminder, forDraft: draft.id) },
                    onTap: { showingPicker = true }
                )
            } else if draft.effectiveReminderOverride == nil {
                addPill(label: "Add reminder", icon: .bell) { showingPicker = true }
            }
            // Present-but-dismissed: renders nothing, same as `DeadlineControl` (dismiss wins).
        }
        .popover(isPresented: $showingPicker) {
            reminderPopoverContent
        }
    }

    private var reminderPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.presets, id: \.self) { seconds in
                Button {
                    appState.setDraftRemindPeriod(seconds, forDraft: draft.id)
                    showingPicker = false
                } label: {
                    Text("Every \(PopoverView.formattedReminderPeriod(seconds))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textPri)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 140)
    }
}

/// T-manual-edit (2026-07-29): the confirm card's tappable START-TIME control — same `.popover` +
/// `DatePicker` shape as `DeadlineControl` above (sao y, per the contract), now that `startTime`
/// has moved from "inert, display-only, deliberately not editable" (see the superseded comment this
/// replaced at its `attributeChips` call site) into the same 7-field manual-edit set as the other
/// three. `startTime` itself stays exactly as inert as before — `TaskItem.startTime`'s own doc
/// comment still holds, this control only changes HOW the value is set, not what it drives.
private struct StartTimeControl: View {
    let draft: ConfirmDraft
    let appState: AppState
    @State private var showingPicker = false

    var body: some View {
        Group {
            if let startTime = draft.effectiveStartTime, !draft.dismissed.contains(.startTime) {
                Chip(
                    label: PopoverView.startTimeLabel(startTime.value),
                    uncertain: startTime.isUncertain,
                    accepted: draft.accepted.contains(.startTime),
                    mono: true,
                    onAccept: { appState.acceptUncertainAttribute(.startTime, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.startTime, forDraft: draft.id) },
                    onTap: { showingPicker = true }
                )
            } else if draft.effectiveStartTime == nil {
                addPill(label: "Add start time", icon: .clock) { showingPicker = true }
            }
            // Present-but-dismissed: renders nothing, same as `DeadlineControl` (dismiss wins).
        }
        .popover(isPresented: $showingPicker) {
            startTimePopoverContent
        }
    }

    /// Binding shape mirrors `DeadlineControl.deadlinePopoverContent`'s exactly (`get` reads the
    /// live effective value with a display-only fallback, `set` writes straight through `AppState`,
    /// no intermediate local `@State` to fall out of sync). Fallback default is a bare `Date()`
    /// ("now") rather than `DeadlineControl`'s smarter "6pm today / 9am tomorrow" — `startTime` is
    /// "when did/do you start", and "now" is the one default that's actually likely right for it,
    /// unlike a deadline where "right now" is almost never what's meant (see `DeadlineControl.
    /// suggestedDefault`'s own doc comment for that contrast).
    private var startTimePopoverContent: some View {
        DatePicker(
            "",
            selection: Binding(
                get: { draft.effectiveStartTime?.value ?? Date() },
                set: { appState.setDraftStartTime($0, forDraft: draft.id) }
            ),
            displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .padding(12)
        .fixedSize()
    }
}

/// Shared "Add …" dashed-pill affordance for `EstimateControl`/`ReminderControl`/`StartTimeControl`
/// — visually identical to `DeadlineControl`'s inline "Add time" button (same padding/capsule/dash
/// pattern), factored out once these three additional call sites needed the exact same look rather
/// than duplicating the `HStack`/`Capsule` three more times. `DeadlineControl.body` itself is left
/// with its own inline copy, unchanged — it predates this helper and touching working, already-
/// shipped deadline code for a pure style refactor is out of scope for this task.
private func addPill(label: String, icon: VolarIconName, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 4) {
            VolarIcon(icon, size: 9, color: VolarColor.textMut)
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(VolarColor.textMut)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(VolarColor.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        )
    }
    .buttonStyle(.plain)
}

/// T-edit-notes (2026-07-28, same anh Khôi request as `DeadlineControl` above): the confirm
/// card's editable notes/description field. Its own `View` struct for the same reason
/// `DeadlineControl` is: it needs `@State` (here, whether the user has explicitly asked to add a
/// note to a draft that came back with none) that a plain `@ViewBuilder` method called once per
/// draft from `taskDraftCard` cannot own independently per draft.
///
/// Renders one of two things:
///   - a note already exists (parsed OR previously typed this session) -> an inline, multi-line
///     `TextField` — SAME `axis: .vertical` + `.textFieldStyle(.plain)` shape as the title field
///     above (proven to render/resize correctly in this exact card), just smaller/secondary
///     styling and NO `.onKeyPress(.return)` interception. That omission is deliberate, not an
///     oversight: the title field above has to go out of its way (`.onKeyPress`) to turn Return
///     INTO a save, specifically overriding the vertical-axis `TextField`'s own default of
///     "Return inserts a newline" (see that field's own comment). Notes wants exactly that
///     DEFAULT, unmodified — Return should insert a newline, never save — so the correct
///     implementation here is to add NOTHING and let the field's native behavior stand. A
///     focused `TextField` also already swallows the Save button's own `.keyboardShortcut
///     (.defaultAction)` (again, see the title field's comment), so Return cannot leak through to
///     `actionsRow`'s Save button while this field has focus either.
///   - no note at all -> a quiet "Add note" affordance, same dashed/muted visual language as
///     `DeadlineControl`'s "Add time".
private struct NotesEditorControl: View {
    let draft: ConfirmDraft
    let appState: AppState
    @State private var isExpanded = false

    private var hasNotes: Bool {
        draft.effectiveNotes?.isEmpty == false
    }

    var body: some View {
        if hasNotes || isExpanded {
            // `get` reads `effectiveNotes` (trimmed + falls back to `task.notes` when blank) —
            // SAME shape as the title field's `get: { draft.effectiveTitle }` above, and it
            // inherits that field's one known quirk on purpose, for consistency: clearing this
            // field all the way to blank makes `effectiveNotes` fall back to the ORIGINAL parsed
            // note on the very next render, so a note that came from the parser can be REPLACED
            // by typing over it, but not fully blanked out via this field alone. Pre-existing
            // limitation, not new here — `effectiveTitle` already has it, and this task's brief
            // didn't ask for a way to delete an existing note entirely.
            TextField(
                "Notes",
                text: Binding(
                    get: { draft.effectiveNotes ?? "" },
                    set: { appState.updateDraftNotes($0, forDraft: draft.id) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(.system(size: 11.5))
            .foregroundStyle(VolarColor.textSec)
        } else {
            Button {
                isExpanded = true
            } label: {
                HStack(spacing: 4) {
                    VolarIcon(.plus, size: 8, color: VolarColor.textMut)
                    Text("Add note")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One already-persisted task resolved from `ConfirmDraft.duplicateCandidates` (a bare `[UUID]`)
/// against `AppState.openTasks`, for `duplicateHintRow`'s `ForEach`. A tiny `Identifiable` struct
/// rather than a labeled tuple so `ForEach` can iterate it directly, with no `id:` keypath.
private struct DuplicateCandidate: Identifiable {
    let id: UUID
    let title: String
}

/// Left-to-right wrapping row for the confirm card's chip set — a fixed `HStack` would clip or
/// squeeze chips once several attributes are present on the fixed 380pt-wide popover. `Layout`
/// has been available since macOS 13, well within this project's macOS 14 floor.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Expanding-ring pulse behind the "Listening…" dot, approximating the JSX `volar-pulse` keyframe
/// box-shadow animation with a scaling/fading ring overlay.
private struct PulsingDot: View {
    /// Was hardcoded to `VolarColor.high` (a priority-badge color, not a listening indicator) —
    /// now takes the caller's accent so it stays the general/cool instrument color, never a warm
    /// tone that could compete with the reserved NOW amber.
    var color: Color = VolarColor.instrument
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(expanded ? 2.4 : 1)
                    .opacity(expanded ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// Soft radial "breathing" glow behind the waveform — mirrors `menubar-now.html`'s `.mic.live`
/// breathing box-shadow, active ONLY while `isActive` (driven by `appState.captureState ==
/// .recording`, never a resting loop: like `PulsingDot`, the animation is only ever started while
/// this view is mounted, and SwiftUI tears the `withAnimation`/`repeatForever` down the moment the
/// parent's `if`/state branch removes it). Respects Reduce Motion by rendering a static glow
/// instead of animating. UNVERIFIED: not rendered/build-checked on this machine (Windows, no Xcode).
private struct MicBreathingGlow: View {
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Group {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .opacity(reduceMotion ? 0.6 : (breathing ? 1 : 0.5))
                    .blur(radius: 18)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// Hard on/off caret blink (JSX `volar-caret` uses `steps(2, start)`, i.e. no easing/cross-fade),
/// driven by a periodic `TimelineView` tick rather than an interpolated SwiftUI animation so the
/// transition stays a hard cut.
private struct BlinkingCaret: View {
    let color: Color
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let on = Int(elapsed / interval) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 2, height: 16)
                .opacity(on ? 1 : 0)
        }
    }
}

#Preview("Recording") {
    let state = AppState()
    state.captureState = .recording
    state.liveTranscript = "Customer call with Acme tomorrow at 2pm"
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VolarColor.bg)
}

#Preview("Parsed") {
    let state = AppState()
    state.captureState = .parsed
    state.confirmDrafts = [
        // Field order follows the contract's declared order (Swift's synthesized memberwise init
        // requires exact declaration order at the call site) — every optional passed explicitly
        // since the contract text doesn't show `= nil` defaults on the struct itself.
        ConfirmDraft(task: ParsedTask(
            title: "Customer call — Acme onboarding feedback",
            notes: "Customer call with Acme tomorrow at 2pm about onboarding feedback, high priority",
            deadline: ParsedValue(value: Date().addingTimeInterval(86_400), confidence: 0.92),
            estimateMinutes: ParsedValue(value: 30, confidence: 0.6),
            priority: ParsedValue(value: 1, confidence: 0.95),
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [.taskDone(titleQuery: "finish the onboarding deck", confidence: 0.4)],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: "Customer call with Acme tomorrow at 2pm about onboarding feedback, high priority"
        ))
    ]
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VolarColor.bg)
}

/// 2026-07-28 (confirm-list UI): covers all three additions in this pass in one batch — a
/// duplicate-candidate hint (draft A, against the seeded `openTasks` entry), an unticked draft
/// (draft B, dimmed) whose condition (draft C's `.taskDone`) is resolved intra-batch to it — so
/// the picker's "Task in this capture" group and the "won't be created" warning state both render.
#Preview("Multi-draft: checkbox / duplicate / intra-batch") {
    let existingTaskID = UUID()
    let state = AppState(tasks: [
        TaskItem(id: existingTaskID, title: "Sanitize html tags", priority: .medium, when: .later)
    ])
    state.captureState = .parsed

    var draftA = ConfirmDraft(task: ParsedTask(
        title: "Sanitize html tag this afternoon",
        sourceTranscript: "sanitize html tag this afternoon"
    ))
    draftA.duplicateCandidates = [existingTaskID]

    var draftB = ConfirmDraft(task: ParsedTask(
        title: "Draft the onboarding deck",
        sourceTranscript: "draft the onboarding deck, then send it to the client"
    ))
    // Unticked — exercises both the dimmed-card rendering AND draft C's "won't be created"
    // warning below, since draft C's condition points at this draft's id.
    draftB.isIncluded = false

    var draftC = ConfirmDraft(task: ParsedTask(
        title: "Send the onboarding deck to the client",
        conditions: [.taskDone(titleQuery: "draft the onboarding deck", confidence: 0.4)],
        sourceTranscript: "draft the onboarding deck, then send it to the client"
    ))
    draftC.intraBatchTaskDone[0] = draftB.id

    state.confirmDrafts = [draftA, draftB, draftC]
    return PopoverView()
        .environment(state)
        .padding(40)
        .background(VolarColor.bg)
}
