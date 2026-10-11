// Sources/Views/GoalsIOSView.swift — Goals tab (feature 011, U-Goals). Artboard: Goals.dc.html.
// Mounted by U-Shell inside a NavigationStack; rows push detail via NavigationLink(value: task.id).
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct GoalsIOSView: View {
    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter

    @State private var showGoalPicker = false
    @State private var showNewReward = false
    @State private var tappedReward: RewardItem?

    private var goals: [TaskItem] {
        let withGrant = appState.tasks.filter { rewardCenter.grant(for: $0.id) != nil }
        return withGrant.filter { !$0.done } + withGrant.filter(\.done)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader("Goal rewards", meta: Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .padding(.top, 8)
                SectionLabel("Today's goals").padding(.top, 10)

                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    GroupedCard {
                        if goals.isEmpty {
                            Text("No goals yet. Pick a task you want a reward for.")
                                .font(IOSFont.body)
                                .foregroundStyle(IOSPalette.fg2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(goals.enumerated()), id: \.element.id) { index, task in
                                if index > 0 { RowDivider(inset: 16) }
                                goalRow(task, now: timeline.date)
                            }
                        }
                    }
                }

                Button { showGoalPicker = true } label: {
                    Text("+ Add a goal")
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
        .sheet(isPresented: $showGoalPicker) { GoalTaskPickerSheet() }
        .sheet(isPresented: $showNewReward) { RewardNewSheet() }
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
    private func goalRow(_ task: TaskItem, now: Date) -> some View {
        if let grant = rewardCenter.grant(for: task.id) {
            let state = rewardCenter.state(of: grant, tasks: appState.tasks, now: now)
            VStack(alignment: .leading, spacing: 10) {
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.title)
                                .font(IOSFont.rowTitle)
                                .strikethrough(task.done)
                                .foregroundStyle(task.done ? IOSPalette.fg3 : IOSPalette.fg)
                                .multilineTextAlignment(.leading)
                            if let title = grant.title {
                                RewardChip(title: title, minutes: grant.minutes, icon: grant.icon,
                                           highlighted: state == .unlocked)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
            .padding(.trailing, 16)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    NavigationStack { GoalsIOSView() }
        .environment(AppState())
        .environment(RewardCenter(store: nil))
}
