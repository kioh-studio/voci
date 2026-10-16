// Sources/Views/RewardSheets.swift — reward sheets for the iOS companion (feature 011, U-Goals).
// Artboards: Reward-Picker / Reward-New / Reward-Unlocked / Goals (+ Add a goal).
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

// MARK: - New goal

/// "+ New goal": a name plus one or more open tasks.
struct GoalNewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var selected: Set<UUID> = []

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !trimmed.isEmpty && !selected.isEmpty }

    private func add() {
        guard canAdd else { return }
        // Keep the task list's order rather than Set order.
        let ids = appState.openTasks.map(\.id).filter { selected.contains($0) }
        rewardCenter.addGoal(title: trimmed, taskIds: ids)
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "New goal", trailing: "Add",
                onLeading: { dismiss() }, onTrailing: add,
                trailingEnabled: canAdd
            )
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Goal")
                    TextField("Ship the landing page", text: $title)
                        .font(IOSFont.ui(17))
                        .foregroundStyle(IOSPalette.fg)
                        .submitLabel(.done)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))
                    SectionLabel("Tasks").padding(.top, 6)
                    Text("Pick one or more. The goal is done when all of them are.")
                        .font(IOSFont.meta)
                        .foregroundStyle(IOSPalette.fg3)
                    if appState.openTasks.isEmpty {
                        Text("No open tasks.")
                            .font(IOSFont.body)
                            .foregroundStyle(IOSPalette.fg2)
                            .padding(.vertical, 8)
                    } else {
                        GroupedCard {
                            ForEach(Array(appState.openTasks.enumerated()), id: \.element.id) { index, task in
                                if index > 0 { RowDivider(inset: 16) }
                                selectRow(task.title, isOn: selected.contains(task.id)) {
                                    if selected.contains(task.id) { selected.remove(task.id) } else { selected.insert(task.id) }
                                }
                            }
                        }
                    }
                    HomeIndicatorSpacer()
                }
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 16)
            }
        }
        .iosScreenBackground()
        .preferredColorScheme(.dark)
    }
}

/// Multi-select row: title + trailing checkmark.
@ViewBuilder
private func selectRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            Text(title)
                .font(IOSFont.rowTitle)
                .foregroundStyle(IOSPalette.fg)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IOSPalette.mint)
                .opacity(isOn ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

// MARK: - Reward picker (attach to a task)

struct RewardPickerSheet: View {
    let goalId: UUID

    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: UUID?
    @State private var others: Set<UUID> = []
    @State private var showNew = false

    private var goalTitle: String {
        rewardCenter.goal(goalId)?.title ?? "this goal"
    }

    private var otherGoals: [RewardItem] {
        rewardCenter.goals.filter { $0.id != goalId }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Reward", leading: "Cancel", trailing: "Save",
                onLeading: { dismiss() },
                onTrailing: {
                    rewardCenter.attachReward(selectedId, toGoals: [goalId] + otherGoals.map(\.id).filter { others.contains($0) })
                    dismiss()
                }
            )
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What do you get after \u{201C}\(goalTitle)\u{201D}?")
                        .font(IOSFont.body)
                        .foregroundStyle(IOSPalette.fg2)
                    GroupedCard {
                        ForEach(rewardCenter.catalog) { reward in
                            catalogRow(reward)
                            RowDivider(inset: 16)
                        }
                        actionRow(icon: "plus.circle", title: "New reward", accent: true) {
                            showNew = true
                        }
                        RowDivider(inset: 16)
                        actionRow(icon: "circle.slash", title: "No reward", selected: selectedId == nil) {
                            selectedId = nil
                        }
                    }
                    if !otherGoals.isEmpty {
                        SectionLabel("Also needs").padding(.top, 6)
                        GroupedCard {
                            ForEach(Array(otherGoals.enumerated()), id: \.element.id) { index, goal in
                                if index > 0 { RowDivider(inset: 16) }
                                selectRow(goal.title ?? "Goal", isOn: others.contains(goal.id)) {
                                    if others.contains(goal.id) { others.remove(goal.id) } else { others.insert(goal.id) }
                                }
                            }
                        }
                        Text("The reward unlocks when all of these are done.")
                            .font(IOSFont.meta)
                            .foregroundStyle(IOSPalette.fg3)
                    }
                    HomeIndicatorSpacer()
                }
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 16)
            }
        }
        .iosScreenBackground()
        .preferredColorScheme(.dark)
        .onAppear {
            let grant = rewardCenter.grant(forGoal: goalId)
            selectedId = grant?.rewardId
            others = Set((grant?.goalIds ?? []).filter { $0 != goalId })
        }
        .sheet(isPresented: $showNew) {
            RewardNewSheet(onAdded: { selectedId = $0.id })
        }
    }

    private func catalogRow(_ reward: RewardItem) -> some View {
        Button { selectedId = reward.id } label: {
            HStack(spacing: 12) {
                Image(systemName: reward.icon?.systemImage ?? "gift")
                    .font(.system(size: 20))
                    .foregroundStyle(IOSPalette.fg2)
                    .frame(width: 24)
                Text(reward.title ?? "Reward")
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(IOSPalette.fg)
                Spacer(minLength: 8)
                if let minutes = reward.minutes {
                    Text("\(minutes)m").font(IOSFont.mono(13)).foregroundStyle(IOSPalette.fg2)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IOSPalette.mint)
                    .opacity(selectedId == reward.id ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(icon: String, title: String, accent: Bool = false, selected: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(accent ? IOSPalette.mint : IOSPalette.fg2)
                    .frame(width: 24)
                Text(title)
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(accent ? IOSPalette.mint : IOSPalette.fg)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IOSPalette.mint)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New reward

struct RewardNewSheet: View {
    var onAdded: ((RewardItem) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(\.dismiss) private var dismiss

    private static let presets = [10, 20, 30, 40, 45, 60]

    @State private var title = ""
    @State private var icon: RewardIcon = .gamepad
    @State private var minutes = 30
    @State private var custom = false
    @State private var remind = true

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let item = rewardCenter.addReward(title: trimmed, minutes: minutes, icon: icon, remindWhenOver: remind)
        onAdded?(item)
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "New reward", trailing: "Add",
                onLeading: { dismiss() }, onTrailing: add,
                trailingEnabled: !trimmed.isEmpty
            )
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("What's the reward?")
                    HStack(spacing: 8) {
                        TextField("An album", text: $title)
                            .font(IOSFont.ui(17))
                            .foregroundStyle(IOSPalette.fg)
                            .submitLabel(.done)
                        // Voice entry is not wired yet.
                        Button {} label: {
                            Image(systemName: "mic")
                                .font(.system(size: 17))
                                .foregroundStyle(IOSPalette.fg3)
                                .frame(width: IOSLayout.minTouch, height: IOSLayout.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                        .help("Soon")
                        .accessibilityLabel("Voice entry, coming soon")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .frame(height: 48)
                    .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))

                    SectionLabel("Icon").padding(.top, 6)
                    HStack(spacing: 10) {
                        ForEach(RewardIcon.allCases, id: \.self) { option in
                            Button { icon = option } label: {
                                Image(systemName: option.systemImage)
                                    .font(.system(size: 20))
                                    .foregroundStyle(icon == option ? IOSPalette.mint : IOSPalette.fg2)
                                    .frame(width: 44, height: 44)
                                    .background(icon == option ? IOSPalette.mintSur : IOSPalette.bg2,
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(icon == option ? IOSPalette.mint : IOSPalette.border, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                        }
                    }

                    SectionLabel("How long?").padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Self.presets, id: \.self) { value in
                            durationChip("\(value)m", selected: !custom && minutes == value) {
                                custom = false
                                minutes = value
                            }
                        }
                        durationChip("Custom", selected: custom) { custom = true }
                    }
                    if custom {
                        Stepper(value: $minutes, in: 1...240, step: 5) {
                            Text("\(minutes) min").font(IOSFont.mono(14)).foregroundStyle(IOSPalette.fg)
                        }
                    }
                    Text("When it's over, Volar calls you back to Now.")
                        .font(IOSFont.meta)
                        .foregroundStyle(IOSPalette.fg3)

                    GroupedCard {
                        ToggleRow(icon: "bell", title: "Remind me when time's up", isOn: $remind)
                    }
                    .padding(.top, 6)

                    PrimaryButton("Add reward", action: add)
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.4 : 1)
                        .padding(.top, 8)
                    HomeIndicatorSpacer()
                }
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 16)
            }
        }
        .iosScreenBackground()
        .preferredColorScheme(.dark)
    }

    private func durationChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(IOSFont.chip)
                .foregroundStyle(selected ? IOSPalette.mint : IOSPalette.fg2)
                .frame(maxWidth: .infinity, minHeight: IOSLayout.minTouch)
                .background(selected ? IOSPalette.mintSur : IOSPalette.bg2,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? IOSPalette.mint : IOSPalette.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unlocked

struct RewardUnlockedSheet: View {
    let grant: RewardItem

    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(\.dismiss) private var dismiss

    private var doneLine: String {
        if grant.goalIds.count == 1 {
            let title = rewardCenter.goal(grant.goalIds[0])?.title ?? ""
            return "DONE \u{00B7} \(title.uppercased())"
        }
        return "DONE \u{00B7} \(grant.goalIds.count) GOALS"
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(IOSPalette.mint).frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(IOSPalette.onMint)
            }
            .padding(.top, 28)
            Text(doneLine)
                .font(IOSFont.mono(11))
                .foregroundStyle(IOSPalette.fg3)
                .lineLimit(1)
            if let title = grant.title {
                Text("You earned it.")
                    .font(IOSFont.ui(24, .semibold))
                    .foregroundStyle(IOSPalette.fg)
                RewardChip(title: title, minutes: grant.minutes, icon: grant.icon, highlighted: true)
                Spacer(minLength: 4)
                PrimaryButton("Start timer") {
                    rewardCenter.startBreak(grant.id)
                    dismiss()
                }
                SecondaryButton("Save it for later") {
                    rewardCenter.dismissUnlocked(grant.id)
                    dismiss()
                }
                Text("The timer runs on this iPhone. We'll call you back to Now.")
                    .font(IOSFont.meta)
                    .foregroundStyle(IOSPalette.fg3)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nice. That was a goal.")
                    .font(IOSFont.ui(24, .semibold))
                    .foregroundStyle(IOSPalette.fg)
                Spacer(minLength: 4)
                PrimaryButton("Done") {
                    rewardCenter.dismissUnlocked(grant.id)
                    dismiss()
                }
            }
        }
        .padding(.horizontal, IOSLayout.screenPadH)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .iosScreenBackground()
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}

#Preview("Unlocked") {
    RewardUnlockedSheet(grant: RewardItem(kind: .grant, title: "Game", minutes: 30, icon: .gamepad))
        .environment(AppState())
        .environment(RewardCenter(store: nil))
}

#Preview("New") {
    RewardNewSheet()
        .environment(AppState())
        .environment(RewardCenter(store: nil))
}

#Preview("Picker") {
    RewardPickerSheet(goalId: UUID())
        .environment(AppState())
        .environment(RewardCenter(store: nil))
}
