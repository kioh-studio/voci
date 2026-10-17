// Sources/App/VolarApp.swift — @main entry point: scenes, environment injection, delegate hookup
import SwiftUI
import AppKit
import UserNotifications

@main
struct VolarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @AppStorage("hasOnboardedV1") private var hasOnboarded = false
    /// Day key ("yyyy-MM-dd") the morning-frog sheet was last shown on — gates it to once/day.
    @AppStorage("morningFrogLastShown") private var frogLastShown = ""
    /// ISO year-week key ("2026-W29") the weekly stale-task triage batch (T034/FR-018) was last
    /// shown on — gates it to once/week, mirroring `frogLastShown`'s once/day pattern.
    @AppStorage("triageLastShownWeek") private var triageLastShownWeek = ""

    init() {
        // Degrade gracefully: if the SwiftData container fails to initialize for any reason,
        // fall back to AppState's empty in-memory task list rather than crashing at launch.
        let store = try? TaskStore()
        let state = AppState(store: store)
        _appState = State(initialValue: state)

        // F1/F2 integration fix: hand the SAME AppState instance to the AppDelegate so its
        // window-independent observers (registered in `applicationDidFinishLaunching`, see
        // AppDelegate below) operate on this one instance rather than a second one. There is
        // exactly one AppState in the app — this line and `_appState` above are the only two
        // places `AppState(...)` is constructed/held. `@NSApplicationDelegateAdaptor`'s default
        // initializer expression (declared above `appState`) runs before this custom `init()`
        // body executes, so `appDelegate` already exists here and this assignment lands before
        // `applicationDidFinishLaunching` fires later on the run loop.
        appDelegate.appState = state

        // App Intents seam (Shared/Intents/IntentBridge.swift): Siri/Shortcuts/Spotlight dispatch
        // into `perform()` with no SwiftUI environment to read `AppState` from, so the one instance
        // constructed two lines above is published here. Deliberately assigned at the SAME place as
        // `appDelegate.appState` — the comment above is explicit that this init is one of only two
        // places an `AppState` is ever held, and `AppState.shared` is `weak` precisely so it stays a
        // reference to that instance rather than becoming a third owner of one.
        AppState.shared = state
    }

    /// ⌘K — in-app-only shortcut for `CommandBar` (`Sources/Views/CommandBar.swift`). Deliberately
    /// NOT registered in `HotkeyManager` (`Sources/Speech/HotkeyManager.swift`) — that file owns the
    /// two GLOBAL Carbon hotkeys (⌃⌥M/⌃⌥T), untouched by this task; this is an ordinary in-app
    /// SwiftUI shortcut that only fires while Volar's own window has focus. Carried by an invisible
    /// `.keyboardShortcut`-bound `Button`, the same "zero-size button carries the shortcut" trick
    /// `TextCaptureView.escCancelButton` (`TextCapturePanel.swift`) already uses elsewhere in this
    /// codebase — grepped every `keyboardShortcut(` call site under `Sources/` before wiring this
    /// (self-review point 3 of this task's brief): ⌘K was unclaimed.
    private var commandBarShortcut: some View {
        Button("") { appState.openCommandBar() }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// The ⌘K bar itself, presented as an OVERLAY on the main window's content — not a `.sheet`
    /// (design-spec §4.2: "floats over the content without dimming it into a modal", unlike every
    /// other presentation in this file's `.sheet` chain below). `GeometryReader` places it in the
    /// window's upper third, horizontally centered, per the same spec note ("Cursor puts ⌘K high,
    /// not dead center") — `CommandBar` itself owns width/appearance, this only owns position.
    /// `CommandBar`'s own Esc-bound hidden button closes it; `submit()` closes it too (see that
    /// file). `.transition`'s matching `.animation(value: appState.showCommandBar)` is on the
    /// `.overlay` call site below.
    @ViewBuilder
    private var commandBarOverlay: some View {
        if appState.showCommandBar {
            GeometryReader { geo in
                CommandBar()
                    .environment(appState)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.28)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    var body: some Scene {
        // SCENE ORDER IS LOAD-BEARING (changed 2026-07-26 together with dropping LSUIElement from
        // Info.plist): `Window` is declared FIRST so SwiftUI treats it as the primary scene and
        // opens it at launch. Previously `MenuBarExtra` came first, which — combined with
        // LSUIElement — is what made the app launch with no visible window at all. `MenuBarExtra`
        // now sits below the `Window` scene; it still works exactly the same, it just isn't the
        // scene SwiftUI opens on launch. Moving it back above `Window` would silently restore the
        // old no-window-at-launch behavior. // UNVERIFIED: not built on a Mac yet — confirm at
        // Cổng 1 that the window actually appears on a cold launch.
        Window("Volar", id: "main") {
            TodayView()
                .environment(appState)
                .frame(minWidth: 920, minHeight: 560)
                .task {
                    // Starts the global ⌃⌥M toggle-capture hotkey (degrades gracefully without
                    // Accessibility permission — see AppState.activateServices).
                    // F1/F2 fix: ALSO called from `AppDelegate.applicationDidFinishLaunching` below
                    // — the window opens at launch as of 2026-07-26, but the user can still close it
                    // (⌘W) and leave Volar running from the menu bar, so relying solely on this
                    // `.task` would leave the hotkey/rebuild/overdue-scan dead for
                    // the rest of that session. The double call is intentional and safe: `hotkey.start` tears down any
                    // existing registration first, mỗi `start*` invalidates any existing
                    // timer first, and `rebuildFromStorage`/the overdue scan are both idempotent.
                    appState.activateServices()

                    // Daily morning-frog prompt: once per calendar day, once onboarding is done,
                    // and only when there's actually something open to pick from.
                    // POSIX locale + Gregorian so the day key is stable even if the user's
                    // system region uses a non-Gregorian calendar or changes over time.
                    let day = {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "en_US_POSIX")
                        f.calendar = Calendar(identifier: .gregorian)
                        f.dateFormat = "yyyy-MM-dd"
                        return f.string(from: Date())
                    }()
                    // Guided tour (`Sources/Views/Tour/*`): `!appState.tourActive` added to every
                    // sheet gate below (morning frog / weekly triage / evening sweep) so a modal
                    // sheet can never stack on top of the tour's own full-window overlay — without
                    // it, a fresh install's very first launch could pop the morning-frog sheet
                    // right in the middle of `TourOverlay`'s spotlight walkthrough.
                    if hasOnboarded, !appState.tourActive, frogLastShown != day, !appState.openTasks.isEmpty {
                        appState.showMorningFrog = true
                        frogLastShown = day
                    }

                    // T034/FR-018: weekly stale-task triage — once per ISO week, once onboarding
                    // is done, and only when there's actually something stale to review (skipped
                    // otherwise; `TriageView` itself also no-ops on an empty batch as a second
                    // line of defense).
                    let weekKey = {
                        var cal = Calendar(identifier: .iso8601)
                        cal.locale = Locale(identifier: "en_US_POSIX")
                        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
                        return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
                    }()
                    if hasOnboarded, !appState.tourActive, triageLastShownWeek != weekKey, !appState.staleTasks.isEmpty {
                        appState.showTriage = true
                        triageLastShownWeek = weekKey
                    }

                    // WG-B (ship-blocker, FR-021): evening sweep — `maybeShowEveningSweep()` itself
                    // already self-gates on ISO-day (once/day, via `sweepLastShownDayKey`) and a
                    // non-empty `sweepItems`; this call site adds the one gate it can't do on its
                    // own — only offer the sweep in the evening (hour >= 18), so it's never sprung
                    // on someone opening the window at 9am.
                    let hour = Calendar.current.component(.hour, from: Date())
                    if hasOnboarded, !appState.tourActive, hour >= 18 {
                        appState.maybeShowEveningSweep()
                    }
                }
                // F1/F2 integration fix: the window-independent observers that used to live
                // here (`.onOpenURL` and sleep/wake recovery) were
                // moved to `AppDelegate` below — this `Window` scene can be CLOSED by the user at
                // any time (⌘W leaves Volar alive in the menu bar), so `.onReceive`/`.onOpenURL`
                // attached to it were torn down along with the window and silently stopped firing.
                // Still true after the 2026-07-26 switch to opening this window at launch: "opens at
                // launch" is not "always open". `AppDelegate` is
                // app-lifetime (registered via `@NSApplicationDelegateAdaptor` above) and shares
                // this exact `appState` instance (wired in `init()` above), so those three concerns
                // now fire whether or not this window is open. What's left on this scene — sheets,
                // the onboarding/frog/triage/sweep gates below — genuinely needs a visible window.
                .sheet(isPresented: Binding(
                    get: { !hasOnboarded },
                    // Guided tour (`Sources/Views/Tour/*`): `appState.startTourIfNeeded()` is
                    // ALSO called from `OnboardingView`'s own `onComplete:` below — that covers the
                    // normal "Start using Volar"/"Skip for now" tap, which sets `hasOnboarded =
                    // true` directly and lets SwiftUI's diffing notice `get()` now reads `false`.
                    // This binding's `set:` is the FRAMEWORK's own dismissal path (used when
                    // SwiftUI itself decides to tear the sheet down, e.g. a future change that
                    // drops `.interactiveDismissDisabled(true)` below) — calling it here too, not
                    // just in `onComplete:`, is what makes "the tour starts however onboarding
                    // ends" true regardless of which of the two paths actually fires for a given
                    // dismissal. `startTourIfNeeded()` itself is idempotent (no-op once
                    // `hasSeenTour` is `true`), so both call sites firing for the same completion
                    // is harmless, not a double-start.
                    set: { presented in
                        if !presented {
                            hasOnboarded = true
                            appState.startTourIfNeeded()
                        }
                    }
                )) {
                    OnboardingView(onComplete: {
                        hasOnboarded = true
                        appState.startTourIfNeeded()
                    })
                    .environment(appState)
                    .interactiveDismissDisabled(true)
                    .frame(minWidth: 640, minHeight: 440)
                }
                .sheet(isPresented: Binding(
                    get: { appState.showMorningFrog },
                    set: { presented in if !presented { appState.showMorningFrog = false } }
                )) {
                    MorningFrogView(
                        onPick: { appState.pickFrog($0) },
                        onSkip: { appState.dismissMorningFrog() }
                    )
                    .environment(appState)
                    .frame(minWidth: 640, minHeight: 560)
                }
                .sheet(isPresented: Binding(
                    get: { appState.showBreakdown },
                    set: { presented in if !presented { appState.showBreakdown = false } }
                )) {
                    TaskBreakdownView(
                        onSave: { appState.saveBreakdown($0) },
                        onClose: { appState.showBreakdown = false }
                    )
                    .environment(appState)
                    .frame(minWidth: 480, minHeight: 560)
                }
                // Panel-refactor (specs/005-cursor-retheme/panel-refactor.md §5 item 2): the detail
                // `.sheet` that used to live here is GONE — `TaskDetailView` is now rendered as a
                // 300pt inspector column inside `TodayView.body`'s own `HStack`, not a modal. Do not
                // re-add it; `detailTaskID != nil` now only drives that in-window panel.
                .sheet(isPresented: Binding(
                    get: { appState.showTriage },
                    set: { presented in if !presented { appState.showTriage = false } }
                )) {
                    TriageView(
                        items: appState.staleTasks,
                        onKeep: { appState.triageKeep($0) },
                        onBreakdown: { appState.triageBreakdown($0) },
                        onDefer: { appState.triageDefer($0) },
                        onDrop: { appState.triageDrop($0) }
                    )
                    .environment(appState)
                    .frame(minWidth: 560, minHeight: 480)
                }
                .sheet(isPresented: Binding(
                    get: { appState.showSweep },
                    set: { presented in if !presented { appState.dismissSweep() } }
                )) {
                    SweepView(
                        items: appState.sweepItems,
                        onComplete: { appState.sweepComplete($0) },
                        onSkip: { appState.sweepSkip($0) },
                        onDismiss: { appState.dismissSweep() }
                    )
                    .environment(appState)
                    .frame(minWidth: 560, minHeight: 480)
                }
                // ⌘K command bar (design-spec §4.2) — invisible shortcut-carrying button + overlay,
                // added last in the chain so the overlay paints above the sheets' own content when
                // a sheet happens to be up (sheets themselves are a separate system layer above
                // this whole view regardless, so ordering here only matters for the in-window
                // overlay/background pieces, not the `.sheet`s above).
                .background(commandBarShortcut)
                // Sơn titlebar cùng màu `VolarColor.bg` (anh Khôi 2026-08-09: "header màu trắng
                // mà body đen nhìn xấu"). Không vẽ gì cả — chỉ mượn `.background` làm chỗ móc vào
                // `NSWindow`; xem `WindowChrome.swift` để biết vì sao là view chứ không phải một
                // lệnh gọi một lần trong `AppDelegate`, và vì sao không dùng `.hiddenTitleBar`.
                .background(WindowChrome())
                .overlay { commandBarOverlay }
                .animation(VolarMotion.state, value: appState.showCommandBar)
        }

        // Declared AFTER `Window` on purpose — see the scene-order note at the top of `body`.
        MenuBarExtra {
            MenuBarMenuContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// `MenuBarExtra`'s dropdown content (the "window" style menu). Kept private to this file rather
/// than a new file under `Sources/Views/` since it's pure app-assembly glue, not a design-frozen
/// component: "Open Volar" / "New task" / "Settings…" / "Quit".
private struct MenuBarMenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Open Volar") {
                openWindow(id: "main")
            }
            Button("New task (\u{2303}\u{2325}M)") {
                appState.startCapture()
                openWindow(id: "main")
            }
            SettingsLink {
                Text("Settings\u{2026}")
            }
            Button("Preview reminder") {
                appState.showReminderPreview()
            }
            Divider()
            Button("Quit Volar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}

/// Handles app-lifecycle setup at launch. The global ⌃⌥M hotkey is started from
/// `AppState.activateServices()` (called from the main window's `.task` above) rather than here,
/// since `AppState` — and its `HotkeyManager` — don't exist yet at `NSApplicationDelegate`
/// construction time.
///
/// F1/F2 integration fix: this is also the home for the three concerns that must survive the main
/// `Window("Volar")` scene being closed. As of 2026-07-26 that window opens at launch (LSUIElement
/// dropped from Info.plist, `Window` declared first in `body`), but the user can still close it with
/// ⌘W and leave Volar running from the menu bar — at which point anything attached to that scene
/// (`.onReceive`/`.onOpenURL`) is torn down. `AppDelegate` itself is app-lifetime (owned by
/// `@NSApplicationDelegateAdaptor` for the whole run), so observers registered here keep firing
/// regardless of window state.
///
/// It also owns the two window-presentation entry points that having a Dock icon requires:
/// `showMainWindow()` (launch) and `applicationShouldHandleReopen` (Dock icon click).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once, in `VolarApp.init()`, right after the single `AppState` instance is constructed
    /// — see that init's doc comment. Not a `let` because `NSApplicationDelegateAdaptor` builds
    /// this object before `AppState` exists; by the time `applicationDidFinishLaunching` (or
    /// `application(_:open:)`) actually runs, `init()` has already returned and this is set.
    /// `?.`-guarded everywhere it's used below so a hypothetical launch ordering slip degrades
    /// gracefully (no crash) rather than force-unwrapping.
    var appState: AppState?

    /// Re-opens the `Window(id: "main")` scene after the user closed it with ⌘W. Set by
    /// `MenuBarLabel` (always mounted), which owns an `openWindow` environment action.
    var openMainWindow: (() -> Void)?

    /// Owns the Services-menu provider for the app's lifetime (backlog "Đường vào Volar" [I2]).
    /// Required because `NSApplication.servicesProvider` does not retain what it is handed — drop
    /// this reference and the system menu item silently stops working the moment ARC collects it.
    var servicesProvider: VolarServicesProvider?

    /// Glance (⌃⌥N) — owns whether the card is on screen and in which mode. Window state, not app
    /// state, which is why it lives here and not on `AppState` (see `GlanceHUD.swift`).
    let glance = GlanceController()

    /// Glance's own floating panel. A THIRD `CapturePanelController`, constructed with
    /// `activates: false` — the two capture panels deliberately steal focus like Spotlight does;
    /// this one must not, or it defeats the entire purpose of a peek that appears mid-keystroke.
    var glancePanelController: CapturePanelController?

    /// Feature 002 gap fix: owns the floating capture panel (`Sources/Views/CapturePanel.swift`)
    /// for the app's lifetime. Created lazily, on the first `syncCapturePanel()` call, rather than
    /// here in `init`/`applicationDidFinishLaunching` — `CapturePanelController.init` needs a real
    /// `AppState` to inject into `PopoverView`'s `.environment(...)`, and (per this class's own
    /// doc comment above) `appState` isn't guaranteed assigned until `VolarApp.init()` has run,
    /// which — for this property specifically — has already happened by the time
    /// `applicationDidFinishLaunching` fires. Lazy construction here is just the more defensive
    /// choice: it also tolerates `observeCaptureState()` firing before that assignment somehow did.
    private var capturePanelController: CapturePanelController?

    /// ⌃⌥T's typed-capture popup — a SECOND, independent `CapturePanelController` instance hosting
    /// `TextCaptureView` instead of `PopoverView` (`CapturePanel.swift`'s `init(content:)` no
    /// longer hardcodes which view it hosts — see that file's header comment for the "two
    /// instances, mutually exclusive by construction" note). Same lazy-construction reasoning as
    /// `capturePanelController` above, driven by `observeTextCaptureState()`/`syncTextCapturePanel()`
    /// below instead of `observeCaptureState()`/`syncCapturePanel()`.
    private var textCapturePanelController: CapturePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fix (2026-07-27, first real-Mac run): originally, Volar's whole palette (`Design/
        // Theme.swift`, `VolarColor.bg` etc.) was hardcoded dark — there was no light variant
        // anywhere in this app. But `Picker`/`Menu`/`TextField`/`Toggle` are backed by real AppKit
        // controls, and AppKit controls draw themselves according to the SYSTEM appearance, not
        // this app's own color tokens. On a Mac running Light Mode that meant every dropdown/menu
        // popup painted its text BLACK on top of Volar's near-black background — unreadable.
        // Forcing the whole app's `NSApplication.appearance`, once, here at launch, is what fixes
        // this for every window AND every floating surface AppKit draws on the app's behalf —
        // including a `Picker`'s popup menu, which AppKit renders in its OWN separate window,
        // outside the SwiftUI view tree entirely. That's specifically why this is `NSApp.appearance`
        // and not `.preferredColorScheme(...)` on a SwiftUI scene: `.preferredColorScheme` only
        // reaches views SwiftUI itself draws, and cannot reach an AppKit-owned popup window. Set
        // as early as possible in the launch sequence (before any window/menu is materialized) so
        // nothing has a chance to draw once in the wrong appearance first.
        //
        // specs/009-light-mode-list-v2/design.md §7: the app now HAS a light palette
        // (`Shared/Design/Theme.swift`), so hardcoding `.darkAqua` unconditionally would fight the
        // user's own System/Light/Dark pick in Settings → General (`AppState.appearance`,
        // `AppearancePreference`, `Shared/App/AppState.swift`). The reasoning above for WHY this
        // line has to exist at all is unchanged — AppKit controls still need to be told an
        // appearance explicitly — it just now reads WHICH appearance from that pref instead of
        // always forcing dark. `.system` maps to `nil` (let AppKit follow the Mac's own setting,
        // same as if this app never touched `NSApp.appearance`), `.light`/`.dark` pin it.
        NSApp.appearance = nsAppearance(for: appState?.appearance ?? .system)

        // F1/F2 fix (MAJOR, liveness): `activateServices()` used to be reachable ONLY from the main
        // `Window`'s `.task` above, which never ran while the app launched with that window closed
        // (the normal case back when this was an LSUIElement menu-bar-only app). That
        // left the global ⌃⌥M hotkey, `rebuildFromStorage()`, the FR-016 overdue scan, and the
        // dead until the user happened to open the window. Calling it here too
        // — right after `appState` is guaranteed assigned (`VolarApp.init()` sets it before this
        // delegate method can fire) — closes that gap. The double call (here + the `Window`'s
        // `.task`) is intentional and safe; see that call site's own comment for why each half of
        // `activateServices()` tolerates being invoked twice.
        appState?.activateServices()

        // Services menu ("New Task in Volar" on any text selection, system-wide) — backlog
        // "Đường vào Volar" [I2]. Registered here rather than in the `Window` scene for exactly the
        // liveness reason spelled out just above: the service must work while Volar is a menu-bar
        // app with no window open, which is the normal case. Retained in a stored property because
        // `NSApplication.servicesProvider` does not keep its provider alive.
        servicesProvider = VolarServicesProvider.install()

        // ⌃⌥N — attached after `activateServices()` above has started the hotkey manager. Weak on
        // self so the retained Carbon callback can't keep the delegate alive.
        // `up: nil` — ⌃⌥N giờ là phím bấm-bật/bấm-tắt, key-up không còn mang nghĩa gì (bỏ chế độ
        // giữ-để-xem, anh Khôi 2026-08-24). `HotkeyManager` vẫn gửi key-up như cũ; không ai nhận.
        appState?.hotkey.setGlanceHandlers(
            down: { [weak self] in self?.glance.hotkeyDown() },
            up: nil
        )
        observeGlanceMode()

        // specs/009-light-mode-list-v2/design.md §7: re-applies `NSApp.appearance` LIVE whenever
        // the user changes the picker in Settings → General, so the effect isn't "restart the app
        // to see it" — see this method's own doc comment for why `NSApp.appearance` has to be set
        // at all. `NSApp.appearance = nsAppearance(...)` right above only covers launch; without
        // this observer, every AppKit control (Picker/Menu/TextField popups) would keep whatever
        // appearance was current at launch until the next relaunch.
        observeAppearancePreference()

        // Best-effort; ignore the result/error — notifications are a nice-to-have, not required
        // for the app to function (see backlog: real notification scheduling not yet wired).
        // `@Sendable` is load-bearing: without it, a closure literal formed in this @MainActor
        // context is inferred MainActor-isolated, and Swift 6's runtime isolation check traps
        // (EXC_BREAKPOINT) when UserNotifications invokes it on its background queue — the same
        // failure mode as the SpeechCapture authorization callback.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }

        // T033 (contracts/phase4-contract.md §A/§E): replaces the old auth-only setup with real
        // category registration — deadline (Done/Snooze 10m/Tomorrow), unblocked-ready, and
        // overdue-reschedule (tonight/tomorrow/weekend) actions (tasks.md T030,
        // `Sources/Reminders/NotificationActions.swift`, sibling-owned — its own doc comment names
        // this exact call site: "call this once from VolarApp/AppDelegate ... alongside the existing
        // requestAuthorization call"). The matching `UNUserNotificationCenter.current().delegate =
        // ...` assignment is NOT here — it needs a live `ReminderScheduler`/`TaskStore`, neither of
        // which exists yet at this point in app launch (see the note below); that's wired instead
        // in `AppState.activateServices()`, called once `AppState`/`TaskStore` exist.
        NotificationActions.registerCategories()

        // F1/F2 integration fix: window-independent observers, moved here from the `Window`
        // scene's `.onReceive` modifiers so they fire even while the window is closed (see this
        // class's doc comment and VolarApp's final report).
        registerWindowIndependentObservers()

        // Feature 002 gap fix: starts the `captureState` -> floating-panel mirroring described on
        // `observeCaptureState()` below. Same "window-independent" motivation as the observers
        // just above — this is what makes ⌃⌥M capture visible even while `Window("Volar")` is
        // closed (still reachable via ⌘W even though the window now opens at launch).
        observeCaptureState()
        // ⌃⌥T typed-capture popup: same window-independent mirroring, off `appState.textCapture`
        // instead of `appState.captureState` — see `observeTextCaptureState()`'s own doc comment.
        observeTextCaptureState()

        // 2026-07-26: guarantee the main window is actually on screen at launch. Dropping
        // LSUIElement + declaring `Window` as the first scene in `VolarApp.body` SHOULD be enough
        // on its own — but that is a SwiftUI-internal ordering behavior we cannot verify from
        // Windows, and "app opens and nothing appears" is exactly the App Review rejection this
        // change exists to prevent. So this is a deliberate belt-and-braces second path: if SwiftUI
        // already opened and fronted the window, `showMainWindow()` is a no-op re-front; if it
        // didn't, this is what puts it on screen.
        //
        // 2026-07-27 (Task 1c, login-item feature): this call must be SKIPPED when the launch was
        // not a normal, user-initiated one — most importantly, launching because Volar is now a
        // real login item (`LoginItem.swift`/`SMAppService`). Nobody wants their desktop to open a
        // window on top of everything else the instant they log in; a login launch should be as
        // quiet as any other menu-bar-only launch used to be, with the menu bar (and Dock icon,
        // clickable to reopen via `applicationShouldHandleReopen` below) as the way back in.
        //
        // `NSApplication.launchIsDefaultUserInfoKey` is Apple's own signal for exactly this:
        // `notification.userInfo` carries `false` for launches that are NOT a normal user
        // double-click/Dock-click/Spotlight open — Apple's header doc lists opening a file, a
        // service invocation, being resumed, and (the case that matters here) being launched as a
        // login item, as all reporting `false`. Defaulting to `true` when the key is absent errs
        // toward the OLD behavior (window opens) rather than toward hiding it, since a missing key
        // is far more likely to mean "this OS version doesn't bother setting it for a default
        // launch" than "silently suppress the window nobody asked to suppress".
        //
        // // UNVERIFIED: not exercised on a real Mac — cannot confirm from Windows that
        // `launchIsDefaultUserInfoKey` actually reports `false` for a login-item launch on macOS
        // 14/15/26, or that AppKit populates `userInfo` at all by the time this delegate method
        // fires. The failure mode is BENIGN either way: if the key doesn't report login launches
        // as expected, `isDefaultLaunch` stays `true` and `showMainWindow()` runs exactly like it
        // does today — i.e. NOT a regression, just this guard being a no-op. Must be verified on a
        // real Mac (`docs/mac-verify-checklist.md`) before relying on it.
        //
        // RESIDUAL KNOWN GAP (also flagged in `docs/mac-verify-checklist.md`): `VolarApp.swift`'s
        // scene order was deliberately changed on 2026-07-26 so the SwiftUI `Window` scene comes
        // FIRST specifically so it opens automatically at launch. Suppressing this EXPLICIT
        // `showMainWindow()` call may not be sufficient on its own to stop THAT SwiftUI-internal
        // behavior from opening the window anyway on a login launch — SwiftUI's own "open the
        // first scene at launch" logic is not something this delegate method controls or can
        // observe. Whether an additional fix (e.g. closing the window immediately after it opens)
        // is needed is a Mac-verify question; deliberately NOT adding a blind close()-after-the-
        // fact hack here without first observing the real behavior.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard isDefaultLaunch else { return }

        // Deferred one run-loop turn: SwiftUI may not have materialized the scene's NSWindow yet
        // at `applicationDidFinishLaunching` time, so looking for it synchronously here can find
        // nothing at all.
        Task { @MainActor in
            self.showMainWindow()
        }
    }

    /// Brings Volar's main document-style window to the front, activating the app if needed.
    ///
    /// Window lookup is by exclusion rather than by identifier: SwiftUI does not expose a stable,
    /// documented `NSWindow.identifier` for a `Window(id:)` scene, so matching on `"main"` would be
    /// relying on an implementation detail that can change between OS releases. Instead we skip the
    /// two window kinds this app is known to also own — `NSPanel` (the floating `CapturePanel`, and
    /// the `MenuBarExtra` dropdown, both panels) and anything that cannot become the main window
    /// (the status-bar item's backing window) — and take the first real window that's left.
    ///
    /// No-ops safely if nothing matches, rather than force-unwrapping: a missing window here should
    /// degrade to "menu bar still works", never to a crash on launch.
    // UNVERIFIED: written on Windows without an AppKit toolchain. Confirm on Mac that a cold launch
    // shows the window exactly once (not two windows, no flicker) — see docs/app-store-submission-guide.md Cổng 1.
    private func showMainWindow() {
        let mainWindow = NSApp.windows.first { window in
            !(window is NSPanel) && window.canBecomeMain
        }
        guard let mainWindow else {
            // Closed with ⌘W: the SwiftUI Window scene is gone, ask it to open again.
            openMainWindow?()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    /// Now that Volar has a Dock icon (LSUIElement removed 2026-07-26), clicking that icon while no
    /// window is open must bring the window back — otherwise the click appears to do nothing and the
    /// app reads as broken. AppKit only asks this delegate; without implementing it, a SwiftUI
    /// `Window` scene the user closed with ⌘W stays closed forever and the menu bar is the only way
    /// back in.
    ///
    /// Returning `true` lets AppKit perform its own default reopen handling (unminiaturize/restore)
    /// as well; `showMainWindow()` covers the case where the window exists but is merely hidden
    /// behind other apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showMainWindow()
        }
        return true
    }

    /// Drives `CapturePanelController` purely off `appState.captureState`, without touching
    /// `AppState.swift` itself (off-limits for this task — another agent owns it right now).
    /// `withObservationTracking`'s `onChange` closure fires exactly ONCE per call and — critically
    /// — fires BEFORE the new value is actually committed to the observed property, so reading
    /// `appState.captureState` synchronously inside `onChange` would still observe the OLD value.
    /// Hopping into `Task { @MainActor in ... }` defers the read to the next run-loop turn, by
    /// which point the mutation has landed; re-invoking `observeCaptureState()` from inside that
    /// same hop is what re-arms tracking for the NEXT change (skip it and this would fire exactly
    /// once, ever, and the panel would silently stop following `captureState` after the very first
    /// capture).
    private func observeCaptureState() {
        withObservationTracking {
            _ = appState?.captureState
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncCapturePanel()
                self?.observeCaptureState()
            }
        }
    }

    /// ⌃⌥T typed-capture popup — same `withObservationTracking` re-arming pattern as
    /// `observeCaptureState()` above (see that method's own doc comment for why re-subscribing
    /// must happen from INSIDE the deferred `Task { @MainActor in ... }` hop rather than before
    /// it — skip that and this fires exactly once, ever), just tracking `appState.textCapture`
    /// instead of `appState.captureState`.
    ///
    /// Also re-runs `syncCapturePanel()` (not just `syncTextCapturePanel()`) on every change —
    /// `syncCapturePanel()`'s mutual-exclusion guard below reads `appState.textCapture`, so the
    /// voice panel's suppression needs re-evaluating whenever THAT value changes too, not only
    /// when `captureState` itself does. Concretely: `openTextCapture()` can set
    /// `textCapture = .editing` while `captureState` was already `.idle` (and therefore never
    /// fires `observeCaptureState()`'s own tracking) — without this second call, the voice
    /// panel's suppression would only ever get (re-)confirmed by whatever `captureState` happens
    /// to do next, which is not guaranteed to happen promptly (or at all) for that transition.
    /// Re-arms on every change, same one-shot-`withObservationTracking` pattern as
    /// `observeTextCaptureState()` below — `withObservationTracking` fires `onChange` exactly once,
    /// so the re-registration inside the callback is what makes it continuous.
    private func observeGlanceMode() {
        withObservationTracking {
            _ = glance.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncGlancePanel()
                self?.observeGlanceMode()
            }
        }
    }

    /// specs/009-light-mode-list-v2/design.md §7: maps the user's System/Light/Dark preference to
    /// the `NSAppearance` `NSApp.appearance` needs. `.system` -> `nil` (follow the Mac's own
    /// setting — passing `nil` here is exactly what "don't touch it" looks like for this API);
    /// `.light`/`.dark` pin every AppKit control to one specific appearance regardless of System
    /// Settings, same reasoning as `applicationDidFinishLaunching`'s doc comment above.
    private func nsAppearance(for pref: AppearancePreference) -> NSAppearance? {
        switch pref {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// specs/009-light-mode-list-v2/design.md §7: keeps `NSApp.appearance` in sync with
    /// `AppState.appearance` for the rest of the app's lifetime — same one-shot-`withObservationTracking`-
    /// re-armed-from-inside-`onChange` pattern as `observeCaptureState()`/`observeGlanceMode()`
    /// above (see `observeCaptureState()`'s doc comment for why the re-registration has to happen
    /// INSIDE the deferred `Task { @MainActor in ... }` hop rather than before it).
    /// `appState?.setAppearance(_:)` (`Shared/App/AppState.swift`) is the only writer of
    /// `AppState.appearance`, and it's called from `SettingsView`'s picker — this is what turns
    /// that Settings change into an immediate visual effect instead of a "restart to apply" pref.
    private func observeAppearancePreference() {
        withObservationTracking {
            _ = appState?.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NSApp.appearance = self.nsAppearance(for: self.appState?.appearance ?? .system)
                self.observeAppearancePreference()
            }
        }
    }

    /// Shows/hides Glance's panel to match `glance.mode`. Thẻ hiện lên là lấy key focus luôn —
    /// nó chỉ mở khi được bấm, và Esc/⌘D/Return trên thẻ cần key window mới chạy.
    private func syncGlancePanel() {
        guard let appState else { return }
        if glancePanelController == nil {
            glancePanelController = CapturePanelController(
                content: AnyView(GlanceHUD(controller: glance).environment(appState)),
                activates: false
            )
        }
        guard let controller = glancePanelController else { return }

        switch glance.mode {
        case .hidden:
            controller.hide()
            controller.setActivates(false)
        case .shown:
            controller.presentOrRefit()
            // Order matters: present first, THEN promote. `setActivates(true)` only takes key on an
            // already-visible panel, so promoting first would leave the card without Esc.
            controller.setActivates(true)
        }
    }

    private func observeTextCaptureState() {
        withObservationTracking {
            _ = appState?.textCapture
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncTextCapturePanel()
                self?.syncCapturePanel()
                self?.observeTextCaptureState()
            }
        }
    }

    /// Lazily creates `capturePanelController` (see that property's doc comment for why lazy),
    /// then shows/refits or hides it to match the CURRENT `appState.captureState` — `.idle` hides,
    /// anything else shows (first time) or re-fits (already visible; see
    /// `CapturePanelController.presentOrRefit()`'s own doc comment for that distinction).
    private func syncCapturePanel() {
        guard let appState else { return }
        if capturePanelController == nil {
            capturePanelController = CapturePanelController(
                content: AnyView(PopoverView().environment(appState))
            )
        }
        guard let controller = capturePanelController else { return }

        // MUTUAL EXCLUSION (self-review point 4, task brief): `AppState.confirmSave()` — the
        // SAME method `AppState.submitTextCapture()` calls to reuse the voice save path — mutates
        // `captureState` itself (`.saving`, then `.done` via `finishSaveUI`). Without this guard,
        // a typed-capture save would make THIS method see a non-`.idle` `captureState` mid-save
        // and show the voice popover for a save the user never triggered by voice.
        // `appState.textCapture != .closed` is true for the ENTIRE duration the typed popup is
        // open/saving/reporting an outcome (`AppState.openTextCapture()` through
        // `cancelTextCapture()`/the post-save auto-dismiss), so it unconditionally wins over
        // whatever `captureState` happens to be doing underneath — the voice panel simply never
        // shows while the text popup owns the surface, regardless of how many times this method
        // gets re-invoked (from either observer) during that window.
        if appState.textCapture != .closed {
            controller.hide()
            return
        }

        if appState.captureState == .idle {
            controller.hide()
        } else {
            controller.presentOrRefit()
        }
    }

    /// Lazily creates `textCapturePanelController` (see that property's doc comment), then
    /// shows/refits or hides it to match the CURRENT `appState.textCapture` — mirrors
    /// `syncCapturePanel()`'s own show/hide/refit split exactly, just against
    /// `AppState.TextCaptureState.closed` instead of `AppState.CaptureState.idle`. Deliberately
    /// has NO analogous "hide because the other surface owns it" guard the way `syncCapturePanel()`
    /// does — `AppState.openTextCapture()` already tears the voice surface down (via
    /// `cancelCapture()`) BEFORE ever setting `textCapture` to anything non-`.closed`, so by the
    /// time this method could show the text panel, there is nothing left on the voice side to
    /// race against (the reverse direction, voice winning back the surface, is `cancelTextCapture()`
    /// via `AppState.handleHotkey()`, which flips `textCapture` back to `.closed` and this method
    /// hides the panel exactly like any other close).
    private func syncTextCapturePanel() {
        guard let appState else { return }
        if textCapturePanelController == nil {
            textCapturePanelController = CapturePanelController(
                content: AnyView(TextCaptureView().environment(appState))
            )
        }
        guard let controller = textCapturePanelController else { return }

        if appState.textCapture == .closed {
            controller.hide()
        } else {
            controller.presentOrRefit()
        }
    }

    /// Moved verbatim (behaviorally) from `Window("Volar")`'s `.onReceive` modifiers in
    /// `VolarApp.body` — only the delivery mechanism changed (app-lifetime `NotificationCenter`
    /// observer tokens instead of a SwiftUI view's `.onReceive`), not what each handler does.
    private func registerWindowIndependentObservers() {
        // Constitution IV: sleep/wake recovery re-evaluates overdue `.scheduled` reminders and
        // fires immediately if still due. `ReminderScheduler` registers no wake observer of its own
        // (`NSWorkspace.didWakeNotification` posts on `NSWorkspace.shared.notificationCenter`, not
        // `.default`), so this is the one wake path. Registered once, here, for the app's lifetime.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.appState?.scheduler?.rebuildFromStorage()
            }
        }
    }

    /// Phase 6 (US4, phase6-contract.md §C): inbound `volar://` app links (`ai-done`/`capture`).
    /// Moved here from the `Window` scene's `.onOpenURL` — `.onOpenURL` only delivers while a
    /// scene is actually open, which defeats it for an `LSUIElement` menu-bar app whose window is
    /// normally closed; this AppKit-level delegate method is the app-lifetime equivalent and
    /// receives the same `GURL` Apple events regardless of window state. Routes through
    /// `AppLinkHandler.handle(_:)` (Orchestrator/AppLinkHandler.swift, sibling-owned/landed), which
    /// is inbound-only/idempotent/non-destructive per contracts/app-links.md — never completes a
    /// task itself; an ambiguous match becomes a disambiguation candidate list, same as before.
    /// `appState.onAppLinkHandled()` mirrors the handler's resulting state (pending
    /// disambiguation, ambient recheck queue, test-signal receipt) into `AppState`'s own
    /// `@Observable` surface, exactly as the old `.onOpenURL` did right after `handle(_:)`.
    /// `?.` degrades gracefully in the no-store fallback (`appLinkHandler` is `nil` there, same as
    /// `scheduler`). // UNVERIFIED
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            appState?.appLinkHandler?.handle(url)
            appState?.onAppLinkHandled()
        }
    }
}
