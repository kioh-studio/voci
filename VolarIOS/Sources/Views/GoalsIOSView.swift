// Sources/Views/GoalsIOSView.swift — Goals tab (feature 011, U-Goals). Artboard: Goals.dc.html.
// Mounted by U-Shell inside a NavigationStack; rows push detail via NavigationLink(value: task.id).
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct GoalsIOSView: View {
    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter

    @State private var showNewGoal = false
    @State private var showNewReward = false
    @State private var tappedReward: RewardItem?
    @State private var rewardForGoal: RewardItem?
    @State private var goalToDelete: RewardItem?

    /// Not-yet-done goals first, then done.
    private var goals: [RewardItem] {
        let open = rewardCenter.goals.filter { !rewardCenter.isDone($0, tasks: appState.tasks) }
        let done = rewardCenter.goals.filter { rewardCenter.isDone($0, tasks: appState.tasks) }
        return open + done
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader("Goal rewards", meta: Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .padding(.top, 8)
                SectionLabel("Goals").padding(.top, 10)

                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    GroupedCard {
                        if goals.isEmpty {
                            Text("No goals yet. A goal is a few tasks you want to finish together.")
                                .font(IOSFont.body)
                                .foregroundStyle(IOSPalette.fg2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
                                if index > 0 { RowDivider(inset: 16) }
                                goalCard(goal, now: timeline.date)
                            }
                        }
                    }
                }

                Button { showNewGoal = true } label: {
                    Text("+ New goal")
                        .font(IOSFont.ui(16, .medium))
                        .foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                SectionLabel("Your rewards").padding(.top, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(rewardCenter.catalog) { reward in
                        Button { tappedReward = reward } label: {
                            RewardChip(title: reward.title ?? "Reward", minutes: reward.minutes, icon: reward.icon)
                                .frame(minHeight: IOSLayout.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { showNewReward = true } label: {
                    Text("+ Add reward")
                        .font(IOSFont.ui(16, .medium))
                        .foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Rewards are yours to set. No points, no streaks.")
                    .font(IOSFont.meta)
                    .foregroundStyle(IOSPalette.fg3)
                    .padding(.top, 6)
                Color.clear.frame(height: 180)
            }
            .padding(.horizontal, IOSLayout.screenPadH)
        }
        .iosScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showNewGoal) { GoalNewSheet() }
        .sheet(isPresented: $showNewReward) { RewardNewSheet() }
        .sheet(item: $rewardForGoal) { goal in RewardPickerSheet(goalId: goal.id) }
        .confirmationDialog(
            goalToDelete?.title ?? "Goal",
            isPresented: Binding(get: { goalToDelete != nil }, set: { if !$0 { goalToDelete = nil } }),
            titleVisibility: .visible,
            presenting: goalToDelete
        ) { goal in
            Button("Delete goal", role: .destructive) { rewardCenter.removeGoal(goal.id) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            tappedReward?.title ?? "Reward",
            isPresented: Binding(get: { tappedReward != nil }, set: { if !$0 { tappedReward = nil } }),
            titleVisibility: .visible,
            presenting: tappedReward
        ) { reward in
            Button("Delete reward", role: .destructive) { rewardCenter.removeReward(reward.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func goalCard(_ goal: RewardItem, now: Date) -> some View {
        let grant = rewardCenter.grant(forGoal: goal.id)
        let tasks = goal.taskIds.compactMap { id in appState.tasks.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(goal.title ?? "Goal")
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(IOSPalette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(rewardCenter.doneCount(of: goal, tasks: appState.tasks))/\(goal.taskIds.count) tasks")
                    .font(IOSFont.mono(13))
                    .foregroundStyle(IOSPalette.fg3)
                Button { goalToDelete = goal } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IOSPalette.fg3)
                        .frame(width: IOSLayout.minTouch, height: IOSLayout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Goal options")
            }
            .padding(.leading, 16)
            ForEach(tasks) { task in
                goalRow(task)
            }
            rewardRow(goal, grant: grant, now: now)
        }
        .padding(.trailing, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rewardRow(_ goal: RewardItem, grant: RewardItem?, now: Date) -> some View {
        let state = grant.map { rewardCenter.state(of: $0, tasks: appState.tasks, now: now) }
        Button { rewardForGoal = goal } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let grant, let title = grant.title {
                    RewardChip(title: title, minutes: grant.minutes, icon: grant.icon,
                               highlighted: state == .unlocked)
                    if grant.goalIds.count > 1 {
                        let n = grant.goalIds.count - 1
                        Text("with \(n) other goal\(n == 1 ? "" : "s")")
                            .font(IOSFont.meta)
                            .foregroundStyle(IOSPalette.fg3)
                    }
                } else {
                    Text("Add reward")
                        .font(IOSFont.ui(15, .medium))
                        .foregroundStyle(IOSPalette.mint)
                }
            }
            .frame(minHeight: IOSLayout.minTouch, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        if let grant, let state {
            statusBlock(grant, state: state)
        }
    }

    @ViewBuilder
    private func goalRow(_ task: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { appState.toggleDone(task.id) } label: {
                ZStack {
                    Circle()
                        .stroke(task.done ? IOSPalette.done : IOSPalette.borderHi, lineWidth: 1.5)
                        .background(Circle().fill(task.done ? IOSPalette.done : Color.clear))
                        .frame(width: 22, height: 22)
                    if task.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IOSPalette.onMint)
                    }
                }
                .frame(width: IOSLayout.minTouch, height: IOSLayout.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(task.title) as \(task.done ? "open" : "done")")

            NavigationLink(value: task.id) {
                Text(task.title)
                    .font(IOSFont.rowTitle)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? IOSPalette.fg3 : IOSPalette.fg)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func statusBlock(_ grant: RewardItem, state: RewardState) -> some View {
        if state == .unlocked, let title = grant.title {
            HStack {
                Text("Earned: \(title)\(grant.minutes.map { " \u{00B7} \($0)m" } ?? "")")
                    .font(IOSFont.mono(13))
                    .foregroundStyle(IOSPalette.mint)
                Spacer(minLength: 8)
                Button { rewardCenter.startBreak(grant.id) } label: {
                    Text("Start timer")
                        .font(IOSFont.ui(15, .semibold))
                        .foregroundStyle(IOSPalette.onMint)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(IOSPalette.primaryGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(minHeight: IOSLayout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, IOSLayout.minTouch + 8)
        } else if state == .running, let ends = grant.breakEndsAt {
            Text("On a break \u{00B7} ends \(ends.formatted(.dateTime.hour().minute()))")
                .font(IOSFont.mono(13))
                .foregroundStyle(IOSPalette.mint)
                .padding(.leading, IOSLayout.minTouch + 8)
        }
    }
}

#Preview {
    NavigationStack { GoalsIOSView() }
        .environment(AppState())
        .environment(RewardCenter(store: nil))
}
