# Volar hero — storyboard (DRAFT, chờ anh Khôi duyệt)

> Chốt 2026-09-27: gộp "Many ways in" vào hero (16s). Chụp-màn-hình→task CHƯA ship → không đưa vào video (ghi backlog).

**Spec:** 16:9 · 1920×1080 · 30fps · **16s = 480 frame** · loop liền (frame cuối ≡ frame 0) · không tiếng
**Hướng:** A — Product loop kiểu Linear/Raycast hero. Nền `#1C1C1E`, accent duy nhất mint `#A9F5DA` / `#74DDB6`.
**Copy:** EN, outcome-first. Tagline: **Stop choosing. Start doing.**
**Luật motion:** easing spring/bezier (không linear), mỗi shot đúng 1 chuyển động có chủ đích, không fade-in-up hàng loạt, không gradient/glass/particle.

| # | Thời gian | Hình | Chữ trên màn hình | Chuyển động / chuyển cảnh | Âm thanh |
|---|---|---|---|---|---|
| 1 | 0.0–1.0s | Cửa sổ Volar tối, list mờ. Keycap `⌃ ⌥ M` nhấn xuống, popover rơi từ menubar | — | Keycap lún 2px → popover spring xuống; waveform mint bắt đầu đập ở 0.3s (hook) | — |
| 2 | 1.0–2.8s | Popover: transcript hiện từng chữ | *"Send the deck to Nam before 5, it's urgent"* (transcript, không phải caption) | Chữ gõ ra theo nhịp waveform; waveform lặng dần khi câu hết | — |
| 3 | 2.8–4.0s | Transcript co lại thành task card: title + chip `Today 5 PM` · `High` · `15m` | Caption trái: **Say it once.** | Từng chip "rút" ra từ đúng cụm chữ trong transcript (5 → `5 PM`, urgent → `High`) — cho thấy parse, không phải phép màu | — |
| 4 | 4.0–6.6s | Camera lùi ra thấy cả cửa sổ: list ~30 dòng | **Volar picks what's next.** | 30 dòng dồn dập → 29 dòng lùi mờ/co lại, 1 dòng nổi lên, thanh mint 3px + chip `NOW` bật ra | — |
| 5 | 6.6–8.8s | Task B chen ngang lên hero card; A lùi xuống thành hàng **PAUSED — «Send the deck to Nam»** dưới card, note `Stopped at slide 7 numbers`. Tick B xong → A trả về hero card, note đi kèm | **Park it. Resume right there.** | A trượt xuống thành hàng PAUSED (gác) → B tick ✓ → A trượt lên lại (resume); note đi theo A như "save game". Đúng UI đã ship (`ParkedNoteRow` trong `TodayView`) | — |
| 6 | 8.8–12.4s | **Many ways in.** Lưới 5 ô nhỏ, mỗi ô 1 mini-demo: ① `⌃⌥M` voice ② `⌃⌥T` gõ ③ bôi đen câu trong email → chuột phải → *New Task in Volar* (⚠️ `ServicesProvider` chưa verify trên Mac — hỏng thì bỏ ô này) ④ Raycast gõ `volar` ⑤ Siri/Shortcuts | **Many ways in. One list.** | Các ô bật lần lượt (so le 0.35s, không đồng loạt); ở 11.4s text từ cả 5 ô bay hội tụ vào cùng một task list ở giữa | — |
| 7 | 12.4–15.2s | UI lùi tối; giữa màn: lockup Volar (mark + wordmark) | **Stop choosing. Start doing.** | Mark mint vẽ nét ra (stroke draw) → wordmark trượt ngang ra từ sau mark; tagline hiện sau 0.4s | — |
| 8 | 15.2–16.0s | Chuyển về đúng frame 0 (cửa sổ idle) | — | Lockup mờ đi, cửa sổ idle hiện lại → loop không giật | — |

## Asset

| Asset | Shot | Trạng thái |
|---|---|---|
| Logo `design/logo/lockup.svg`, `mark.svg`, `wordmark.svg` | 7 | ✅ có |
| Token màu `Shared/Design/Theme.swift` + `design/tokens.jsx` | tất cả | ✅ có |
| UI component (TaskRow, Waveform, Popover, ParseRow, Kbd) từ prototype `design/volar-*.jsx` | 1–6 | ✅ có — **nhưng prototype là bản trước retheme 005 / sidebar kiểu Linear**, sẽ chỉnh theo Theme.swift hiện tại |
| Screenshot app thật hiện tại (Today + Parked + popover) để khớp UI đã ship | 1–5 | 🔴 thiếu — cần anh chụp trên Mac |
| Font | tất cả | ⚠️ SF Pro không được license dùng ngoài nền tảng Apple → dùng **Inter** (Google Fonts) thay |
| Icon Raycast / Siri trong ô ④⑤ | 6 | ⚠️ không dùng logo thương hiệu bên thứ ba — vẽ ô lệnh/sóng Siri trung tính + nhãn chữ |
| Nhạc | — | không cần (hero tắt tiếng) |
