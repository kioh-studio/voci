// Sources/App/VolarIOSApp.swift — @main entry point for the iOS app (feature 011, U-Shell).
// iOS has no menu bar / hotkey / AppDelegate: everything a macOS AppDelegate did is inlined on the
// scene via `.task` / `.onOpenURL` / `.onChange(of: scenePhase)`.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct VolarIOSApp: App {
    @State private var appState: AppState
    @State private var rewardCenter: RewardCenter
    @State private var offlineCapture: OfflineCaptureCenter
    @Environment(\.scenePhase) private var scenePhase
    /// When the app left the foreground; the focus timer is suspended in the background.
    @State private var backgroundedAt: Date?

    /// Onboarding gate: no `OnboardingIOSView` yet, so the flag is flipped true on first launch.
    @AppStorage("hasOnboardedV1") private var hasOnboarded = false

    /// BGAppRefresh identifier. P45 adds it to Info.plist `BGTaskSchedulerPermittedIdentifiers`
    /// and adds `fetch` to `UIBackgroundModes`; without those keys `register`/`submit` fail.
    private static let refreshTaskID = "tech.kioh.Volar.refresh"

    init() {
        // Degrade gracefully: if SwiftData fails to open, AppState falls back to an empty list.
        let store = try? TaskStore()
        let state = AppState(store: store)
        let rewards = RewardCenter(store: store)
        let offline = OfflineCaptureCenter()
        state.offlineCapture = offline
        state.rewardCenterDidApplyRemote = { rewards.handleRemoteApplied() }
        _appState = State(initialValue: state)
        _rewardCenter = State(initialValue: rewards)
        _offlineCapture = State(initialValue: offline)
        RootTabView.configureTabBarAppearance()

        // Must be registered before the app finishes launching; `App.init` runs early enough.
        // UNVERIFIED: not run on device. The handler is delivered on the main queue (`using: .main`); the
        // `@MainActor` hop is still explicit for the async body; the 20s sleep gives the sync round-trip time before we report done.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: .main) { task in
            // Re-arm first: BGAppRefresh is one-shot, so without this it only ever fires once.
            Self.scheduleRefresh()
            // `BGTask` is not Sendable; boxing it like `ReminderScheduler` boxes completion handlers
            // keeps Swift 6 strict concurrency from rejecting the hop into the `@MainActor` Task.
            nonisolated(unsafe) let bgTask = task
            let work = Task { @MainActor in
                SyncEngine.shared.requestSync(reason: .foreground)
                try? await Task.sleep(for: .seconds(20))
                bgTask.setTaskCompleted(success: !Task.isCancelled)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
    }

    private static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(rewardCenter)
                .environment(offlineCapture)
                // Dark-only (plan §4).
                .preferredColorScheme(.dark)
                .task {
                    appState.activateServices()
                    if !hasOnboarded { hasOnboarded = true }
                    // `@Sendable` is load-bearing: UNUserNotificationCenter calls this off the main
                    // actor and Swift 6 traps on an inferred-MainActor closure (see VolarApp.swift).
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
                    NotificationActions.registerCategories()
                }
                .onOpenURL { url in
                    appState.appLinkHandler?.handle(url)
                    appState.onAppLinkHandled()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        // The 1s focus timer does not run while suspended: catch up by wall clock.
                        if let since = backgroundedAt, appState.focusActive, !appState.focusPaused {
                            let elapsed = Int(Date().timeIntervalSince(since))
                            appState.focusSecondsLeft = max(0, appState.focusSecondsLeft - elapsed)
                            if appState.focusSecondsLeft == 0 { appState.endFocus() }
                        }
                        backgroundedAt = nil
                        appState.refreshFromStore()
                        rewardCenter.refresh()
                    case .background:
                        backgroundedAt = Date()
                        Self.scheduleRefresh()
                    default:
                        break
                    }
                }
        }
    }
}
