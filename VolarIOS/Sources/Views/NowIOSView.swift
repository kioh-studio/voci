// VolarIOS/Sources/Views/NowIOSView.swift — Now tab (feature 011, artboards Main / Now-Empty /
// Break-Running / Capture-Offline). Replaces TodayIOSView. U-Shell mounts it in a NavigationStack
// that declares `.navigationDestination(for: UUID.self)`.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct NowIOSView: View {
    @Environment(AppState.self) private var appState
    @Environment(RewardCenter.self) private var rewardCenter
    @Environment(OfflineCaptureCenter.self) private var offlineCapture

    @State private var showSavedToast = false
    @State private var showReparse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader("Now", meta: Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 8)
                .padding(.bottom, 14)

            if !offlineCapture.isOnline { offlineBanner }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if offlineCapture.isOnline && !offlineCapture.pending.isEmpty { tidyUpRow }
                    mainBlock
                    if showSavedToast { savedToast }
                }
                .padding(.horizontal, IOSLayout.screenPadH)
                .padding(.top, 8)
                // Clears the mic FAB + tab bar.
                .padding(.bottom, 180)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .iosScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showReparse) { ReparseReviewSheet() }
        // Close a break whose timer ran out (the device that started it owns the write; once only,
        // because `closedAt` is set afterwards).
        .task {
            while !_Concurrency.Task.isCancelled {
                closeExpiredBreaks()
                try? await _Concurrency.Task.sleep(for: .seconds(1))
            }
        }
        .task(id: offlineCapture.lastSavedOfflineAt) {
            guard let saved = offlineCapture.lastSavedOfflineAt else { return }
            let left = 4 - Date().timeIntervalSince(saved)
            guard left > 0 else { return }
            withAnimation { showSavedToast = true }
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
            withAnimation { showSavedToast = false }
        }
    }

    // MARK: - Main block

    @ViewBuilder
    private var mainBlock: some View {
        // Re-evaluated every second so a break flips back to NOW by itself when the timer ends.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if rewardCenter.isEnabled, let brk = rewardCenter.runningBreak(now: ctx.date) {
                breakBlock(brk, now: ctx.date)
            } else if let task = appState.dashboardActiveTask {
                nowBlock(task)
            } else {
                emptyBlock
            }
        }
    }

    private func nextTask(after task: TaskItem?) -> TaskItem? {
        appState.openTasks.first { $0.id != task?.id }
    }

    // MARK: - NOW

    private func nowBlock(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NowChip()

            NavigationLink(value: task.id) {
                Text(task.title)
                    .font(IOSFont.nowTitle)
                    .tracking(IOSFont.nowTitleTracking)
                    .lineSpacing(4)
                    .foregroundStyle(IOSPalette.fg)
                    .shadow(color: IOSPalette.mintGlow, radius: 15)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            chipsRow(task)

            if let text = descriptionText(task) {
                Text(text)
                    .font(IOSFont.body)
                    .foregroundStyle(IOSPalette.fg2)
                    .lineSpacing(3)
            }

            if let next = nextTask(after: task) {
                nextBlock(title: next.title, trailing: "after this one")
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                PrimaryButton("Start focus") { appState.startFocus() }
                HStack(spacing: 10) {
                    SecondaryButton("Done", systemImage: "checkmark") { appState.toggleDone(task.id) }
                    SecondaryButton("Switch", systemImage: "arrow.left.arrow.right") { appState.switchDashboardActiveTask() }
                        .disabled(!appState.canSwitchDashboardActiveTask)
                        .opacity(appState.canSwitchDashboardActiveTask ? 1 : 0.4)
                }
            }
            .padding(.top, 8)
        }
    }

    private func chipsRow(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            if task.priority == .high { MetaChip("High", dot: IOSPalette.high) }
            if let deadline = task.deadline { MetaChip(deadlineLabel(deadline), color: IOSPalette.med) }
            if let minutes = task.durationMinutes { MetaChip("\(minutes)m") }
        }
    }

    private func deadlineLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func descriptionText(_ task: TaskItem) -> String? {
        let d = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        let n = (task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    private func nextBlock(title: String, trailing: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEXT")
                .font(IOSFont.mono(11))
                .tracking(0.66)
                .foregroundStyle(IOSPalette.fg3)
            HStack(spacing: 10) {
                Circle().stroke(IOSPalette.fg3, lineWidth: 1.2).frame(width: 14, height: 14)
                Text(title)
                    .font(IOSFont.ui(15))
                    .foregroundStyle(IOSPalette.fg2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(IOSFont.mono(12))
                    .foregroundStyle(IOSPalette.med)
            }
        }
    }

    // MARK: - BREAK

    private func breakBlock(_ brk: RewardItem, now: Date) -> some View {
        let nowTask = appState.dashboardActiveTask
        let start = brk.breakStartedAt ?? now
        let end = max(brk.breakEndsAt ?? now, now)
        let total = max(end.timeIntervalSince(start), 1)
        return VStack(alignment: .leading, spacing: 14) {
            BreakChip()
            Text(brk.title ?? "Break")
                .font(IOSFont.ui(30, .semibold))
                .tracking(IOSFont.nowTitleTracking)
                .foregroundStyle(IOSPalette.fg)
                .shadow(color: IOSPalette.mintGlow, radius: 15)
            // Artboard Break-Running: mono 64/500 (the brief said 44; artboard wins).
            Text(timerInterval: now...end, countsDown: true)
                .font(IOSFont.mono(64, .medium))
                .monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(IOSPalette.fg)
                .padding(.top, 10)
            ProgressView(value: min(max(now.timeIntervalSince(start), 0), total), total: total)
                .progressViewStyle(.linear)
                .tint(IOSPalette.mint)
            Text(endsLine(end: end, back: nowTask?.title))
                .font(IOSFont.meta)
                .foregroundStyle(IOSPalette.fg2)

            if let nowTask {
                nextBlock(title: nowTask.title, trailing: "when the timer ends")
                    .padding(.top, 24)
            }

            SecondaryButton("I'm back early") { rewardCenter.endBreak(brk.id) }
                .padding(.top, 16)
        }
    }

    private func endsLine(end: Date, back: String?) -> String {
        let t = end.formatted(.dateTime.hour().minute())
        return back.map { "Ends \(t) · then back to \($0)" } ?? "Ends \(t)"
    }

    // MARK: - Empty

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing on your plate.")
                .font(IOSFont.ui(30, .semibold))
                .tracking(IOSFont.nowTitleTracking)
                .foregroundStyle(IOSPalette.fg3)
            Text("Tap the mic and say what needs doing — all of it, in one breath. Volar writes it down and works out the order.")
                .font(IOSFont.body)
                .lineSpacing(5)
                .foregroundStyle(IOSPalette.fg2)
        }
        .padding(.top, 100)
    }

    // MARK: - Offline / tidy-up

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 16))
            Text("Offline — what you say is saved word for word.").font(IOSFont.meta)
        }
        .foregroundStyle(IOSPalette.fg2)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))
        .padding(.horizontal, IOSLayout.screenPadH)
        .padding(.bottom, 8)
    }

    private var savedToast: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(IOSPalette.done)
                Text("Saved. Nothing lost.").font(IOSFont.ui(15, .medium)).foregroundStyle(IOSPalette.fg)
            }
            Text("Volar will tidy it up when you're back online.")
                .font(IOSFont.meta)
                .foregroundStyle(IOSPalette.fg2)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSPalette.surfaceHi, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
        .transition(.opacity)
    }

    private var tidyUpRow: some View {
        let n = offlineCapture.pending.count
        return GroupedCard {
            ValueRow(icon: "sparkles", title: "Tidy up \(n) capture\(n == 1 ? "" : "s")",
                     value: nil, action: { showReparse = true })
        }
    }

    // MARK: - Expired breaks

    private func closeExpiredBreaks() {
        let now = Date()
        let me = SyncEngine.shared.deviceId
        for g in rewardCenter.grants {
            guard g.closedAt == nil, g.startedDevice == me, let ends = g.breakEndsAt, ends <= now else { continue }
            rewardCenter.endBreak(g.id, now: ends)
        }
    }
}

/// Same pill as `NowChip`, text BREAK (NowChip is frozen, so no `text:` param).
private struct BreakChip: View {
    var body: some View {
        Text("BREAK")
            .font(IOSFont.nowChip)
            .tracking(IOSFont.nowChipTracking)
            .foregroundStyle(IOSPalette.onMint)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(IOSPalette.mint, in: Capsule())
    }
}

#Preview("Now") {
    NavigationStack { NowIOSView() }
        .environment(AppState())
        .environment(RewardCenter(store: nil))
        .environment(OfflineCaptureCenter())
        .preferredColorScheme(.dark)
}
