# Goals & rewards — "goal = nhiều task, reward = 1..N goal" (2026-10-16, rev 2)

anh Khôi chốt 2026-10-16: Volar có goal-based. **Goal** = entity có tên + nhiều task, done khi mọi task
done. **Reward (grant)** gắn với **1 hoặc nhiều goal**, mở khi tất cả goal đó done. Thay thế D2 của
`plan.md` ("goal = task") và D-E/D-F của `implementation-contract.md`.

## Quyết định

| # | Quyết định |
|---|---|
| G1 | Bảng `rewards` có 3 kind: `catalog` (như cũ), **`goal`** (`title` = tên goal, `taskIds: [UUID]` ≥1), `grant` (`goalIds: [UUID]` ≥1 + snapshot reward như cũ). Không thêm bảng, không migration server (payload jsonb). |
| G2 | Goal done = `!taskIds.isEmpty && mọi task done`. Grant unlocked = `!goalIds.isEmpty && mọi goal còn sống đều done` (goal id không resolve → coi là chưa done). Vẫn DERIVED, không lưu. |
| G3 | Một task có thể thuộc nhiều goal (không ràng buộc). Một goal chỉ thuộc **tối đa một** grant sống; sau sync nếu một goal nằm trong 2 grant sống → giữ grant `updatedAt` mới nhất, tombstone cả grant thua. |
| G4 | Xoá goal → tombstone goal, gỡ id khỏi mọi grant sống; grant rỗng → tombstone. Xoá task → không làm gì (goal lọc id không resolve khi tính). |
| G5 | Không còn "Today's goal" toggle trên task; TaskDetail bỏ hẳn section GOAL REWARDS. Goal quản lý ở tab Goals. |
| G6 | Chỉ iOS có UI; Mac/Windows backlog. Grant cũ chỉ có `taskIds`/`taskId` (bản 1 cấp, chưa ship) coi như chết: bị lọc vì `goalIds` rỗng. |
| G7 | Wire: goal ghi `taskIds`; grant ghi `goalIds`. Giữ decode tolerant `taskId` → `taskIds` (đã có). |

## API (Shared) — chữ ký cố định

```swift
enum RewardKind: String { case catalog, goal, grant }

// RewardItem: thêm
var goalIds: [UUID]            // grant only; init param `goalIds: [UUID] = []`; CodingKeys + encode + tolerant decode
// RewardRecord: thêm `var goalIds: [UUID] = []`, apply/asItem đủ cả hai mảng.

// RewardRules
static func state(of grant: RewardItem, allGoalsDone: Bool, now: Date) -> RewardState   // như rev 1
static func isGoalDone(_ goal: RewardItem, doneTaskIds: Set<UUID>) -> Bool              // MỚI (G2)
static func duplicateGrantIDsToTombstone(_ grants: [(item: RewardItem, updatedAt: Date)]) -> [UUID] // G3: xét từng goalId

// TaskStore (RewardStore.swift)
func liveGrant(forGoal goalId: UUID) -> RewardItem?   // THAY liveGrant(for taskId:)
// liveGrantModels(): kind grant, closedAt nil, !goalIds.isEmpty

// RewardCenter
private(set) var catalog: [RewardItem]
private(set) var goals: [RewardItem]                   // MỚI: kind .goal, sống, sort createdAt
private(set) var grants: [RewardItem]                  // live + closed hôm nay, !goalIds.isEmpty
func goal(_ id: UUID) -> RewardItem?
func isDone(_ goal: RewardItem, tasks: [TaskItem]) -> Bool
func doneCount(of goal: RewardItem, tasks: [TaskItem]) -> Int   // số task done trong goal
func grant(forGoal goalId: UUID) -> RewardItem?        // THAY grant(for taskId:)
func state(of grant: RewardItem, tasks: [TaskItem], now: Date = Date()) -> RewardState  // qua goals
@discardableResult func addGoal(title: String, taskIds: [UUID]) -> RewardItem
func updateGoal(_ goal: RewardItem)                    // đổi tên / taskIds
func removeGoal(_ id: UUID)                            // G4
func attachReward(_ rewardId: UUID?, toGoals goalIds: [UUID])
   // nil → tombstone grant sống của từng goal (cancel notification); có → gỡ các goal khỏi grant khác
   // (grant khác rỗng → tombstone), tạo 1 grant mới goalIds + snapshot catalog. Luôn grant mới, không sửa grant cũ.
// BỎ: setGoal(_:_:), addGoals(_:to:), grant(for taskId:), liveGrant(for taskId:)
// startBreak/endBreak/dismissUnlocked/runningBreak/handleRemoteApplied: không đổi
```

## iOS UI

- `GoalsIOSView`: section "Goals" = card per **goal** (chưa done trước, done sau): tên goal
  (`IOSFont.rowTitle`), mono `"\(done)/\(count) tasks"`, các task rows (checkbox `appState.toggleDone`
  + title, NavigationLink detail; id không resolve thì bỏ qua), rồi dòng reward: có grant → chip reward
  (+ meta `"with \(n-1) other goal(s)"` nếu grant nhiều goal), không có → text mint "Add reward";
  bấm dòng này mở `RewardPickerSheet(goalId:)`. Grant unlocked → "Earned …" + Start timer; running →
  "On a break · ends …" (markup cũ). Long-press / nút "…" → confirmationDialog "Delete goal".
  Nút `+ New goal` → `GoalNewSheet()`. Section "Your rewards" giữ nguyên. Empty copy: "No goals yet.
  A goal is a few tasks you want to finish together."
- `GoalNewSheet` (thay `GoalTaskPickerSheet`): TextField tên goal (placeholder "Ship the landing page"),
  multi-select task từ `appState.openTasks` (checkmark), trailing "Add" enabled khi tên non-empty và
  ≥1 task; gọi `rewardCenter.addGoal(title:taskIds:)`.
- `RewardPickerSheet(goalId: UUID)` (thay `taskId`): câu hỏi "What do you get after “<goal title>”?";
  danh sách catalog như cũ; thêm section "Also needs" = multi-select các goal khác (checkmark) với
  caption "The reward unlocks when all of these are done."; Save → `attachReward(selectedId,
  toGoals: [goalId] + selectedOthers)`; onAppear: selectedId = grant(forGoal:)?.rewardId, selectedOthers =
  grant's goalIds trừ goalId.
- `RewardUnlockedSheet`: dòng DONE: 1 goal → `"DONE · <goal title>"`; N → `"DONE · \(n) GOALS"`.
- `TaskDetailIOSView`: BỎ section GOAL REWARDS, `goalRows`, `showRewardPicker`, sheet reward picker,
  `goalRewardsOn` nếu không còn dùng.
- `NowIOSView`: không đổi.

## Tests (SharedTests/RewardTests.swift)
- isGoalDone: rỗng → false; 1/2 → false; 2/2 → true.
- RewardCenter.state: grant 2 goal, goal A done, B chưa → locked; cả hai → unlocked; goal id không resolve → locked.
- dedup G3 theo goalIds.
- removeGoal: gỡ khỏi grant nhiều goal; grant 1 goal → tombstone.
- attachReward(nil) tombstone; attachReward(reward, toGoals:[A,B]) tạo grant mới, snapshot; gọi lại với
  B riêng → grant cũ còn [A], grant mới [B].
- decode legacy `taskId` → `taskIds` (giữ); round-trip giữ `goalIds` + `taskIds`.
- `SyncIntegrationTests.swift:64`: grant → `goalIds: [goalID]` (tạo goal trước hoặc UUID giả).
