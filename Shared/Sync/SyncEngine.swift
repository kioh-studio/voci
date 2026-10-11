// Shared/Sync/SyncEngine.swift — schedules and drives `sync_exchange` rounds; the only file in
// `Shared/Sync/` that touches `TaskStore` (via `SyncTaskStoring`) or a live clock.
//
// UNVERIFIED: written on Windows, never compiled.
//
// ARCHITECTURE NOTE (Opus, per this task's brief — design.md §7 says "actor", this splits it in
// two): `SyncClient` is the `actor` — networking runs off-main, matching design intent. This type
// is `@MainActor` instead, because it has to touch `TaskStore` (a `@MainActor` class) directly.
// Under `SWIFT_STRICT_CONCURRENCY: complete`, passing a live `TaskStore` across an actor boundary
// buys a whole layer of Sendable errors nobody on this (Windows, no Swift toolchain) machine can
// verify. `SyncTaskStoring` (`SyncContracts.swift`) only ever hands `Sendable` VALUE types
// (`PendingTask`/`RemoteTask`/...) across the one real boundary this file crosses — into `SyncClient`
// — so the store itself never needs to leave `@MainActor`.
//
// GOVERNING PRINCIPLE for anything added to this file later (Opus, 2026-08-10, after anh Khôi's
// mid-task revision below): IF a future change adds push notifications or Supabase Realtime on top
// of this, that channel may ONLY ever be a "something changed, go pull" hint — NEVER a carrier of
// record content. A device that's offline the instant a push fires would lose that record forever
// if the content itself rode the push; missing a mere SIGNAL costs nothing, because the next poll's
// cursor pull still catches everything. Cursor pull stays the ONE source of truth for content,
// always — never build a second read path that has to agree with it.
//
// SCHEDULING (client-contract.md §8, revised 2026-08-10 — anh Khôi: 5-minute foreground polling
// read as "the app isn't working" when machine A finished a task and machine B still showed it
// pending): foreground poll interval starts at `baseInterval` (30s) and backs off exponentially
// toward `maxInterval` (300s) after `quietRoundsBeforeBackoff` consecutive rounds pull nothing new
// — so a machine actively in use (edited within the last couple of polls) stays fast, and only a
// machine left open and genuinely idle drifts slow. Polling runs ONLY while foreground; going to
// background cancels it outright rather than letting it free-run — see `handleBackground()`.
// Deliberately NOT applied to watch (no watch target exists yet — Phase 3): LTE + a 30s poll would
// drain a standalone watch's battery by lunchtime, so whatever watch code eventually lands here
// must stay activate-based, never on this timer.
import Foundation
import Network
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class SyncEngine {
    /// FIX (Swift 6 strict concurrency, first Mac build 2026-08-18): this was `nonisolated static
    /// let`, which asks the compiler to evaluate `SyncEngine()` — a `@MainActor`-isolated
    /// initializer, since the whole class is `@MainActor` — from a nonisolated context. Error:
    /// "main actor-isolated default value in a nonisolated context".
    ///
    /// Dropping `nonisolated` lets the property inherit the type's `@MainActor` isolation, which is
    /// where it belonged: every one of the five call sites (all in `AppState.swift` —
    /// `attach`/`deviceLabel`/`resyncFromScratch`/`requestSync`) is already `@MainActor`, so nothing
    /// needed the nonisolated access this was granting. Grepped before changing, not assumed.
    ///
    /// Do NOT "fix" this by marking it `nonisolated(unsafe)`: that would silence the diagnostic
    /// while leaving a `@MainActor` object reachable from any thread, which is the actual hazard the
    /// compiler is pointing at here.
    static let shared = SyncEngine()

    /// Why a sync round was requested — diagnostics/backoff-reset only; every reason funnels
    /// through the SAME debounced path (`requestSync`) and the same exchange loop.
    enum SyncReason: Sendable, Equatable {
        case localEdit
        case foreground
        case periodic
        /// `NWPathMonitor` observed an `unsatisfied -> satisfied` edge right after the last round
        /// failed with `.offline` (`handlePathUpdate(satisfied:)` below) — kept as its OWN case
        /// rather than reusing `.foreground` for two reasons: diagnostics need to tell "user
        /// switched back to this app" apart from "network came back while the user touched
        /// nothing", and `.foreground` also triggers `startPolling()` (`handleForeground()`),
        /// which this case must NOT do — the poll loop is already running whenever this can fire
        /// at all (see `pathMonitor`'s lifecycle note).
        case networkRestored
        /// The user pressed "Re-sync from scratch" in Settings (`resyncFromScratch()`). Its own case
        /// so a diagnostics reader can tell a deliberate full re-pull apart from an ordinary round.
        case manualResync
    }

    // MARK: - Constants

    /// Coalesces a burst of local edits (many `TaskStore` mutator calls in a row) into ONE
    /// `sync_exchange` call — contract §8: "gộp bằng debounce ~2 giây".
    private static let debounceInterval: TimeInterval = 2
    /// Starting/steady-state foreground poll interval (anh Khôi, 2026-08-10 — see file header).
    private static let baseInterval: TimeInterval = 30
    /// Ceiling the backoff below may never cross — a laptop left open and idle for hours should
    /// still notice a remote change within 5 minutes, not go silent indefinitely.
    private static let maxInterval: TimeInterval = 300
    /// Consecutive quiet rounds (nothing new pulled) required before the interval doubles. 4
    /// rounds at the base interval = ~2 minutes of confirmed quiet — long enough that a user
    /// actively editing every 20-40s never sees backoff engage at all.
    private static let quietRoundsBeforeBackoff = 4
    /// `hasMore == true` follow-up cap within ONE round — contract §3.1's runaway-server guard.
    private static let maxConsecutiveRounds = 20
    private static let batchLimit = 500

    // MARK: - UserDefaults keys (client-contract.md §7 — this file is the ONLY writer of these)

    private static let deviceIdKey = "volar.sync.deviceId"
    private static let cursorTasksKey = "volar.sync.cursorTasks"
    private static let cursorCompletionsKey = "volar.sync.cursorCompletions"
    private static let cursorRewardsKey = "volar.sync.cursorRewards"
    private static let lastSuccessAtKey = "volar.sync.lastSuccessAt"

    // MARK: - Dependencies

    private let client: SyncClient
    private let defaults: UserDefaults
    private weak var store: SyncTaskStoring?
    private weak var rewardStore: SyncRewardStoring?

    // MARK: - Observable state (client-contract.md §8's "Nhóm C đọc" — exactly these three)

    private(set) var lastFailure: SyncFailure?
    private(set) var lastSuccessAt: Date?
    private(set) var isSyncing = false

    // MARK: - Internal scheduling state

    private var hasAttached = false
    private var isForeground = false
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var currentInterval: TimeInterval = SyncEngine.baseInterval
    private var quietRoundsInARow = 0
    /// Guards against two overlapping `runSyncRound()` calls (e.g. a periodic tick landing while a
    /// debounced edit-triggered round is still awaiting the network) — `isSyncing` alone would let
    /// a second caller start a SECOND concurrent `sync_exchange` rather than deferring.
    private var isExchanging = false
    /// Set when `requestSync` lands while a round is already in flight. Runs exactly ONE more
    /// round after the current one finishes, rather than dropping the request or queuing without
    /// bound.
    private var pendingRerun = false
    /// Bumped by `resyncFromScratch()`. A round captures this at its start and refuses to write a
    /// cursor if the value changed while it was in flight — that round's cursor describes a page
    /// that began at the OLD position, so storing it would silently undo the reset the user just
    /// asked for and leave the button looking like it worked. Not a lock: the round still applies
    /// everything it pulled (that data is real and already on disk), it just declines to move a
    /// cursor it is no longer entitled to move. Only ever compared for equality, never ordered, so
    /// wrapping via `&+` on a pathological number of presses is harmless.
    private var cursorEpoch = 0

    /// Internal: `RewardCenter` stamps `startedDevice` with it.
    lazy var deviceId: String = {
        if let existing = defaults.string(forKey: Self.deviceIdKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.deviceIdKey)
        return fresh
    }()

    /// `"<model> · <os> · <short id>"`. Pinned by client-contract.md §7. Internal ON PURPOSE, not a
    /// missed `private`: this is the ONE formula for a device label in the whole client (group B
    /// owns it per §7) — `AppState` reads it when calling `volar_set_sync_enabled` so the label
    /// that lands in `sync_prefs.enabled_by_device` matches the one `sync_exchange` writes into
    /// `sync_devices`. A second, independently-written formula would let the two drift and show
    /// the same machine under two different names side by side in Settings.
    ///
    /// 🔴 NEVER put a user-assignable device name in this string. It is sent as `p_device_label`,
    /// stored in `sync_devices.label` against the account, and kept until the user purges or deletes
    /// the account — so anything that lands here is personal data at rest, and
    /// `docs/app-store-privacy.md` answers `Contact Info › Name: No` on the strength of this property
    /// alone. macOS's `Host.current().localizedName` was exactly that mistake: it returns the
    /// user-assigned computer name, which macOS defaults to one built from the account holder's name.
    ///
    /// `UIDevice.current.model` (not `.name`) on iOS: `.name` already degrades to the model name
    /// without the `user-assigned-device-name` entitlement, which this app does not request — but
    /// relying on that would mean adding that entitlement someday silently turns this into a name
    /// leak. `.model` is documented to never carry one, which makes the guarantee structural.
    ///
    /// The short id suffix keeps two machines of the same model apart in Settings. It reveals nothing
    /// new: it is the first four characters of `deviceId`, an app-generated random UUID the server
    /// already receives in full as `p_device`. Reading this property therefore forces `deviceId` to
    /// be generated, which is harmless — every caller of this property is about to send `deviceId`
    /// anyway, or is a user-initiated `volar_set_sync_enabled` call.
    var deviceLabel: String {
        let shortId = String(deviceId.prefix(4))
        #if os(macOS)
        return "Mac · macOS · \(shortId)"
        #elseif os(iOS)
        return "\(UIDevice.current.model) · iOS · \(shortId)"
        #else
        return "Volar device · \(shortId)"
        #endif
    }

    init(client: SyncClient = .shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.lastSuccessAt = defaults.object(forKey: Self.lastSuccessAtKey) as? Date
    }

    // MARK: - Wiring (client-contract.md §8: "AppState chỉ gọi đúng hai thứ")

    /// Called ONCE from `AppState` as soon as a `TaskStore` exists. Idempotent — a second call is
    /// a no-op beyond re-assigning `store` — so an accidental double-call from app wiring can never
    /// double-register the foreground/background observers or start a second poll loop.
    func attach(store: SyncTaskStoring) {
        self.store = store
        self.rewardStore = store as? SyncRewardStoring
        guard !hasAttached else { return }
        hasAttached = true
        registerLifecycleObservers()
        // The app is presumably already foreground at the moment a `TaskStore` exists (launch has
        // already gotten this far) — bootstrap directly rather than waiting for a
        // `didBecomeActive` that may never fire again this session if launch already consumed it.
        handleForeground()
    }

    /// Valve 2 (design.md §6): forget where this device has read up to and pull the account again
    /// from the beginning. For the case where the local copy is SUSPECTED to have drifted, and as the
    /// manual counterpart to `trustedCursor(forKey:)`'s automatic reset.
    ///
    /// 🔴 THIS IS NOT "DELETE AND RE-DOWNLOAD" AND MUST NEVER BECOME THAT. It clears two
    /// `UserDefaults` strings, nothing else. What follows is an ORDINARY sync round that happens to
    /// start from a `nil` cursor: every row comes back down, `SyncMerge.decide` arbitrates each one
    /// under LWW exactly as on any other round, and a local row that is newer than the server's
    /// simply wins and stays. No local task is deleted, no pending push is dropped, no `syncedAt` is
    /// cleared. The only cost is bandwidth and time proportional to the account's task count.
    func resyncFromScratch() {
        // Bumped BEFORE clearing the keys — any round already in flight captured the OLD epoch at
        // its start and will refuse to write a cursor once this one no longer matches (see
        // `cursorEpoch`'s doc comment and the guard in `runOneExchange`).
        cursorEpoch &+= 1
        defaults.removeObject(forKey: Self.cursorTasksKey)
        defaults.removeObject(forKey: Self.cursorCompletionsKey)
        defaults.removeObject(forKey: Self.cursorRewardsKey)
        requestSync(reason: .manualResync)
    }

    /// `AppState` calls this after every local write (client-contract.md §8) — also the engine's
    /// own periodic tick and the foreground observer route through here, so there is exactly ONE
    /// place that decides "run a round now" (see `debounceTask` below).
    func requestSync(reason: SyncReason) {
        guard store != nil else { return }
        // Any of these is evidence this window is genuinely in use (or usable) right now — snap
        // the poll interval back to the fast steady state (contract §8 backoff rule 3). A bare
        // periodic tick does NOT reset backoff; that would defeat the entire point of backing
        // off. `.networkRestored` belongs here too: it exists SPECIFICALLY to undo the backoff a
        // string of `.offline` failures already applied (`backOffForOffline()`) the moment the
        // network is worth trying again — see `handlePathUpdate(satisfied:)`. `.manualResync`
        // belongs here too: the user reaching for "Re-sync from scratch" in Settings is the
        // strongest possible evidence this window is in use — there is no stronger signal than an
        // explicit request.
        if reason == .localEdit || reason == .foreground || reason == .networkRestored
            || reason == .manualResync {
            resetBackoff()
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            } catch {
                return // cancelled by a newer `requestSync` — the newer call's own Task takes over
            }
            guard !Task.isCancelled else { return }
            await self?.runSyncRound()
        }
    }

    // MARK: - Lifecycle observers (client-contract.md §8 — foreground/background, engine-owned)

    private func registerLifecycleObservers() {
        #if os(macOS)
        let activeName = NSApplication.didBecomeActiveNotification
        // `didResignActiveNotification` (not `willResignActive`): this repo has no existing
        // precedent for either on macOS, and the "did" pair reads as the more literal analogue of
        // `didBecomeActive`'s own naming — both fire once the transition has actually completed.
        let inactiveName = NSApplication.didResignActiveNotification
        #elseif os(iOS)
        let activeName = UIApplication.didBecomeActiveNotification
        // `didEnterBackground` (not `willResignActive`): iOS's `willResignActive` also fires for
        // brief interruptions (Control Center, an incoming call) where the app isn't really gone —
        // cancelling a live poll loop for those would be needless churn. `didEnterBackground` is
        // the point iOS actually suspends execution soon after, matching what "foreground" means
        // for THIS timer's purpose (contract §8 rule 1: "background thì huỷ timer").
        let inactiveName = UIApplication.didEnterBackgroundNotification
        #endif

        // `@Sendable` closure + explicit `Task { @MainActor in }` hop: same pattern
        // `AppState.swift`'s own `didBecomeActiveNotification` registration and
        // `ReminderScheduler.swift`'s iOS foreground observer both use, for the same reason (a
        // MainActor-inferred closure literal invoked by a system API not itself on `@MainActor`
        // traps at runtime under Swift 6 isolation checking).
        NotificationCenter.default.addObserver(
            forName: activeName, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        }
        NotificationCenter.default.addObserver(
            forName: inactiveName, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.handleBackground() }
        }
    }

    private func handleForeground() {
        isForeground = true
        resetBackoff()
        startPolling()
        startNetworkMonitor()
        // design §8.2's second required moment. Fire-and-forget: the result lands in
        // `SyncAccountClient.cachedState`, which `currentGate()` reads on the round the debounce
        // below is about to schedule.
        Task { @MainActor in _ = try? await SyncAccountClient.shared.fetchState() }
        requestSync(reason: .foreground)
    }

    private func handleBackground() {
        isForeground = false
        stopPolling()
        stopNetworkMonitor()
        // Deliberately NOT cancelling `debounceTask`: a debounced edit-triggered round already
        // queued right before backgrounding should still fire once (it's a bounded, one-shot 2s
        // wait, not a recurring timer) — only the recurring poll loop is the battery concern rule
        // 1 targets.
    }

    // MARK: - Network-restored trigger (offline -> back online, foreground only)
    //
    // Gap caught in review: app foreground, network drops, comes back, user touches NOTHING (no
    // edit, doesn't leave/re-enter the app). With only the triggers above, a string of `.offline`
    // failures has already backed the poll interval off toward `maxInterval` (300s,
    // `backOffForOffline()`), and nothing resets it until the next poll tick happens to land on
    // its own schedule — which can be minutes away. That reads as "the app is stuck", and it's
    // stuck at exactly the moment the user regained the ability to sync. `NWPathMonitor` closes
    // this one gap without becoming a second polling mechanism — see the two guards in
    // `handlePathUpdate(satisfied:)` below.
    //
    // Lifecycle tied to `handleForeground()`/`handleBackground()`, same as `startPolling()`/
    // `stopPolling()` above, NOT "start once at `attach(store:)` and live forever": this trigger
    // only exists to unblock the foreground poll loop, which is itself foreground-only — a
    // monitor that outlived backgrounding would mean a network-restore event WAKING sync from the
    // background, which is realtime-adjacent behavior design.md §12 explicitly rules out for this
    // v1 (push/realtime are out of scope; the only channels allowed to trigger a round are the
    // ones already enumerated in contract §8). Tying the two lifecycles together is what keeps
    // this a pure "unstick the thing that's already running" fix instead of a new wake source.
    //
    // `Network` needs NO `#if os(...)` guard — confirmed available on macOS, iOS, AND watchOS
    // (unlike `AppKit`/`UIKit` above), so this is the one system import in this file usable
    // unconditionally. Left unguarded on purpose; do not wrap it in a platform check "to match
    // the rest of the file" — there is nothing to guard against.
    private var pathMonitor: NWPathMonitor?
    /// Last observed satisfaction, so `handlePathUpdate` only acts on a `false`/`nil -> true`
    /// EDGE, never on every callback — `NWPathMonitor` fires repeatedly on ordinary interface
    /// churn (wifi <-> cellular handoff, VPN toggling) even while staying satisfied throughout,
    /// and reacting to each one would turn this into an uncontrolled second poll trigger.
    private var lastPathSatisfied: Bool?

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        lastPathSatisfied = nil
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        // `Network`'s callback runs on whatever queue is passed to `start(queue:)` — never
        // `.main` on its own — so hop to `@MainActor` the same way every other system-callback
        // observer in this file does (`registerLifecycleObservers()` above): this handler touches
        // `lastPathSatisfied`/`lastFailure`/`requestSync`, all `@MainActor`-isolated.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.handlePathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "tech.kioh.Volar.sync.pathMonitor"))
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSatisfied = nil
    }

    /// The two guards this trigger exists to enforce: react ONLY on a real edge (never a repeat
    /// callback at the same satisfaction), and ONLY when the round that just failed did so
    /// because of `.offline` specifically — an interface change while sync was already healthy
    /// (or already blocked by `.proRequired`/`.disabled`/`.signedOut`, none of which a network
    /// change can fix) is not evidence a round needs to run right now. Delegates entirely to
    /// `requestSync(reason:)` rather than touching the poll loop or the network directly, so
    /// there is still exactly ONE place that decides "run a round now" — the existing ~2s debounce
    /// there also means a `.networkRestored` landing alongside an in-flight `.localEdit` request
    /// simply coalesces into the one already queued, same as any other reason would.
    ///
    /// KNOWN, HARMLESS QUIRK — written down so nobody "fixes" this into a probing mechanism later:
    /// `NWPathMonitor` can report `.satisfied` slightly before the path is ACTUALLY usable end to
    /// end (a captive portal not yet clicked through, wifi that just associated but hasn't
    /// finished DHCP/DNS). That's fine here: worst case this fires `requestSync(reason:
    /// .networkRestored)` a few seconds early, the exchange call fails with another `.offline`,
    /// and `runSyncRound`'s own `backOffForOffline()` takes back over exactly as if this trigger
    /// had never fired. No retry storm, no special-casing needed.
    private func handlePathUpdate(satisfied: Bool) {
        defer { lastPathSatisfied = satisfied }
        guard lastPathSatisfied != true, satisfied else { return }
        guard case .offline = lastFailure else { return }
        requestSync(reason: .networkRestored)
    }

    // MARK: - Poll loop (contract §8 rule 1 + 3: foreground-only, self-adjusting interval)

    /// A self-rescheduling `Task` rather than `Timer` — matches this codebase's existing
    /// convention for every other delayed/repeating async operation (`AppState`/`AmbientSound`'s
    /// own `try? await Task.sleep(nanoseconds:)` call sites), and sidesteps `Timer`'s own
    /// `Sendable`/`@MainActor` friction this repo has already hit once (`ReminderScheduler.swift`'s
    /// removed-`deinit` note). Re-reads `currentInterval` at the TOP of every iteration, so a
    /// backoff/reset decided by the previous round's outcome takes effect on the very next sleep
    /// without needing to cancel and restart this loop.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.currentInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.requestSync(reason: .periodic)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func resetBackoff() {
        currentInterval = Self.baseInterval
        quietRoundsInARow = 0
    }

    /// Called after a round that succeeded but pulled nothing new. Doubles the interval (capped at
    /// `maxInterval`) only once `quietRoundsBeforeBackoff` such rounds have happened IN A ROW, then
    /// resets the counter so the NEXT doubling requires its own full streak at the new, slower
    /// interval.
    private func registerQuietRound() {
        quietRoundsInARow += 1
        guard quietRoundsInARow >= Self.quietRoundsBeforeBackoff else { return }
        currentInterval = min(currentInterval * 2, Self.maxInterval)
        quietRoundsInARow = 0
    }

    /// `.offline` backs off ONE notch immediately (contract §8 rule 3: "gặp `.offline` thì lùi
    /// ngay một nấc") — waiting for `quietRoundsBeforeBackoff` failed attempts first would mean
    /// hammering a network that's already known to be down.
    private func backOffForOffline() {
        currentInterval = min(currentInterval * 2, Self.maxInterval)
    }

    /// Reads the cached account state, fetching it ONCE if it has never been fetched. The fetch lives
    /// here rather than relying on `AppState.refreshSyncState()` alone so the engine can never end up
    /// permanently dead: a launch whose first state fetch failed (offline) would otherwise leave the
    /// gate at `.unknown` forever with nothing to retry it.
    ///
    /// `volar_sync_state()` is itself UNGATED server-side (design §8.2) and MUST stay reachable here —
    /// gating the one call that reports the gate is how a client locks itself out permanently after
    /// the user buys Pro or flips the switch on another device.
    private func currentGate() async -> SyncGate {
        var state = await SyncAccountClient.shared.cachedState
        if state == nil {
            // `try?` — a failed fetch leaves `state == nil`, which resolves to `.unknown`: silent, no
            // content sent, retried next round. Never `.proRequired`: an offline client has learned
            // nothing about the user's tier and must not say otherwise.
            state = try? await SyncAccountClient.shared.fetchState()
        }
        return SyncMerge.gate(state: state)
    }

    // MARK: - The exchange round itself

    /// Runs `sync_exchange` repeatedly (bounded by `maxConsecutiveRounds`) until the server reports
    /// `hasMore == false` or a failure stops the loop, then updates the backoff interval from the
    /// OUTCOME of the whole round. Re-entrancy-safe (`isExchanging`/`pendingRerun` above).
    private func runSyncRound() async {
        guard let store else { return }

        // Client-side gate (design §8, added 2026-08-10). Deliberately BEFORE the outbox is gathered
        // and before any request is built: the whole point is that task content —
        // `sourceTranscript` included — never leaves the machine just to be rejected. The
        // server-side RLS check is untouched and remains the real authority; this only stops the
        // pointless (and privacy-relevant) upload.
        switch await currentGate() {
        case .allowed:
            break
        case .blocked(let failure):
            // Same two values `sync_exchange`'s 403 would have produced, so the UI path is identical
            // to the one it already handles — no new state, no "sync error" string (contract §1
            // rule 2).
            lastFailure = failure
            return
        case .unknown:
            // Never asked, or the ask failed. Say nothing and send nothing (contract §3.3: offline is
            // SILENT) — do NOT set `lastFailure`, which would make "we haven't checked yet" render as
            // a problem the user could act on.
            return
        }

        guard !isExchanging else {
            pendingRerun = true
            return
        }
        isExchanging = true
        isSyncing = true

        var remainingRounds = Self.maxConsecutiveRounds
        var pulledRealChanges = false
        var keepGoing = true
        var failureThisRound: SyncFailure?

        while keepGoing && remainingRounds > 0 {
            remainingRounds -= 1
            guard let outcome = await runOneExchange(store: store) else {
                failureThisRound = lastFailure
                break
            }
            pulledRealChanges = pulledRealChanges || outcome.pulledSomething
            keepGoing = outcome.hasMore
        }

        // Backoff decision: RULE 3's three reset triggers plus the one immediate-backoff trigger.
        // A blocked outcome (`.proRequired`/`.disabled`/`.signedOut`/non-offline `.server`) touches
        // neither — repolling faster wouldn't help any of those, but there's no stated rule to slow
        // down for them either, so the interval simply holds until the next real signal.
        if case .offline = failureThisRound {
            backOffForOffline()
        } else if failureThisRound == nil {
            if pulledRealChanges {
                resetBackoff()
            } else {
                registerQuietRound()
            }
        }

        isSyncing = false
        isExchanging = false

        if pendingRerun {
            pendingRerun = false
            await runSyncRound()
        }
    }

    /// Valve 1 (design.md §6, `SyncMerge.cursorAfterStalenessCheck`): read a stored cursor, and if it
    /// is too old to be trusted, FORGET it — clear the key as well as returning `nil`. Clearing
    /// matters: `nextCursor(previous:candidate:)` at the end of a round re-reads this same key, and a
    /// stale value left sitting there would win that comparison and be written straight back, undoing
    /// the reset. This is NOT a wipe — a `nil` cursor is an ordinary full pull; nothing local is
    /// deleted and LWW arbitrates every row as usual.
    private func trustedCursor(forKey key: String) -> String? {
        let stored = defaults.string(forKey: key)
        let trusted = SyncMerge.cursorAfterStalenessCheck(stored, now: Date())
        if trusted == nil, stored != nil {
            defaults.removeObject(forKey: key)
        }
        return trusted
    }

    /// One `sync_exchange` HTTP call: gather the outbox, send it, apply what comes back. Returns
    /// `nil` on failure (already recorded into `lastFailure` before returning) — the caller stops
    /// looping for this round; nothing here is ever undone on failure (RULE 1 — see below).
    private func runOneExchange(
        store: SyncTaskStoring
    ) async -> (hasMore: Bool, pulledSomething: Bool)? {
        // Captured FIRST, before anything below can await and let `resyncFromScratch()` land
        // concurrently — see `cursorEpoch`'s doc comment. Compared again just before the cursor
        // writes at the bottom of this function.
        let epoch = cursorEpoch
        let pendingTasks = store.pendingForSync(limit: Self.batchLimit)
        let pendingCompletions = store.pendingCompletions(limit: Self.batchLimit)
        let pendingRewards = rewardStore?.pendingRewardsForSync(limit: Self.batchLimit) ?? []

        let request = SyncExchangeRequest(
            cursorTasks: trustedCursor(forKey: Self.cursorTasksKey),
            cursorCompletions: trustedCursor(forKey: Self.cursorCompletionsKey),
            device: deviceId,
            deviceLabel: deviceLabel,
            tasks: pendingTasks.map(SyncTaskOutbound.init),
            completions: pendingCompletions.map(SyncCompletionOutbound.init),
            cursorRewards: trustedCursor(forKey: Self.cursorRewardsKey),
            rewards: pendingRewards.map(SyncRewardOutbound.init),
            limit: Self.batchLimit
        )

        let response: SyncExchangeResponse
        do {
            response = try await client.exchange(request)
        } catch let failure as SyncFailure {
            await handleFailure(failure)
            return nil
        } catch {
            // `SyncClient.exchange` is documented to only ever throw `SyncFailure` — this branch is
            // pure defensive belt-and-suspenders for a call signature that technically allows any
            // `Error`, never expected to actually run.
            await handleFailure(.server(status: -1, message: "unexpected error"))
            return nil
        }

        // ── RULE 1: a failed push NEVER rolls back local state. Upheld trivially in this whole
        // function — every statement below describes something that DID happen (the server
        // confirmed it, or handed us a row that's now durably on disk), never an undo. ──

        // §4b (client-contract.md, added after a review caught this): APPLY TO DISK BEFORE ANYTHING
        // ELSE, cursor LAST. `TaskStore.save()` swallows a failed `context.save()` via `try?`, so
        // `applyRemote`/`applyRemoteCompletions` are the ONLY signal a disk write actually failed —
        // and the cursor is our own promise to the server "I've seen up to here, don't resend it".
        // Advancing the cursor BEFORE the rows it covers are durably on disk is an unretractable
        // lie: next round the server won't send them again, and nothing else in this system ever
        // asks for them a second time. That failure mode needs no crash at all — a full disk or a
        // constraint violation on an ordinary, still-running app is enough. Order matters here in a
        // way it doesn't for `markSynced`/`markCompletionsSynced` below (those stay `try?` by
        // design — losing a confirmation just re-pushes a row the server will happily no-op via
        // LWW/`on conflict do nothing`, cost is a wasted round, not lost data).
        var appliedTaskIds: [UUID] = []
        var appliedRewardIds: [UUID] = []
        do {
            let remoteTasks = response.tasks.map(\.asRemoteTask)
            if !remoteTasks.isEmpty {
                // `TaskStore.applyRemote` (group A) owns the "don't re-stamp `updatedAt`"
                // suppression required by contract §4; this file only calls through
                // `SyncTaskStoring` and never touches `updatedAt` itself.
                appliedTaskIds = try store.applyRemote(remoteTasks)
            }
            let remoteCompletions = response.completions.map(\.asRemoteCompletion)
            if !remoteCompletions.isEmpty {
                _ = try store.applyRemoteCompletions(remoteCompletions)
            }
            // Rewards: same do block, so a failed write skips every cursor (§4b).
            let remoteRewards = response.rewards.map(\.asRemoteReward)
            if !remoteRewards.isEmpty, let rewardStore {
                appliedRewardIds = try rewardStore.applyRemoteRewards(remoteRewards)
            }
        } catch {
            // Disk write failed. Do NOT advance the cursor (still holding the pre-round value in
            // `UserDefaults` below — this function returns before ever touching it) and do NOT
            // clear `lastFailure` — a caller checking `lastFailure` right after this round must see
            // that something is wrong, not a stale `nil` from a previous success. `.server`, not
            // `.offline`: this is not a transport failure and `.offline` is contractually SILENT
            // (§8.2) — burying a real local-persistence failure behind that would hide the one
            // failure mode this whole reordering exists to surface.
            lastFailure = .server(status: -1, message: "local persistence failed")
            return nil
        }

        if !appliedTaskIds.isEmpty || !appliedRewardIds.isEmpty {
            NotificationCenter.default.post(
                name: .volarSyncDidApplyRemote, object: nil,
                userInfo: ["taskIds": appliedTaskIds, "rewardIds": appliedRewardIds]
            )
        }

        // Only now — rows are durably on disk — is it safe to tell the server "don't resend these".
        lastFailure = nil

        // Confirm pushed tasks using the WRAPPER's echoed `updatedAt` — never the value this device
        // sent — because the server clamps a clock-skewed timestamp (`least(updated_at, now() + 1
        // minute)`, migration 0005) and THAT clamped value is what must be treated as this row's
        // truth from now on (contract §4/§5). A pushed row absent from `response.tasks` lost LWW
        // (it's in `response.rejected`, and its losing payload is preserved server-side in
        // `sync_rejects`) — it simply isn't confirmed here, so it stays pending and the next round
        // retries it, converging once the newer remote version comes back down through the PULL
        // side above. `markSynced` failing silently (`try?` inside `TaskStore`, by design — see the
        // big comment above) only means one extra redundant push next round, never data loss.
        //
        // `reduce(into:)` (first-wins), not `Dictionary(uniqueKeysWithValues:)` — the page query's
        // primary key (`profile_id, id`) already rules out a duplicate id in one response, but this
        // function has no business trapping over a hypothetical malformed response it doesn't
        // control (same defensive stance `WaitingMode.decide` takes on its own caller-supplied
        // array).
        let echoedUpdatedAtById = response.tasks.reduce(into: [UUID: Date]()) { dict, task in
            if dict[task.id] == nil { dict[task.id] = task.updatedAt }
        }
        var confirmedTasks: [UUID: Date] = [:]
        for pending in pendingTasks {
            guard let echoedUpdatedAt = echoedUpdatedAtById[pending.item.id] else { continue }
            confirmedTasks[pending.item.id] = echoedUpdatedAt
        }
        if !confirmedTasks.isEmpty {
            store.markSynced(confirmedTasks)
        }

        // Rewards: confirm with the echoed `updatedAt`, same reasoning as tasks above.
        if let rewardStore, !pendingRewards.isEmpty {
            let echoedRewards = response.rewards.reduce(into: [UUID: Date]()) { dict, row in
                if dict[row.id] == nil { dict[row.id] = row.updatedAt }
            }
            var confirmedRewards: [UUID: Date] = [:]
            for pending in pendingRewards {
                if let echoed = echoedRewards[pending.item.id] { confirmedRewards[pending.item.id] = echoed }
            }
            if !confirmedRewards.isEmpty { rewardStore.markRewardsSynced(confirmedRewards) }
        }

        // Completions can never lose a conflict (append-only, `on conflict do nothing` — migration
        // 0005's own header on `completions`) — a 2xx response means every completion in THIS
        // push was accepted, full stop.
        if !pendingCompletions.isEmpty {
            store.markCompletionsSynced(pendingCompletions.map(\.id))
        }

        // Cursor LAST, and only after the `do` block above proved the rows it covers are durably on
        // disk (§4b). NOT folded into a SwiftData transaction with the writes above: the cursor
        // lives in `UserDefaults`, which can't join a `ModelContext` transaction, and making it
        // atomic with the disk write would cost a `@Model` + migration to buy back exactly one
        // thing — avoiding a RE-fetch of a few already-applied rows next round, which is free
        // (LWW/`on conflict do nothing` are both idempotent). With apply-then-cursor ordering,
        // every crash window resolves to "pull some already-applied rows again" (safe), never to
        // "the server thinks I have rows I don't" (data loss) — do not reorder this for tidiness.
        // Cursors are opaque strings end to end (contract §6) — `SyncMerge.nextCursor` is the only
        // place that ever compares them, and only lexically, never via `Date`.
        let newCursorTasks = SyncMerge.nextCursor(
            previous: defaults.string(forKey: Self.cursorTasksKey), candidate: response.cursorTasks
        )
        let newCursorCompletions = SyncMerge.nextCursor(
            previous: defaults.string(forKey: Self.cursorCompletionsKey), candidate: response.cursorCompletions
        )
        let newCursorRewards = SyncMerge.nextCursor(
            previous: defaults.string(forKey: Self.cursorRewardsKey), candidate: response.cursorRewards
        )
        // `resyncFromScratch()` guard: if the epoch moved while this round was in flight, this
        // round's cursor describes a page that began at the position the user just asked to
        // discard — writing it would silently undo the reset (`cursorEpoch`'s doc comment). Only
        // the cursor is epoch-scoped: everything pulled above is real and already durably applied,
        // and `markSynced`/`markCompletionsSynced`/`lastSuccessAt` below still reflect a push/pull
        // that genuinely succeeded regardless of which epoch it belonged to.
        if epoch == cursorEpoch {
            defaults.set(newCursorTasks, forKey: Self.cursorTasksKey)
            defaults.set(newCursorCompletions, forKey: Self.cursorCompletionsKey)
            defaults.set(newCursorRewards, forKey: Self.cursorRewardsKey)
        }

        let now = Date()
        lastSuccessAt = now
        defaults.set(now, forKey: Self.lastSuccessAtKey)

        let pulledSomething = !response.tasks.isEmpty || !response.completions.isEmpty || !response.rewards.isEmpty
        return (hasMore: response.hasMore, pulledSomething: pulledSomething)
    }

    /// Contract §3.3: after `.proRequired`/`.disabled`, MUST refetch `volar_sync_state()` and let
    /// its real answer drive the UI — never infer the account-level state from the error code
    /// alone. `SyncAccountClient` (group C, `SyncAccountState.swift`) owns what happens to the
    /// fetched `SyncState` from here — this engine's own observable surface is deliberately just
    /// the three fields client-contract.md §8 names (`lastFailure`/`lastSuccessAt`/`isSyncing`); it
    /// does not duplicate `SyncState` storage. The fetch is triggered here purely so that whatever
    /// group C wires up to read it (their own cache/`@Observable` property) is current by the time
    /// a UI reacting to `lastFailure` next asks.
    private func handleFailure(_ failure: SyncFailure) async {
        lastFailure = failure
        switch failure {
        case .proRequired, .disabled:
            _ = try? await SyncAccountClient.shared.fetchState()
        case .signedOut, .offline, .server:
            break
        }
    }
}
