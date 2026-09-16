// Sources/Views/SettingsView.swift — Settings window: 5 tabs (General/Hotkeys/Notifications/
// Appearance/About), ported from `design/volar-extras.jsx`'s `VolarSettings`. Native-first: a
// custom top tab strip (icon + label, accent-tinted when selected) switches a `@State tab` with
// the tab content below. Most rows here are local, cosmetic `@State` (reminder defaults,
// notification toggles, etc.) — the frozen `AppState` (spec §4) does not own these preferences,
// only `accent` and `density`, which this view binds for real via `@Bindable`. "Launch at login"
// is the one exception below that list: it's wired for real to `SMAppService` via `LoginItem.swift`,
// not local `@State` at all.
import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import Speech
import UniformTypeIdentifiers
import UserNotifications

/// Recessed "well" fill behind key-combo chips and the code preview block (light-mode fix,
/// specs/009-light-mode-list-v2/design.md §7 follow-up — anh Khôi 2026-08-19). The original
/// `Color.black.opacity(0.25)` darkened the dark-mode `bg` (`#1C1C1E`) just slightly, reading as a
/// subtle recess. A flat black film at the SAME 0.25 alpha over the light-mode `bg` (`#FFFFFF`)
/// reads as a heavy gray box instead — not a recess, a slab — so this keeps black on both sides but
/// tunes the alpha per mode rather than reusing `VolarColor.veil(_:)` (which would also flip to a
/// WHITE film in dark mode, the wrong direction for a "well"). File-scope (not a `Theme.swift`
/// token) since only this file's three well-style chips use it.
private let volarWellFill = Color(volarLight: 0x000000, lightOpacity: 0.04, dark: 0x000000, darkOpacity: 0.25)

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable, Equatable {
        case general, hotkeys, notifications, permissions, appearance, account, about
        var id: String { rawValue }

        var icon: VolarIconName {
            switch self {
            case .general: return .settings
            case .hotkeys: return .cmd
            case .notifications: return .bell
            // Same "no dedicated glyph" situation as `.account` below — `VolarIconName` has no
            // lock/shield icon, and adding one is out of scope for this fix (would mean editing
            // `Design/VolarIcon.swift`, which this task deliberately leaves alone). `.check` reads
            // reasonably as "permission granted/verified", even though it now doubles up with
            // `.account`'s use of the same glyph below.
            case .permissions: return .check
            case .appearance: return .sparkle
            // No dedicated "person/account" glyph exists in `VolarIconName` (`Design/VolarIcon.swift`,
            // not in this task's owned files — adding a case would require editing it). `.check`
            // is the closest available stand-in (reads as "verified identity"); flagged in backlog.md
            // as a follow-up for whoever next owns that file.
            case .account: return .check
            case .about: return .project
            }
        }

        var label: String {
            switch self {
            case .general: return "General"
            case .hotkeys: return "Hotkeys"
            case .notifications: return "Notifications"
            case .permissions: return "Permissions"
            case .appearance: return "Appearance"
            case .account: return "Account"
            case .about: return "About"
            }
        }

        /// Account/About không phải danh sách row — chúng có card, form đăng nhập, nút — nên giữ
        /// lề hai bên. Năm tab còn lại để row chạy hết bề ngang cửa sổ.
        var isInset: Bool { self == .account || self == .about }
    }


    // Cosmetic-only local settings state (not part of the frozen AppState API).
    // `defaultDuration` used to live here too — 2026-07-29: promoted to a real `AppState` setting
    // (`appState.defaultTaskDurationMinutes`/`setDefaultTaskDurationMinutes`), see the "Default task
    // duration" row below, so it no longer needs a local `@State` mirror.
    @State private var hyperfocusInterrupt = 90
    @State private var showMorningFrog = true
    @State private var captureAppContext = true

    @State private var showReminders = true
    @State private var notifSound = true
    @State private var focusModeAware = false

    // "Launch at login" — unlike every `@State` above this line, this is NOT cosmetic/local: it
    // mirrors the REAL `SMAppService.mainApp.status` (`LoginItem.swift`), re-read fresh in
    // `.onAppear` below rather than cached across app launches, since the user can flip it from
    // System Settings behind Volar's back at any time (see `LoginItem.swift`'s header comment).
    @State private var loginItemStatus: SMAppService.Status = .notFound
    @State private var loginItemError: String?

    // Permissions tab (Việc 3, 2026-07-27) — live OS-level authorization statuses. Unlike most
    // `@State` above, these mirror real system state rather than app preferences: they exist so a
    // user who denied/allowed something can SEE the current truth and, if needed, be routed to
    // System Settings — see `refreshPermissionStatuses()`. `EventKit`'s own status lives on
    // `appState.calendarAccess` already (no local copy needed for that one).
    @State private var micAuthStatus: AVAuthorizationStatus = MicrophonePermission.status
    @State private var speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined

    // Account tab (Task 4, account-auth.md contract) — purely local UI state; the actual
    // session/tier/quota state lives on `AppState` (`accountEmail`, `accountTier`,
    // `subscriptionStatus`, `accountBusy`, `accountError`), same split as every other tab's
    // cosmetic `@State` vs. the frozen `AppState` API. The sign-in FORM's own field state
    // (email/code text, "code sent?" flag) used to live here too, but moved to `EmailSignInForm`
    // (Sign-in-entry-point fix, 2026-07-28) so it exists in exactly one place in the codebase —
    // `signedOutAccountBody` below just embeds that view now.
    @State private var showDeleteAccountConfirm = false
    /// Backlog "1 free month of Pro" promo codes (Task 3, redeem contract). Local `@State`, same
    /// convention `EmailSignInForm`'s own field state now follows — the FIELD text is view-local,
    /// the actual redeem call + success/failure state lives on `appState` (`redeemPromoCode(_:)`/
    /// `lastRedeemedUntil`/`accountError`).
    @State private var promoCodeInput = ""
    /// Drives the `PaywallView` sheet — the ONE purchase surface in the app (replaces the old bare
    /// `productRow` pair that used to live directly in `upgradeSection`).
    @State private var showPaywall = false
    /// Drives `SignInSheet` when `PaywallView`'s "Sign in to subscribe" CTA fires `onNeedSignIn`
    /// from within this tab (main-window Sign-in entry point fix, 2026-07-28).
    @State private var showSignInSheet = false
    /// Set by the paywall's sign-in CTA and read back in the paywall sheet's `onDismiss` — the two
    /// sheets are handed off across a full dismissal rather than swapped in one update. See the
    /// `.sheet(isPresented: $showPaywall, onDismiss:)` on `accountTab` for the whole reasoning.
    @State private var pendingSignInAfterPaywall = false

    // 008-sync (client-contract.md §0 group C) — same "purely local UI state, real state lives on
    // AppState" split as every other Account `@State` above. `showSyncEnableSheet` drives
    // `SyncEnableSheet` (the confirmation screen — never skipped when turning sync ON); turning it
    // OFF needs no confirmation (design.md §8.3) and calls `appState.setSyncEnabled(false)` directly.
    @State private var showSyncEnableSheet = false
    @State private var showSyncRejects = false
    @State private var showSyncPurgeConfirm = false

    @State private var tab: Tab = .general

    @Environment(AppState.self) private var appState
    // Settings is its own scene (a separate `Window`/`Settings` group from the main window per
    // VolarApp.swift) — the guided-tour overlay (agent A, Views/Tour/*) lives IN the main window,
    // so "Show tour" below must explicitly bring that window forward or the click appears to do
    // nothing while Settings just sits there.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appState = appState

        // Bảy tab GIỮ NGUYÊN (anh Khôi 2026-08-24): chia tab là để nhảy thẳng tới nhóm mình
        // cần, không phải cuộn đi tìm. Thứ đổi nằm bên TRONG mỗi tab — xem `SettingsRow`: các
        // option không còn là những cái card bo tròn tách rời nữa mà xếp liền thành một danh sách.
        VStack(spacing: 0) {
            tabStrip

            ScrollView {
                Group {
                    switch tab {
                    case .general: generalTab
                    case .hotkeys: hotkeysTab
                    case .notifications: notificationsTab
                    case .permissions: permissionsTab
                    case .appearance: appearanceTab(appState: appState)
                    case .account: accountTab
                    case .about: aboutTab
                    }
                }
                // Danh sách row chạy hết bề ngang cửa sổ (row tự có lề 22 bên trong), nên tab nào
                // là danh sách thì không đệm ngang. Account/About là card + form nên vẫn cần lề.
                .padding(.horizontal, tab.isInset ? 22 : 0)
                .padding(.vertical, tab.isInset ? 22 : 6)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(VolarColor.bg)
        .onAppear {
            // Real status, re-read every time Settings opens — never trust a stale value left
            // over from the last time this view appeared, since the user may have toggled Login
            // Items from System Settings while Settings was closed. See `LoginItem.swift`.
            loginItemStatus = LoginItem.status
        }
    }

    // MARK: - Tab strip

    private var accentColors: Accent { appState.accent.accent }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                let selected = t == tab
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 4) {
                        VolarIcon(t.icon, size: 18, color: selected ? accentColors.solid : VolarColor.textSec, weight: .regular)
                        Text(t.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selected ? accentColors.solid : VolarColor.textSec)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(minWidth: 72)
                    .background(selected ? accentColors.surface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(VolarColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }

    // MARK: - General

    /// All locales `SFSpeechRecognizer` supports on this Mac (includes vi-VN), sorted by their
    /// localized display name so the picker below reads naturally instead of by raw identifier.
    private var speechLocales: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Short status text for the WhisperKit model row: download/load progress or the reason it
    /// can't run, so picking the engine doesn't silently fall back to Apple with no explanation.
    private var whisperKitStatusText: String {
        guard WhisperKitEngine.isSupported else { return "Requires Apple Silicon" }
        switch appState.whisper.state {
        case .notReady: return "Not downloaded"
        case .preparing: return "Downloading model…"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }

    private var whisperKitStatusHint: String {
        WhisperKitEngine.isSupported
            ? "First use downloads a small on-device model (~145MB) and caches it. Falls back to Apple until it's ready."
            : "WhisperKit needs an Apple Silicon Mac. Volar will use Apple's on-device recognizer instead."
    }

    private var generalTab: some View {
        VStack(spacing: 0) {
            SettingsRow(label: "Speech engine", hint: "On-device (Apple, WhisperKit) stays private and free. Groq is cloud — it sends your audio for the best multilingual/Vietnamese accuracy.") {
                // `SpeechEngineChoice` (AppState.swift) doesn't declare Hashable, so — same
                // convention as the Density picker below — bind through its `String` rawValue
                // instead of the enum itself.
                Picker("", selection: Binding(
                    get: { appState.speechEngineChoice.rawValue },
                    set: { if let choice = SpeechEngineChoice(rawValue: $0) { appState.setSpeechEngine(choice) } }
                )) {
                    ForEach(SpeechEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            if appState.speechEngineChoice == .whisperKit {
                SettingsRow(label: "WhisperKit model", hint: whisperKitStatusHint) {
                    Text(whisperKitStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
            }
            if appState.speechEngineChoice == .groq, !GroqEngine.isConfigured {
                SettingsRow(label: "Groq status", hint: "Cloud transcription needs an account, free or Pro — sign in in the Account tab to enable it (Pro just raises your daily quota). Until then Volar uses Apple on-device recognition.") {
                    Text("Not configured — using Apple on-device")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
            }
            // Hàng "Task parsing" (On-device / Cloud AI) và hàng trạng thái của nó đã bỏ
            // 2026-08-24 (anh Khôi): "user đâu cần biết họ đang xài AI hay on-device parse đâu,
            // họ chỉ quan tâm xong việc thôi". Câu hỏi này không có phương án đúng cho người dùng
            // chọn — cloud hiểu câu khó hơn, on-device là thứ tự chạy khi không có mạng/chưa đăng
            // nhập, và app đã tự lùi về on-device ở mọi trường hợp cloud không dùng được.
            //
            // Cập nhật 2026-09-06 (anh Khôi chốt "auto dùng cloud parse kể cả hình thức nào"):
            // cửa sổ hỏi một lần trước lần parse ĐẦU TIÊN đã BỎ (`proceedToCapture` gọi thẳng
            // `runParse`), và khoá chưa trả lời giờ tính là ĐỒNG Ý (`DefaultCloudParseGate
            // .isOptedIn()`). `AppState.cloudParseConsent`/`setParseEngine` vẫn còn — trên macOS
            // chỗ duy nhất còn ghi được là toggle bước 3 của onboarding (bản iOS vẫn có toggle
            // trong Settings). Muốn trả lại chỗ chọn ở đây thì thêm lại đúng một `Picker`.
            SettingsRow(label: "Recognition language", hint: "The language Volar listens for when you capture a task by voice, including Vietnamese.") {
                Picker("", selection: Binding(
                    get: { appState.recognitionLocaleID },
                    set: { appState.setRecognitionLocale($0) }
                )) {
                    // "Automatic (multilingual)" first, ahead of the localized-name-sorted locale
                    // list below, for anyone who code-switches between languages (e.g. vi↔en) —
                    // see `AppState.autoRecognitionLocaleID`'s doc comment. Labeled in English (not
                    // localized) to match every other row in this list, which are Apple's
                    // localized locale names rather than translated UI strings.
                    Text("Automatic (multilingual)").tag(AppState.autoRecognitionLocaleID)
                    ForEach(speechLocales, id: \.id) { loc in
                        Text(loc.name).tag(loc.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            launchAtLoginRow
            // Wired for real to `AppState` (2026-07-29) — same "custom `Binding` around a
            // `private(set)` property + setter" convention as `globalReminderPolicy`/
            // `voiceDeliveryMode` below in `notificationsTab`, not cosmetic local `@State` like most
            // rows in this tab. Doubles as the `estimateMinutes` a no-estimate task gets, so the
            // hint spells out the "urgent, no deadline" scenario that setting actually drives
            // (`IntentRouter.applyStartTimeDerivation`), not just "duration".
            SettingsRow(
                label: "Default task duration",
                hint: "Used when you say something is urgent without giving a deadline — Volar blocks this much time and sets the same number as the task's estimate."
            ) {
                Segmented(
                    value: Binding(
                        get: { appState.defaultTaskDurationMinutes },
                        set: { appState.setDefaultTaskDurationMinutes($0) }
                    ),
                    options: [
                        .init(id: 15, label: "15", mono: true), .init(id: 30, label: "30", mono: true),
                        .init(id: 45, label: "45", mono: true), .init(id: 60, label: "60 min", mono: true),
                    ]
                )
            }
            SettingsRow(label: "Hyperfocus interrupt after", hint: "Volar checks in if you've been deep on one task this long.") {
                Segmented(value: $hyperfocusInterrupt, options: [
                    .init(id: 60, label: "60", mono: true), .init(id: 90, label: "90", mono: true), .init(id: 120, label: "120 min", mono: true),
                ])
            }
            SettingsRow(label: "Show morning frog prompt", hint: "A daily question at first launch: what's the ONE task that matters most?") {
                VolarToggle(isOn: $showMorningFrog)
            }
            SettingsRow(label: "Guided tour", hint: "Walk through capture, the task list, and focus mode again.") {
                Button("Show tour") {
                    appState.replayTour()
                    // Load-bearing: Settings is a separate `Window` scene from the main window
                    // (see the `openWindow` doc comment on this view's property), and the tour
                    // overlay is drawn inside the main window's view tree — without this call the
                    // tour would start invisibly behind Settings and the click would look like a
                    // no-op.
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .volarHairline(cornerRadius: 5)
            }
            SettingsRow(label: "Capture foreground app context", hint: "Tags new tasks with the app you were in when you captured them.") {
                VolarToggle(isOn: $captureAppContext)
            }
            calendarAccessRow
            if appState.calendarAccess.status == .granted {
                calendarMirrorRow
                calendarReadRow
            }
        }
    }

    /// Wired for real to `SMAppService.mainApp` (`LoginItem.swift`) — see that file's header
    /// comment for why `loginItemStatus` is re-read live rather than cached. The toggle's `isOn`
    /// binding calls `LoginItem.setEnabled(_:)` synchronously in its `set:` (no `Task` hop needed
    /// — `SMAppService`'s register/unregister calls are synchronous) and immediately re-reads
    /// `status` afterward, so the switch always reflects what macOS actually did, not what the
    /// user merely requested. `.requiresApproval` is a real, ordinary post-register state (macOS
    /// posts its own "Volar added a login item" notification and the login item doesn't actually
    /// fire until the user approves it in System Settings) — surfaced here as its own explanatory
    /// row + "Open Login Items…" button rather than treated as a toggle failure.
    @ViewBuilder
    private var launchAtLoginRow: some View {
        SettingsRow(
            label: "Launch at login",
            hint: "Volar opens automatically when you log in to your Mac."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                VolarToggle(isOn: Binding(
                    get: { loginItemStatus == .enabled },
                    set: { newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginItemError = nil
                        } catch {
                            loginItemError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                        // Re-read live status regardless of success/failure — a throw can still
                        // leave `SMAppService` in a different state than before the call (e.g.
                        // partial unregister), so this is the one honest source of truth either way.
                        loginItemStatus = LoginItem.status
                    }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.reschedule)
                        .lineLimit(2)
                }
            }
        }
        if loginItemStatus == .requiresApproval {
            HStack(spacing: 10) {
                Text("macOS needs your approval to finish enabling this.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
                settingsPillButton("Open Login Items…") {
                    LoginItem.openLoginItemsSettings()
                }
            }
            .padding(.horizontal, 18)
        }
    }

    /// Real EventKit permission status — replaces a former dead prototype toggle ("Calendar
    /// integration" / "Mirror tasks... into your Mac Calendar") that had no backing implementation
    /// at all (a local `@State` bool wired to nothing, and an "Open in Calendar" button with an
    /// empty action). `appState.calendarAccess` (agent A's addition to `AppState`, per this
    /// feature's cross-agent contract) is the single source of truth for status — this row never
    /// keeps its own copy of it. This row is just PERMISSION status; whether Volar actually WRITES
    /// anything is a separate, opt-in decision surfaced in `calendarMirrorRow` below (shown only
    /// once access is granted — asking about mirroring before Volar can even read the calendar
    /// would be premature).
    @ViewBuilder
    private var calendarAccessRow: some View {
        SettingsRow(
            label: "Calendar access",
            // §2.5 (2026-08-19): this permission grant alone does NOT turn on reading — that's the
            // separate "Read my calendar" toggle below, off by default. This row only unlocks the
            // two features that ask for it explicitly: mirroring (below) and that read toggle.
            hint: "Lets Volar mirror tasks into a calendar it creates called \"Volar\" (once you turn that on below), and — only if you also turn on \"Read my calendar\" — warn you about clashes with your other events. It never touches your other calendars, and nothing leaves your Mac."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                calendarAccessControl
                if let lastError = appState.calendarAccess.lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textMut)
                        .lineLimit(2)
                }
            }
        }
    }

    /// One-way (Volar → Calendar) mirroring opt-in. `appState.calendarSync` owns `mirrorEnabled` —
    /// bound here via an explicit `Binding(get:set:)` rather than a raw `$appState.calendarSync...`
    /// path, matching this file's existing convention for every other enum/nested-object-backed
    /// control (`speechEngineChoice`/`parseEnginePreference`/etc. above) instead of introducing a
    /// new binding idiom for just this one row. `mirrorEnabled` is `private(set)` on `CalendarSync`
    /// (turning it off deletes real calendar events — a destructive action deliberately kept behind
    /// a named method, not a raw property set), so the setter here calls
    /// `AppState.setCalendarMirror(_:)` — which calls `CalendarSync.setMirrorEnabled(_:)` and then
    /// immediately reconciles — rather than assigning `appState.calendarSync.mirrorEnabled`
    /// directly (which no longer compiles).
    @ViewBuilder
    private var calendarMirrorRow: some View {
        SettingsRow(
            label: "Mirror tasks to Calendar",
            hint: "Tasks with a scheduled time appear as events in a separate calendar named \"Volar\" — Volar never touches your other calendars. Turning this off removes the events it created."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                VolarToggle(isOn: Binding(
                    get: { appState.calendarSync.mirrorEnabled },
                    set: { appState.setCalendarMirror($0) }
                ))
                if let lastError = appState.calendarSync.lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textMut)
                        .lineLimit(2)
                }
            }
        }
    }

    /// specs/010-calendar-and-hard-deadlines/design.md §2.5 — a SEPARATE opt-in from
    /// `calendarMirrorRow` right above, deliberately shown alongside it (not merged into one
    /// toggle): granting EventKit access lets Volar WRITE its own tasks into a calendar it creates,
    /// but does not by itself mean "read my other events back" — two different sensitivity levels,
    /// so this gets its own switch, default OFF (`AppState.calendarReadEnabled`'s own doc comment).
    /// Bound the same `Binding(get:set:)` shape as `calendarMirrorRow`'s toggle above, routing
    /// through `AppState.setCalendarReadEnabled(_:)` rather than a raw property set.
    @ViewBuilder
    private var calendarReadRow: some View {
        SettingsRow(
            label: "Read my calendar",
            hint: "Lets Volar warn you when a new task's time clashes with something already on your calendar. Nothing it reads ever leaves your Mac."
        ) {
            VolarToggle(isOn: Binding(
                get: { appState.calendarReadEnabled },
                set: { appState.setCalendarReadEnabled($0) }
            ))
        }
    }

    @ViewBuilder
    private var calendarAccessControl: some View {
        switch appState.calendarAccess.status {
        case .notDetermined:
            Button("Enable Calendar") {
                // FIX 6: routes through `AppState.enableCalendarAccess()` (awaits the real
                // EventKit prompt, then immediately reconciles the calendar mirror) instead of
                // calling `calendarAccess.requestAccess()` directly, so a fresh grant here takes
                // effect right away rather than waiting for the next task edit.
                Task { await appState.enableCalendarAccess() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.textPri)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(VolarColor.veil(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .volarHairline(cornerRadius: 5)

        case .granted:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(VolarColor.done).frame(width: 7, height: 7)
                    Text("Connected · \(appState.calendarAccess.calendarCount) calendars")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
                Button("Refresh") {
                    appState.calendarAccess.refreshStatus()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .volarHairline(cornerRadius: 5)
            }

        case .denied, .restricted:
            // Hard "no red for status" rule (this project's convention) — calm neutral text, not
            // an alarm color, even though access is off.
            HStack(spacing: 10) {
                Text("Access is off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Button("Open System Settings") {
                    appState.calendarAccess.openSystemSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .volarHairline(cornerRadius: 5)
            }

        case .unavailable:
            Text("Unavailable on this Mac")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
        }
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        VStack(spacing: 0) {
            SettingsRow(label: "Quick capture", hint: "Press this combo from anywhere to toggle recording — press to start, press again to stop.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "M"])
            }
            // Add a task by typing (⌃⌥T, `Sources/Speech/HotkeyManager.swift` /
            // `Sources/Views/TextCapturePanel.swift`) — the typed equivalent of Quick capture
            // above, for when speaking isn't an option (a meeting, a café, an open-plan office).
            // Same `SettingsRow`/`KeyRecorder` structure as every other row in this tab.
            SettingsRow(label: "Add a task by typing", hint: "Press this combo from anywhere to open a small text box — type, hit Return, done. No speaking required.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "T"])
            }
            SettingsRow(label: "Task breakdown (long press)", hint: "Hold the same hotkey \u{2265}1.5s to have AI split the task into steps.") {
                HStack(spacing: 8) {
                    Text("Long-press")
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textSec)
                    KeyBadge("\u{2303}")
                    KeyBadge("\u{2325}")
                    KeyBadge("M")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(volarWellFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .volarHairline(cornerRadius: 8)
            }
            SettingsRow(label: "Show Volar window", hint: "Bring the main window to the front.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "V"])
            }
            SettingsRow(label: "Toggle Focus Lock", hint: "Lock the current task as your only focus — Volar will gently interrupt if you drift.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "F"])
            }
            SettingsRow(label: "Complete current task", hint: "When Focus Lock is active, mark the current task done without opening the window.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "\u{21A9}"])
            }
        }
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        VStack(spacing: 0) {
            SettingsRow(label: "Show reminders", hint: "Send a macOS notification before each task.") {
                VolarToggle(isOn: $showReminders)
            }
            SettingsRow(label: "Sound", hint: "Subtle chime when a task is captured.") {
                VolarToggle(isOn: $notifSound)
            }
            SettingsRow(label: "Focus mode aware", hint: "Stay silent while macOS Focus is on.") {
                VolarToggle(isOn: $focusModeAware)
            }
            // Phase 4 (T033): the two rows below are wired for real to `AppState` (unlike the
            // toggles above, still cosmetic-only local `@State` — out of this task's scope).
            SettingsRow(
                label: "Default reminders before deadline",
                hint: "Applies to any task without its own custom reminder — the global default the reminder scheduler falls back to."
            ) {
                Segmented(
                    value: Binding(
                        get: { ReminderPolicyPreset(matching: appState.globalReminderPolicy) },
                        set: { appState.setGlobalReminderPolicy($0.policy) }
                    ),
                    options: ReminderPolicyPreset.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            SettingsRow(
                label: "Voice delivery",
                hint: "Visual notifications always show. Voice is an extra, on-device-spoken nudge for urgent or unacknowledged reminders."
            ) {
                Segmented(
                    value: Binding(
                        get: { appState.voiceDeliveryMode },
                        set: { appState.setVoiceDeliveryMode($0) }
                    ),
                    options: VoiceDeliveryMode.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            // Full-screen deadline escalation (this task): reads/writes
            // `FullScreenEscalationSetting` directly rather than through `appState` — this
            // preference isn't `AppState`-owned (see that enum's own doc comment in
            // `Sources/Reminders/FullScreenEscalationDecision.swift`), so it follows the same
            // "bind a `VolarToggle` straight to the real external source" convention this file
            // already uses for "Launch at login" (`LoginItem.swift`) rather than the
            // `appState.set...`-method convention used for the two rows just above.
            SettingsRow(
                label: "Full-screen alert khi tới hạn",
                hint: "Only for a reminder AT or PAST its deadline that you haven't acknowledged after a few minutes — never for a plain nudge on a task with no deadline. Skipped while you're on a call or Volar itself is recording, and always has a one-tap snooze."
            ) {
                VolarToggle(isOn: Binding(
                    get: { FullScreenEscalationSetting.isEnabled },
                    set: { FullScreenEscalationSetting.isEnabled = $0 }
                ))
            }
        }
    }

    /// Named presets over the full `ReminderPolicy` shape (`Recurrence.swift`) so the Settings row
    /// above can stay a simple `Segmented` control rather than a free-form offsets editor — mirrors
    /// this file's existing convention for other multi-value settings (`Density`, `AmbientMode`).
    private enum ReminderPolicyPreset: String, CaseIterable, Identifiable, Hashable {
        case dayHourAt, hourAt, atOnly, none

        var id: String { rawValue }

        var label: String {
            switch self {
            // Label kept in sync with `.defaultPolicy` (`Recurrence.swift`) after anh Khôi's
            // 2026-07-28 change from fixed -1 day/-1 hour marks to proportional reminders — this
            // preset IS `.defaultPolicy`, so the string here must describe whatever that constant
            // actually does, not the old fixed offsets.
            case .dayHourAt: return "Halfway, 1/3 remaining, at deadline"
            case .hourAt: return "1 hour, at deadline"
            case .atOnly: return "At deadline"
            case .none: return "None"
            }
        }

        var policy: ReminderPolicy {
            switch self {
            case .dayHourAt: return .defaultPolicy
            case .hourAt: return ReminderPolicy(offsets: [-3600, 0], repeatEvery: nil)
            case .atOnly: return ReminderPolicy(offsets: [0], repeatEvery: nil)
            case .none: return ReminderPolicy(offsets: [], repeatEvery: nil)
            }
        }

        /// Falls back to `.dayHourAt` for a policy that doesn't match any named preset (e.g. one
        /// set by a future finer-grained editor) rather than crashing on an unrecognized shape.
        init(matching policy: ReminderPolicy) {
            self = Self.allCases.first { $0.policy == policy } ?? .dayHourAt
        }
    }

    // MARK: - Permissions (Việc 3, 2026-07-27 fix batch)
    //
    // Born from anh Khôi's very first real-Mac run: there was nowhere in the app to SEE whether
    // Volar actually had microphone/speech/notifications/calendar access, or to get routed to
    // System Settings when it didn't. This tab is read-mostly — it never invents its own notion of
    // "granted", it only ever reads the OS's/EventKit's own authorization state and mirrors it.

    /// Coarse three-way status shared by all four rows below. Each real source has its own richer
    /// enum (`AVAuthorizationStatus`, `SFSpeechRecognizerAuthorizationStatus`, `UNAuthorizationStatus`,
    /// `CalendarAccess.Status`) — this collapses every one of them down to the one distinction the
    /// UI actually needs to react to: what to say, and which button (if any) to offer.
    private enum PermissionState: Equatable {
        case allowed, notAllowed, notAsked

        var text: String {
            switch self {
            case .allowed: return "Allowed"
            case .notAllowed: return "Not allowed"
            case .notAsked: return "Not asked yet"
            }
        }

        /// Hard "no red for status" rule (this project's convention, see `calendarAccessControl`
        /// above) does NOT apply here — unlike overdue-task badges, a permission that's actually
        /// off is a real, actionable state the user should notice, not an ambient nag.
        var color: Color {
            switch self {
            case .allowed: return VolarColor.done
            case .notAllowed: return VolarColor.destruct
            case .notAsked: return VolarColor.textSec
            }
        }
    }

    private var micPermissionState: PermissionState {
        switch micAuthStatus {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .notAllowed
        @unknown default: return .notAllowed
        }
    }

    private var speechPermissionState: PermissionState {
        switch speechAuthStatus {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .notAllowed
        @unknown default: return .notAllowed
        }
    }

    private var notifPermissionState: PermissionState {
        switch notifAuthStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notAsked
        case .denied: return .notAllowed
        @unknown default: return .notAllowed
        }
    }

    private var calendarPermissionState: PermissionState {
        switch appState.calendarAccess.status {
        case .granted: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted, .unavailable: return .notAllowed
        }
    }

    /// Re-reads all four live statuses from their real sources. Called from `permissionsTab`'s
    /// `.task` (fires every time this tab is switched to
    /// `.task` convention above for the same "may have changed while the user was elsewhere"
    /// reason) and again after any "Request" button actually asks the OS for something, so a grant
    /// or denial is reflected immediately rather than waiting for the next tab switch.
    private func refreshPermissionStatuses() {
        micAuthStatus = MicrophonePermission.status
        speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        appState.calendarAccess.refreshStatus()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notifAuthStatus = settings.authorizationStatus
        }
    }

    /// Opens System Settings' Privacy & Security pane at the given anchor (e.g.
    /// "Privacy_Microphone"). `URL(string:)` is optional — guarded rather than force-unwrapped, so
    /// a malformed/renamed anchor just no-ops instead of crashing (mirrors
    /// `CalendarAccess.openSystemSettings()`'s existing precedent one file over).
    private func openSystemSettingsPrivacy(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Same guard-not-force-unwrap reasoning as `openSystemSettingsPrivacy` above — Notifications
    /// lives under its own pane extension, not the Privacy & Security anchor scheme.
    private func openNotificationsSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var permissionsTab: some View {
        VStack(spacing: 0) {
            SettingsRow(label: "Microphone", hint: "Needed while you hold the capture hotkey, so Volar can hear what you're saying.") {
                HStack(spacing: 10) {
                    Text(micPermissionState.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(micPermissionState.color)
                    switch micPermissionState {
                    case .notAsked:
                        settingsPillButton("Request") {
                            Task {
                                _ = await MicrophonePermission.request()
                                refreshPermissionStatuses()
                            }
                        }
                    case .notAllowed:
                        settingsPillButton("Open System Settings") {
                            openSystemSettingsPrivacy(anchor: "Privacy_Microphone")
                        }
                    case .allowed:
                        EmptyView()
                    }
                }
            }
            // The one fact that actually resolves anh Khôi's confusion: macOS's mic/speech TCC
            // prompts are one-shot. If either was answered "Don't Allow" (by anh Khôi or on his
            // behalf) at any point in the past, Volar cannot make the system ask again — the ONLY
            // way back in is the user flipping it by hand in System Settings, which is exactly what
            // the "Open System Settings" buttons above/below route to.
            Text("macOS only asks for microphone and speech-recognition access once each. If either was ever denied, Volar can't prompt again — turn it back on in System Settings instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
                .lineSpacing(2)
                .padding(.horizontal, 18)

            SettingsRow(label: "Speech Recognition", hint: "Apple's on-device recognizer turns your captured audio into a task title.") {
                HStack(spacing: 10) {
                    Text(speechPermissionState.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(speechPermissionState.color)
                    switch speechPermissionState {
                    case .notAsked:
                        settingsPillButton("Request") {
                            Task {
                                // Same `@Sendable`-completion-handler hazard `SpeechCapture
                                // .requestAuthorization()` documents in detail: this method lives
                                // on a `@MainActor` view, so a non-`@Sendable` closure literal here
                                // would be inferred MainActor-isolated — and the Speech framework
                                // invokes its completion handler on a background queue, which traps
                                // at the isolation check before the closure body even runs. `@Sendable`
                                // opts this one out of that inference.
                                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                    SFSpeechRecognizer.requestAuthorization { @Sendable _ in
                                        continuation.resume()
                                    }
                                }
                                refreshPermissionStatuses()
                            }
                        }
                    case .notAllowed:
                        settingsPillButton("Open System Settings") {
                            openSystemSettingsPrivacy(anchor: "Privacy_SpeechRecognition")
                        }
                    case .allowed:
                        EmptyView()
                    }
                }
            }

            SettingsRow(label: "Notifications", hint: "Task reminders arrive as macOS notifications.") {
                HStack(spacing: 10) {
                    Text(notifPermissionState.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(notifPermissionState.color)
                    if notifPermissionState == .notAllowed {
                        settingsPillButton("Open System Settings") {
                            openNotificationsSystemSettings()
                        }
                    }
                }
            }

            SettingsRow(label: "Calendar", hint: "Just the permission grant. Whether Volar actually mirrors tasks or reads your other events is decided by two separate toggles in the General tab, both off by default.") {
                HStack(spacing: 10) {
                    Text(calendarPermissionState.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(calendarPermissionState.color)
                    switch calendarPermissionState {
                    case .notAsked:
                        settingsPillButton("Request") {
                            Task { await appState.enableCalendarAccess() }
                        }
                    case .notAllowed:
                        settingsPillButton("Open System Settings") {
                            appState.calendarAccess.openSystemSettings()
                        }
                    case .allowed:
                        EmptyView()
                    }
                }
            }
        }
        // Refreshes every time this tab is shown
        // (re-checks on every appearance for the identical
        // reason: state that can change OUTSIDE the app, behind Settings' back, while the window
        // isn't looking). Without this, a user who grants access in System Settings and clicks
        // back into Volar would still see a stale "Not allowed" — which is precisely the confusion
        // this whole tab exists to resolve.
        .task {
            refreshPermissionStatuses()
        }
    }

    // MARK: - Appearance

    private func appearanceTab(appState: AppState) -> some View {
        VStack(spacing: 0) {
            // specs/009-light-mode-list-v2/design.md §7, moved here from General per anh Khôi
            // (2026-08-19): the old "Theme" row above was a dead `@State` control ("Volar is
            // dark-only" — no longer true now that a real light palette exists) that never
            // touched `AppState`. This is the real one: routes through `AppState.setAppearance`
            // (persists to UserDefaults + applies to `NSApp.appearance` live — see
            // `VolarApp.swift`'s `observeAppearancePreference()`), same
            // `Picker`/`Binding(get:set:)`/rawValue convention as "Speech engine"/"Task parsing"
            // in the General tab.
            SettingsRow(label: "Appearance", hint: "System follows your Mac's Light/Dark setting. Light and Dark pin Volar regardless of it.") {
                // 2026-08-20, anh Khôi báo: "chữ dark và light đang trùng với màu nền — lúc đen
                // thì chữ Dark nên trắng, lúc chọn light thì chữ Light nên đen". Đây từng là một
                // `Picker(.menu)` của AppKit, và màu chữ của nó KHÔNG do file này quyết: pop-up
                // button + menu popup tự vẽ theo `NSApp.appearance`, tức là theo đúng cái pref mà
                // hàng này đang sửa. Mọi khoảnh khắc hai thứ đó lệch nhau (đang đổi, hoặc pref là
                // `.system` mà máy vừa tự chuyển) là một khoảnh khắc chữ trùng nền, và không có
                // cách nào ép màu chữ của một AppKit popup từ SwiftUI.
                //
                // `Segmented` (ngay dưới đây, hàng Background đã dùng) vẽ chữ bằng chính token của
                // Volar (`accentColors.solid` khi chọn, `textSec` khi không) trên nền token của
                // Volar — nên nó đọc được ở cả hai chế độ theo đúng định nghĩa, không phụ thuộc
                // AppKit. Ba lựa chọn cũng vừa đủ để nằm ngang, không cần menu thả xuống.
                Segmented(
                    value: Binding(
                        get: { appState.appearance },
                        set: { appState.setAppearance($0) }
                    ),
                    options: AppearancePreference.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            SettingsRow(label: "Background", hint: "A live scene or your own image behind the glass. Task list and panels stay readable on top.") {
                Segmented(
                    value: Binding(
                        get: { appState.ambient },
                        set: { appState.setAmbient($0) }
                    ),
                    options: AmbientMode.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            if appState.ambient == .custom {
                SettingsRow(label: "Custom image", hint: "Choose a photo or wallpaper from your Mac.") {
                    HStack(spacing: 10) {
                        CustomImageThumbnail(url: appState.customImageURL)
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button("Choose image…") { chooseImage(appState: appState) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(VolarColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .volarHairline(cornerRadius: 5)

                        if appState.customImageURL != nil {
                            Button("Remove") {
                                SecureImageBookmark.clear()
                                appState.setCustomImage(nil)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.textSec)
                        }
                    }
                }
            }
            SettingsRow(label: "Accent color", hint: "Used for active states and the capture button.") {
                HStack(spacing: 10) {
                    ForEach(VolarAccent.allCases) { candidate in
                        // `VolarAccent` (Theme.swift, frozen §3) doesn't declare Equatable, so
                        // compare via `rawValue` instead of `==`.
                        let selected = candidate.rawValue == appState.accent.rawValue
                        Circle()
                            .fill(candidate.accent.solid)
                            .frame(width: 22, height: 22)
                            .overlay(
                                // Was `Color.white` — invisible on a white light-mode bg, so the
                                // selected swatch's ring vanished (2026-08-19 light-mode fix).
                                // `VolarColor.textPri` self-inverts (near-black light / near-white
                                // dark), so the ring stays readable against either.
                                Circle().stroke(selected ? VolarColor.textPri : VolarColor.veil(0.2), lineWidth: 0.5)
                            )
                            .overlay(
                                Circle().stroke(candidate.accent.solid, lineWidth: selected ? 1.5 : 0)
                                    .padding(-2.5)
                            )
                            .onTapGesture {
                                // FIX 4: routes through `AppState.setAccent` (persists to
                                // UserDefaults) instead of a bare property assignment — a plain
                                // `appState.accent = candidate` never survived relaunch.
                                appState.setAccent(candidate)
                            }
                    }
                }
            }
            SettingsRow(label: "Density", hint: "How tight the rows pack.") {
                // `Density` (Theme.swift, frozen §3) doesn't declare Hashable/Equatable, so the
                // generic `Segmented<T: Hashable>` binds through a `String` id here instead of
                // the enum itself.
                Segmented(
                    value: Binding(
                        get: { densityID(appState.density) },
                        // FIX 4: routes through `AppState.setDensity` (persists to UserDefaults)
                        // instead of a bare property assignment — a plain `appState.density = ...`
                        // never survived relaunch.
                        set: { appState.setDensity(density(fromID: $0)) }
                    ),
                    options: [
                        .init(id: "cozy", label: "Cozy"),
                        .init(id: "comfy", label: "Comfy"),
                        .init(id: "roomy", label: "Roomy"),
                    ]
                )
            }
        }
    }

    /// Opens a file picker for the custom ambient background image. App Sandbox is ON (T002):
    /// `NSOpenPanel` grants a transient sandbox extension for whatever the user picks, which is
    /// enough for the current session, but persisting access across relaunches needs a
    /// security-scoped bookmark — `SecureImageBookmark.save` (AmbientBackground.swift) creates
    /// and persists that bookmark under its own UserDefaults key, alongside (not instead of)
    /// `appState.setCustomImage`'s existing raw-path persistence, which is left untouched.
    private func chooseImage(appState: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            SecureImageBookmark.save(for: url)
            appState.setCustomImage(url)
        }
    }

    private func densityID(_ density: Density) -> String {
        switch density {
        case .cozy: return "cozy"
        case .comfy: return "comfy"
        case .roomy: return "roomy"
        }
    }

    private func density(fromID id: String) -> Density {
        switch id {
        case "cozy": return .cozy
        case "roomy": return .roomy
        default: return .comfy
        }
    }

    // Tab "Integrations" (T044, "Connect Claude Code") đã bỏ cùng tính năng delegation
    // 2026-08-22: nó chỉ chứa đúng một card — cài Stop hook cho Claude Code để nó bắn
    // `volar://ai-done` về. Không còn delegation thì cái hook đó không có gì để báo.

    // MARK: - Account (Task 4, account-auth.md contract)

    private var accountTab: some View {
        VStack(spacing: 12) {
            accountCard
            if appState.accountEmail != nil {
                syncCard
            }
        }
        // `onNeedSignIn`: the paywall's own CTA routes here instead of attempting a doomed purchase
        // while signed out (`Entitlements.purchase` throws `.notSignedIn` — see `PaywallView`'s doc
        // comment).
        //
        // The handoff runs through `onDismiss` rather than flipping both flags in the callback
        // (`showPaywall = false; showSignInSheet = true`). Setting both in one closure asks SwiftUI
        // to tear down one sheet and present another within the same update, and the second
        // presentation is routinely dropped — the paywall closes and nothing replaces it, which
        // reads to the user as a dead button. `onDismiss` fires only once the paywall is fully
        // gone, so the second present always lands. `pendingSignInAfterPaywall` is what
        // distinguishes "closed via the sign-in CTA" from "closed with the X button", which must
        // not open anything.
        .sheet(isPresented: $showPaywall, onDismiss: {
            guard pendingSignInAfterPaywall else { return }
            pendingSignInAfterPaywall = false
            showSignInSheet = true
        }) {
            PaywallView(onNeedSignIn: {
                pendingSignInAfterPaywall = true
                showPaywall = false
            })
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet()
        }
        .sheet(isPresented: $showSyncEnableSheet) {
            SyncEnableSheet()
        }
        .sheet(isPresented: $showSyncRejects) {
            SyncRejectsView()
        }
        // Refetches every time this tab is shown — same "always re-read live state, never trust a
        // stale value" reasoning as `.onAppear { loginItemStatus = LoginItem.status }` on `body`
        // above: another device could have flipped this account's toggle since Settings last opened.
        .onAppear {
            appState.refreshSyncState()
        }
    }

    /// Single card, same "one `VolarColor.card` block, not several `SettingsRow`s" reasoning as
    /// — the sign-in forms and the signed-in summary don't fit that row's
    /// fixed label/hint/control shape.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Account")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text(appState.accountEmail == nil
                     ? "Sign in to unlock Cloud parsing and Groq speech transcription. Volar's core (capture, tasks, reminders, focus) never requires an account."
                     : "Manage your Volar account, subscription, and daily AI quota.")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
            }

            if let email = appState.accountEmail {
                signedInAccountBody(email: email)
            } else {
                signedOutAccountBody
            }

            // Signed-in-only here: the signed-OUT case's error display now lives INSIDE
            // `EmailSignInForm` (embedded by `signedOutAccountBody` below), which shows the exact
            // same `appState.accountError` text right under its own Verify button. Without this
            // guard a sign-in failure would render twice on this card — once from the form, once
            // from here.
            if appState.accountEmail != nil, let accountError = appState.accountError {
                Text(accountError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(4)
            }
        }
        .padding(16)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .volarHairline(cornerRadius: 11)
    }

    // MARK: - Sync (008-sync, client-contract.md §0 group C)
    //
    // Signed-in only (see `accountTab`'s guard above) — the toggle is an account-level property, so
    // it's meaningless to show before there's an account to attach it to. Same
    // "one `VolarColor.card` block" shape as `accountCard` above.

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync across devices")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text("Keeps this Mac's tasks in step with every other device signed in to this account.")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
            }

            Toggle(isOn: syncToggleBinding) {
                Text("Sync across devices")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            // Rule 3 (task brief): tắt thì LUÔN được, kể cả đã hết Pro — NEVER `.disabled` this
            // toggle based on `syncState.isPro`. The only thing allowed to disable it is an
            // in-flight request or the state not having loaded yet (see `syncStateLoaded` below),
            // same as every other Account control on this tab.
            .disabled(appState.syncBusy || !appState.syncStateLoaded)

            // THREE distinct lines, matching client-contract.md §3.3's table exactly — never
            // collapsed into one "sync error" string:
            //   · not Pro / toggle off  -> `SyncState.settingsStatusLine` (informational tone,
            //     `VolarColor.textSec`, NOT `reschedule`/`destruct` — this is a STATE, not an error)
            //   · offline               -> shows NOTHING (silently omitted below)
            //   · real server/signed-out failure -> `appState.syncError`, in the warning tone every
            //     other inline error on this tab already uses
            //
            // GATED on `syncStateLoaded`: before the first `refreshSyncState()` resolves,
            // `syncState` is still `.unknown` (`isPro: false`) — rendering `settingsStatusLine` off
            // that would tell a real Pro user "Sync is a Pro feature." for one frame, which is
            // exactly the false-statement-about-their-account bug §8.2 exists to prevent. Show
            // nothing at all until we actually know (Opus review, 2026-08-10: "im lặng tốt hơn sai").
            if appState.syncStateLoaded {
                if let statusLine = appState.syncState.settingsStatusLine {
                    Text(statusLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.textSec)
                } else {
                    syncEnabledSummary
                }
            }

            if let syncError = appState.syncError {
                Text(syncError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(3)
            }

            if appState.syncState.syncEnabled {
                syncDeviceList
            }

            HStack(spacing: 8) {
                settingsPillButton("View lost edits") { showSyncRejects = true }
                if appState.syncState.syncEnabled {
                    settingsPillButton("Re-sync from scratch") { appState.resyncFromScratch() }
                        .disabled(appState.syncBusy)
                }
            }

            // Valve 2 (design.md §6) — explains what the button above actually does, so no
            // confirmation dialog is needed: the action is harmless by construction and this line
            // says so.
            if appState.syncState.syncEnabled {
                Text("Forgets where this Mac left off and reads the whole account back from the server. Nothing on this Mac is deleted — with a lot of tasks it can take a while.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
            }

            // Styled like `signedInAccountBody`'s "Delete account" button (its own `role:
            // .destructive` Button below, not `settingsPillButton`) rather than a neutral pill —
            // `VolarColor.destruct` is explicitly allowed for an irreversible action button (task
            // brief: "destruct chỉ dành cho hành động huỷ diệt không đảo được (nút purge thì
            // được)"), and this button IS that action: it's the one and only path that deletes
            // anything on the server (design.md §8.3).
            Button("Delete data on server", role: .destructive) {
                showSyncPurgeConfirm = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.destruct)
            .disabled(appState.syncBusy)
        }
        .padding(16)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .volarHairline(cornerRadius: 11)
        .confirmationDialog(
            "Delete this account's data on Volar's server? Your tasks on THIS Mac (and every other signed-in device) are not touched — this only clears the server-side copy. Sync will start re-uploading from whatever devices are still syncing.",
            isPresented: $showSyncPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete server data", role: .destructive) { appState.purgeSyncData() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Turning ON routes through `SyncEnableSheet` (never a silent flip — design.md §8.1's
    /// confirmation is mandatory) — but ONLY when the account is actually Pro. A non-Pro attempt is
    /// a client-side no-op rather than letting the sheet round-trip to the server and land on a
    /// generic RLS-violation message: `volar_set_sync_enabled`'s failure path (an RLS rejection on
    /// `sync_prefs`, not a `raise exception`) doesn't carry the friendly `sync_pro_required` string
    /// `sync_exchange` does, so a real attempt here would surface as an opaque `.server` error
    /// instead of the clean "Sync is a Pro feature." line — which `syncCard`'s status line already
    /// shows, so the toggle not moving reads as "explained above," not as "broken." Turning OFF
    /// calls straight through: design.md §8.3 says it's always allowed and needs no confirmation,
    /// and it deletes nothing either way.
    private var syncToggleBinding: Binding<Bool> {
        Binding(
            get: { appState.syncState.syncEnabled },
            set: { newValue in
                if newValue {
                    guard appState.syncState.isPro else { return }
                    showSyncEnableSheet = true
                } else {
                    appState.setSyncEnabled(false)
                }
            }
        )
    }

    private var syncEnabledSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let enabledAt = appState.syncState.enabledAt {
                Text("Enabled since \(enabledAt.formatted(date: .abbreviated, time: .omitted))")
            }
            if let device = appState.syncState.enabledByDevice {
                Text("Turned on from \(device)")
            }
            if let lastSync = appState.lastSyncSuccessAt {
                Text("Last synced \(lastSync.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(Font.volarMono(size: 11))
        .monospacedDigit()
        // Informational, not the NOW spotlight — `instrument` (ice blue) is exactly the token this
        // theme reserves for readouts like this one (Theme.swift: "Trạng thái thông tin dùng
        // VolarColor.instrument (ice blue)"); `nowAccent` never appears outside the NOW task.
        .foregroundStyle(VolarColor.instrument)
    }

    private var syncDeviceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Devices")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VolarColor.textMut)
            ForEach(appState.syncState.devices) { device in
                HStack(spacing: 6) {
                    Text(device.label ?? "Unknown device")
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.textSec)
                    Spacer(minLength: 8)
                    if let lastSeen = device.lastSeen {
                        Text(lastSeen.formatted(date: .abbreviated, time: .omitted))
                            .font(Font.volarMono(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(VolarColor.textMut)
                    }
                }
            }
        }
    }

    /// The email-OTP form itself now lives in exactly one place, `EmailSignInForm.swift` — this
    /// used to be a full copy of that form's fields/buttons, inlined directly here. Kept as its own
    /// `private var` (rather than inlining `EmailSignInForm()` straight into `accountCard` above)
    /// so the "why this exists / what it used to be" comment has an obvious home, and so a future
    /// diff against this tab's history reads cleanly.
    private var signedOutAccountBody: some View {
        EmailSignInForm()
    }

    @ViewBuilder
    private func signedInAccountBody(email: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(email)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                tierBadge
            }

            if let status = appState.subscriptionStatus {
                Text("Parse: \(status.parseUsedToday)/\(status.parseLimit) lượt AI hôm nay")
                    .font(Font.volarMono(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textSec)
                if appState.accountTier == .pro {
                    Text("Speech: \(status.speechUsedToday)/\(status.speechLimit) lượt hôm nay")
                        .font(Font.volarMono(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(VolarColor.textSec)
                }
            }

            if appState.accountTier == .free {
                upgradeSection
            }

            redeemCodeRow

            HStack(spacing: 8) {
                settingsPillButton("Restore Purchases") { appState.restorePurchases() }
                    .disabled(appState.accountBusy)
                settingsPillButton("Manage Subscription") { openManageSubscriptions() }
                settingsPillButton("Sign out") { appState.signOutAccount() }
            }

            Button("Delete account", role: .destructive) {
                showDeleteAccountConfirm = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.destruct)
            .padding(.top, 4)
            .confirmationDialog(
                "Delete your Volar account? This cannot be undone — your tasks stay on this Mac, but your account, subscription link, and quota history are permanently removed.",
                isPresented: $showDeleteAccountConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) { appState.deleteAccount() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Backlog "1 free month of Pro" promo codes (Task 3, redeem contract). Only reachable from
    /// `signedInAccountBody` — redemption attaches the grant to the signed-in identity, so showing
    /// this to a signed-out user would just produce `AccountError.signedOut` on every tap; visible-
    /// but-disabled was considered and rejected in favor of just not rendering it, matching how
    /// `upgradeSection`/`Restore Purchases`/"Delete account" are ALSO signed-in-only rows on this
    /// same card rather than disabled placeholders — same-page precedent, not a new pattern.
    ///
    /// Styled identically to the email-OTP field/button pair directly above in
    /// `signedOutAccountBody` (same `VolarColor.surfaceHi` field background, `volarHairline`,
    /// monospaced font matching the 6-digit code field, `settingsPillButton`) — deliberately no new
    /// visual treatment introduced for this row.
    private var redeemCodeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Have a promo code?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VolarColor.textMut)
            HStack(spacing: 8) {
                TextField("PROMOCODE", text: $promoCodeInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(VolarColor.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .volarHairline(cornerRadius: 5)
                    // Live-uppercase as the user types — cosmetic only (Task 1's
                    // `AccountService.redeemPromoCode` is the ONE place that actually normalizes
                    // what goes on the wire; this just keeps what's on screen matching what will be
                    // sent, since a pasted lowercase code otherwise LOOKS unnormalized until submit).
                    // Mutating the bound string directly here (rather than `.textCase(.uppercase)`,
                    // which only recases the RENDERED glyphs and would leave `promoCodeInput` itself
                    // mixed-case) is the straightforward option — no fight with the binding, since
                    // `TextField` already treats `$promoCodeInput` as the single source of truth.
                    .onChange(of: promoCodeInput) { _, newValue in
                        let upper = newValue.uppercased()
                        if upper != newValue { promoCodeInput = upper }
                    }
                settingsPillButton("Redeem", solid: true) {
                    appState.redeemPromoCode(promoCodeInput)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.accountBusy || promoCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // Success confirmation only — failures already surface through `accountCard`'s existing
            // `appState.accountError` `Text` right below this whole card, so this does NOT duplicate
            // that as a second error label (task brief's explicit instruction).
            if let until = appState.lastRedeemedUntil {
                Text("Pro until \(until.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.done)
            }
        }
    }

    private var tierBadge: some View {
        Text(appState.accountTier == .pro ? "Pro" : "Free")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(appState.accountTier == .pro ? VolarColor.done : VolarColor.textSec)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // Was `Color.white.opacity(0.14)` for the Free branch — invisible on a white light-mode
            // bg (2026-08-19 light-mode fix). `VolarColor.veil(0.14)` already bakes in the 0.14 and
            // self-inverts polarity, so it's swapped in whole rather than composed with `.opacity`
            // again (that would double-apply the alpha).
            .background(appState.accountTier == .pro ? VolarColor.done.opacity(0.14) : VolarColor.veil(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// Single entry point into `PaywallView` (the one purchase surface in the app — see that file's
    /// header comment) rather than the plan cards previously inlined directly here. Real
    /// price/trial/plan copy now lives in exactly one place instead of two independently-maintained
    /// UIs that could drift apart.
    private var upgradeSection: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 8) {
                VolarIcon(.sparkle, size: 13, color: .white, weight: .medium)
                Text("Upgrade to Pro")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .background(accentColors.solid)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 4)
    }

    /// macOS has no `AppStore.showManageSubscriptions(in:)` equivalent (that StoreKit 2 call is
    /// iOS-only) — opening the App Store's own subscriptions management page via `NSWorkspace` is
    /// the standard macOS approach. // UNVERIFIED: not exercised on a real Mac.
    private func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - About

    /// Read the real marketing version from the bundle instead of typing it in the string below —
    /// a typed literal silently drifts from `Info.plist`'s `CFBundleShortVersionString` on every
    /// version bump (this string used to read "1.0.2" while Info.plist said "1.0.0"). Falls back
    /// to an empty string (never force-unwrapped) so a lookup failure just omits the version
    /// rather than crashing or showing a placeholder.
    private var appVersionSuffix: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty
        else { return "" }
        return " \(version)"
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay {
                    VolarIcon(.mic, size: 32, color: .white, weight: .regular)
                }
                .shadow(color: accentColors.glow, radius: 20, y: 8)

            Text("Volar AI\(appVersionSuffix)")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VolarColor.textPri)

            Text("Voice-first task manager for Mac. Built in Cambridge.")
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textSec)

            HStack(spacing: 8) {
                Text("What's new")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentColors.solid)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text("Acknowledgements")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(VolarColor.veil(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

// MARK: - Private shared row/control views

/// Label + hint on the left, arbitrary control on the right. Ported from the prototype's
/// `SettingsRow`.
private struct SettingsRow<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(VolarColor.textSec)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Không còn nền card + bo góc riêng cho từng dòng (anh Khôi 2026-08-24). Mỗi card là một
        // cái khung, mà ba mươi cái khung xếp dọc thì mắt phải đọc ba mươi lần "đây là một khối
        // mới" trước khi đọc được nội dung. Một gạch tóc giữa hai dòng nói đúng chừng ấy chuyện.
        .overlay(alignment: .bottom) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }
}

/// Custom pill toggle (named `VolarToggle` — not `Toggle` — to avoid clashing with the SwiftUI
/// control). Ported from the prototype's `Toggle`.
private struct VolarToggle: View {
    @Binding var isOn: Bool

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isOn ? accentColors.solid : VolarColor.veil(0.12))
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(2)
            }
            .shadow(color: isOn ? accentColors.glow.opacity(0.4) : .clear, radius: 8)
            .animation(VolarMotion.hover, value: isOn)
            .onTapGesture { isOn.toggle() }
    }
}

private struct SegmentOption<T: Hashable> {
    let id: T
    let label: String
    var disabled: Bool = false
    /// Set `true` only for options whose label is a measurement a user reads/compares as a number
    /// (minute values in duration pickers) — design-spec.md §2's mono-numerals rule. Defaults
    /// `false` so every other `Segmented` row in this file (Density, Theme, Ambient, reminder
    /// policy, voice delivery — all prose labels) keeps its ordinary system font untouched.
    var mono: Bool = false
}

/// Segmented control. Ported from the prototype's `Segmented`.
private struct Segmented<T: Hashable>: View {
    @Binding var value: T
    let options: [SegmentOption<T>]

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let selected = option.id == value
                Button {
                    guard !option.disabled else { return }
                    value = option.id
                } label: {
                    Text(option.label)
                        .font(option.mono ? Font.volarMono(size: 11.5, weight: .medium) : .system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(option.disabled ? VolarColor.textMut : (selected ? accentColors.solid : VolarColor.textSec))
                        .opacity(option.disabled ? 0.5 : 1)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(selected ? accentColors.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(VolarColor.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .volarHairline(cornerRadius: 5)
    }
}

/// Small preview swatch for the custom ambient background image, loaded via
/// `SecureImageBookmark.loadImage` (sandbox-safe — see AmbientBackground.swift) instead of a raw
/// `NSImage(contentsOf:)` call, and cached in `@State` so it decodes once per `url` change rather
/// than on every `body` evaluation of the surrounding `appearanceTab`.
private struct CustomImageThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VolarColor.veil(0.06)
            }
        }
        .onAppear { reload() }
        .onChange(of: url) { _, _ in reload() }
    }

    private func reload() {
        image = SecureImageBookmark.loadImage(fallbackRawURL: url)
    }
}

/// Static key-combo chip with a trailing "Change" affordance. Ported from the prototype's
/// `KeyRecorder`. Re-binding the actual global hotkey is Phase 3 (`HotkeyManager`).
private struct KeyRecorder: View {
    let keys: [String]

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { KeyBadge($0) }
            Text("Change")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(volarWellFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
