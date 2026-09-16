// Sources/Views/TaskRow.swift — single task row (checkbox, title, priority/dur/frog subrow, time badge)
// Ported from `design/volar-mac.jsx`'s `TaskRow`. List v2 (specs/009-light-mode-list-v2/design.md
// §5): rows no longer carry their own background/border (§5.1) — hover and selection are the only
// fills a row ever gets (§5.2/§5.3) — plus four additions (§5.6): rank index, rank-reason subrow
// text, a blocked/waiting chip, and hover quick-actions.
import SwiftUI
import VolarCore

struct TaskRow: View {
    let task: TaskItem
    let isActive: Bool
    /// Position in the engine's ranked order (1-based), supplied by the caller — NOT `task.id`.
    /// `nil` (default) opts a call site out of numbering entirely, same as before this pass.
    let index: Int?
    /// Why this task ranks where it does (`VolarCore.rankReason`), for the "3 lines" caller opts
    /// into per design.md §5.6.2. `nil` (default) keeps every existing call site compiling as-is.
    let reason: RankReason?

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false
    @GestureState private var isPressed = false

    init(task: TaskItem, isActive: Bool, index: Int? = nil, reason: RankReason? = nil) {
        self.task = task
        self.isActive = isActive
        self.index = index
        self.reason = reason
    }

    private var accentColors: Accent { appState.accent.accent }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private var priorityLabel: String {
        switch task.priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Màu hạn theo `DeadlineUrgency` (anh Khôi chốt 2026-08-20) — `nil` khi còn ≥ nửa quãng
    /// đường, khi task không có hạn, khi đã xong, hoặc khi đã quá hạn (quá hạn có luật riêng, xem
    /// `DeadlineUrgency`'s header). `Date()` đọc tại chỗ, cùng lý do `volarRankReason` trong
    /// `TodayView` đã ghi: `AppState.clock` là `private` và đây không phải vòng lặp nóng.
    private var deadlineTint: Color? {
        DeadlineUrgency.tint(for: task, now: Date())
    }

    /// Mirrors the prototype's `task.time` — the raw formatted deadline time shown (muted) once a
    /// task is done, independent of `timeBadge` (which is only ever populated for open tasks).
    private var rawTimeLabel: String? {
        guard let deadline = task.deadline else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    /// §5.1/§5.2/§5.3: no chrome of its own — `cardHover` is the only fill an unselected row gets
    /// (hover), `surfaceHi` the only fill a selected row gets. No more `card`/`rowBorderColor`.
    private var rowBackground: Color {
        if isActive { return VolarColor.surfaceHi }
        return isHovering ? VolarColor.cardHover : .clear
    }

    /// §5.3 "Selected (không phải NOW)" treatment: a solid 2px leading bar in the active accent —
    /// NOT the NOW row's 3px `nowAccent` treatment, which is a different call site's concern.
    @ViewBuilder
    private var selectionBar: some View {
        if isActive {
            Rectangle()
                .fill(accentColors.solid)
                .frame(width: 2)
        }
    }

    /// §5.6.1: fixed-width gutter so every open row's title lines up regardless of digit count.
    /// Only ever placed in the tree when `index != nil` (see `body`) — an absent index must not
    /// reserve a gap via an invisible view, so this itself is never conditional on `index` being
    /// nil, only its inclusion in `body` is.
    private var indexLabel: some View {
        Text(task.done ? "" : "\(index ?? 0)")
            .font(Font.volarMono(size: 11))
            .foregroundStyle(VolarColor.textMut)
            .frame(width: 18, alignment: .leading)
    }

    /// §5.6.4: only "Break down" has a real `AppState` action to call (`openBreakdown(for:)`).
    /// No generic "mark in progress" / "postpone deadline" action exists for an arbitrary row —
    /// re-grepped `AppState` for a setter that takes a target task id: only `switchDashboardActiveTask()`
    /// exists, and it takes no id, it just hands the spotlight to whatever `nextSwitchTarget`
    /// computes — there's no "make THIS row active" entry point to wire a Start button to.
    /// `start`/`snooze`/`postpone`/`reschedule` status-setters: none exist either. Reported, not
    /// invented.
    ///
    /// A "Defer" button was considered and DROPPED by anh Khôi (2026-08-19). Do not re-add it: the
    /// app already says "not now" in two other places (`SweepView`'s Skip, `triageDefer(_:)` in the
    /// inbox flow) and a third spelling of the same idea is how a user stops being able to predict
    /// what any of them does. If deferring ever gets built, it replaces one of those two rather
    /// than joining them — and the mechanism already exists (`VolarCore.Condition.afterDate`, which
    /// the engine honors and the blocked chip above already renders), so it needs no new concept.
    ///
    /// Icon: `.sparkle` is reused from the Pro/AI CTA elsewhere in the sidebar, which isn't a
    /// perfect semantic match for "split into steps" — but `VolarIconName` (not owned by this file)
    /// has no branch/split/list glyph closer to that meaning, so this keeps it rather than adding a
    /// case there. `.help` gives the mismatch a text fallback on hover.
    @ViewBuilder
    private var quickActions: some View {
        if isHovering, !task.done {
            HStack(spacing: 4) {
                QuickActionButton(icon: .sparkle) { appState.openBreakdown(for: task) }
                    .help("Break down into steps")
            }
            .transition(.opacity)
        }
    }

    /// §5.6.3: one id -> status lookup built once per row render, not per condition — feeds
    /// `Condition.isSatisfied(statusByID:now:)` (now `public`, VolarCore/Condition.swift) so this
    /// view calls the engine's own answer instead of hand-copying its three cases (that copy is
    /// exactly how `AppState.eligibleOrder` drifted from `eligibleTasks` once before, backlog.md).
    private var statusByID: [UUID: TaskStatus] {
        Dictionary(uniqueKeysWithValues: appState.tasks.map { ($0.id, $0.status) })
    }

    private var unsatisfiedCondition: VolarCore.Condition? {
        // ponytail: early-out before building statusByID — most tasks have zero conditions, so
        // this skips the O(n) dictionary build for nearly every row on every re-render. Rows that
        // DO have conditions still pay O(n) per read (read twice per render, see body/blockedLabel),
        // so it's still O(n²) across a list where every row is blocked — fine at hundreds of tasks,
        // not at thousands. Upgrade path: hoist statusByID onto AppState, built once per list render.
        guard !task.conditions.isEmpty else { return nil }
        let byID = statusByID
        return task.conditions.first { !$0.isSatisfied(statusByID: byID, now: Date()) }
    }

    /// "waiting: <title>" / "from <time>" / the condition's own description — design.md §5.6.3.
    private var blockedLabel: String? {
        guard let condition = unsatisfiedCondition else { return nil }
        switch condition {
        case .taskDone(let id):
            let title = appState.tasks.first(where: { $0.id == id })?.title ?? "another task"
            return "waiting: \(title)"
        case .afterDate(let date):
            return "from \(date.formatted(.dateTime.hour().minute()))"
        case .external(let description, _):
            return description
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if index != nil { indexLabel }
            checkbox
            titleAndSubrow
            Spacer(minLength: 0)
            trailing
            quickActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, appState.density.rowPadY)
        .background(rowBackground)
        .overlay(alignment: .leading) { selectionBar }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        // §5.6.3: blocked rows stay visible, just dimmed — "app không được nuốt mất việc".
        .opacity(unsatisfiedCondition != nil ? 0.55 : 1)
        .scaleEffect(isPressed ? 0.985 : 1)
        .onHover { isHovering = $0 }
        // Row tap opens the detail inspector panel (panel-refactor.md); the checkbox above is its
        // own `Button` and consumes its own tap first, so toggling done never also opens the
        // panel. A plain nested
        // `Button` (row-as-Button wrapping the checkbox Button) was considered for press feedback,
        // but macOS's AppKit-backed hit-testing for nested buttons is unreliable, so press feedback
        // is layered on separately via a `simultaneousGesture` instead — it doesn't compete with
        // the checkbox's own tap recognition, same as the existing `onTapGesture` above.
        .onTapGesture { appState.openDetail(task.id) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
        )
        .animation(VolarMotion.hover, value: isHovering)
        .animation(VolarMotion.hover, value: isActive)
        .animation(VolarMotion.press, value: isPressed)
        .contextMenu {
            Button("Break down into steps…") { appState.openBreakdown(for: task) }
            // Park & resume (2026-09-06): the "something urgent came up, do THIS one" entry point.
            // Switch (FocusOverlay/hero card) lets the engine pick the next task; this is how the
            // user names it — and it remembers what was parked, so finishing this one hands the
            // spotlight back. Hidden for a task that is already the one spotlit.
            if !task.done, appState.dashboardActiveTask?.id != task.id {
                Button("Do this now") { appState.focusTaskNow(task.id) }
            }
            Button(task.done ? "Mark not done" : "Mark done") { appState.toggleDone(task.id) }
            // Archive (2026-08-24): đường DUY NHẤT để một task vào section Archived. Không phải
            // hoàn thành, không phải xoá — "tôi không làm cái này nữa nhưng đừng vứt nó". Ẩn khi
            // task đã archived rồi, vì chưa có đường bỏ archive (xem backlog).
            if task.status != .archived {
                Button("Archive") { appState.archiveTask(task.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { appState.deleteTask(task.id) }
        }
    }

    private var checkbox: some View {
        Button {
            appState.toggleDone(task.id)
        } label: {
            Circle()
                .strokeBorder(task.done ? accentColors.solid : VolarColor.veil(0.45), lineWidth: 1.5)
                .background(Circle().fill(task.done ? accentColors.solid : .clear))
                .frame(width: 18, height: 18)
                .overlay {
                    if task.done {
                        VolarIcon(.check, size: 11, color: .white, weight: .bold)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .animation(VolarMotion.press, value: task.done)
    }

    private var titleAndSubrow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                if task.frog && !task.done {
                    Circle()
                        .fill(VolarColor.high)
                        .frame(width: 5, height: 5)
                        .shadow(color: VolarColor.high.opacity(0.5), radius: 3)
                }
                Text(task.title)
                    .font(.system(size: 13, weight: task.done ? .regular : .medium))
                    .tracking(-0.065)
                    .strikethrough(task.done, pattern: .solid, color: VolarColor.veil(0.25))
                    .foregroundStyle(task.done ? VolarColor.textMut : VolarColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 8) {
                Circle().fill(priorityColor).frame(width: 5, height: 5)
                Text(task.done ? "Done" : priorityLabel)
                if let durationLabel = task.durationLabel, !task.done {
                    Text("·").opacity(0.4)
                    Text(durationLabel)
                        .font(Font.volarMono(size: 11))
                        .monospacedDigit()
                }
                if task.frog && !task.done {
                    Text("·").opacity(0.4)
                    Text("Frog")
                        .fontWeight(.medium)
                        .tracking(0.22)
                        .foregroundStyle(VolarColor.high)
                }
                if !task.done, let reason, let reasonLabel = rankReasonLabel(reason) {
                    Text("·").opacity(0.4)
                    // specs/010-calendar-and-hard-deadlines/design.md §3.2 row 2: a `.hard`
                    // deadline that's overdue reads in `VolarColor.high` (muted terracotta —
                    // still NOT `destruct` red, the anti-shame rule holds for both kinds); a
                    // `.soft` overdue label keeps inheriting the subrow's own `textSec`, which
                    // already equals `VolarColor.reschedule` (see that token's doc comment) —
                    // so this `if` only ever touches the `.hard` case, `.soft` is unchanged.
                    if case .overdue = reason, task.deadlineKind == .hard {
                        Text(reasonLabel).foregroundStyle(VolarColor.high)
                    } else {
                        Text(reasonLabel)
                    }
                }
                if let blockedLabel {
                    BlockedChip(text: blockedLabel)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(VolarColor.textSec)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let timeBadge = task.timeBadge, !task.done {
            if task.deadlineKind == .hard {
                hardDeadlineBadge(timeBadge, tint: deadlineTint)
            } else {
                TimeBadge(timeBadge, filled: isActive, tint: deadlineTint)
            }
        } else if task.done, let rawTimeLabel {
            Text(rawTimeLabel)
                .font(Font.volarMono(size: 11))
                .monospacedDigit()
                .foregroundStyle(VolarColor.textMut)
        }
    }

    /// specs/010-calendar-and-hard-deadlines/design.md §3.2 row 1: `.hard`'s badge must read as a
    /// DIFFERENT kind of mark than `.soft`'s `TimeBadge` — shape/weight, never color (the
    /// anti-red-alarm rule: `VolarColor.destruct` stays reserved for the irreversible Delete
    /// action only). Same footprint as `TimeBadge` (rounded rect, 22pt tall, mono digits) so the
    /// trailing column doesn't jump around switching between the two, but filled with
    /// `veil(0.10)` instead of the accent color and prefixed with a short "due" label instead of
    /// relying on color/fill to say "this one's different".
    private func hardDeadlineBadge(_ text: String, tint: Color?) -> some View {
        HStack(spacing: 4) {
            Text("due")
                .font(Font.volarMono(size: 9, weight: .semibold))
                .tracking(0.3)
            Text(text)
                .font(Font.volarMono(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
        // `tint` (DeadlineUrgency) KHÔNG mâu thuẫn với luật "shape/weight, never color" ở doc
        // comment ngay trên: luật đó nói màu không được là thứ phân biệt hạn CỨNG với hạn MỀM —
        // và nó vẫn không phải, cái phân biệt hai loại vẫn là chữ "due" + nền `veil`. Màu ở đây
        // mang một nghĩa khác hẳn (còn bao nhiêu thời gian), và nó nói đúng nghĩa đó trên cả hai
        // loại badge như nhau.
        .foregroundStyle(tint ?? VolarColor.textPri)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(VolarColor.veil(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
