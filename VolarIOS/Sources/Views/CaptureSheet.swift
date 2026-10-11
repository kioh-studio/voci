// Sources/Views/CaptureSheet.swift — voice-capture bottom-sheet CONTENT (feature 011 re-skin).
//
// Behavior is unchanged from the 5-state version ported from `Volar/Sources/Views/PopoverView.swift`
// — same `appState.captureState` machine, same `ConfirmDraft` chip accept/dismiss interaction,
// same voice-done confirm card, same server/cloud consent rows. Only presentation changed, to match
// `design/ios-companion/project/Capture-Listening.dc.html` and `Capture-Confirm.dc.html`
// (tokens: `IOSPalette`/`IOSFont`/`IOSLayout`). `RootTabView` owns `.sheet(...)`/detents/drag
// indicator/presentation background; this file never calls those on itself.
//
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI
// `VolarCore.TaskConflict` (contract C) — the only VolarCore symbol this file needs directly.
import VolarCore

struct CaptureSheet: View {
    @Environment(AppState.self) private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                grabber

                if appState.captureState == .error {
                    errorHeader()
                    errorActionsRow()
                        .transition(.opacity)
                } else if showVoiceDoneCard {
                    statusPill()
                        .padding(.bottom, 18)
                    voiceDoneCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if showListening {
                    listeningContent()
                        .transition(.opacity)
                } else if showConfirm {
                    confirmContent()
                        .transition(.opacity)
                } else if appState.captureState == .done {
                    doneContent()
                        .transition(.opacity)
                }
            }
            .padding(.top, 8)
            // Generous home-indicator clearance — the sheet has no system nav bar to absorb it.
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(sheetBackground)
        .animation(VolarMotion.state, value: appState.captureState)
    }

    // MARK: - Chrome

    private var grabber: some View {
        Capsule()
            .fill(IOSPalette.fg3)
            .frame(width: 36, height: 5)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
    }

    /// Top-rounded surface fill — bottom stays flush with the sheet edge (artboard: `#232326`, radius 28 top).
    private var sheetBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: IOSLayout.sheetRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: IOSLayout.sheetRadius,
            style: .continuous
        )
        .fill(IOSPalette.surface)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Visibility

    private var showListening: Bool {
        appState.captureState == .recording || appState.captureState == .parsing
    }

    private var showConfirm: Bool {
        (appState.captureState == .parsed || appState.captureState == .saving)
            && !appState.confirmDrafts.isEmpty
    }

    private var showVoiceDoneCard: Bool {
        appState.voiceDoneConfirm != nil || appState.voiceDoneNoMatchTranscript != nil
    }

    private var isSaving: Bool { appState.captureState == .saving }

    // MARK: - Status pill — mono 13, fg2 on surfaceHi, mint dot while listening

    @ViewBuilder
    private func statusPill() -> some View {
        if let confirm = appState.voiceDoneConfirm {
            pill(text: confirm.candidates.count == 1 ? "Got it — confirm?" : "A few matches — pick one.")
        } else if appState.voiceDoneNoMatchTranscript != nil {
            pill(text: "Didn't find a matching task.", foreground: IOSPalette.med)
        } else {
            switch appState.captureState {
            case .idle, .error:
                EmptyView() // `.error` is handled by `errorHeader()`
            case .recording:
                pill(dot: true, text: "Listening…")
            case .parsing:
                pill(text: "Understanding…")
            case .parsed:
                pill(text: "Confirm or edit")
            case .saving:
                pill(text: "Saving…")
            case .done:
                pill(text: "Saved", foreground: IOSPalette.done, background: IOSPalette.done.opacity(0.14))
            }
        }
    }

    private func pill(
        dot: Bool = false,
        text: String,
        foreground: Color = IOSPalette.fg2,
        background: Color = IOSPalette.surfaceHi
    ) -> some View {
        HStack(spacing: 8) {
            if dot {
                PulsingDot(color: IOSPalette.mint)
            }
            Text(text)
                .font(IOSFont.mono(13))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(background, in: Capsule())
        .transition(.opacity)
    }

    // MARK: - Error header (replaces the status pill while `.error`)

    /// Consent copy (`pendingServerConsent`/`pendingCloudConsent`) runs several sentences, which
    /// doesn't fit a capsule — plain text instead.
    private func errorHeader() -> some View {
        Text(appState.captureErrorDetail ?? "Didn't catch that.")
            .font(IOSFont.meta)
            .foregroundStyle(IOSPalette.high)
            .multilineTextAlignment(.center)
            .lineLimit(6)
            .padding(.horizontal, IOSLayout.screenPadH)
            .padding(.bottom, 18)
    }

    // MARK: - Listening (.recording / .parsing)

    private func listeningContent() -> some View {
        VStack(spacing: 0) {
            statusPill()
                .padding(.top, 8)

            Waveform(
                active: appState.captureState == .recording,
                color: IOSPalette.mint,
                glow: IOSPalette.mintGlow,
                bars: 24,
                height: 48
            )
            .padding(.vertical, 12)
            .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
            .padding(.top, 18)
            .padding(.horizontal, IOSLayout.screenPadH)

            // The speech API exposes one `liveTranscript` string (no recognized/pending split), so
            // the whole text is fg; fg2 for the still-recognizing tail is not mappable.
            HStack(alignment: .top, spacing: 2) {
                Text(appState.liveTranscript)
                    .font(IOSFont.ui(17, .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(IOSPalette.fg)
                if appState.captureState == .recording {
                    BlinkingCaret(color: IOSPalette.mint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.horizontal, IOSLayout.screenPadH)
            .padding(.top, 20)

            finishButton
                .padding(.top, 20)

            Text("Tap to finish · swipe down to cancel")
                .font(IOSFont.meta)
                .foregroundStyle(IOSPalette.fg3)
                .padding(.top, 14)
        }
    }

    /// 64pt mint circle, checkmark 28pt onMint. Stopping = the existing `toggleCapture()` (it stops
    /// while `.recording`; same call `MicFAB` makes). While `.parsing` it shows a spinner instead.
    @ViewBuilder
    private var finishButton: some View {
        if appState.captureState == .recording {
            Button {
                appState.toggleCapture()
            } label: {
                ZStack {
                    Circle().fill(IOSPalette.mint)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(IOSPalette.onMint)
                }
                .frame(width: IOSLayout.fabSize, height: IOSLayout.fabSize)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish and parse")
        } else {
            Spinner(color: IOSPalette.mint, size: 28)
                .frame(width: IOSLayout.fabSize, height: IOSLayout.fabSize)
        }
    }

    // MARK: - Done

    private func doneContent() -> some View {
        VStack(spacing: 18) {
            statusPill()
            ZStack {
                Circle()
                    .fill(IOSPalette.done)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(IOSPalette.bg)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Confirm (.parsed / .saving)

    private var includedCount: Int {
        appState.confirmDrafts.filter(\.isIncluded).count
    }

    private var saveLabel: String {
        includedCount == 1 ? "Save 1 task" : "Save \(includedCount) tasks"
    }

    private var heardTranscript: String {
        let live = appState.liveTranscript
        if !live.isEmpty { return live }
        return appState.confirmDrafts.first?.task.sourceTranscript ?? ""
    }

    private func confirmContent() -> some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: includedCount == 1 ? "1 task" : "\(includedCount) tasks",
                leading: "Cancel",
                trailing: "Save all",
                onLeading: { appState.cancelCapture() },
                onTrailing: { appState.confirmSave() },
                trailingEnabled: !isSaving && includedCount > 0
            )

            Text("Looks right? Save all, or tap anything to change it.")
                .font(IOSFont.body)
                .foregroundStyle(IOSPalette.fg2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 6)

            VStack(spacing: 12) {
                ForEach(appState.confirmDrafts) { draft in
                    taskDraftCard(draft, showRemove: appState.confirmDrafts.count > 1)
                }
            }
            .padding(.horizontal, IOSLayout.screenPadH)
            .padding(.top, 18)

            if !heardTranscript.isEmpty {
                Text("Heard: \u{201C}\(heardTranscript)\u{201D}")
                    .font(IOSFont.meta)
                    .foregroundStyle(IOSPalette.fg3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IOSLayout.screenPadH)
                    .padding(.top, 14)
            }

            VStack(spacing: 8) {
                SecondaryButton("Say it again") {
                    // Existing retry path (`errorActionsRow`'s "Try again"): cancel then restart.
                    appState.cancelCapture()
                    appState.startCapture()
                }
                .disabled(isSaving)

                PrimaryButton(isSaving ? "Saving…" : saveLabel) {
                    appState.confirmSave()
                }
                .disabled(isSaving || includedCount == 0)
                .opacity(isSaving || includedCount == 0 ? 0.5 : 1)
            }
            .padding(.horizontal, IOSLayout.screenPadH)
            .padding(.top, 20)
        }
    }

    /// One draft: bg2 card (the sheet itself is `surface`, so the artboard inverts to bg2 for
    /// contrast), editable title, wrapping attribute chips, condition + conflict rows, trailing
    /// 44pt "Remove task" control (`setDraftIncluded` — reversible, nothing leaves `confirmDrafts`).
    private func taskDraftCard(_ draft: ConfirmDraft, showRemove: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(
                    "Task title",
                    text: Binding(
                        get: { draft.effectiveTitle },
                        set: { appState.updateDraftTitle($0, forDraft: draft.id) }
                    ),
                    axis: .vertical
                )
                .font(IOSFont.ui(17, .semibold))
                .foregroundStyle(IOSPalette.fg)
                .lineLimit(1...3)
                .padding(.bottom, 8)
                .frame(minHeight: IOSLayout.minTouch - 8, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(IOSPalette.borderHi).frame(height: 1)
                }
                .padding(.trailing, showRemove ? 36 : 0)
                .disabled(!draft.isIncluded || isSaving)

                attributeChips(draft)
                conditionRows(draft)
                conflictAdvisoryRow(draft)
            }
            .padding(16)
            .opacity(draft.isIncluded ? 1 : 0.4)

            if showRemove {
                removeTaskButton(draft)
            }
        }
        .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous)
                .stroke(IOSPalette.border, lineWidth: 1)
        )
    }

    private func removeTaskButton(_ draft: ConfirmDraft) -> some View {
        Button {
            appState.setDraftIncluded(draft.id, !draft.isIncluded)
        } label: {
            Image(systemName: draft.isIncluded ? "xmark" : "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(IOSPalette.fg3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(draft.isIncluded ? "Remove task" : "Restore task")
    }

    /// AT MOST ONE calm advisory line, never blocking Save (constitution II / FR-036: no red, no dialog).
    @ViewBuilder
    private func conflictAdvisoryRow(_ draft: ConfirmDraft) -> some View {
        if let conflict = draft.conflicts.first, !draft.conflictDismissed {
            HStack(alignment: .top, spacing: 6) {
                Text(conflictAdvisoryText(conflict))
                    .font(IOSFont.meta)
                    .foregroundStyle(IOSPalette.med)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .frame(minHeight: IOSLayout.minTouch, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.dismissConflictAdvisory(forDraft: draft.id)
            }
        }
    }

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

    /// Every PRESENT attribute renders as a dismissible chip; absent ones render nothing. Mirrors
    /// `PopoverView.attributeChips` field-for-field. Time values (deadline) use `IOSPalette.med`.
    @ViewBuilder
    private func attributeChips(_ draft: ConfirmDraft) -> some View {
        FlowLayout(spacing: 8) {
            if let deadline = draft.task.deadline, !draft.dismissed.contains(.deadline) {
                Chip(
                    label: deadline.value.formatted(.dateTime.month().day().hour().minute()),
                    uncertain: deadline.isUncertain,
                    accepted: draft.accepted.contains(.deadline),
                    color: IOSPalette.med,
                    onAccept: { appState.acceptUncertainAttribute(.deadline, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.deadline, forDraft: draft.id) }
                )
            }
            if let estimate = draft.task.estimateMinutes, !draft.dismissed.contains(.estimate) {
                Chip(
                    label: formattedDuration(estimate.value),
                    uncertain: estimate.isUncertain,
                    accepted: draft.accepted.contains(.estimate),
                    onAccept: { appState.acceptUncertainAttribute(.estimate, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.estimate, forDraft: draft.id) }
                )
            }
            if let priority = draft.task.priority, !draft.dismissed.contains(.priority) {
                Chip(
                    label: priorityLabel(priority.value),
                    uncertain: priority.isUncertain,
                    accepted: draft.accepted.contains(.priority),
                    dot: priorityDot(priority.value),
                    onAccept: { appState.acceptUncertainAttribute(.priority, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.priority, forDraft: draft.id) }
                )
            }
            if let reminder = draft.task.reminderOverride, !draft.dismissed.contains(.reminder) {
                Chip(
                    label: reminderLabel(reminder.value),
                    uncertain: reminder.isUncertain,
                    accepted: draft.accepted.contains(.reminder),
                    onAccept: { appState.acceptUncertainAttribute(.reminder, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.reminder, forDraft: draft.id) }
                )
            }
            if let recurrence = draft.task.recurrence, !draft.dismissed.contains(.recurrence) {
                Chip(
                    label: recurrenceLabel(recurrence.value),
                    uncertain: recurrence.isUncertain,
                    accepted: draft.accepted.contains(.recurrence),
                    onAccept: { appState.acceptUncertainAttribute(.recurrence, forDraft: draft.id) },
                    onDismiss: { appState.dismissAttribute(.recurrence, forDraft: draft.id) }
                )
            }
            if draft.task.kind != .task, !draft.dismissed.contains(.kind) {
                Chip(
                    label: kindLabel(draft.task.kind),
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.kind, forDraft: draft.id) }
                )
            }
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                Chip(
                    label: "+ Review after done",
                    uncertain: false,
                    accepted: true,
                    onAccept: nil,
                    onDismiss: { appState.dismissAttribute(.followUpReview, forDraft: draft.id) }
                )
            }
        }
    }

    private func priorityDot(_ raw: Int) -> Color {
        switch raw {
        case 1: return IOSPalette.high
        case 2: return IOSPalette.med
        default: return IOSPalette.fg3
        }
    }

    @ViewBuilder
    private func conditionRows(_ draft: ConfirmDraft) -> some View {
        let visible = draft.task.conditions.indices.filter { !draft.dismissedConditions.contains($0) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible, id: \.self) { index in
                    conditionRow(draft.task.conditions[index], index: index, draft: draft)
                }
            }
        }
    }

    @ViewBuilder
    private func conditionRow(_ condition: ParsedCondition, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 6) {
            Circle().fill(IOSPalette.fg3).frame(width: 5, height: 5)
            switch condition {
            case .taskDone(let titleQuery, let confidence):
                taskDoneRow(titleQuery: titleQuery, confidence: confidence, index: index, draft: draft)
            case .afterDate(let date, let confidence):
                Chip(
                    label: "After \(date.formatted(.dateTime.month().day()))",
                    uncertain: confidence < 0.7,
                    accepted: draft.acceptedConditions.contains(index),
                    color: IOSPalette.med,
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

    /// `.taskDone`: if already resolved (confident auto-match OR explicit picker choice), a solid
    /// chip naming the matched task; otherwise the constitution-II picker (never auto-attach below
    /// 0.7 confidence). Mirrors `PopoverView.taskDoneRow`'s `resolvedTaskDone`-only gate exactly.
    @ViewBuilder
    private func taskDoneRow(titleQuery: String, confidence: Double, index: Int, draft: ConfirmDraft) -> some View {
        if let resolvedID = draft.resolvedTaskDone[index] {
            let title = appState.openTasks.first { $0.id == resolvedID }?.title ?? titleQuery
            Chip(
                label: "After: \(title)",
                uncertain: false,
                accepted: true,
                onAccept: nil,
                onDismiss: { appState.dismissCondition(at: index, forDraft: draft.id) }
            )
        } else {
            dependencyPicker(titleQuery: titleQuery, index: index, draft: draft)
        }
    }

    /// Native `Menu` picker for a `.taskDone` condition below 0.7 confidence. `.menuStyle` is left
    /// at the default (`.borderlessButton` is macOS-only).
    private func dependencyPicker(titleQuery: String, index: Int, draft: ConfirmDraft) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button("Skip — no dependency") {
                    appState.resolveTaskDone(at: index, to: nil, forDraft: draft.id)
                }
                if !appState.openTasks.isEmpty {
                    Divider()
                    ForEach(appState.openTasks.prefix(100)) { task in
                        Button(task.title) {
                            appState.resolveTaskDone(at: index, to: task.id, forDraft: draft.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("?").font(IOSFont.mono(11, .semibold))
                    Text("After: \u{201C}\(titleQuery)\u{201D}")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(IOSFont.chip)
                .foregroundStyle(IOSPalette.fg2)
                .padding(.horizontal, 12)
                .frame(minHeight: IOSLayout.minTouch)
                .overlay(
                    Capsule().strokeBorder(IOSPalette.borderHi, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
            }
            .contentShape(Rectangle())

            Button {
                appState.dismissCondition(at: index, forDraft: draft.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(IOSPalette.fg3)
                    .frame(width: 32, height: IOSLayout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove dependency")
        }
    }

    // MARK: - Voice-done confirm card (T036, contract A)

    @ViewBuilder
    private func voiceDoneCard() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confirm = appState.voiceDoneConfirm {
                voiceDoneConfirmContent(confirm)
            } else if appState.voiceDoneNoMatchTranscript != nil {
                voiceDoneNoMatchContent()
            }
        }
        .padding(16)
        .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous)
                .stroke(IOSPalette.border, lineWidth: 1)
        )
        .padding(.horizontal, IOSLayout.screenPadH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func voiceDoneConfirmContent(_ confirm: VoiceDoneConfirm) -> some View {
        Text(voiceDoneQuestion(confirm))
            .font(IOSFont.ui(17, .semibold))
            .foregroundStyle(IOSPalette.fg)
            .lineLimit(2)

        if confirm.candidates.count == 1, let only = confirm.candidates.first {
            PrimaryButton(voiceDoneOneTapLabel(confirm.action, title: only.title)) {
                appState.confirmVoiceDone(taskId: only.taskId)
            }
            voiceDoneDismissButton
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(confirm.candidates.prefix(10), id: \.taskId) { match in
                    Button {
                        appState.confirmVoiceDone(taskId: match.taskId)
                    } label: {
                        Text(match.title)
                            .font(IOSFont.rowTitle)
                            .foregroundStyle(IOSPalette.fg)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(minHeight: IOSLayout.minTouch)
                            .background(IOSPalette.surfaceHi, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(IOSPalette.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
            voiceDoneDismissButton
        }
    }

    private func voiceDoneQuestion(_ confirm: VoiceDoneConfirm) -> String {
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

    private func voiceDoneOneTapLabel(_ action: VoiceDoneAction, title: String) -> String {
        switch action {
        case .complete, .clearExternal: return "Yes — \(title)"
        }
    }

    // MARK: - Chip label formatting (mirrors `PopoverView`'s private formatters exactly)

    private func priorityLabel(_ raw: Int) -> String {
        switch raw {
        case 1: return "High priority"
        case 2: return "Medium priority"
        case 3: return "Low priority"
        default: return "Priority \(raw)" // engine allows up to 4 (data-model.md); no crash on the edge value
        }
    }

    private func reminderLabel(_ policy: ReminderPolicy) -> String {
        policy.repeatEvery != nil ? "Custom reminders" : "\(policy.offsets.count) reminder\(policy.offsets.count == 1 ? "" : "s")"
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

    /// Mirrors `TaskItem.durationLabel`'s formatting; duplicated (not reached into `TaskItem`)
    /// because `ParsedTask` is a distinct pre-save value type, same rationale as `PopoverView`'s
    /// own copy of this formatter.
    private func formattedDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(mins)m"
    }

    @ViewBuilder
    private func voiceDoneNoMatchContent() -> some View {
        Text("Didn't find a matching task for that.")
            .font(IOSFont.rowTitle)
            .foregroundStyle(IOSPalette.fg2)
            .lineLimit(2)
        PrimaryButton("Capture as new task instead") {
            appState.captureVoiceDoneAsNewTask()
        }
        voiceDoneDismissButton
    }

    private var voiceDoneDismissButton: some View {
        SecondaryButton("Not this") {
            appState.dismissVoiceDoneConfirm()
        }
    }

    // MARK: - Error retry / consent rows

    @ViewBuilder
    private func errorActionsRow() -> some View {
        Group {
            if appState.pendingServerConsent {
                VStack(spacing: 10) {
                    PrimaryButton("Open Settings") {
                        appState.openDictationSettings()
                    }
                    textButton("Use Apple servers instead (sends audio online)", color: IOSPalette.med) {
                        appState.useServerRecognition()
                    }
                }
            } else if appState.pendingCloudConsent {
                // Privacy-preserving decline stays the visually primary (filled) button.
                VStack(spacing: 10) {
                    PrimaryButton("Keep parsing on-device only") {
                        appState.resolveCloudConsent(allow: false)
                    }
                    textButton("Allow cloud parsing (sends this text online)", color: IOSPalette.fg2) {
                        appState.resolveCloudConsent(allow: true)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    SecondaryButton("Dismiss") {
                        appState.cancelCapture()
                    }
                    PrimaryButton("Try again") {
                        appState.startCapture()
                    }
                }
            }
        }
        .padding(.horizontal, IOSLayout.screenPadH)
        .padding(.top, 14)
    }

    /// Wrapping, bordered secondary text action (consent rows' long copy doesn't fit `SecondaryButton`'s single line).
    private func textButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(IOSFont.meta)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: IOSLayout.minTouch)
                .background(IOSPalette.surfaceHi, in: RoundedRectangle(cornerRadius: IOSLayout.buttonRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: IOSLayout.buttonRadius, style: .continuous)
                        .stroke(IOSPalette.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Private subviews

/// Dismissible confirm-card attribute/condition chip — `MetaChip` look (mono 13, border) as a 44pt
/// pill per the Capture-Confirm artboard. Same accept/dismiss semantics as before: tapping an
/// uncertain (<0.7, not-yet-accepted) chip's body accepts it (constitution II — never silently
/// committed); the trailing "x" always dismisses it from what gets saved. Uncertain = dashed `borderHi`.
private struct Chip: View {
    let label: String
    var uncertain: Bool = false
    var accepted: Bool = false
    var color: Color = IOSPalette.fg
    var dot: Color?
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void

    private var showsDashed: Bool { uncertain && !accepted }

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if showsDashed {
                Text("?").font(IOSFont.mono(11, .semibold))
            }
            Text(label)
                .font(IOSFont.chip)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(IOSPalette.fg3)
                    .frame(width: 28, height: IOSLayout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
        }
        .foregroundStyle(showsDashed ? IOSPalette.fg2 : color)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: IOSLayout.minTouch)
        .background(showsDashed ? Color.clear : IOSPalette.surfaceHi, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                showsDashed ? IOSPalette.borderHi : IOSPalette.border,
                style: StrokeStyle(lineWidth: 1, dash: showsDashed ? [3, 2] : [])
            )
        )
        .contentShape(Capsule())
        .onTapGesture {
            if showsDashed { onAccept?() }
        }
    }
}

/// Left-to-right wrapping row for the confirm card's chip set — same technique as
/// `PopoverView`'s own `FlowLayout` (`Layout`, available since iOS 16, inside this feature's iOS
/// 17 floor), redefined here for the same file-private/cross-target reason as `Chip` above.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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


/// Expanding-ring pulse behind the "Listening…" dot — a BOUNDED, mount-scoped animation: started
/// `onAppear`, torn down the instant the pill stops rendering it (only exists while `.recording`).
/// Uses `.repeatForever` like `PopoverView.PulsingDot`; Theme.swift's "never repeatForever" rule
/// is scoped to MenuBarExtra-hosted views and resting motion, not a transient sheet indicator.
private struct PulsingDot: View {
    var color: Color = IOSPalette.mint
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
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

/// Hard on/off caret blink, driven by a periodic `TimelineView` tick (not `.repeatForever`).
private struct BlinkingCaret: View {
    let color: Color
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let on = Int(elapsed / interval) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 2, height: 18)
                .opacity(on ? 1 : 0)
        }
    }
}

#Preview("Recording") {
    let state = AppState()
    state.captureState = .recording
    state.liveTranscript = "Customer call with Acme tomorrow at 2pm"
    return CaptureSheet()
        .environment(state)
        .background(IOSPalette.bg)
}

#Preview("Parsed") {
    let state = AppState()
    state.captureState = .parsed
    state.confirmDrafts = [
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
    return CaptureSheet()
        .environment(state)
        .background(IOSPalette.bg)
}
