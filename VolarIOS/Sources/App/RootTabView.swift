// Sources/App/RootTabView.swift — Now · Goals · Views shell, mic FAB, capture sheet, Focus cover
// (feature 011, contract D-C/D-D/D-M/§6).
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI
import UIKit   // iOS-only file: UITabBarAppearance proxy below.

enum RootTab: Hashable {
    case now, goals, views
}

struct RootTabView: View {
    @Environment(AppState.self) private var appState: AppState
    @Environment(RewardCenter.self) private var rewardCenter
    @State private var selectedTab: RootTab = .now
    @State private var unlockedGrant: RewardItem?
    /// Same key as `RewardCenter.isEnabled` and the Views toggle.
    @AppStorage("volar.view.goalRewards") private var goalRewardsOn = false

    /// FAB clearance above the system tab bar (~49pt bar + gap).
    // UNVERIFIED: tab bar height not measured on-device; tune at Cổng iOS verify.
    private static let fabBottomInset: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                stack("Now") { NowIOSView() }
                    .tabItem { Label("Now", systemImage: "target") }
                    .tag(RootTab.now)

                if goalRewardsOn {
                    stack("Goals") { GoalsIOSView() }
                        .tabItem { Label("Goals", systemImage: "flag") }
                        .tag(RootTab.goals)
                }

                stack("Views") { ViewsIOSView() }
                    .tabItem { Label("Views", systemImage: "square.grid.2x2") }
                    .tag(RootTab.views)
            }
            .tint(IOSPalette.mint)

            if selectedTab != .views {
                MicFAB()
                    .padding(.bottom, Self.fabBottomInset)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: selectedTab)
        // Hoisted from the Now tab so a goal finished from Goals/Views still offers its reward.
        .sheet(item: $unlockedGrant) { grant in RewardUnlockedSheet(grant: grant) }
        .onAppear(perform: checkUnlocked)
        .onChange(of: appState.doneTasks.map(\.id)) { _, _ in checkUnlocked() }
        .onChange(of: rewardCenter.grants) { _, _ in checkUnlocked() }
        .onChange(of: goalRewardsOn) { _, on in
            if !on && selectedTab == .goals { selectedTab = .now }
        }
        // Capture sheet: driven purely by `appState.captureState`; interactive dismiss routes through
        // `cancelCapture()` so the state machine never stays non-idle behind a closed sheet.
        .sheet(isPresented: Binding(
            get: { appState.captureState != .idle },
            set: { presented in if !presented { appState.cancelCapture() } }
        )) {
            CaptureSheet()
                .environment(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(IOSPalette.surface)
                .presentationCornerRadius(IOSLayout.sheetRadius)
        }
        // Focus (D-M): full-screen cover; `endFocus()` is idempotent so racing the view's own End is safe.
        .fullScreenCover(isPresented: Binding(
            get: { appState.focusActive },
            set: { if !$0 { appState.endFocus() } }
        )) {
            FocusIOSView().environment(appState)
        }
    }

    /// Each tab owns a NavigationStack; the root hides its bar (custom `ScreenHeader`) but keeps a
    /// title so pushed detail shows a back button named after the tab.
    private func stack<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { TaskDetailIOSView(taskId: $0) }
        }
    }

    private func checkUnlocked() {
        guard rewardCenter.isEnabled, unlockedGrant == nil else { return }
        let hit = rewardCenter.grants.first {
            !rewardCenter.offeredGrantIDs.contains($0.id)
                && rewardCenter.state(of: $0, tasks: appState.tasks) == .unlocked
        }
        guard let hit else { return }
        // Mark offered now so a swipe-dismiss (no button) never re-presents it.
        rewardCenter.dismissUnlocked(hit.id)
        unlockedGrant = hit
    }

    static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor(IOSPalette.tabBarBg)
        appearance.shadowColor = UIColor(IOSPalette.border)

        let font = UIFont(name: "Geist-Medium", size: 10) ?? UIFont.systemFont(ofSize: 10, weight: .medium)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(IOSPalette.fg3)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(IOSPalette.fg3), .font: font]
        item.selected.iconColor = UIColor(IOSPalette.mint)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(IOSPalette.mint), .font: font]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
