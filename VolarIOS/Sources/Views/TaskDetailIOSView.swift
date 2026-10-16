// Sources/Views/TaskDetailIOSView.swift — iOS task detail / inline edit (feature 011, artboard Task-Detail).
// Pushed inside a NavigationStack: `TaskDetailIOSView(taskId:)`. The view is a function of
// `appState.tasks`; only the in-progress title/note text lives in local @State.
// Every edit goes through `appState.updateTask` (the single write path), untouched fields copied
// from the current TaskItem.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct TaskDetailIOSView: View {
    let taskId: UUID

    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(\.dismiss) private var dismiss

    private enum Panel { case date, time, duration, priority, reminder, repeatRule }

    @State private var panel: Panel?
    @State private var titleDraft = ""
    @State private var detailsDraft = ""
    @State private var confirmDelete = false
    @FocusState private var focus: Field?
    private enum Field { case title, details }

    private var task: TaskItem? { appState.tasks.first { $0.id == taskId } }

    private static let durations = [15, 30, 45, 60, 90]
    // Seconds before the deadline; matches the macOS detail presets (TaskDetailView.swift:500).
    private static let reminders: [(label: String, seconds: TimeInterval)] = [
        ("15m", 900), ("30m", 1800), ("1h", 3600), ("1d", 86400),
    ]

    var body: some View {
        Group {
            if let task {
                content(task)
            } else {
                Color.clear
            }
        }
        .iosScreenBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    commitTitle()
                    commitDetails()
                    dismiss()
                } label: {
                    Text("Done").font(IOSFont.ui(17, .semibold)).foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch)
                }
            }
        }
        .onAppear {
            titleDraft = task?.title ?? ""
            detailsDraft = task?.details ?? ""
        }
        // Remote/other-screen edits refresh the draft only while the user is not typing in it.
        .onChange(of: task?.title) { _, new in if focus != .title { titleDraft = new ?? "" } }
        .onChange(of: task?.details) { _, new in if focus != .details { detailsDraft = new ?? "" } }
        .onChange(of: focus) { old, _ in
            if old == .title { commitTitle() }
            if old == .details { commitDetails() }
        }
        // Deleted elsewhere (sync, notification action) -> leave.
        .onChange(of: task == nil) { _, gone in if gone { dismiss() } }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete task", role: .destructive) {
                appState.deleteTask(taskId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Layout

    private func content(_ task: TaskItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .font(IOSFont.ui(28, .semibold))
                    .tracking(-0.56)
                    .foregroundStyle(IOSPalette.fg)
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onSubmit { commitTitle() }
                    .padding(.top, 12)

                TextField("Add a note", text: $detailsDraft, axis: .vertical)
                    .font(IOSFont.body)
                    .foregroundStyle(IOSPalette.fg2)
                    .lineSpacing(3)
                    .focused($focus, equals: .details)
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: IOSLayout.minTouch, alignment: .topLeading)
                    .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))
                    .padding(.top, 16)

                GroupedCard {
                    dateRows(task)
                }
                .padding(.top, 20)

                GroupedCard {
                    reminderRows(task)
                }
                .padding(.top, 16)


                Button { confirmDelete = true } label: {
                    Text("Delete task")
                        .font(IOSFont.ui(16))
                        .foregroundStyle(IOSPalette.destruct)
                        .frame(maxWidth: .infinity)
                        .frame(height: IOSLayout.secondaryHeight)
                        .background(IOSPalette.surfaceHi, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)

                HomeIndicatorSpacer()
            }
            .padding(.horizontal, IOSLayout.screenPadH)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func dateRows(_ task: TaskItem) -> some View {
        ValueRow(icon: "calendar", title: "Date", value: Self.dateLabel(task.deadline),
                 chevron: false) { toggle(.date) }
        if panel == .date {
            VStack(alignment: .trailing, spacing: 0) {
                DatePicker("Date", selection: dateBinding(task), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(IOSPalette.mint)
                if task.deadline != nil {
                    chip("Clear date", selected: false) { edit { $0.deadline = nil } }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        RowDivider()
        ValueRow(icon: "clock", title: "Time",
                 value: task.deadline.map { $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) } ?? "—",
                 chevron: false) { toggle(.time) }
        if panel == .time {
            DatePicker("Time", selection: timeBinding(task), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(.horizontal, 12)
        }
        RowDivider()
        ValueRow(icon: "timer", title: "Duration", value: Self.durationLabel(task.durationMinutes),
                 chevron: false) { toggle(.duration) }
        if panel == .duration {
            chips {
                ForEach(Self.durations, id: \.self) { m in
                    chip("\(m)m", selected: task.durationMinutes == m) { edit { $0.duration = m } }
                }
            }
        }
        RowDivider()
        ValueRow(icon: "flag", title: "Priority", value: Self.priorityLabel(task.priority),
                 chevron: false) { toggle(.priority) }
        if panel == .priority {
            chips {
                ForEach(Priority.allCases, id: \.self) { p in
                    chip(Self.priorityLabel(p), selected: task.priority == p) { edit { $0.priority = p } }
                }
            }
        }
    }

    @ViewBuilder
    private func reminderRows(_ task: TaskItem) -> some View {
        let period = task.reminderOverride?.remindPeriod
        ValueRow(icon: "bell", title: "Reminder", value: Self.reminderLabel(period),
                 chevron: false) { toggle(.reminder) }
        if panel == .reminder {
            chips {
                ForEach(Self.reminders, id: \.seconds) { r in
                    chip(r.label, selected: period == r.seconds) { edit { $0.remind = r.seconds } }
                }
                chip("Default", selected: period == nil) { edit { $0.remind = nil } }
            }
        }
        RowDivider()
        ValueRow(icon: "repeat", title: "Repeat", value: Self.repeatLabel(task.recurrence),
                 chevron: false) { toggle(.repeatRule) }
        if panel == .repeatRule {
            chips {
                chip("Never", selected: task.recurrence == nil) { appState.setTaskRecurrence(taskId, nil) }
                chip("Daily", selected: task.recurrence == .daily) { appState.setTaskRecurrence(taskId, .daily) }
                chip("Weekly", selected: task.recurrence == .weekly) { appState.setTaskRecurrence(taskId, .weekly) }
                chip("Monthly", selected: task.recurrence == .monthly) { appState.setTaskRecurrence(taskId, .monthly) }
            }
        }
    }

    // MARK: - Small pieces

    private func chips<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }.padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(IOSFont.chip)
                .foregroundStyle(selected ? IOSPalette.mint : IOSPalette.fg2)
                .padding(.horizontal, 14)
                .frame(minHeight: IOSLayout.minTouch)
                .background(selected ? IOSPalette.mintSur : IOSPalette.bg2, in: Capsule())
                .overlay(Capsule().stroke(selected ? IOSPalette.mint : IOSPalette.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ p: Panel) {
        withAnimation(.easeInOut(duration: 0.18)) { panel = (panel == p) ? nil : p }
    }

    // MARK: - Editing

    private struct Fields {
        var title: String
        var details: String
        var priority: Priority
        var deadline: Date?
        var duration: Int?
        var remind: TimeInterval?
    }

    /// Re-reads the current task, applies `change`, writes through `updateTask`.
    private func edit(_ change: (inout Fields) -> Void) {
        guard let t = task else { return }
        var f = Fields(title: t.title, details: t.details, priority: t.priority,
                       deadline: t.deadline, duration: t.durationMinutes,
                       remind: t.reminderOverride?.remindPeriod)
        change(&f)
        appState.updateTask(taskId, title: f.title, details: f.details, priority: f.priority,
                            startTime: t.startTime, deadline: f.deadline, deadlineKind: t.deadlineKind,
                            durationMinutes: f.duration, remindPeriod: f.remind)
    }

    private func commitTitle() {
        let clean = titleDraft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty title is not allowed: restore the stored one.
        guard !clean.isEmpty else { titleDraft = task?.title ?? ""; return }
        titleDraft = clean
        guard clean != task?.title else { return }
        edit { $0.title = clean }
    }

    private func commitDetails() {
        guard detailsDraft != task?.details else { return }
        edit { $0.details = detailsDraft }
    }

    /// Date-only: keeps the existing time of day (09:00 when the task has no deadline yet).
    private func dateBinding(_ task: TaskItem) -> Binding<Date> {
        Binding(
            get: { task.deadline ?? Date() },
            set: { picked in
                let cal = Calendar.current
                let base = task.deadline ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: picked) ?? picked
                let t = cal.dateComponents([.hour, .minute], from: base)
                let merged = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: picked) ?? picked
                edit { $0.deadline = merged }
            }
        )
    }

    /// Time-only: applied onto the same day as `deadline` (today when none).
    private func timeBinding(_ task: TaskItem) -> Binding<Date> {
        Binding(
            get: { task.deadline ?? Date() },
            set: { picked in
                let cal = Calendar.current
                let t = cal.dateComponents([.hour, .minute], from: picked)
                let day = task.deadline ?? Date()
                let merged = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
                edit { $0.deadline = merged }
            }
        )
    }

    // MARK: - Labels

    private static func dateLabel(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private static func durationLabel(_ m: Int?) -> String {
        guard let m, m > 0 else { return "—" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    private static func priorityLabel(_ p: Priority) -> String {
        switch p {
        case .high: return "High"
        case .medium: return "Normal"
        case .low: return "Low"
        }
    }

    private static func reminderLabel(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Default" }
        if seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400))d before" }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h before" }
        return "\(Int(seconds / 60))m before"
    }

    private static func repeatLabel(_ r: Recurrence?) -> String {
        switch r {
        case nil: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .every(let days): return "Every \(days)d"
        }
    }
}

#Preview {
    NavigationStack { TaskDetailIOSView(taskId: UUID()) }
        .environment(AppState())
        .environment(RewardCenter(store: nil))
        .preferredColorScheme(.dark)
}
