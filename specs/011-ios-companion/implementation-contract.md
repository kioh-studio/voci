# 011 iOS companion — implementation contract (Opus/Fable, 2026-10-11)

Goal (anh Khôi, 2026-10-11): implement the iOS app following the 18-artboard design in
`design/ios-companion/project/*.dc.html` (spec `design/ios-companion/SPEC.md`), server side included,
so iOS ↔ macOS sync works for tasks AND rewards. Plan context: `specs/011-ios-companion/plan.md`.

Every agent: read this file first, then `design/ios-companion/SPEC.md`, then the artboards you own.
Everything is written blind on Windows (no Swift toolchain). Mark anything you could not verify with
`// UNVERIFIED:` and keep the code boring. **Never run `supabase/scripts/probe-*.ts`, never apply a
migration, never `git commit`.** `deno check` is fine. Copy is English, calm, taken from the artboards.
No emoji, no red except Delete, no points/streaks/guilt copy.

## 0. Decisions (don't re-litigate)

| # | Decision |
|---|---|
| D-A | iOS gets its own token set `IOSPalette` (bg `#0E0F11` etc. from SPEC.md). `Shared/Design/Theme.swift` is NOT edited. Shared views (sign-in, sync sheets) keep `VolarColor`. |
| D-B | Font = Geist / Geist Mono bundled in `VolarIOS/Resources/Fonts/`. `IOSFont` helpers use `Font.custom`; if the file is missing SwiftUI silently falls back to system, so nothing breaks. |
| D-C | Native `TabView` (iOS 17 `.tabItem`) with SF Symbols (`target`, `flag`, `square.grid.2x2`) — not a hand-drawn bar. Appearance proxy tints it to the artboard. |
| D-D | Tabs: **Now · Goals · Views**. The Goals tab exists only while the "Goal rewards" view is on (`@AppStorage("volar.view.goalRewards")`, default **false** per plan §2.3 "mặc định tắt"). Settings is pushed from Views, not a tab. |
| D-E | A **goal** = a task that has a live grant. A grant may have no reward (`rewardId == nil`) — that is "Today's goal, no reward". |
| D-F | Reward state is DERIVED (plan §2.2), never stored. One live grant per task. |
| D-G | Rewards live in the same SwiftData container as tasks (`RewardRecord` added to the `Schema`), CRUD in `extension TaskStore` (`RewardStore.swift`), observable state in `RewardCenter` injected via `.environment` — **AppState is not modified for rewards**. |
| D-H | Reward sync = third stream in `sync_exchange` (`p_cursor_rewards`, `p_rewards`, response `cursorRewards`, `rewards`). Same LWW, no `sync_rejects` row. |
| D-I | Break-end notification only on the device that started the break (`startedDevice == SyncEngine.shared.deviceId`). Plain `UNNotificationRequest`, identifier `reward-break-<grantId>`, no category. |
| D-J | Mac UI for rewards is out of scope this round (backlog). Mac must only TOLERATE the new wire keys (it compiles `Shared/`, so it does by construction). |
| D-K | Out of scope → backlog: Live Activity, Home/Lock-screen widgets, Share Extension target, Control Center, App Group container move (plan phases 3/6/7, all need Mac + new targets). |
| D-L | "Add a view" rows for Task board / Daily wins / Soundscape render with a muted `Soon` chip instead of `+ Add` (those views don't exist on iOS). |
| D-M | Focus on iOS = minimal full-screen cover (`FocusIOSView`): title, mm:ss from `appState.focusSecondsLeft`, Pause/Resume, Done, End. No ambient canvas. |

## 1. File ownership (one owner per file; never edit a file you don't own)

| Agent | Owns |
|---|---|
| S1 server | `supabase/migrations/0007_rewards.sql` |
| C1 model | `Shared/Model/RewardRecord.swift` (new), `Shared/Model/RewardStore.swift` (new), `Shared/Model/RewardCenter.swift` (new), `SharedTests/RewardTests.swift` (new), **`Shared/Model/TaskStore.swift`** (only: add `RewardRecord.self` to both `Schema([...])`, make `context` internal `let context`, stamp `RewardRecord.updatedAt` in `saveThrowing()`), `Shared/Reminders/NotificationActions.swift` (nothing needed — leave) |
| C2 sync | `Shared/Sync/SyncContracts.swift`, `SyncPayload.swift`, `SyncEngine.swift`, `SyncAccountState.swift` (purge tolerance), `SharedTests/RewardSyncTests.swift` (new), `specs/008-sync/client-contract.md` (append §rewards) |
| D1 design | `VolarIOS/Sources/Design/IOSPalette.swift` (new), `VolarIOS/Sources/Design/IOSComponents.swift` (new), `VolarIOS/Resources/Fonts/*` (new), `VolarIOS/Resources/Info.plist` (add `UIAppFonts` only), `VolarIOS/Sources/Design/IOSMetrics.swift` (may add, never remove) |
| U-Now | `VolarIOS/Sources/Views/NowIOSView.swift` (new, replaces `TodayIOSView.swift` which it DELETES), `VolarIOS/Sources/Views/FocusIOSView.swift` (new), `VolarIOS/Sources/Views/MobileTaskCard.swift` (restyle or delete if unused) |
| U-Goals | `VolarIOS/Sources/Views/GoalsIOSView.swift` (new), `VolarIOS/Sources/Views/RewardSheets.swift` (new: `RewardPickerSheet`, `RewardNewSheet`, `RewardUnlockedSheet`, `GoalTaskPickerSheet`) |
| U-Shell | `VolarIOS/Sources/App/RootTabView.swift`, `VolarIOS/Sources/Views/ViewsIOSView.swift` (new), `VolarIOS/Sources/Views/SettingsIOSView.swift`, `VolarIOS/Sources/Views/MicFAB.swift`, `VolarIOS/Sources/App/VolarIOSApp.swift` |
| U-Detail | `VolarIOS/Sources/Views/TaskDetailIOSView.swift` (new) |
| U-Capture | `VolarIOS/Sources/Views/CaptureSheet.swift` |
| P45 | `Shared/App/OfflineCaptureCenter.swift` (new), `VolarIOS/Sources/Views/ReparseReviewSheet.swift` (new), `Shared/Reminders/ReminderScheduler.swift` (time-sensitive + `#if os(iOS)` only), `VolarIOS/Resources/VolarIOS.entitlements`, **`Shared/App/AppState.swift`** (only the hooks listed in §7), `Shared/Sync/SyncEngine.swift` is C2's — P45 asks for the `volarSyncDidApplyRemote` notification C2 posts (see §5) |

Shared files nobody else touches: `Shared/Design/Theme.swift`, `VolarIOS/project.yml` (D1 may add `UIBackgroundModes`? no — P45 owns `Info.plist` keys `BGTaskSchedulerPermittedIdentifiers`/`UIBackgroundModes`; D1 owns `UIAppFonts`. Both edit `Info.plist` in different keys — D1 goes first, P45 runs after D1 is done).

## 2. Design tokens — `IOSPalette` / `IOSFont` (D1 writes, everyone uses)

```swift
enum IOSPalette {               // values from SPEC.md token table, all `Color(volar:)`
    static let bg, bg2, surface, surfaceHi, border, borderHi, fg, fg2, fg3,
               mint, mintSoft, mintSur, mintGlow, onMint, high, med, done, destruct: Color
    static let primaryGradient: LinearGradient   // top mintSoft → bottom mint
    static let tabBarBg: Color                   // rgba(14,15,17,0.92)
}
enum IOSFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font   // Geist
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font // Geist Mono
    // named roles:
    static let screenTitle: Font      // ui 30 semibold, tracking -0.6
    static let nowTitle: Font         // ui 30 semibold, tracking -0.75, lineSpacing ~4
    static let sectionLabel: Font     // mono 12 semibold, uppercase, tracking 0.72
    static let rowTitle: Font         // ui 16 medium
    static let body: Font             // ui 15 regular
    static let meta: Font             // ui 13
    static let chip: Font             // mono 13
    static let button: Font           // ui 16 semibold
    static let nowChip: Font          // mono 11 semibold tracking 1.1
}
enum IOSLayout { static let screenPadH: CGFloat = 22; cardRadius 14; sheetRadius 28; buttonRadius 14;
                 primaryHeight 52; secondaryHeight 48; fabSize 64; minTouch 44 }
```

## 3. Components — `IOSComponents.swift` (D1 writes, everyone uses; exact signatures)

```swift
struct PrimaryButton: View   { init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) }  // 52pt, gradient, onMint text
struct SecondaryButton: View { init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) }  // 48pt, surfaceHi, borderHi
struct NowChip: View         { init() }                                           // "NOW" pill
struct MetaChip: View        { init(_ text: String, color: Color = IOSPalette.fg2, dot: Color? = nil) } // bg2, border, mono 13
struct SectionLabel: View    { init(_ text: String) }                            // uppercase mono fg2
struct ScreenHeader: View    { init(_ title: String, meta: String? = nil) }      // "Now" + mono date on same baseline
struct RewardChip: View      { init(title: String, minutes: Int?, icon: RewardIcon?, highlighted: Bool = false) } // pill with 14pt stroke icon
struct GroupedCard<Content: View>: View { init(@ViewBuilder content: () -> Content) }  // surface, radius 14, border; children separated by hairline
struct ValueRow: View        { init(icon: String, title: String, value: String?, valueColor: Color = IOSPalette.fg2, chevron: Bool = true, action: (() -> Void)? = nil) }
struct ToggleRow: View       { init(icon: String, title: String, isOn: Binding<Bool>) }
struct SheetHeader: View     { init(title: String, leading: String = "Cancel", trailing: String?, onLeading: @escaping () -> Void, onTrailing: (() -> Void)? = nil, trailingEnabled: Bool = true) }
struct HomeIndicatorSpacer: View { }  // 24pt bottom spacer helper for scroll views
extension View { func iosScreenBackground() -> some View }   // bg + ignoresSafeArea
enum RewardIcon: String, CaseIterable, Codable, Sendable { case gamepad, tv, headphones, cup, book, walk
    var systemImage: String   // gamecontroller, tv, headphones, cup.and.saucer, book, figure.walk
}
```
`RewardIcon` is declared in `Shared/Model/RewardRecord.swift` by **C1** (it is persisted/synced), NOT in
IOSComponents. D1 only uses it.

## 4. Reward model (C1 writes; C2, U-* use)

```swift
// Shared/Model/RewardRecord.swift
enum RewardKind: String, Codable, Sendable { case catalog, grant }
enum RewardIcon: String, CaseIterable, Codable, Sendable { case gamepad, tv, headphones, cup, book, walk; var systemImage: String { ... } }

@Model final class RewardRecord {            // same conventions as VolarTask: defaults on every non-optional
    @Attribute(.unique) var id: UUID
    var kindRaw: String = "catalog"
    var title: String?                       // catalog name / grant SNAPSHOT
    var minutes: Int?                        // catalog / grant SNAPSHOT
    var iconRaw: String?                     // RewardIcon.rawValue
    var taskId: UUID?                        // grant only
    var rewardId: UUID?                      // grant only; nil = goal without reward
    var breakStartedAt: Date?
    var breakEndsAt: Date?
    var startedDevice: String?
    var closedAt: Date?
    var remindWhenOver: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date(timeIntervalSince1970: 0)   // stamped by TaskStore.saveThrowing like VolarTask
    var deletedAt: Date?
    var syncedAt: Date?
    var isPendingSync: Bool
    var asItem: RewardItem
    func apply(_ item: RewardItem)           // copies every field except id/updatedAt/deletedAt/syncedAt
}

struct RewardItem: Identifiable, Sendable, Equatable, Codable {   // wire payload == this, Codable synthesized, Date via SyncCoding
    let id: UUID; var kind: RewardKind; var title: String?; var minutes: Int?; var icon: RewardIcon?
    var taskId: UUID?; var rewardId: UUID?; var breakStartedAt: Date?; var breakEndsAt: Date?
    var startedDevice: String?; var closedAt: Date?; var remindWhenOver: Bool; var createdAt: Date
    // decode tolerant: every field decodeIfPresent with fallback except id (same convention as TaskPayload)
}

enum RewardState: Sendable, Equatable { case locked, unlocked, running, ended }
enum RewardRules {
    /// plan §2.2 — pure, testable.
    static func state(of grant: RewardItem, taskDone: Bool, now: Date) -> RewardState
    /// plan §2.3 — among grants for one task keep newest `updatedAt`, return ids to tombstone.
    static func duplicateGrantIDsToTombstone(_ grants: [(item: RewardItem, updatedAt: Date)]) -> [UUID]
}
```
```swift
// Shared/Model/RewardStore.swift — extension TaskStore
func fetchRewards() -> [RewardItem]                       // non-deleted, both kinds
func addReward(_ item: RewardItem)                        // insert, save()
func updateReward(_ item: RewardItem)                     // apply + save()
func deleteReward(_ id: UUID, now: Date = Date())         // tombstone (deletedAt), save()
func liveGrant(for taskId: UUID) -> RewardItem?           // kind == .grant, deletedAt == nil, closedAt == nil ... (the one grant; if >1 enforce rule)
// Sync (conformance declared here): extension TaskStore: SyncRewardStoring — see §5
```
```swift
// Shared/Model/RewardCenter.swift
@MainActor @Observable final class RewardCenter {
    init(store: TaskStore?)
    private(set) var catalog: [RewardItem]            // kind == .catalog
    private(set) var grants: [RewardItem]             // live grants (closedAt == nil) + ended ones from today
    var isEnabled: Bool                               // backed by UserDefaults "volar.view.goalRewards" (same key as @AppStorage in views)
    func refresh()                                    // re-fetch both lists from store
    func grant(for taskId: UUID) -> RewardItem?
    func state(of grant: RewardItem, tasks: [TaskItem], now: Date = Date()) -> RewardState
    func runningBreak(now: Date = Date()) -> RewardItem?     // the grant with state .running, if any
    // catalog
    @discardableResult func addReward(title: String, minutes: Int, icon: RewardIcon, remindWhenOver: Bool) -> RewardItem
    func updateReward(_ item: RewardItem)
    func removeReward(_ id: UUID)
    // goals
    func setGoal(_ taskId: UUID, _ isGoal: Bool)            // creates grant(rewardId nil) / tombstones live grant
    func attachReward(_ rewardId: UUID?, to taskId: UUID)   // creates grant if none; snapshots title/minutes/icon; nil = no reward
    // break
    func startBreak(_ grantId: UUID, now: Date = Date())    // sets breakStartedAt/EndsAt, startedDevice = SyncEngine.shared.deviceId; schedules UNNotification if remindWhenOver
    func endBreak(_ grantId: UUID, now: Date = Date())      // closedAt = now; cancels notification
    func dismissUnlocked(_ grantId: UUID)                   // closedAt = now ("Save it for later" keeps grant unlocked? NO: see below)
    var offeredGrantIDs: Set<UUID>                          // grants whose Unlocked sheet was already shown this session
    func handleRemoteApplied()                              // refresh + if a running break started elsewhere, cancel local notification
}
```
"Save it for later" = just dismiss the sheet (`offeredGrantIDs.insert`), grant stays `unlocked` and shows
on Goals as "Earned … Start timer". "I'm back early" / timer end = `endBreak`.
After every mutation: `store.save` path stamps `updatedAt`; then call `SyncEngine.shared.requestSync(reason: .localEdit)`.
`SyncEngine.deviceId` must be made `internal` (C2) — C1 may reference `SyncEngine.shared.deviceId`.

## 5. Sync wire contract (C2 writes; S1 mirrors in SQL)

Request adds `p_cursor_rewards timestamptz default null`, `p_rewards jsonb default '[]'`.
Element of `p_rewards`: `{ id, updatedAt, deletedAt?, payload: RewardItem-JSON, schemaVersion: 1 }`.
Response adds `cursorRewards` (same semantics as `cursorTasks`) and `rewards: [{ id, updatedAt, deletedAt, payload, schemaVersion, serverUpdatedAt, originDevice }]`. `hasMore` also considers the rewards page.

```swift
// SyncContracts.swift additions
struct PendingReward: Sendable { var item: RewardItem; var updatedAt: Date; var deletedAt: Date? }
struct RemoteReward: Sendable { var id: UUID; var updatedAt: Date; var deletedAt: Date?; var item: RewardItem? }
@MainActor protocol SyncRewardStoring: AnyObject {
    func pendingRewardsForSync(limit: Int) -> [PendingReward]
    func markRewardsSynced(_ confirmations: [UUID: Date])
    @discardableResult func applyRemoteRewards(_ remote: [RemoteReward]) throws -> [UUID]   // LWW via SyncMerge.decide, withoutStamping, saveThrowing, then enforce one-grant-per-task
}
```
`SyncEngine`: `private weak var rewardStore: SyncRewardStoring?` set in `attach(store:)` via `store as? SyncRewardStoring`;
key `volar.sync.cursorRewards`; apply rewards to disk in the same `do` block as tasks, BEFORE any cursor write;
`resyncFromScratch` clears the third key; after a successful apply of ≥1 task or reward post
`NotificationCenter.default.post(name: .volarSyncDidApplyRemote, object: nil, userInfo: ["taskIds": [UUID], "rewardIds": [UUID]])` (declare `extension Notification.Name { static let volarSyncDidApplyRemote }` in SyncContracts.swift).
`deviceId` becomes `internal` (was `private lazy var`).
`SyncAccountClient.purge()` tolerates a `rewards` count key (ignore unknown keys).

## 6. Navigation & state conventions (U-* agents)

- Each tab is its own `NavigationStack`. Rows push detail with `NavigationLink(value: task.id)` and the stack declares
  `.navigationDestination(for: UUID.self) { TaskDetailIOSView(taskId: $0) }`. Nav bar hidden on Now/Goals/Views roots (custom `ScreenHeader`); detail uses the system back button titled "Now"/"Goals".
- Environment objects available everywhere: `AppState` (`@Environment(AppState.self)`), `RewardCenter`, `OfflineCaptureCenter`.
- Dates: Now header meta = `Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())` → "Sat, Oct 4".
- NOW task = `appState.dashboardActiveTask`. NEXT = first of `appState.openTasks` whose id ≠ NOW id (ordered as the engine ranks them — good enough, note UNVERIFIED).
- Done = `appState.toggleDone(id)`; Switch = `appState.switchDashboardActiveTask()` (disabled when `!appState.canSwitchDashboardActiveTask`); Start focus = `appState.startFocus()` → `RootTabView` presents `FocusIOSView` as `.fullScreenCover(isPresented: focusActive binding)` whose dismiss calls `appState.endFocus()`.
- Task edit = `appState.updateTask(id, title:, details:, priority:, startTime:, deadline:, deadlineKind:, durationMinutes:, remindPeriod:)` (all args required; read current values from the `TaskItem`). Repeat = `appState` has `setRecurrence`? → use `store`-level API only if `AppState` exposes one; otherwise show value read-only with "Soon" and note in backlog. Delete = `appState.deleteTask(id)` then pop.
- Capture = `appState.toggleCapture()` / `captureState` machine as today (`CaptureSheet` unchanged in behavior).
- `@AppStorage("volar.view.goalRewards")` controls both the Goals tab and the GOAL REWARDS section in detail.
- `@AppStorage("volar.reminders.timeSensitive")` (default true) read by `ReminderScheduler` on iOS.

## 7. P45 — offline capture, reparse, background refresh, time-sensitive

```swift
// Shared/App/OfflineCaptureCenter.swift
struct PendingReparse: Codable, Identifiable, Sendable { let id: UUID /* task id */; let transcript: String; let capturedAt: Date }
@MainActor @Observable final class OfflineCaptureCenter {
    init()                                             // starts NWPathMonitor
    private(set) var isOnline: Bool                    // true until first callback says otherwise
    private(set) var pending: [PendingReparse]         // persisted in UserDefaults "volar.offline.pendingReparse" (JSON)
    private(set) var lastSavedOfflineAt: Date?         // Now shows "Saved. Nothing lost." for ~4s after this
    func recordOfflineSave(taskIds: [UUID], transcript: String)   // called by AppState.confirmSave hook
    func remove(_ id: UUID)
}
```
AppState hooks (P45 is the only agent editing AppState this round):
1. `var offlineCapture: OfflineCaptureCenter?` stored property + at the END of `confirmSave()` success path: if
   `router.lastRoute == .titleOnly` and `offlineCapture?.isOnline == false` → `offlineCapture?.recordOfflineSave(taskIds:transcript:)`.
   (`router` is `private let router: IntentRouter`; add an internal `var lastParseRoute: IntentRouter.Route { router.lastRoute }`.)
2. `func reparse(_ transcript: String) async -> [ParsedTask]` thin wrapper over `router.parse(transcript, now: clock(), openTaskTitles: ...)` for the review sheet.
3. `func applyReparse(taskId: UUID, parsed: [ParsedTask])` — first parsed task updates the original (title/deadline/priority/duration via `updateTask`), remaining parsed tasks become new tasks via `addTask`. Skip if the original's title no longer equals the transcript (user edited it) — then only add nothing and return false.
4. In `activateServices()`: observe `.volarSyncDidApplyRemote` → `refreshFromStore()`; for each `taskIds` id: if task done/deleted → `scheduler?.cancelReminders(taskId:)` else `scheduler?.scheduleReminders(taskId:)`; also `rewardCenterDidApplyRemote?()` closure (RewardCenter sets it to `handleRemoteApplied`).
`VolarIOSApp` (U-Shell owns the file; P45 hands U-Shell a snippet): `BGTaskScheduler` id `tech.kioh.Volar.refresh`, schedule on background, handler calls `SyncEngine.shared.requestSync(reason: .foreground)` then completes after ≤25s. Info.plist: `BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes: [fetch]`.
`ReminderScheduler.buildContent`: `#if os(iOS)` if `UserDefaults.standard.object(forKey: "volar.reminders.timeSensitive") as? Bool ?? true` and offsetKind is "at"/"-1h" → `content.interruptionLevel = .timeSensitive`. Entitlement `com.apple.developer.usernotifications.time-sensitive = true`.
`ReparseReviewSheet` (artboard Reparse-Review): header "Later" / "Tidy up N capture(s)"; quote; "BECOMES N TASKS"; rows via `DiffRow`-like simple rows (title + chips); buttons `Apply` (primary) / `Keep as I said it` (secondary). Runs `appState.reparse` on appear (one cloud call per capture — say so in the copy: "Uses one AI capture").

## 8. Self-review (every agent, in your final report)

1. Every file you touched is in your ownership row. 2. Every API you called exists in this contract or in the
code you read (quote file:line). 3. No `VolarColor`/`IOSMetrics` old tokens on new iOS screens (shared sheets
excepted). 4. Copy matches the artboard. 5. Touch targets ≥ 44pt, no emoji, no red except Delete. 6. List every
`UNVERIFIED` and anything you left out, with why.
