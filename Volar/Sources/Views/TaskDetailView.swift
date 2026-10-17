// Sources/Views/TaskDetailView.swift — TRANG task detail: edit-in-place + read-aloud + actions.
// Hai lần đổi vỏ, không lần nào đụng tới cơ chế commit bên dưới — chỉ cái khung chứa đổi:
//   2026-08-07 panel-refactor (specs/005-cursor-retheme/panel-refactor.md): từ modal `.sheet`
//     (`.sheet` từng sống ở `VolarApp.swift`, gate bằng `appState.detailTaskID != nil`) thành một
//     cột 340pt dock cạnh `Sidebar`/`mainColumn` trong `TodayView.body`.
//   2026-08-22 (anh Khôi: "lấy như cái trang của Linear luôn"): từ cột đó thành TRANG hai cột
//     THAY CHỖ `mainColumn` — nội dung bên trái, rail thuộc tính 240pt bên phải. Xem `body`.
// Phase 1 originally shipped this read-only. T-manual-edit (2026-07-29, anh Khôi — see
// specs/002-workflow-command-center/contracts/manual-edit-contract.md §4) turns it into an
// edit-in-place surface for all 7 manually-editable fields (title, description, priority, start
// time, deadline, duration, remind period) instead of adding a separate Edit panel — the same UI
// decision the contract froze for this file. Every edit commits through `AppState.updateTask`
// (the manual-edit contract's single write path, §1.4, owned by a sibling agent) — this file never
// touches `TaskStore` directly. Reads the live task off `AppState.detailTask` (rather than taking
// one as a param) so toggling done / editing elsewhere is reflected immediately while the panel is
// open.
import SwiftUI
import VolarCore

struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let task = appState.detailTask {
            // `.id(task.id)` gives `TaskDetailEditor` a fresh identity — and therefore freshly
            // re-seeded `@State` edit buffers — whenever the panel switches to a DIFFERENT task
            // (clicking a different row while the panel is already open, which is the whole reason
            // this is a panel now instead of a sheet: a sheet could never be switched without
            // closing it first). Re-renders of the SAME task (e.g. `detailTask` recomputing after
            // this view's own commit, or after some unrelated background change) keep the existing
            // identity, so in-progress edits in the buffers are never stomped — see
            // `TaskDetailEditor`'s own header comment for the full argument.
            TaskDetailEditor(task: task, appState: appState)
                .id(task.id)
        } else {
            // Panel is closed (or `detailTaskID` got cleared out from under us) — nothing to show.
            // `TodayView.detailPanel` also wraps this whole view in an `if appState.detailTask !=
            // nil` at the `HStack` level, so in practice this branch just means "don't reserve any
            // visual weight" rather than "hide a 300pt empty box."
            EmptyView()
        }
    }
}

/// Owns the edit-in-place `@State` buffers for exactly one task's detail panel. A dedicated `View`
/// struct (not a set of private methods on `TaskDetailView` itself) for the same reason
/// `DeadlineControl`/`NotesEditorControl` in `PopoverView.swift` are: `@State` needs a stable
/// identity to seed once and hold across re-renders, which a `@ViewBuilder` method sharing its
/// parent's identity can't own independently.
///
/// COMMIT MECHANISM (frozen by manual-edit-contract.md §4 — do not replace with a Save button, do
/// not drop a branch):
///   (a) a discrete control (priority/duration/remind-period `Menu`, deadline/start-time
///       `DatePicker`) changes value -> commit immediately;
///   (b) the title or description text field loses focus -> commit;
///   (c) the Close button is tapped -> commit, then `appState.closeDetail()`;
///   (d) `.onDisappear` -> commit (safety net for Esc / click-outside, which never runs (c)).
///
/// Every path funnels through `commitIfChanged()`, which is idempotent BY CONSTRUCTION: it diffs
/// the buffers against `task`'s CURRENT fields (no separate "did I already save this" flag needed)
/// and calls `appState.updateTask` only when something differs. This works because `task` is
/// re-supplied fresh on every re-render (`TaskDetailView.body` reads `appState.detailTask`, which
/// is recomputed from `appState.tasks`) while `@State` buffers persist across re-renders of the
/// SAME identity — so once a successful `updateTask` round-trips back through `tasks` ->
/// `detailTask` -> a fresh `task` parameter here, the buffers and `task` agree again and the next
/// `commitIfChanged()` (e.g. `.onDisappear` firing right after a control already committed) is
/// correctly a no-op instead of a redundant `fetchAll` + reminder-schedule rebuild.
private struct TaskDetailEditor: View {
    let task: TaskItem
    let appState: AppState

    @State private var titleBuffer: String
    @State private var detailsBuffer: String
    @State private var priorityBuffer: Priority
    @State private var deadlineBuffer: Date?
    @State private var deadlineKindBuffer: DeadlineKind
    @State private var startTimeBuffer: Date?
    @State private var durationBuffer: Int?
    @State private var remindPeriodBuffer: TimeInterval?

    /// Cycle-detection contract §4: NOT one of the seven commit-mechanism buffers above — a
    /// dependency edit is validated and written immediately at tap time
    /// (`appState.addTaskDependency`/`removeTaskDependency`), so this only ever holds the inline
    /// error string from the most recent `addTaskDependency` rejection (kept until the next
    /// dependency action, per the contract). It never participates in `commitIfChanged()`.
    @State private var dependencyError: String?

    private enum EditableField: Hashable { case title, details }
    @FocusState private var focusedField: EditableField?

    private var accentColors: Accent { appState.accent.accent }

    /// UNVERIFIED: explicit `State(initialValue:)` assignment inside a custom `init` (rather
    /// than each property's own default-value expression) is the standard SwiftUI way to seed
    /// `@State` from an init parameter — needed here since every buffer starts from `task`, which
    /// isn't available to a stored-property default expression. This shape is used throughout
    /// Apple's own SwiftUI documentation and believed correct on macOS 14+ (this app's floor), but
    /// this file was written entirely on Windows with no Xcode to compile it against.
    init(task: TaskItem, appState: AppState) {
        self.task = task
        self.appState = appState
        _titleBuffer = State(initialValue: task.title)
        _detailsBuffer = State(initialValue: task.details)
        _priorityBuffer = State(initialValue: task.priority)
        _deadlineBuffer = State(initialValue: task.deadline)
        _deadlineKindBuffer = State(initialValue: task.deadlineKind)
        _startTimeBuffer = State(initialValue: task.startTime)
        _durationBuffer = State(initialValue: task.durationMinutes)
        _remindPeriodBuffer = State(initialValue: task.reminderOverride?.remindPeriod)
    }

    // 2026-08-22 (anh Khôi: "lấy như cái trang của Linear luôn"): panel dọc 340pt — title, danh
    // sách field, mô tả, actions xếp chồng một cột — đổi thành TRANG hai cột như Linear dựng issue:
    // nội dung (title + mô tả + waiting on) chiếm phần rộng, thuộc tính dồn hết sang rail 240pt bên
    // phải. Đây cũng là lý do `TodayView` không còn dock view này cạnh `mainColumn` nữa mà cho nó
    // THAY CHỖ `mainColumn` — 340pt panel không đủ chỗ cho hai cột, mà bóp `mainColumn` xuống
    // dưới 400pt thì hỏng luôn cột chính.
    var body: some View {
        HStack(spacing: 0) {
            contentColumn
            Rectangle().fill(VolarColor.border).frame(width: 0.5)
            propertiesRail
        }
        // Esc = quay lại, đường thoát bằng bàn phím cho thứ giờ chiếm trọn cửa sổ thay vì là một
        // panel bấm ra ngoài là xong. Commit trước, đúng branch (c) như nút Back.
        .onExitCommand {
            commitIfChanged()
            appState.closeDetail()
        }
        .onChange(of: focusedField) { oldValue, _ in
            // Mechanism branch (b): fires on every focus transition; only commit when LEAVING a
            // field (oldValue != nil) — landing focus in a field for the first time has nothing to
            // commit yet, and would otherwise fire a spurious commit on panel open.
            if oldValue != nil {
                commitIfChanged()
            }
        }
        .onDisappear {
            // Mechanism branch (d): safety net for Esc / click-outside, neither of which runs the
            // Back button's own commit (branch (c), in `topBar` above) — STILL load-bearing now
            // that this is a panel, not a sheet (panel-refactor.md §3). This view disappears twice:
            // when `detailTask` goes back to `nil` (panel closes), and when `TaskDetailView`'s
            // `.id(task.id)` changes because the user clicked a DIFFERENT row while this panel was
            // already open — SwiftUI tears down the old `.id()`-identified view (firing this
            // `.onDisappear` on it) before building the new one. That second case is the only
            // reason a panel can lose an in-progress edit that a sheet never could (a sheet has to
            // close before another task can be opened at all), which is exactly what this branch
            // protects against. Do not delete this modifier on the theory that "the panel never
            // disappears" — it does, and this is the safety net for both times it does.
            commitIfChanged()
        }
    }

    // MARK: - Cột nội dung

    /// `topBar` nằm NGOÀI `ScrollView` (Linear cũng vậy): nút quay lại và hai action chính phải
    /// đứng yên khi cuộn một mô tả dài, không trôi mất lên trên.
    ///
    /// Nội dung bị kẹp `maxWidth: 680` rồi canh giữa thay vì kéo hết chiều ngang: dòng chữ 14pt
    /// dài quá 90 ký tự là mắt bắt đầu lạc dòng, mà cửa sổ Volar trừ sidebar và rail vẫn có thể
    /// rộng hơn thế nhiều trên màn lớn.
    private var contentColumn: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    descriptionSection
                    dependencySection
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                // Mechanism branch (c) như nút Close cũ: commit TRƯỚC khi rời trang, vì một cú bấm
                // vào đây có thể không đi qua `.onChange(of: focusedField)`.
                commitIfChanged()
                appState.closeDetail()
            } label: {
                HStack(spacing: 5) {
                    VolarIcon(.back, size: 11, color: VolarColor.textSec, weight: .semibold)
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09).
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                appState.toggleDone(task.id)
            } label: {
                Text(task.done ? "Mark not done" : "Mark done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Button(role: .destructive) {
                appState.deleteTask(task.id)
                appState.closeDetail()
            } label: {
                // `destruct` (not `high`) — token cho hành động không thể hoàn tác.
                Text("Delete")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.destruct)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    // Nút XOÁ: mở rộng vùng bấm làm nó dễ bấm NHẦM đúng bằng mức dễ bấm TRÚNG.
                    // Chấp nhận được vì nó nằm ở mép phải thanh trên, cách xa mọi thứ hay bấm —
                    // nhưng nếu bố cục đổi và có nút nào dịch lại sát thì phải xem lại chỗ này.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.destruct.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }

    // MARK: - Commit

    /// See this struct's header comment for the full idempotency argument. `title` is flattened
    /// (newlines -> spaces) and trimmed, falling back to the existing `task.title` when blank —
    /// same "never save an empty title, never block on it either" rule
    /// `AppState.ConfirmDraft.effectiveTitle` already establishes (`AppState.swift` ~L315), so this
    /// view doesn't need its own separate validation-error UI for a cleared title field.
    private func commitIfChanged() {
        let flattenedTitle = titleBuffer
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = flattenedTitle.isEmpty ? task.title : flattenedTitle

        let changed =
            resolvedTitle != task.title
            || detailsBuffer != task.details
            || priorityBuffer != task.priority
            || deadlineBuffer != task.deadline
            || deadlineKindBuffer != task.deadlineKind
            || startTimeBuffer != task.startTime
            || durationBuffer != task.durationMinutes
            || remindPeriodBuffer != task.reminderOverride?.remindPeriod
        guard changed else { return }

        appState.updateTask(
            task.id,
            title: resolvedTitle,
            details: detailsBuffer,
            priority: priorityBuffer,
            startTime: startTimeBuffer,
            deadline: deadlineBuffer,
            deadlineKind: deadlineKindBuffer,
            durationMinutes: durationBuffer,
            remindPeriod: remindPeriodBuffer
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if task.frog && !task.done {
                Circle()
                    .fill(VolarColor.high)
                    .frame(width: 7, height: 7)
                    .shadow(color: VolarColor.high.opacity(0.5), radius: 3)
                    // `Circle` không có baseline chữ nào để `firstTextBaseline` bám vào, nên tự
                    // căn: dịch xuống cho nó nằm ngang thân chữ hoa của tít 26pt.
                    .alignmentGuide(.firstTextBaseline) { _ in 1 }
            }
            // `axis: .vertical` + `lineLimit(1...3)` thay cho `.lineLimit(2)` cũ: trang rộng hơn
            // panel 340pt nên tít dài giờ xuống dòng được thay vì cụt đuôi. Cùng API mà
            // `descriptionSection` bên dưới vốn đã dùng trong chính file này.
            TextField("Title", text: $titleBuffer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1...3)
                .focused($focusedField, equals: .title)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Properties rail — cột phải kiểu Linear
    //
    // Mỗi field là một hàng `icon + GIÁ TRỊ`, KHÔNG có nhãn "PRIORITY"/"DEADLINE"… nữa: Linear bỏ
    // nhãn vì icon đã nói field là gì, và sáu dòng nhãn in hoa 10pt xếp dọc chính là thứ làm panel
    // cũ trông như inspector Windows Forms.
    //
    // Chỗ Volar khác Linear và suýt gãy vì bỏ nhãn: Linear chỉ có MỘT trường ngày, còn ở đây
    // deadline / start / remind đều là mốc thời gian — ba icon đồng hồ giống nhau thì không ai
    // đoán ra hàng nào là hàng nào. Nên ba field đó cố ý lấy ba icon khác họ (cờ hạn chót, nút
    // play cho giờ bắt đầu, chuông cho nhắc), và mỗi hàng mang `.help(...)` để rê chuột là hiện
    // tên field.
    private var priorityColor: Color {
        switch priorityBuffer {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private var priorityLabel: String {
        switch priorityBuffer {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private var propertiesRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Properties")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(VolarColor.textMut)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)

                railRow(.flag, "Priority") { priorityMenu }
                railRow(.today, "Deadline") { deadlineControl }
                // design.md §3.1 — vô nghĩa khi chưa có deadline để gắn nhãn, nên chỉ hiện khi đã
                // có một cái (đúng guard mà doc comment của `TaskItem.deadlineKind` đòi).
                if deadlineBuffer != nil {
                    deadlineKindSection
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                railRow(.play, "Start time") { startTimeControl }
                railRow(.clock, "Duration") { durationMenu }
                railRow(.bell, "Remind") { remindPeriodMenu }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240)
        // Rail có nền riêng (mainColumn/`contentColumn` để trong suốt cho ambient hiện qua) — đúng
        // cách Linear tách cột thuộc tính khỏi thân issue mà không cần thêm đường kẻ nào.
        .background(VolarColor.surface.opacity(0.5))
    }

    /// Một hàng trong rail: icon (đóng vai nhãn) + control sẵn có của field.
    ///
    /// `label` KHÔNG vẽ ra chữ nào — nó đi vào `.help` (tooltip cho người dùng chuột) và vào
    /// `.accessibilityLabel` của riêng cái ICON. Đặt nhãn lên icon chứ không lên cả hàng là có chủ
    /// đích: gộp cả hàng thành một phần tử rồi đặt nhãn "Deadline" sẽ NUỐT MẤT giá trị mà control
    /// con đang đọc ra. Tách đôi thì VoiceOver đọc "Deadline" rồi tới control đọc giá trị của nó —
    /// đúng bằng lượng thông tin cặp nhãn+giá trị cũ có.
    private func railRow<Value: View>(
        _ icon: VolarIconName,
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 9) {
            VolarIcon(icon, size: 12, color: VolarColor.textMut)
                .frame(width: 14, alignment: .leading)
                .accessibilityLabel(label)
            value()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(VolarColor.textSec)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .help(label)
    }

    /// Mechanism branch (a): a `Menu` selection commits in the same step it mutates the buffer —
    /// a menu tap is a single atomic user action with no separate "confirm" step of its own.
    /// `.menuStyle(.borderlessButton)` + `.fixedSize()` matches the existing custom-labeled `Menu`
    /// convention this app already uses (`PopoverView.swift`'s `dependencyPicker`).
    private var priorityMenu: some View {
        Menu {
            Button("High") { priorityBuffer = .high; commitIfChanged() }
            Button("Medium") { priorityBuffer = .medium; commitIfChanged() }
            Button("Low") { priorityBuffer = .low; commitIfChanged() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(priorityColor).frame(width: 6, height: 6)
                Text(priorityLabel)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var deadlineControl: some View {
        DateBufferControl(
            placeholder: "deadline",
            value: Binding(
                get: { deadlineBuffer },
                set: { deadlineBuffer = $0; commitIfChanged() }
            )
        )
    }

    /// specs/010-calendar-and-hard-deadlines/design.md §3.1/§3.5 — manual-only marker for
    /// whether `deadline` is a plan the user can freely move (`.soft`, default) or one an
    /// outside party enforces (`.hard`). Label deliberately avoids the "hard deadline" jargon —
    /// what the user actually needs to recognize is "did someone else set this, and is there a
    /// real consequence if I miss it," which is the distinction `SweepView`'s "Change due date"
    /// (instead of "Skip") acts on for `.hard` tasks. Commits through the same
    /// `commitIfChanged()` path as every other buffer here — a `Toggle` flip is mechanism branch
    /// (a), same as the priority `Menu`, so it saves immediately, no separate Save step.
    private var deadlineKindSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { deadlineKindBuffer == .hard },
                set: { deadlineKindBuffer = $0 ? .hard : .soft; commitIfChanged() }
            )) {
                Text("Someone else set this deadline")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
            }
            .toggleStyle(.switch)

            Text("Missing it has a real consequence — Volar won't quietly push it to tomorrow for you.")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textMut)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startTimeControl: some View {
        DateBufferControl(
            placeholder: "start time",
            value: Binding(
                get: { startTimeBuffer },
                set: { startTimeBuffer = $0; commitIfChanged() }
            )
        )
    }

    private var durationBufferLabel: String {
        guard let durationBuffer, durationBuffer > 0 else { return "Add duration" }
        return TaskItem.durationLabel(minutes: durationBuffer)
    }

    private var durationMenu: some View {
        Menu {
            ForEach(TaskItem.durationPresetMinutes, id: \.self) { minutes in
                Button(TaskItem.durationLabel(minutes: minutes)) {
                    durationBuffer = minutes
                    commitIfChanged()
                }
            }
            Divider()
            Button("No duration") {
                durationBuffer = nil
                commitIfChanged()
            }
        } label: {
            Text(durationBufferLabel)
                .font(Font.volarMono(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var remindPeriodBufferLabel: String {
        guard let remindPeriodBuffer else { return "Add reminder" }
        return "Remind \(ReminderPolicy.repeatLabel(remindPeriodBuffer))"
    }

    /// "Default reminders" sets the buffer back to `nil` — per manual-edit-contract.md §1.1/§1.4
    /// that means "no user-specified cadence," which falls back to the task's underlying
    /// `fractionsRemaining` proportional reminders rather than clearing reminders outright.
    private var remindPeriodMenu: some View {
        Menu {
            ForEach(ReminderPolicy.repeatPresets, id: \.self) { seconds in
                Button(ReminderPolicy.repeatLabel(seconds)) {
                    remindPeriodBuffer = seconds
                    commitIfChanged()
                }
            }
            Divider()
            Button("Default reminders") {
                remindPeriodBuffer = nil
                commitIfChanged()
            }
        } label: {
            Text(remindPeriodBufferLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Description

    /// Mô tả giờ là chữ TRẦN, không nhãn "DESCRIPTION", không khung card viền — cách Linear để
    /// phần mô tả của issue: chữ chạy thẳng dưới tít, cái ô chỉ hiện ra khi con trỏ vào.
    ///
    /// Bỏ luôn `ScrollView` bọc ngoài `TextField`: trước đây nó cần thiết vì cả panel cao cố định
    /// nên mô tả dài phải tự cuộn trong ô của mình; giờ `contentColumn` đã là một `ScrollView` rồi,
    /// lồng thêm một cái nữa chỉ tạo ra hai thanh cuộn tranh nhau cùng một cử chỉ.
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Add description…", text: $detailsBuffer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(VolarColor.textSec)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focusedField, equals: .details)

            readButton
        }
    }

    /// Reads the PERSISTED `task.details` (not `detailsBuffer`) — same as before this change:
    /// unsaved keystrokes aren't spoken until they've committed, which keeps this button's
    /// behavior exactly what it already was.
    private var readButton: some View {
        Button {
            appState.speakDetails(of: task)
        } label: {
            HStack(spacing: 8) {
                VolarIcon(.volume, size: 13, color: accentColors.solid, weight: .regular)
                Text("Read description")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 12)
            .frame(height: 30)
            // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09) — xem
            // `Sidebar.swift`'s `SectionHeaderRow` cho giải thích đầy đủ về họ bug này.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Waiting on (dependencies) — cycle-detection-contract.md §4.
    //
    // Deliberately NOT wired through the buffer/`commitIfChanged()` mechanism above: every
    // action here writes straight through `appState.addTaskDependency`/`removeTaskDependency` at
    // the moment of the tap. A dependency edit has to be validated (cycle check) right then —
    // deferring it to whatever later point `commitIfChanged()` would fire is exactly the "swallow
    // the error" bug this contract exists to close.

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting on")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VolarColor.textMut)

            if task.conditions.isEmpty {
                Text("Nothing")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textMut)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(task.conditions.enumerated()), id: \.offset) { index, condition in
                        conditionRow(condition, index: index)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                addDependencyMenu
                if let dependencyError {
                    Text(dependencyError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.high)
                        .lineLimit(2)
                }
            }
        }
    }

    /// One `.taskDone`/`.afterDate`/`.external` condition, with its own "x" removing exactly that
    /// index via `appState.removeTaskDependency` — same "gather then act on a stable index" shape
    /// `PopoverView`'s `conditionRows`/`dependencyPicker` already use for the confirm card.
    private func conditionRow(_ condition: VolarCore.Condition, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(conditionLabel(condition))
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                appState.removeTaskDependency(task.id, at: index)
            } label: {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove condition")
        }
    }

    /// `.taskDone` resolves against `appState.openTasks` (an id that no longer resolves there —
    /// already done, or deleted out from under this condition — reads as "Unknown task" rather
    /// than silently dropping the row, per constitution II). `.afterDate`/`.external` render their
    /// own payload directly; neither needs a task lookup.
    private func conditionLabel(_ condition: VolarCore.Condition) -> String {
        switch condition {
        case .taskDone(let id):
            return appState.openTasks.first { $0.id == id }?.title ?? "Unknown task"
        case .afterDate(let date):
            return "After \(date.formatted(.dateTime.month().day().hour().minute()))"
        case .external(let description, _):
            return "Waiting: \(description)"
        }
    }

    /// Contract §4: the candidate list excludes this task itself and any task it already depends
    /// on (re-picking one would either no-op or look like it silently did something). Same
    /// `openTasks`-backed `Menu` convention as `PopoverView`'s `dependencyPicker`. A rejection
    /// (non-nil return) replaces `dependencyError` and stays up until the next dependency action —
    /// no alert modal per the contract.
    private var addDependencyMenu: some View {
        let existingDependencyIDs: Set<UUID> = Set(
            task.conditions.compactMap {
                if case .taskDone(let id) = $0 { return id }
                return nil
            }
        )
        // Capped at 100 — same defensive bound `PopoverView`'s `dependencyPicker` uses for its
        // `openTasks` section, so this menu stays O(1) to render even with hundreds of open tasks
        // (self-review "performance").
        let candidates = appState.openTasks
            .filter { $0.id != task.id && !existingDependencyIDs.contains($0.id) }
            .prefix(100)
        return Menu {
            if candidates.isEmpty {
                Text("No other tasks")
            } else {
                ForEach(candidates) { candidate in
                    Button(candidate.title) {
                        dependencyError = appState.addTaskDependency(task.id, dependsOn: candidate.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                VolarIcon(.plus, size: 9, color: VolarColor.textMut, weight: .bold)
                Text("Add dependency")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.textSec)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Actions
    //
    // Nút "Mark done" / "Delete" / quay lại đã dời hết lên `topBar` (2026-08-22). Trước đây chúng
    // nằm cuối một cột dọc 340pt, tức là phải CUỘN XUỐNG HẾT mô tả mới bấm được nút chính của cả
    // panel — chuyện chỉ không lộ ra vì panel cũ hẹp và thường ngắn.
}

/// Shared `.popover` + `DatePicker` control for the `deadline`/`startTime` buffers (both
/// `Date?`): a plain muted "Add …" label when absent, the formatted instant when present — tapping
/// either opens the same popover, which also offers a "Clear" button to go back to `nil`. Mirrors
/// `PopoverView.swift`'s `DeadlineControl` shape (`.popover`, deliberately NOT a `Menu` — a
/// `Menu`'s `NSMenu` backing on macOS is known to render an embedded live control like `DatePicker`
/// unreliably, see that struct's own doc comment) without depending on it directly, since it's
/// `private` to that file and this file is a different agent's file-disjoint scope.
private struct DateBufferControl: View {
    let placeholder: String
    @Binding var value: Date?
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            if let value {
                Text(value.formatted(.dateTime.month().day().hour().minute()))
            } else {
                Text("Add \(placeholder)")
                    .foregroundStyle(VolarColor.textMut)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            // No explicit `.datePickerStyle(...)` override (same reasoning as `DeadlineControl`'s
            // own picker — self-review "Swift-blind risk": macOS's exact non-graphical
            // `DatePickerStyle` case name could not be verified from this environment). `.automatic`
            // is the default and resolves to a reasonably compact date+time control on macOS.
            VStack(alignment: .trailing, spacing: 8) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { value ?? Date() },
                        set: { value = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                if value != nil {
                    Button("Clear") {
                        value = nil
                        showingPicker = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                }
            }
            .padding(12)
            .fixedSize()
        }
    }
}

#Preview {
    let appState = AppState(tasks: SampleData.tasks)
    appState.detailTaskID = SampleData.tasks.first?.id
    return TaskDetailView()
        .environment(appState)
}
