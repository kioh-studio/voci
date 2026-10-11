// VolarIOS/Sources/Views/FocusIOSView.swift — minimal full-screen focus cover (contract D-M).
// Presented by RootTabView as a fullScreenCover bound to `appState.focusActive`.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct FocusIOSView: View {
    @Environment(AppState.self) private var appState

    private var task: TaskItem? {
        let open = appState.openTasks
        if open.indices.contains(appState.focusIndex) { return open[appState.focusIndex] }
        return appState.dashboardActiveTask
    }

    private var clock: String {
        let s = max(appState.focusSecondsLeft, 0)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FOCUS")
                .font(IOSFont.nowChip)
                .tracking(IOSFont.nowChipTracking)
                .foregroundStyle(IOSPalette.onMint)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(IOSPalette.mint, in: Capsule())
                .padding(.top, 59)

            Text(task?.title ?? "Focus")
                .font(IOSFont.nowTitle)
                .tracking(IOSFont.nowTitleTracking)
                .lineSpacing(4)
                .foregroundStyle(IOSPalette.fg)
                .shadow(color: IOSPalette.mintGlow, radius: 15)

            Text(clock)
                .font(IOSFont.mono(72, .medium))
                .monospacedDigit()
                .foregroundStyle(appState.focusPaused ? IOSPalette.fg3 : IOSPalette.fg)
                .padding(.top, 24)

            Spacer()

            VStack(spacing: 10) {
                PrimaryButton(appState.focusPaused ? "Resume" : "Pause",
                              systemImage: appState.focusPaused ? "play.fill" : "pause.fill") {
                    appState.toggleFocusPause()
                }
                HStack(spacing: 10) {
                    if let task {
                        SecondaryButton("Done", systemImage: "checkmark") { appState.completeFocusTask(task.id) }
                    }
                    SecondaryButton("End") { appState.endFocus() }
                }
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, IOSLayout.screenPadH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .iosScreenBackground()
    }
}

#Preview("Focus") {
    FocusIOSView()
        .environment(AppState())
        .preferredColorScheme(.dark)
}
