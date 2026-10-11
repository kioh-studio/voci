// VolarIOS/Sources/Views/SettingsIOSView.swift — iOS Settings (feature 011, design/ios-companion/
// project/Settings.dc.html). Pushed from the Views tab (no NavigationStack of its own).
// Section order: Account, Sync, Capture, Goal rewards, Reminders, Subscription, Appearance, Voice,
// Privacy, About. All account/sync/StoreKit logic is unchanged and calls straight into `AppState`.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI
import Speech
import StoreKit
import UIKit
import UserNotifications

struct SettingsIOSView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("volar.view.goalRewards") private var goalRewardsOn = false
    @AppStorage("volar.reminders.timeSensitive") private var timeSensitive = true

    @State private var accountEmailInput = ""
    @State private var accountCodeInput = ""
    @State private var accountCodeSent = false
    @State private var showDeleteAccountConfirm = false
    @State private var showSyncEnableSheet = false
    @State private var showSyncRejects = false
    @State private var showSyncPurgeConfirm = false
    @State private var pendingWhisperKitConfirm = false
    @State private var notificationsStatus: String?

    var body: some View {
        List {
            accountSection
            syncSection
            captureSection
            goalRewardsSection
            remindersSection
            subscriptionSection
            appearanceSection
            voiceSection
            privacySection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(IOSPalette.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(IOSPalette.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(IOSPalette.mint)
        .alert("Delete your Volar account?", isPresented: $showDeleteAccountConfirm) {
            Button("Delete", role: .destructive) { appState.deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone — your tasks stay on this iPhone, but your account, subscription link, and quota history are permanently removed.")
        }
        .alert("Download the WhisperKit model?", isPresented: $pendingWhisperKitConfirm) {
            Button("Download & Enable") { appState.setSpeechEngine(.whisperKit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WhisperKit needs a one-time on-device model download (about 145MB) before it can transcribe. This can take a while and use meaningful cellular data — we recommend doing this on Wi-Fi. Volar does not check your connection type before starting the download; that gating isn't implemented yet.")
        }
        .alert("Delete this account's synced data on Volar's server?", isPresented: $showSyncPurgeConfirm) {
            Button("Delete server data", role: .destructive) { appState.purgeSyncData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your tasks on THIS iPhone (and every other signed-in device) are not touched — this only clears the server-side copy. Sync will start re-uploading from whatever devices are still syncing.")
        }
        .sheet(isPresented: $showSyncEnableSheet) { SyncEnableSheet() }
        .sheet(isPresented: $showSyncRejects) { SyncRejectsView() }
        .onAppear { appState.refreshSyncState() }
        .task { await loadNotificationStatus() }
    }

    // MARK: - Row helpers

    private func rowTitle(_ s: String) -> some View {
        Text(s).font(IOSFont.rowTitle).foregroundStyle(IOSPalette.fg)
    }

    private func meta(_ s: String, color: Color = IOSPalette.fg2) -> some View {
        Text(s).font(IOSFont.meta).foregroundStyle(color)
    }

    private func footer(_ s: String) -> some View {
        Text(s).font(IOSFont.meta).foregroundStyle(IOSPalette.fg2)
    }

    private func loadNotificationStatus() async {
        switch await UNUserNotificationCenter.current().volarAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral: notificationsStatus = "On"
        default: notificationsStatus = "Off"
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            if let email = appState.accountEmail {
                signedInAccountRows(email: email)
            } else {
                signedOutAccountRows
            }
            if appState.accountBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(IOSPalette.mint)
                    meta("Working…")
                }
            }
            if let accountError = appState.accountError {
                meta(accountError, color: IOSPalette.high)
            }
        } header: {
            SectionLabel("Account")
        } footer: {
            footer(appState.accountEmail == nil
                ? "Sign in to unlock Cloud parsing and Groq speech transcription. Volar's core (capture, tasks, reminders, focus) never requires an account."
                : "Manage your Volar account, subscription, and daily AI quota.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    @ViewBuilder
    private var signedOutAccountRows: some View {
        // Sign in with Apple is not wired anywhere in the app yet (`AppState` has no such API; the
        // old `appState.signInWithApple()` call never compiled) — email OTP is the only sign-in path.
        VStack(alignment: .leading, spacing: 8) {
            meta("Sign in with email", color: IOSPalette.fg3)

            HStack(spacing: 10) {
                TextField("you@example.com", text: $accountEmailInput)
                    .font(IOSFont.body)
                    .foregroundStyle(IOSPalette.fg)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                Button("Send code") {
                    accountCodeSent = true
                    appState.sendEmailOTP(email: accountEmailInput)
                }
                .font(IOSFont.meta)
                .foregroundStyle(IOSPalette.mint)
                .disabled(appState.accountBusy || accountEmailInput.isEmpty)
            }
            .frame(minHeight: IOSLayout.minTouch)

            if accountCodeSent {
                HStack(spacing: 10) {
                    TextField("6-digit code", text: $accountCodeInput)
                        .font(IOSFont.body)
                        .foregroundStyle(IOSPalette.fg)
                        .keyboardType(.numberPad)
                    Button("Verify") {
                        appState.verifyEmailOTP(email: accountEmailInput, code: accountCodeInput)
                    }
                    .font(IOSFont.meta)
                    .foregroundStyle(IOSPalette.mint)
                    .disabled(appState.accountBusy || accountCodeInput.count != 6)
                }
                .frame(minHeight: IOSLayout.minTouch)
            }
        }
    }

    @ViewBuilder
    private func signedInAccountRows(email: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                rowTitle("Signed in")
                meta(email)
            }
            Spacer()
            tierBadge
        }
        .frame(minHeight: IOSLayout.minTouch)

        if let status = appState.subscriptionStatus {
            meta("Parse: \(status.parseUsedToday)/\(status.parseLimit) AI calls today")
            if appState.accountTier == .pro {
                meta("Speech: \(status.speechUsedToday)/\(status.speechLimit) calls today")
            }
        }

        Button("Restore Purchases") { appState.restorePurchases() }
            .font(IOSFont.rowTitle)
            .foregroundStyle(IOSPalette.mint)
            .disabled(appState.accountBusy)
            .frame(minHeight: IOSLayout.minTouch)
        Button("Manage Subscription") { openManageSubscriptions() }
            .font(IOSFont.rowTitle)
            .foregroundStyle(IOSPalette.mint)
            .frame(minHeight: IOSLayout.minTouch)
        Button("Sign out") { appState.signOutAccount() }
            .font(IOSFont.rowTitle)
            .foregroundStyle(IOSPalette.fg)
            .frame(minHeight: IOSLayout.minTouch)
        Button("Delete account") { showDeleteAccountConfirm = true }
            .font(IOSFont.rowTitle)
            .foregroundStyle(IOSPalette.destruct)
            .frame(minHeight: IOSLayout.minTouch)
    }

    private var tierBadge: some View {
        let pro = appState.accountTier == .pro
        return Text(pro ? "Pro" : "Free")
            .font(IOSFont.mono(12, .semibold))
            .foregroundStyle(pro ? IOSPalette.mint : IOSPalette.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(pro ? IOSPalette.mintSur : IOSPalette.surfaceHi, in: Capsule())
    }

    // UNVERIFIED: iOS-only StoreKit 2 API; scene lookup mirrors AccountService's presentationAnchor.
    private func openManageSubscriptions() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        Task { @MainActor in
            try? await AppStore.showManageSubscriptions(in: scene)
        }
    }

    // MARK: - Sync (008-sync; signed-in only)

    @ViewBuilder
    private var syncSection: some View {
        if appState.accountEmail != nil {
            Section {
                Toggle(isOn: syncToggleBinding) { rowTitle("Sync across devices") }
                    .tint(IOSPalette.mint)
                    .frame(minHeight: IOSLayout.minTouch)
                    // Turning OFF must always work, even with lapsed Pro: never gate on isPro.
                    .disabled(appState.syncBusy || !appState.syncStateLoaded)

                // Gated on `syncStateLoaded`: before the first refresh `.unknown` would flash
                // "Sync is a Pro feature." at a real Pro user.
                if appState.syncStateLoaded {
                    if let statusLine = appState.syncState.settingsStatusLine {
                        meta(statusLine)
                    } else {
                        syncEnabledSummary
                    }
                }

                HStack {
                    rowTitle("Last synced")
                    Spacer()
                    Text(appState.lastSyncSuccessAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                        .font(IOSFont.mono(13))
                        .foregroundStyle(IOSPalette.fg2)
                }
                .frame(minHeight: IOSLayout.minTouch)

                if let syncError = appState.syncError {
                    meta(syncError, color: IOSPalette.high)
                }

                if appState.syncState.syncEnabled {
                    ForEach(appState.syncState.devices) { device in
                        HStack {
                            meta(device.label ?? "Unknown device")
                            Spacer()
                            if let lastSeen = device.lastSeen {
                                meta(lastSeen.formatted(date: .abbreviated, time: .omitted), color: IOSPalette.fg3)
                            }
                        }
                    }
                }

                Button("View lost edits") { showSyncRejects = true }
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(IOSPalette.mint)
                    .frame(minHeight: IOSLayout.minTouch)
                if appState.syncState.syncEnabled {
                    Button("Re-sync from scratch") { appState.resyncFromScratch() }
                        .font(IOSFont.rowTitle)
                        .foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch)
                        .disabled(appState.syncBusy)
                    meta("Forgets where this iPhone left off and reads the whole account back from the server. Nothing on this iPhone is deleted — with a lot of tasks it can take a while.")
                }
                Button("Delete data on server") { showSyncPurgeConfirm = true }
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(IOSPalette.destruct)
                    .frame(minHeight: IOSLayout.minTouch)
                    .disabled(appState.syncBusy)
            } header: {
                SectionLabel("Sync")
            } footer: {
                footer("Your Mac and iPhone share one task list. Each device keeps a full copy.")
            }
            .listRowBackground(IOSPalette.surface)
        }
    }

    /// ON routes through the confirmation sheet only when Pro; OFF calls straight through.
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
        }
        .font(IOSFont.meta)
        .foregroundStyle(IOSPalette.fg2)
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            HStack(spacing: 8) {
                rowTitle("Understand with cloud AI")
                Spacer(minLength: 8)
                Toggle("Understand with cloud AI", isOn: Binding(
                    get: { appState.parseEnginePreference == .cloud },
                    set: { appState.setParseEngine($0 ? .cloud : .onDevice) }
                ))
                .labelsHidden()
                .tint(IOSPalette.mint)
            }
            .frame(minHeight: IOSLayout.minTouch)

            if appState.parseEnginePreference == .cloud, !ConfigParseCredentialProvider.isConfigured {
                meta("Sign in above to enable cloud parsing — every signed-in account gets a daily quota, free or Pro. Until you sign in, Volar quietly uses on-device parsing.")
            }

            ValueRow(icon: "mic", title: "Siri & Action Button", value: "Shortcuts", chevron: false)
                .listRowInsets(EdgeInsets())
        } header: {
            SectionLabel("Capture")
        } footer: {
            footer("On-device stays private and free. Cloud AI sends only the TEXT of what you said — never audio — to our proxy for higher-quality parsing of trickier phrasing.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    // MARK: - Goal rewards

    private var goalRewardsSection: some View {
        Section {
            ToggleRow(icon: "flag", title: "Goal rewards", isOn: $goalRewardsOn)
                .listRowInsets(EdgeInsets())
        } header: {
            SectionLabel("Goal rewards")
        } footer: {
            footer("Rewards you set yourself. No points, no streaks.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section {
            ValueRow(icon: "bell", title: "Notifications", value: notificationsStatus, chevron: false)
                .listRowInsets(EdgeInsets())
            ToggleRow(icon: "clock", title: "Time-sensitive for deadlines", isOn: $timeSensitive)
                .listRowInsets(EdgeInsets())
        } header: {
            SectionLabel("Reminders")
        }
        .listRowBackground(IOSPalette.surface)
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        Section {
            if appState.accountEmail == nil {
                meta("Sign in above to subscribe.", color: IOSPalette.fg3)
            } else if appState.accountTier == .pro {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").foregroundStyle(IOSPalette.done)
                    rowTitle("You're on Volar Pro")
                }
            } else {
                productRow(appState.monthlyProduct, which: .monthly)
                productRow(appState.yearlyProduct, which: .yearly)
            }
        } header: {
            SectionLabel("Subscription")
        } footer: {
            footer("Volar Pro — 14-day free trial. Unlocks Cloud AI task parsing and Groq cloud speech transcription with a daily quota.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    @ViewBuilder
    private func productRow(_ product: Product?, which: VolarProduct) -> some View {
        HStack {
            rowTitle(product?.displayName ?? (which == .monthly ? "Monthly" : "Yearly"))
            Spacer()
            if let product {
                Button(product.displayPrice) { appState.purchase(which) }
                    .font(IOSFont.rowTitle)
                    .foregroundStyle(IOSPalette.mint)
                    .disabled(appState.accountBusy)
            } else {
                meta("Unavailable", color: IOSPalette.fg3)
            }
        }
        .frame(minHeight: IOSLayout.minTouch)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            accentSwatchRow

            Picker("Density", selection: Binding(
                get: { appState.density },
                set: { appState.setDensity($0) }
            )) {
                Text("Cozy").tag(Density.cozy)
                Text("Comfy").tag(Density.comfy)
                Text("Roomy").tag(Density.roomy)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSLayout.minTouch)

            // `glass` has no persisting setter on AppState: resets on relaunch (known gap).
            Picker("Glass", selection: Binding(
                get: { appState.glass },
                set: { appState.glass = $0 }
            )) {
                Text("Subtle").tag(GlassLevel.subtle)
                Text("Standard").tag(GlassLevel.standard)
                Text("Heavy").tag(GlassLevel.heavy)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSLayout.minTouch)

            Picker("Background", selection: Binding(
                get: { appState.ambient },
                set: { appState.setAmbient($0) }
            )) {
                ForEach(AmbientMode.allCases.filter { $0 != .custom }) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .font(IOSFont.rowTitle)
            .pickerStyle(.menu)
            .frame(minHeight: IOSLayout.minTouch)
        } header: {
            SectionLabel("Appearance")
        } footer: {
            footer("Volar is dark-only. A custom background photo isn't available on iPhone yet — the desktop picker relies on macOS-only APIs (NSOpenPanel/security-scoped bookmarks); pick a live scene instead.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    /// Swatches render each `VolarAccent`'s own colour (that is the point of the picker).
    private var accentSwatchRow: some View {
        HStack(spacing: 14) {
            ForEach(VolarAccent.allCases) { candidate in
                let selected = candidate == appState.accent
                Button {
                    appState.setAccent(candidate)
                } label: {
                    Circle()
                        .fill(candidate.accent.solid)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(selected ? IOSPalette.fg : IOSPalette.border, lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .frame(width: IOSLayout.minTouch, height: IOSLayout.minTouch)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Voice

    private var speechLocales: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var whisperKitStatusText: String {
        switch appState.whisper.state {
        case .notReady: return "Not downloaded"
        case .preparing: return "Downloading model…"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }

    private var voiceSection: some View {
        Section {
            // `SpeechEngineChoice` isn't Hashable, so bind through its rawValue.
            Picker("Speech engine", selection: Binding(
                get: { appState.speechEngineChoice.rawValue },
                set: { newRaw in
                    guard let newValue = SpeechEngineChoice(rawValue: newRaw) else { return }
                    if newValue == .whisperKit, appState.speechEngineChoice != .whisperKit {
                        pendingWhisperKitConfirm = true
                    } else {
                        appState.setSpeechEngine(newValue)
                    }
                }
            )) {
                ForEach(SpeechEngineChoice.allCases) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .font(IOSFont.rowTitle)
            .pickerStyle(.menu)
            .frame(minHeight: IOSLayout.minTouch)

            if appState.speechEngineChoice == .whisperKit {
                HStack {
                    rowTitle("WhisperKit model")
                    Spacer()
                    meta(whisperKitStatusText)
                }
            }
            if appState.speechEngineChoice == .groq, !GroqEngine.isConfigured {
                footer("Groq cloud transcription needs Volar Pro — sign in and upgrade above. Until then Volar uses Apple on-device recognition.")
            }

            Picker("Recognition language", selection: Binding(
                get: { appState.recognitionLocaleID },
                set: { appState.setRecognitionLocale($0) }
            )) {
                Text("Automatic (multilingual)").tag(AppState.autoRecognitionLocaleID)
                ForEach(speechLocales, id: \.id) { loc in
                    Text(loc.name).tag(loc.id)
                }
            }
            .font(IOSFont.rowTitle)
            .pickerStyle(.navigationLink)
            .frame(minHeight: IOSLayout.minTouch)

            // `voiceFeedback` has no persistence on AppState: works live, resets on relaunch.
            Toggle(isOn: Binding(
                get: { appState.voiceFeedback },
                set: { appState.voiceFeedback = $0 }
            )) { rowTitle("Voice feedback") }
                .tint(IOSPalette.mint)
                .frame(minHeight: IOSLayout.minTouch)

            Picker("Voice delivery", selection: Binding(
                get: { appState.voiceDeliveryMode },
                set: { appState.setVoiceDeliveryMode($0) }
            )) {
                ForEach(VoiceDeliveryMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSLayout.minTouch)
        } header: {
            SectionLabel("Voice")
        } footer: {
            footer("Apple on-device is the default on iPhone — private, free, no download. WhisperKit is optional and downloads a model file first (see the warning when you pick it). Groq is cloud and needs Volar Pro.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    // MARK: - Privacy (server recognition; cloud parsing toggle lives under Capture)

    private var privacySection: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    rowTitle("Server-based recognition")
                    meta("Off by default — Volar recognizes speech on-device only. Turning this on lets Apple's servers transcribe when on-device recognition isn't available; audio then leaves this iPhone.")
                }
                Spacer(minLength: 8)
                // `allowServerRecognition` is private(set); the only way to flip it is
                // `useServerRecognition()`, which also starts a capture (no way back to off).
                if appState.allowServerRecognition {
                    meta("On")
                } else {
                    Button("Enable") { appState.useServerRecognition() }
                        .font(IOSFont.meta)
                        .foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch)
                }
            }
            .frame(minHeight: IOSLayout.minTouch)
        } header: {
            SectionLabel("Privacy")
        } footer: {
            footer("Volar's core (capture, tasks, reminders, focus) always works fully offline. These switches only affect optional cloud features.")
        }
        .listRowBackground(IOSPalette.surface)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                rowTitle("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .font(IOSFont.mono(13))
                    .foregroundStyle(IOSPalette.fg2)
            }
            .frame(minHeight: IOSLayout.minTouch)
        } header: {
            SectionLabel("About")
        }
        .listRowBackground(IOSPalette.surface)
    }
}

#Preview {
    NavigationStack { SettingsIOSView() }
        .environment(AppState())
}
