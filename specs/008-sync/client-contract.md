# 008 — Client seam contract (v1)

> Opus, 2026-08-10. Viết TRƯỚC khi chia việc, để bốn agent song song không tự đặt tên khác nhau cho
> cùng một thứ. **Đây là hợp đồng, không phải gợi ý.** Mọi chữ ký trong file này là VERBATIM: agent
> nào cần đổi thì phải dừng lại và báo, không tự sửa.
>
> Nguồn: `specs/008-sync/design.md` (thiết kế, anh Khôi đã duyệt) + `supabase/migrations/0005_sync_schema.sql`
> (chữ ký RPC thật). Khi file này và design.md khác nhau ở chi tiết implement, file này thắng — nó
> chỉ cụ thể hoá, không đảo quyết định nào.
>
> **Client không đổi một dòng code chạy nào vì schema đổi tên (2026-08-10).** `0005` đổi
> `sync_tasks`/`sync_completions` → `public.tasks`/`public.completions`, thêm bảng `public.profiles`,
> và đổi cột `user_id` → `profile_id` trên cả năm bảng — nhưng cả 7 chữ ký RPC dưới đây (tên hàm, tên
> tham số, hình dạng JSON request/response) và tên bảng `sync_rejects` mà client `select` thẳng qua
> PostgREST đều **giữ nguyên**. `profile_id` là chuyện thuần server: vì `profiles.id = auth.uid()`,
> mọi RLS policy so trực tiếp `(select auth.uid()) = profile_id`, không có join nào client cần biết.
>
> ⚠️ Toàn bộ Swift dưới đây **UNVERIFIED** — máy dev là Windows, không có Swift/Xcode.

---

## 0. Ai sở hữu file nào

| Nhóm | File được sửa/tạo | KHÔNG được đụng |
|---|---|---|
| **A** Model + persistence | `Shared/Model/VolarTask.swift`, `Shared/Model/TaskStore.swift`, `Shared/Model/CompletionLog.swift` | mọi file khác |
| **B** Sync engine | `Shared/Sync/SyncContracts.swift`, `SyncPayload.swift`, `SyncMerge.swift`, `SyncClient.swift`, `SyncEngine.swift` | mọi file khác |
| **C** Toggle + UI | `Shared/Sync/SyncAccountState.swift`, `Shared/Views/SyncEnableSheet.swift`, `Shared/Views/SyncRejectsView.swift`, `Shared/App/AppState.swift`, `Volar/Sources/Views/SettingsView.swift`, `VolarIOS/Sources/Views/SettingsIOSView.swift` | mọi file khác |
| **D** Test | `SharedTests/Sync*Tests.swift` (file mới) | mọi file khác |

`backlog.md` do Opus ghi, **không agent nào sửa** — báo việc dở về trong report.

`Volar/project.yml` và `VolarIOS/project.yml` dùng tham chiếu cả-cây (`- path: ../Shared`,
`- path: ../SharedTests`) nên **file mới tự được biên dịch, không cần sửa project.yml**.

---

## 1. Ba luật không được vi phạm

1. **Đẩy hỏng KHÔNG BAO GIỜ đụng dữ liệu local.** Không rollback, không revert cờ, không xoá hàng.
   Thất bại = no-op, hàng vẫn `pending`, lần sau gom lại. (design §7)
2. **`sync_pro_required` / `sync_disabled` / lỗi mạng là BA thứ khác nhau.** Không có kiểu enum nào
   gộp chúng, không có chuỗi "sync lỗi" nào phủ cả ba. (design §8.2)
3. **`updatedAt` đóng dấu ở ĐÚNG MỘT chỗ: `TaskStore.save()`.** Không mutator nào tự gán
   `updatedAt = Date()`. (design §7)

---

## 2. `Shared/Sync/SyncContracts.swift` — B tạo, chép VERBATIM

Đây là các kiểu ba nhóm cùng dùng. **Không logic, không mạng, không SwiftData.** B tạo file này
trước tiên; A và C chỉ đọc/dùng, không định nghĩa lại.

```swift
// Shared/Sync/SyncContracts.swift — the seam every sync group codes against.
//
// UNVERIFIED: written on Windows, never compiled. Types only — no networking, no SwiftData, no
// SwiftUI, so this file compiles on macOS, iOS and (later) watchOS identically.
//
// Pinned by `specs/008-sync/client-contract.md` §2. Changing a name or a field here silently
// breaks a sibling file owned by a different agent — change the contract doc first.
import Foundation

/// One local task waiting to be pushed. Built by `TaskStore.pendingForSync()` (group A), consumed
/// by `SyncEngine` (group B). Carries `TaskItem` rather than the `@Model` on purpose: the wire
/// shape must never be a live SwiftData object crossing an actor boundary.
struct PendingTask: Sendable {
    var item: TaskItem
    /// The task's logical clock — the value stamped by `TaskStore.save()`. Never `Date()` read here.
    var updatedAt: Date
    /// Non-nil = tombstone. The payload is still sent in full (design §6: a later edit may revive it).
    var deletedAt: Date?
}

/// One remote task the server says we should apply. Produced by `SyncEngine` after decoding the
/// wire payload, consumed by `TaskStore.applyRemote(_:)` (group A).
struct RemoteTask: Sendable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    /// `nil` only when the payload was unreadable (schema skew, corrupt row). A `nil` item with a
    /// non-nil `deletedAt` is still applicable — a tombstone needs no content.
    var item: TaskItem?
}

/// One local completion event waiting to be pushed. `CompletionEvent` is append-only, so there is
/// no `updatedAt` and no conflict — see `completions` in 0005.
struct PendingCompletion: Sendable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?
}

/// One remote completion to insert locally if absent. Same shape as `PendingCompletion` — the
/// separate type exists so a reader never has to ask which direction a value is travelling.
struct RemoteCompletion: Sendable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?
}

/// The THREE outcomes of §8.2, kept apart by the type system so no call site can accidentally
/// collapse them into "sync failed". Every UI string for these lives in group C; this enum carries
/// no copy of its own beyond `LocalizedError` fallbacks.
enum SyncFailure: Error, Equatable, Sendable {
    /// 403 + message `sync_pro_required`. The account is not Pro (or Pro lapsed).
    case proRequired
    /// 403 + message `sync_disabled`. The account-level toggle is OFF. **This is not an error** —
    /// it is a state. UI shows "Sync is off for this account" plus a way to turn it on.
    case disabled
    /// 401 + message `sync_not_authenticated`, or no local session at all.
    case signedOut
    /// Transport failure: offline, timeout, DNS, TLS. **Silent** — the UI shows nothing.
    case offline(String)
    /// Anything else the server said (5xx, malformed body, unexpected status). Retried later,
    /// surfaced only in the diagnostics row — never as a banner.
    case server(status: Int, message: String?)
}

/// Server truth about the account-level switch. Decoded from `volar_sync_state()` (and returned by
/// `volar_set_sync_enabled`). Group C owns fetching it; group B reads it after any 403.
struct SyncState: Sendable, Equatable, Codable {
    var isPro: Bool
    var syncEnabled: Bool
    var enabledAt: Date?
    var enabledByDevice: String?
    var devices: [SyncDevice]

    static let unknown = SyncState(
        isPro: false, syncEnabled: false, enabledAt: nil, enabledByDevice: nil, devices: []
    )
}

struct SyncDevice: Sendable, Equatable, Codable, Identifiable {
    var deviceId: String
    var label: String?
    var lastSeen: Date?

    var id: String { deviceId }
}

/// One losing record kept in `public.sync_rejects` — design §5's black box. Read-only in v1.
struct SyncReject: Sendable, Equatable, Identifiable {
    var id: UUID
    var taskId: UUID
    var updatedAt: Date
    var rejectedAt: Date
    var originDevice: String?
    /// The losing payload verbatim, pretty-printed. Kept as a string, not a decoded `TaskItem`:
    /// this row exists precisely because the shape may be from another build.
    var payloadJSON: String
    /// Best-effort title lifted out of the payload for the list row; `nil` if unreadable.
    var title: String?
}

/// The seam `SyncEngine` (B) uses to reach persistence (A) without importing SwiftData itself.
/// `TaskStore` declares conformance inside `TaskStore.swift`; every method below is implemented
/// there. `@MainActor` because `TaskStore` is.
@MainActor
protocol SyncTaskStoring: AnyObject {
    /// Every row with `isPendingSync == true`, oldest `updatedAt` first, capped at `limit`.
    /// INCLUDES tombstones (`deletedAt != nil`) — a delete is just another pending edit.
    func pendingForSync(limit: Int) -> [PendingTask]
    /// Marks rows as confirmed by the server: sets `syncedAt = confirmedUpdatedAt` for each id.
    /// A row edited again in the meantime stays pending because its `updatedAt` moved past this.
    func markSynced(_ confirmations: [UUID: Date])
    /// Applies a batch of remote rows under LWW. MUST NOT re-stamp `updatedAt` (see §4).
    /// Returns the ids it actually wrote (for logging/tests); rows that lost LWW are skipped.
    /// THROWS if the write to disk failed — the caller MUST NOT advance the cursor in that case
    /// (see §4b). Swallowing this is silent permanent data loss with no crash involved.
    func applyRemote(_ remote: [RemoteTask]) throws -> [UUID]
    /// Append-only completions still to push, oldest first, capped at `limit`.
    func pendingCompletions(limit: Int) -> [PendingCompletion]
    func markCompletionsSynced(_ ids: [UUID])
    /// Inserts any completion whose id is not already present. Never updates an existing row.
    /// THROWS on a failed disk write, same contract as `applyRemote` above (see §4b).
    func applyRemoteCompletions(_ remote: [RemoteCompletion]) throws -> Int
}
```

---

## 3. Chữ ký RPC — khớp `0005_sync_schema.sql`, không được đoán

Base URL và apikey đã có sẵn trong `Shared/Account/AccountService.swift`
(`https://cjaamylayaylbuuhwlnz.supabase.co`, `sb_publishable_...`). Token lấy qua
`AccountService.shared.validAccessToken()`.

Mọi RPC: `POST /rest/v1/rpc/<tên>`, headers `apikey: <publishable>`,
`Authorization: Bearer <access_token>`, `Content-Type: application/json`.

### 3.1 `sync_exchange`

Body — **tên tham số phải đúng từng ký tự**:

```json
{
  "p_cursor_tasks": "2026-08-09T10:00:00.123456+00:00" | null,
  "p_cursor_completions": "…" | null,
  "p_device": "<uuid ổn định của máy>",
  "p_device_label": "MacBook Pro · macOS",
  "p_tasks": [ { "id": "<uuid>", "updatedAt": "<iso>", "deletedAt": "<iso>"|null,
                 "payload": { … }, "schemaVersion": 1 } ],
  "p_completions": [ { "id": "<uuid>", "taskId": "<uuid>", "completedAt": "<iso>",
                       "payload": { … } } ],
  "p_limit": 500
}
```

200 → thân trả về:

```json
{
  "cursorTasks": "<iso>"|null,
  "cursorCompletions": "<iso>"|null,
  "tasks": [ { "id", "updatedAt", "deletedAt", "payload", "schemaVersion",
               "serverUpdatedAt", "originDevice" } ],
  "completions": [ { "id", "taskId", "completedAt", "payload", "serverUpdatedAt" } ],
  "hasMore": true|false,
  "rejected": [ "<uuid>", … ]
}
```

**`hasMore == true` ⇒ gọi lại NGAY với cursor mới**, đừng đợi chu kỳ sau. Giới hạn số vòng lặp
liên tiếp ở **20** để một server hỏng không quay vòng vô hạn.

🔴 **`payload` mang `isSensitive`, và nó KHÔNG đến từ `TaskItem`** (bổ sung 2026-08-10, design §3.1).
`isSensitive` chỉ sống trên `VolarTask` — `TaskItem` không mang nó, cố ý. Nên `PendingTask` và
`RemoteTask` (§2) chở cờ này **song song với `item`**, và `TaskPayload` phải có nó như một field
riêng. Quên chỗ nào trong chuỗi đó là task "đừng đọc to" sang máy khác bị **đọc to tiêu đề thật**.

**Decode thiếu key `isSensitive` ⇒ `true`** (`decodeIfPresent(...) ?? true`), ngược hẳn với
`TaskStore.isSensitive(_:)` dùng `?? false` cho đường local. Hai hướng mặc định **cố ý lệch nhau** —
bảng lý do đầy đủ ở design §3.1. Đừng thống nhất chúng.

### 3.2 Ba RPC còn lại

| RPC | Body | Trả về |
|---|---|---|
| `volar_sync_state` | `{}` | JSON của `SyncState` (§2) |
| `volar_set_sync_enabled` | `{"p_enabled": true|false, "p_device": "<label>"|null}` | JSON của `SyncState` |
| `volar_sync_purge` | `{}` | `{"deletedTasks": n, "deletedCompletions": n}` |

`volar_sync_state` **không bị gate** — gọi được kể cả khi hết Pro / đã tắt sync. Đó là cả lý do nó
tồn tại. Client gọi nó: lúc khởi động, lúc vào foreground, và **sau MỌI 403**.

Đọc `sync_rejects` là truy vấn PostgREST thường, không phải RPC:
`GET /rest/v1/sync_rejects?select=id,task_id,updated_at,payload,origin_device,rejected_at&order=rejected_at.desc&limit=200`

### 3.3 Phân loại lỗi — bảng tra duy nhất

PostgREST đặt nguyên văn `message` của `raise exception` vào `body.message`.

| HTTP | `body.message` | → `SyncFailure` | UI |
|---|---|---|---|
| 403 | `sync_pro_required` | `.proRequired` | "Sync là tính năng Pro" + đường nâng cấp |
| 403 | `sync_disabled` | `.disabled` | "Sync đang tắt cho tài khoản này" + nút bật. KHÔNG phải lỗi |
| 401 | `sync_not_authenticated` | `.signedOut` | mời đăng nhập |
| — | `URLError`, không có HTTP response | `.offline(...)` | **không hiện gì cả** |
| khác | bất kỳ | `.server(status:message:)` | chỉ hiện trong dòng chẩn đoán |

Sau `.proRequired` và `.disabled`: **bắt buộc** gọi `volar_sync_state()` rồi cập nhật UI từ kết quả
thật, không suy đoán từ mã lỗi.

---

## 4. Cái bẫy chết người: `applyRemote` không được đóng dấu lại `updatedAt`

Design §7 chốt `TaskStore.save()` đóng dấu `updatedAt = Date()` cho mọi model vừa đổi. Nhưng
`applyRemote` cũng ghi qua `save()` — nếu không chặn, **mọi hàng vừa kéo về lập tức thành "mới hơn
bản server" và bị đẩy ngược lên**, LWW hỏng hoàn toàn, hai máy đẩy qua đẩy lại vô hạn. Chỗ này
design.md không nói tới; đây là bổ sung bắt buộc:

```swift
// Trong TaskStore:
/// True chỉ trong lúc `applyRemote`/backfill đang chạy. `save()` BỎ QUA việc đóng dấu khi cờ này
/// bật — nếu không, mỗi hàng kéo về sẽ tự nhận `updatedAt = now` và bị đẩy ngược lên ngay, làm
/// LWW đảo chiều và hai máy ping-pong vô hạn.
private var suppressStamp = false

private func withoutStamping(_ body: () -> Void) {
    suppressStamp = true
    defer { suppressStamp = false }
    body()
}

private func save() {
    if !suppressStamp {
        let stamp = Date()
        for model in context.insertedModelsArray + context.changedModelsArray {
            (model as? VolarTask)?.updatedAt = stamp
        }
    }
    try? context.save()
}
```

Ba đường phải chạy trong `withoutStamping`: `applyRemote`, `applyRemoteCompletions`, và **backfill**
`updatedAt` một lần cho user cũ (backfill đặt `= completedAt ?? createdAt`; đóng dấu lại thành `now`
sẽ biến cả kho thành "vừa sửa xong").

`markSynced` cũng chỉ đụng `syncedAt` — phải chạy trong `withoutStamping`, nếu không nó tự làm hàng
bẩn trở lại ngay sau khi vừa xác nhận sạch.

> ⚠️ `context.insertedModelsArray` / `changedModelsArray` là API SwiftData **UNVERIFIED** trên
> macOS 14 / iOS 17. Đường lui viết sẵn (design §7): helper `private func touch(_ model: VolarTask)`
> gọi tường minh ở 12 mutator. Nếu Mac báo API không tồn tại thì đổi sang đường lui — **không đổi
> sang "rải `updatedAt = Date()` khắp nơi"**.

---

## 4b. Thứ tự bắt buộc: ghi đĩa XONG rồi mới nhảy cursor

```
nhận response → applyRemote + applyRemoteCompletions → save() THÀNH CÔNG → rồi mới ghi cursor
```

Cursor nghĩa là *"tôi đọc tới đây rồi, đừng gửi lại nữa"*. Nhảy cursor trước khi dữ liệu nằm trên
đĩa là tự khai một lời nói dối không rút lại được — lần sau server không trả lại những hàng đó nữa.
**Mất vĩnh viễn, im lặng.** Hai đường dẫn tới đó, chặn cả hai:

1. **App bị kill giữa chừng** (iOS đình chỉ rất nhanh khi vào background, đúng lúc chu kỳ 30 giây
   vừa chạy) → chặn bằng đúng thứ tự trên.
2. **`context.save()` ném lỗi mà không ai nghe.** `TaskStore.save()` viết `try? context.save()` —
   nuốt lỗi. ⇒ `applyRemote`/`applyRemoteCompletions` **phải `throws`**, và engine phải coi đó là
   một lượt thất bại: **không nhảy cursor, không xoá `lastFailure`**. Đây là ca **không cần crash
   nào cả** vẫn mất dữ liệu.

Khoảng chồng lấn 2 giây (§4 design) **không cứu được** — nó chỉ lùi 2 giây, vá khe commit của
transaction, không vá khe crash.

**Không nhét cursor vào cùng transaction SwiftData.** Cursor ở `UserDefaults`, không tham gia
`ModelContext` transaction được; muốn nguyên tử thật thì phải biến nó thành một `@Model` + thêm một
migration. Cái giá đó mua về đúng một thứ: khỏi **kéo lại** vài hàng — mà kéo lại thì vô hại, LWW
idempotent. Với thứ tự đúng, **mọi khe crash rơi về phía an toàn (kéo thừa), không khe nào rơi về
phía bỏ sót.**

---

## 5. Soft-delete: năm `FetchDescriptor` phải lọc, hai chỗ thì không

`TaskStore.delete(_:)` đổi `context.delete(target)` → `target.deletedAt = now` (giữ nguyên phần dọn
tham chiếu `.taskDone` và `parentId` của con, giữ nguyên `eligibilityDiff`).

Lọc `deletedAt == nil` ở: `fetchModel`, `fetchAllModels`, `fetchChildren`, `hasChildren`, và
predicate trong `delete`.

**KHÔNG lọc** ở hai đường sync — chúng phải nhìn thấy tombstone:
- `pendingForSync()` — tombstone là thứ cần đẩy đi nhất.
- một helper mới `fetchModelIncludingDeleted(_:)` cho `applyRemote`, để một bản sửa mới hơn từ máy
  khác **hồi sinh** được task đã tombstone local (design §6: giữ thừa hơn nuốt mất).

Dọn tombstone local sau 30 ngày (design §6): làm trong `fetchAll()`, cùng chỗ với backfill, chạy
trong `withoutStamping`. `context.delete` thật ở đây là đúng — 30 ngày sau thì không máy nào còn
cần biết nữa.

---

## 6. Ngày tháng trên dây

- **Cursor là CHUỖI MỜ.** Không bao giờ parse `cursorTasks`/`cursorCompletions` thành `Date`. Lưu
  nguyên văn vào `UserDefaults`, gửi lại nguyên văn. Postgres trả timestamptz có 6 chữ số thập
  phân; đi vòng qua `Date` là mất độ chính xác và cursor nhảy sai.
- ⚠️ **Ngoại lệ DUY NHẤT, thêm 2026-08-10 (design §6.1 van 1):**
  `SyncMerge.cursorAfterStalenessCheck(_:now:)` được parse cursor — **chỉ để trả lời "cái này đã cũ
  hơn `cursorMaxAgeDays` chưa"**, không bao giờ để serialize lại. Chuỗi đi lên dây vẫn luôn là chuỗi
  gốc nguyên văn, hoặc `nil`. Đó là lý do ngoại lệ này không phạm vào lý do của luật ở trên. **Đừng
  mở rộng nó**: mọi nhu cầu "so sánh cursor" khác vẫn phải đi qua `SyncMerge.nextCursor` (so lexical).
- `updatedAt`/`deletedAt`/`completedAt` thì **phải** parse (LWW cần so sánh). B viết đúng một cặp
  helper trong `SyncPayload.swift`, không ai hand-roll cái thứ hai:

```swift
enum SyncDate {
    /// Postgres emits up to 6 fractional digits; `ISO8601DateFormatter` accepts at most 3 and
    /// rejects the rest outright, so trim before parsing rather than losing the whole value.
    static func parse(_ s: String) -> Date?
    /// Always emits exactly 3 fractional digits + `Z`. Postgres accepts it verbatim.
    static func string(from date: Date) -> String
}
```

---

## 7. Khoá `UserDefaults` (B sở hữu, không ai khác ghi)

| Khoá | Nội dung |
|---|---|
| `volar.sync.deviceId` | UUID sinh một lần cho máy này |
| `volar.sync.cursorTasks` | chuỗi mờ |
| `volar.sync.cursorCompletions` | chuỗi mờ |
| `volar.sync.lastSuccessAt` | `Date` — chỉ để hiển thị "đồng bộ lần cuối" |

Nhãn máy: **`"<model> · <os> · <4 ký tự đầu của deviceId>"`** — `"Mac · macOS · A3F9"`,
`"iPhone · iOS · A3F9"`. Phải nằm trong `#if os(...)` (luật `Shared/`).

🔴 **KHÔNG BAO GIỜ để tên máy do người dùng đặt vào chuỗi này** (sửa 2026-08-10, trước đó sai).
Nhãn này đi lên `sync_devices.label`, gắn với `profile_id`, **giữ vô thời hạn** — thứ gì rơi vào đây
là dữ liệu cá nhân nằm nghỉ trên server, và `docs/app-store-privacy.md` khai `Contact Info › Name:
No` **dựa hẳn vào property này**.

- **macOS là chỗ đã sai.** `Host.current().localizedName` trả tên máy do user đặt, mà macOS mặc định
  đặt theo tên chủ tài khoản ("MacBook Pro của Khôi") ⇒ **tên người** lên server. Đổi thành hằng
  `"Mac"`.
- **iOS thì chưa bao giờ sai**, nhưng vẫn đổi từ `.name` sang `.model`. Từ iOS 16 `.name` tự suy
  giảm về tên model nếu app không xin entitlement `com.apple.developer.device-information.
  user-assigned-device-name` (Volar không xin, target iOS 17) — nhưng dựa vào điều đó nghĩa là ngày
  nào đó ai thêm entitlement ấy thì chỗ này **lặng lẽ** thành chỗ rò tên. `.model` thì theo tài liệu
  không bao giờ mang tên người ⇒ bảo đảm bằng **cấu trúc**, không bằng trí nhớ.
- **Hậu tố 4 ký tự** để hai máy cùng model không trùng nhãn trong Settings. Nó **không lộ thêm gì**:
  đó là 4 ký tự đầu của `deviceId`, một UUID ngẫu nhiên do app tự sinh mà server vốn đã nhận đủ qua
  `p_device`.

---

## 8. Lịch chạy (design §7) — `SyncEngine` tự lo, KHÔNG rải vào AppState

`SyncEngine` tự đăng ký observer và tự hẹn giờ:
- app vào foreground (`NSApplication.didBecomeActiveNotification` / `UIApplication.didBecomeActiveNotification`)
- sau mỗi lần sửa: `requestSync(reason:)` gộp bằng debounce ~2 giây
- **mỗi ~30 giây khi app đang FOREGROUND** (anh Khôi sửa 2026-08-10, design §7 — trước đó là 5 phút;
  5 phút thì máy A bấm xong mà máy B vẫn thấy task nằm đó, và người dùng đọc điều đó thành "app
  không ăn")

Ba ràng buộc của chu kỳ 30 giây, không được bỏ sót:

1. **Chỉ foreground.** Xuống background thì **huỷ timer**, không để nó sống tiếp. Thiếu cái này thì
   30 giây thành cỗ máy đốt pin.
2. **Không áp cho watch** — watch giữ activate-based. LTE + poll 30s = hết pin trước bữa trưa.
3. **Backoff, làm trong v1.** Sau **4 lượt liên tiếp không có gì mới** thì nhân đôi (30 → 60 → 120 →
   240, **trần 300 giây**); gặp `.offline` thì lùi ngay một nấc. **Reset về 30 giây ngay** khi:
   user sửa gì đó local · app vừa vào foreground · lượt vừa rồi kéo về được thay đổi thật · mạng
   vừa khôi phục (`.networkRestored`) · user bấm "Re-sync from scratch" (`.manualResync`). Máy đang
   được dùng thì luôn ở 30 giây; chỉ máy mở-rồi-bỏ-đó mới trôi ra xa.

AppState gọi đúng ba thứ: `SyncEngine.shared.attach(store:)` một lần lúc có `TaskStore`,
`SyncEngine.shared.requestSync(reason: .localEdit)` sau khi ghi, và
`SyncEngine.shared.resyncFromScratch()` khi user bấm nút ở Settings (đi qua
`AppState.resyncFromScratch()`). Không realtime, không websocket, không APNs (design §12).

### 8.0 Gate ở client TRƯỚC khi dựng request (bổ sung 2026-08-10)

Bản đầu không có gate nào ở client: `SyncEngine` gắn vô điều kiện và poll, nên **user free đã đăng
nhập** — hoặc user Pro **cố ý tắt công tắc** — vẫn đẩy payload task, **gồm `sourceTranscript` tức
nguyên văn lời họ nói**, lên server. Server raise `sync_pro_required`/`sync_disabled` và abort nên
không lưu gì, nhưng **dữ liệu đã rời khỏi máy** — đúng cái màn xác nhận ở design §8.1 hứa sẽ không
xảy ra. Đây là lỗi riêng tư, không phải lỗi hiệu năng.

`SyncMerge.gate(state:) -> SyncGate` (hàm thuần) trả **ba** kết quả, và `runSyncRound` xử lý ngay
sau `guard let store`, **trước khi gom outbox và trước khi dựng bất kỳ request nào**:

| `SyncGate` | Khi nào | Làm gì |
|---|---|---|
| `.allowed` | state đã biết, Pro **và** công tắc bật | chạy bình thường |
| `.blocked(.proRequired)` / `.blocked(.disabled)` | state đã biết, một điều kiện đóng | đặt `lastFailure` **đúng bằng giá trị mà 403 sẽ tạo ra**, rồi dừng — UI không có nhánh mới nào |
| `.unknown` | **chưa bao giờ** lấy được `volar_sync_state()` | **im lặng tuyệt đối**: không gửi gì, và **KHÔNG đặt `lastFailure`** |

Bốn luật của gate này, thiếu cái nào là đổi lỗi này lấy lỗi khác:

1. 🔴 **`volar_sync_state()` KHÔNG được gate.** Nó là đường duy nhất để biết trạng thái đã đổi (vừa
   mua Pro ở máy khác, vừa bật công tắc ở iPhone). Gate luôn cả nó là client **tự nhốt mình vĩnh
   viễn**. `currentGate()` gọi thẳng nó khi cache còn rỗng, và `handleForeground()` cũng gọi — đúng
   ba thời điểm design §8.2 đã quy định (khởi động · foreground · sau mọi 403), trong đó engine
   trước đây mới làm mỗi cái cuối.
2. 🔴 **Chưa biết thì KHÔNG được đoán.** `.unknown` ≠ "chưa có Pro". Một máy offline chưa học được
   gì về tier của user thì không được nói ngược lại. Nó cũng không được đặt `lastFailure` — làm thế
   là biến "chưa kịp hỏi" thành một vấn đề mà user tưởng mình phải xử lý.
3. 🔴 **Server vẫn là quyền cuối.** Gate này **chỉ có thể TỪ CHỐI**, không bao giờ cho phép thứ mà
   server sẽ chặn. Toàn bộ đường xử lý 403 giữ nguyên không sửa một dòng; hai bên lệch nhau (VD Pro
   vừa hết hạn ở máy khác, cache còn cũ) thì server thắng và `handleFailure` refetch state đã tự
   sửa cache ngay lượt đó.
4. **Thứ tự kiểm Pro TRƯỚC công tắc**, khớp thứ tự hai `raise exception` trong `sync_exchange` — để
   một tài khoản vừa hết Pro vừa tắt công tắc không bị hai bên báo hai lý do khác nhau.

Cache sống ở `SyncAccountClient.cachedState` (chứ không ở `SyncEngine`) vì đó là chỗ duy nhất gọi
`volar_sync_state`; để ở engine là đẻ ra bản sao thứ hai có thể lệch. **Không xoá cache khi fetch
hỏng** — một câu trả lời cũ mà thật vẫn tốt hơn `.unknown`, và `.unknown` nghĩa là "chưa bao giờ
hỏi được", không phải "lần hỏi vừa rồi hỏng".

**Lợi ích phụ, không phải mục tiêu:** user free giờ tốn **0 request `sync_exchange`** mỗi 30 giây
thay vì một request mang toàn bộ outbox.

### 8.1 Van 2 — "Re-sync from scratch" (design §6.1, bổ sung 2026-08-10)

`SyncEngine.resyncFromScratch()` làm **đúng ba việc**: tăng `cursorEpoch`, xoá
`volar.sync.cursorTasks` + `volar.sync.cursorCompletions`, rồi `requestSync(reason: .manualResync)`.
Nó **không** tự chạy một lượt sync riêng và **không** đụng vào bất cứ thứ gì khác.

🔴 **Không xoá dữ liệu local. Không xoá cờ pending. Không xoá `syncedAt`.** Cái chạy sau đó là một
lượt sync bình thường với cursor `nil`; LWW phân xử từng hàng như mọi lượt khác. "Xoá rồi tải lại"
là một tính năng KHÁC và không ai được lặng lẽ biến nút này thành nó.

**`cursorEpoch` giải quyết ca đua duy nhất của van này.** Bấm nút trong lúc một lượt đang bay: lượt
đó đã gửi cursor CŨ, nên cursor nó mang về mô tả một trang bắt đầu từ vị trí cũ; ghi lại là **huỷ
mất lần reset mà không có tín hiệu nào cho người dùng**. Nên: `runOneExchange` chụp `cursorEpoch`
ngay dòng đầu, và **chỉ ghi cursor khi giá trị chưa đổi**. `markSynced` / `markCompletionsSynced` /
`lastSuccessAt` **nằm ngoài** guard đó — chúng mô tả việc đã thật sự xảy ra, không phụ thuộc epoch.
Van 1 **không** cần epoch: `trustedCursor` xoá khoá lúc DỰNG request, nên lượt đó thật sự đã gửi
`nil` và cursor nó mang về là hợp lệ.

Nút ở **cả hai** `Volar/Sources/Views/SettingsView.swift` và
`VolarIOS/Sources/Views/SettingsIOSView.swift`, chỉ hiện khi `syncState.syncEnabled`, **cùng một câu
chữ** (chỉ khác danh từ máy: "this Mac" / "this iPhone"), **không có hộp thoại xác nhận** — hành
động vô hại theo cấu trúc và dòng chú thích dưới nút nói thẳng điều đó cùng với việc nó có thể lâu
nếu nhiều task.

---

## 9. Đợt này KHÔNG làm (design §12) — agent nào lấn sang là sai phạm vi

Không merge theo field · không operation log/CRDT · không realtime · không sync `ParseCorrection`,
settings, focus session, `ReminderPolicy` toàn cục, `ReminderRecord` · không UI xung đột · không
E2EE · không client .NET · không promote cột khỏi `payload` · không apply migration, không deploy,
không đụng database production · không gỡ `@Attribute(.unique)`.

**Ngoại lệ duy nhất Opus thêm vào:** phải có **một đường xem `sync_rejects`** (group C). Một bảng
giữ bản thua mà người dùng không mở được thì chẳng khác gì đã mất — mà cả thiết kế này dựng lên
quanh lời hứa "không bao giờ nuốt mất việc".

---

## 10. Rewards stream (011-ios-companion, 2026-10-11)

`sync_exchange` gains a THIRD stream, mirroring tasks (LWW via `SyncMerge.decide`, no `sync_rejects` row):

- Request: `p_cursor_rewards` (opaque string, same rules as §6) and `p_rewards`: `[{ id, updatedAt, deletedAt?, payload, schemaVersion: 1 }]`; `payload` is the `RewardItem` JSON (catalog and grant rows share one table, `kind` tells them apart).
- Response: `cursorRewards` and `rewards: [{ id, updatedAt, deletedAt, payload, schemaVersion, serverUpdatedAt, originDevice }]`. A response WITHOUT these keys (older server) decodes as `cursorRewards == nil`, `rewards == []`.
- Client: `SyncRewardStoring` (`SyncContracts.swift`) is implemented by `TaskStore`; `SyncEngine` applies rewards in the SAME `do` block as tasks (disk before cursor, §4b), stores the cursor under `volar.sync.cursorRewards` (cleared by `resyncFromScratch`), and guards it with the same `cursorEpoch`.
- After a round applied >= 1 task or reward the engine posts `Notification.Name.volarSyncDidApplyRemote` with `userInfo: ["taskIds": [UUID], "rewardIds": [UUID]]`.
- `volar_sync_purge` may return an extra rewards count; the client ignores unknown keys.
- `SyncEngine.deviceId` is internal (RewardCenter stamps `startedDevice`).
