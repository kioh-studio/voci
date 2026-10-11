# Plan: iOS = bản mở rộng của macOS (+ Earned break, + capture offline)

**Ngày**: 2026-10-04 · **Branch**: `macos` (trunk, không tạo branch) · **Người chốt**: anh Khôi

## 0. Định hướng (anh Khôi chốt 2026-10-04)

Mac là nơi **lên kế hoạch**, iPhone là nơi **bắt việc, làm việc và nhận thưởng**. Dữ liệu chỉ có
một bộ (sync 008). Sáu việc lõi trên iPhone:

1. Theo dõi việc phải làm trên mọi thiết bị
2. Thêm việc bất cứ lúc nào nhớ ra, **kể cả khi không có mạng**
3. Nhắc việc
4. Hoàn thành việc
5. **Nhận phần thưởng** sau khi xong (Earned break)
6. Sửa task

**Các quyết định đã chốt:**

| # | Quyết định |
|---|---|
| D1 | Earned break **lên iOS v1**. Phần thưởng do user tự đặt (tên + số phút), không dùng AI, không điểm, không coin, không bao giờ phạt hay khoá |
| D2 | Phần thưởng gắn với **một task hoặc một goal** (goal = task, có thể có task con). **KHÔNG** có kiểu thưởng "xong N việc bất kỳ"; muốn thưởng cho cả cụm việc thì gom thành goal |
| D3 | Phần thưởng có thời lượng → app **đếm giờ và nhắc** khi hết giờ nghỉ |
| D4 | Phần thưởng lưu ở **bảng riêng** `rewards`, không thêm field vào task, có đường sync riêng |
| D5 | **Bắt việc khi offline: CÓ** trong v1 |

**Không đưa lên iPhone:** Orchestrator, Triage/Sweep bản đầy đủ, sidebar kiểu Linear,
`AmbientBackground`.

## 1. Hiện trạng (đã đọc code 2026-10-04)

| Năng lực | Đang có | Còn thiếu trên iOS |
|---|---|---|
| Sync | `Shared/Sync/*` (6 file), RPC `sync_exchange` (migration 0005), toggle trong `SettingsIOSView` | Kiểm tra có sync khi `scenePhase → .active` chưa; chưa có `BGAppRefreshTask` |
| Capture | `CaptureSheet`, `MicFAB`, App Intents `AddVolarTaskIntent` / `WhatAmIDoingIntent` / `StartVolarFocusIntent` (`Shared/Intents/`) | Share Extension iOS (bản macOS ở `Volar/ShareExtension`), Control Center, Lock Screen |
| Parse offline | Router đi Cloud → FM → **title-only floor** (`IntentParsing.swift`, `lastRoute`). Offline thì câu nói **không mất**: nó thành 1 task, title là nguyên câu | Không bao giờ parse lại khi có mạng → task bị nghèo đi (không ngày giờ, không tách việc) |
| Nhắc | `ReminderScheduler`, category Done/Snooze/Tomorrow (`NotificationActions.swift`) | Escalate: iOS đã quyết định nhưng không trình bày gì (backlog). Cần time-sensitive notification |
| Hoàn thành | `AppState.toggleDone`, vuốt trên `MobileTaskCard` | Nút trên notification (kiểm tra delegate iOS), Live Activity |
| Sửa task | Chưa có `TaskDetailSheet` iOS | Sheet sửa từng field |
| Reward | Chưa có gì (grep rỗng) | Toàn bộ |

## 2. Earned break: thiết kế dữ liệu

### 2.1 Một bảng, hai loại bản ghi

Bảng `rewards` có cùng hình dạng với `tasks`: payload JSONB mờ đục, LWW theo `updated_at`, xoá bằng
tombstone `deleted_at`. Server vẫn chỉ là ống dẫn và **không đọc payload**. Client phân biệt hai
loại bản ghi bằng `payload.kind`:

```jsonc
// kind = "catalog": phần thưởng user khai một lần
{ "kind": "catalog", "title": "Chơi game", "minutes": 30 }

// kind = "grant": gắn 1 phần thưởng vào 1 task/goal
{ "kind": "grant", "taskId": "…", "rewardId": "…",
  "title": "Chơi game", "minutes": 30,            // SNAPSHOT: xoá/sửa catalog không làm hỏng grant
  "breakStartedAt": null, "breakEndsAt": null,    // null = chưa bắt đầu nghỉ
  "startedDevice": null, "closedAt": null }       // closedAt = nghỉ xong hoặc user bỏ qua
```

### 2.2 Trạng thái là SUY RA, không lưu (bất biến quan trọng nhất của plan)

```
locked    = task chưa done
unlocked  = task done  && breakStartedAt == nil && closedAt == nil
running   = breakStartedAt != nil && now < breakEndsAt && closedAt == nil
ended     = breakEndsAt <= now || closedAt != nil
```

**Vì sao:** nếu lưu `state = unlocked` thì có hai nơi cùng ghi (máy bấm xong task và máy nhận task
done qua sync) → race, và mất đồng bộ khi user bỏ tick done. Khi suy ra từ `task.status`, máy nào
cũng tự tính ra cùng một kết quả, không cần thêm bước "mở khoá" trong đường sync.

### 2.3 Luật

- **Mỗi task có tối đa 1 grant đang sống.** Merge mà ra 2 grant cho cùng task thì giữ bản có
  `updatedAt` mới nhất và tombstone bản còn lại (cách chữa giống "chỉ một frog").
- **Goal có task con:** grant mở khi task goal chuyển done, đi theo hành vi done sẵn có của task cha.
  Không viết luật riêng.
- **Bỏ tick done** → grant quay về locked. Nếu đang nghỉ dở thì giữ nguyên timer, không phạt.
- **Timer:** chỉ lưu `breakEndsAt`, không lưu số giây còn lại. Chỉ máy có
  `startedDevice == thiết bị này` mới hẹn notification hết giờ; máy khác chỉ hiện đếm ngược.
- **Add-on:** Settings có toggle "Earned break", **mặc định tắt**. Tắt thì ẩn toàn bộ UI nhưng giữ
  dữ liệu.
- **Pro:** sync reward đi cùng cổng Pro như task. Bản free chạy cục bộ đầy đủ.

### 2.4 Server: migration `0007_rewards.sql`

- `create table public.rewards`: copy cấu trúc `tasks` (PK `(profile_id, id)`, `updated_at`,
  `deleted_at`, `payload jsonb` với check object + giới hạn 8192 byte, `schema_version`,
  `origin_device`, `server_updated_at`), index `(profile_id, server_updated_at)`, bật RLS, ba policy
  select/insert/update giống `tasks`.
- `sync_exchange`: thêm tham số `p_cursor_rewards timestamptz default null` và
  `p_rewards jsonb default '[]'`. Upsert LWW giống block tasks, **không ghi `sync_rejects`** (ponytail:
  xung đột reward giá trị thấp; cần thì thêm sau). Response thêm `rewards` cùng cursor.
  ⚠️ Đổi danh sách tham số = **phải `drop function` rồi `create` lại trong cùng migration**. Nếu
  chỉ `create or replace` thì Postgres sinh thêm một overload và PostgREST báo lỗi ambiguous. Client
  cũ (macOS bản trước, Windows) vẫn chạy được vì tham số mới có default; client cũ phải **bỏ qua
  key `rewards` lạ trong response** (Sonnet kiểm decoder của `SyncClient.swift` và client .NET).
- `volar_sync_purge()`: thêm xoá `rewards`.
- 🔴 **Apply lên production = việc của anh Khôi duyệt.** Agent chỉ viết file + chạy `deno check`
  nếu có. Không tự apply.

### 2.5 Client

| File | Việc |
|---|---|
| `Shared/Model/RewardRecord.swift` (mới) | SwiftData `@Model`, cùng convention với `VolarTask` (không `.unique`, mọi property optional hoặc có default, vì sync/CloudKit) + struct thuần `Reward` / `RewardGrant` + hàm `state(task:now:)` thuần để test |
| `Shared/Model/RewardStore.swift` (mới) | CRUD + `pendingForSync` / `markSynced` / `applyRemote` theo đúng hình protocol trong `SyncContracts.swift` |
| `Shared/Sync/*` | Thêm luồng thứ ba: payload, cursor `rewards`, push/pull. **Thứ tự bắt buộc giữ nguyên: ghi đĩa xong rồi mới nhảy cursor** (design §4b) |
| `Shared/Reminders/ReminderScheduler.swift` | Hẹn / huỷ notification hết giờ nghỉ (category mới `reward-break-end`, nút "Quay lại") |
| `Shared/Views/RewardViews.swift` (mới) | `RewardPickerRow` (gắn/đổi/bỏ reward trong trang sửa task), `UnlockedRewardCard` (nút "Bắt đầu nghỉ" / "Để sau"), `BreakRunningCard` (đếm ngược bằng `Text(timerInterval:)`, nút "Xong rồi"), `RewardCatalogView` (thêm/sửa/xoá). Dùng chung cho Mac và iOS |
| `SharedTests/RewardTests.swift` (mới) | Suy ra state; 1 grant/task khi merge; bỏ tick done; chỉ máy bắt đầu mới hẹn notification |

## 3. Các phase

Mỗi phase giao Sonnet. Mỗi agent chỉ sở hữu một nhóm file riêng, không chồng nhau. Agent tự review 6
mục rồi Opus review lại toàn bộ diff. **[Win]** = code được trên Windows (chưa compile), **[Mac]** =
cần anh build/verify.

### Phase 1: Earned break, dữ liệu + sync [Win]
- **Agent S1 (server):** `supabase/migrations/0007_rewards.sql` theo §2.4.
- **Agent C1 (model):** `RewardRecord.swift`, `RewardStore.swift`, `RewardTests.swift`.
- **Agent C2 (sync):** `Shared/Sync/*`. Chạy sau C1 vì cần type của C1.
- Gate: Opus review diff + đối chiếu §2.2 / §2.3. Apply migration chờ anh Khôi.

### Phase 2: Earned break UI + trang sửa task [Win → Mac]
- **Agent U1:** `Shared/Views/RewardViews.swift` + timer trong `ReminderScheduler`.
- **Agent U2 (iOS):** `VolarIOS/Sources/Views/TaskDetailSheet.swift` (mới), sửa được giá trị từng
  field theo luật confirm 21/8, kèm `RewardPickerRow`. Gắn `UnlockedRewardCard` /
  `BreakRunningCard` lên đầu `TodayIOSView`, catalog + toggle add-on vào `SettingsIOSView`.
- **Agent U3 (Mac, tối thiểu):** gắn đúng các view dùng chung vào `TodayView` + `TaskDetailView` +
  `SettingsView`. Không làm cơ chế "Add a view" ở đợt này (backlog).

### Phase 3: Live Activity cho giờ nghỉ + focus [Mac]
- Target Widget Extension mới trong `VolarIOS/project.yml`. `ActivityAttributes` chỉ chứa dữ liệu
  tĩnh (tên, `endsAt`). **Không cần App Group**, vì app tự đẩy cập nhật qua ActivityKit.
- Cùng hạ tầng dùng cho Focus session (thay `FocusOverlay` bên Mac).

### Phase 4: Nhắc việc + theo dõi xuyên máy [Win → Mac]
- Kiểm tra / bổ sung sync khi `scenePhase → .active` (`VolarIOSApp.swift:124`).
- `BGAppRefreshTask` (~80 dòng, backlog đã có thiết kế) + `BGTaskSchedulerPermittedIdentifiers`.
- Sau `applyRemote`: re-derive reminder để **task xong ở máy khác thì huỷ chuông ở máy này**.
- Escalate trên iOS: time-sensitive notification + haptic (entitlement
  `com.apple.developer.usernotifications.time-sensitive`), thay chỗ `#if os(macOS)` đang để trống.
- Kiểm tra `UNUserNotificationCenterDelegate` trên iOS có xử lý Done/Snooze không.

### Phase 5: Bắt việc khi offline [Win → Mac]
- **Hiện trạng:** câu nói không mất (title-only floor), nhưng task bị nghèo đi.
- Khi `parse` chạy xong với `lastRoute != .cloud` **vì lỗi mạng** (không tính lý do quota hay chưa
  consent), ghi `taskID + capturedAt` vào danh sách `PendingReparse`. Danh sách này **chỉ lưu cục
  bộ** (một file JSON nhỏ hoặc `UserDefaults`), không sync.
  `ponytail: không sync — máy khác không biết task này cần parse lại; đủ cho v1 vì máy bắt việc
  thường là máy có mạng trở lại trước.`
- Khi có mạng lại (`NWPathMonitor` hoặc app vào foreground): parse lại `sourceTranscript`, rồi hiện
  **thẻ review dùng `DiffRow`**, ví dụ "Volar hiểu rõ hơn câu anh nói lúc offline". User bấm
  Áp dụng hoặc Giữ nguyên (luật "AI gợi ý, user chốt"). **Bỏ qua** task mà user đã sửa sau
  `capturedAt`.
- Mỗi lần parse lại tốn 1 call cloud và tính vào quota → ghi rõ trong copy, không chạy ngầm.
- ⚠️ **Rủi ro cần verify trên máy thật:** STT offline. `SFSpeechRecognizer` on-device có thể **không
  hỗ trợ tiếng Việt**. Nếu không hỗ trợ thì offline sẽ không ra chữ nào. Phương án lúc đó: lưu file
  audio rồi transcribe khi có mạng. Phần này lớn hơn, **chưa nằm trong scope** đến khi verify xong.

### Phase 6: Bắt việc ở mọi nơi [Mac]
- Share Extension target iOS (tham khảo `Volar/ShareExtension`) → mở `volar://capture`.
- Control Center control (iOS 18, `@available`) + nút mic trên Lock Screen widget.
- Kiểm tra `VolarShortcuts` đã compile vào target iOS, để Siri / Action Button chạy được.

### Phase 7: Widget NOW [Mac]: cần App Group
- Dời SwiftData container vào App Group. Có copy-nếu-tồn-tại cho bản cài dev hiện có.
  **Phải làm trước khi có user thật.**
- Widget Home Screen + Lock Screen hiện task NOW, có nút Done (interactive widget iOS 17).

## 4. Rủi ro

| Rủi ro | Chặn bằng |
|---|---|
| `drop function sync_exchange` làm gãy client đang chạy trong khoảng giữa drop và create | Drop + create trong **cùng một transaction** migration |
| Client cũ crash vì key `rewards` lạ trong response | C2 kiểm tra decoder; tolerance theo từng batch đã là convention của `SyncClient.swift` |
| Hai máy cùng bấm "Bắt đầu nghỉ" | LWW: bản `updatedAt` mới nhất thắng; máy thua tự huỷ notification của mình khi nhận remote |
| Reward bị dùng thành công cụ tự phạt | Không có UI nào khoá hay phạt; copy luôn trung tính |
| Toàn bộ code Swift viết mù trên Windows | Checklist verify Mac ở cuối mỗi phase, ghi vào backlog |

## 5. Ngoài scope đợt này → backlog

Cơ chế "Add a view" trên sidebar Mac · nút "thêm 5 phút" khi hết giờ nghỉ · sửa task bằng giọng ·
ghi âm cuộc họp → action items · STT offline bằng audio lưu tạm · watchOS (chờ sync, đúng thứ tự
đã chốt).
