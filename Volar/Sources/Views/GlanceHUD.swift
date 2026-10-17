// Sources/Views/GlanceHUD.swift — ⌃⌥N "what am I doing?", answered without leaving the app you're in.
//
// THE PROBLEM: you're 20 minutes into something in another app and your brain asks "wait, what was
// I supposed to be doing?". Opening Volar's window to check is an app switch — the exact loop the
// project's own ADHD research names as a structural failure of every task tool. Glance cuts it: a
// small card over whatever you're in, one sentence, gone.
//
// THREE RULES THAT DECIDE EVERYTHING BELOW:
//  1. Bấm để mở, Esc để đóng. Kiểu giữ-để-xem đã bỏ (anh Khôi 2026-08-24): giữ phím thì tay kẹt
//     trên bàn phím, không đọc hết mô tả và không bấm được phím tắt nào — đúng hai thứ thẻ này
//     sinh ra để phục vụ. Đổi lại, panel luôn lấy key focus khi hiện.
//  2. Nó TRẢ LỜI, không hỏi lại. Đúng một việc trên thẻ: không dòng "việc kế tiếp", không danh
//     sách. Ngoại lệ duy nhất là lịch sắp diễn ra — thứ đổi luôn việc nên làm. Hành động ghi dữ
//     liệu duy nhất là ⌘D (xong việc), vì thẻ đã nói rõ nó đang nói về task nào.
//  3. It never appears on its own. No nudge, no reminder, no countdown. A surface that shows up
//     uninvited becomes a notification, and notifications get turned off.
//
// HONESTY NOTE vs. the design mockup: the artifact's eyebrow reads "NOW · 14:32 ELAPSED". There is
// no such number in this app — tasks have no start timestamp, only a deadline — so it is not shown.
// Inventing an elapsed counter would be fabricating data on the one surface whose entire job is to
// tell you the truth in one second. The eyebrow carries the focus countdown when a session is
// running (a real number) and nothing otherwise.
//
// PALETTE: uses the dynamic (light/dark) `VolarColor` tokens; it names tokens and never a literal,
// so it follows the theme for free. Do not hardcode a color here.
//
// UNVERIFIED: written on Windows with no Swift toolchain. Not compiled, not run.
import SwiftUI
import AppKit

// MARK: - Controller

/// Owns whether Glance is on screen and in which mode. Deliberately a small object of its own
/// rather than five more properties on the 6600-line `AppState`: none of this is app state, it is
/// window state, and nothing outside macOS has any use for it.
@MainActor
@Observable
final class GlanceController {
    enum Mode: Equatable {
        /// Not on screen.
        case hidden
        /// Bấm ⌃⌥N — thẻ ở lại tới khi Esc (hoặc bấm ⌃⌥N lần nữa). Lấy key focus để phím tắt trên
        /// thẻ chạy được.
        case shown
    }

    private(set) var mode: Mode = .hidden

    /// ⌃⌥N. Bấm để bật, bấm lần nữa để tắt.
    ///
    /// 2026-08-24 (anh Khôi): bỏ hẳn kiểu "giữ để xem, thả là mất". Giữ phím thì tay còn kẹt trên
    /// bàn phím — không đọc hết nổi mô tả dài, cũng không bấm được phím tắt nào khác, mà đúng hai
    /// thứ đó mới là lý do mở thẻ. Một nhịp bấm, đọc bao lâu tuỳ mình, Esc để đóng.
    func hotkeyDown() {
        mode = mode == .shown ? .hidden : .shown
    }

    func hide() {
        mode = .hidden
    }
}

// MARK: - View

struct GlanceHUD: View {
    @Environment(AppState.self) private var appState
    let controller: GlanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Chỉ còn lịch sắp diễn ra được chiếm dòng này. Dòng "NEXT" (việc kế tiếp) bỏ hẳn
            // 2026-08-24 (anh Khôi): thẻ này trả lời ĐÚNG MỘT câu "đang làm gì" — nêu thêm việc
            // sau là bày ra một lựa chọn ngay lúc người ta đang cố quay lại việc hiện tại. Lịch
            // thì khác hạng: cuộc họp 12 phút nữa đổi luôn việc nên làm, không phải gợi ý.
            if let event = upcomingEvent {
                Divider().overlay(VolarColor.border)
                eventRow(event)
            }
            Divider().overlay(VolarColor.border)
            keyHints
            if appState.focusActive {
                progressBar
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VolarColor.borderHi, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        // Thẻ chỉ hiện khi được bấm và luôn là key window, nên Esc / Return / ⌘D lúc nào cũng
        // dùng được — không còn nhánh nào mà phím tắt hiện ra rồi bấm không ăn.
        .background(shortcutCarriers)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(headerDotColor)
                    .frame(width: 6, height: 6)
                Text(eyebrowText)
                    .font(.volar(size: 10.5, weight: .semibold))
                    .foregroundStyle(VolarColor.textMut)
                    .textCase(.uppercase)
                    .monospacedDigit()
            }
            Text(titleText)
                .font(.volar(size: 17, weight: activeTask == nil ? .medium : .semibold))
                .foregroundStyle(activeTask == nil ? VolarColor.textSec : VolarColor.textPri)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            // Hạn là NHÃN chứ không còn là một dòng chữ mờ (anh Khôi 2026-08-24): chữ "DUE" nhỏ,
            // in hoa, nằm trong khung; giờ thì đậm bằng chữ chính. Trước cả cụm cùng một màu mờ
            // nên mắt lướt qua mất — mà hạn là nửa còn lại của câu trả lời.
            if !metaText.isEmpty {
                HStack(spacing: 6) {
                    Text(isOverdue ? "OVERDUE" : "DUE")
                        .font(Font.volarMono(size: 9.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(VolarColor.textSec)
                    Text(metaText)
                        .font(.volar(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(VolarColor.veil(0.07), in: RoundedRectangle(cornerRadius: 5))
                // Cả cụm nằm chung một khung (anh Khôi 2026-08-24): chữ DUE và cái giờ là MỘT
                // thông tin, tách hai nền thì đọc thành hai mẩu rời.
                .fixedSize()
            }
            // Mô tả — thứ kéo lại context "định làm gì với việc này", đúng lý do Glance tồn tại
            // (anh Khôi 2026-08-24). Trần 5 dòng: dài hơn thì thẻ cao quá, phần còn lại đọc ở trang detail.
            if let details = activeTask?.details, !details.isEmpty {
                Text(details)
                    .font(.volar(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(VolarColor.textSec)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The "spotlight" — a wash behind the answer, not a border around it. Only drawn when there
        // IS a NOW task: nothing running means nothing to light up.
        .background(activeTask == nil ? Color.clear : VolarColor.nowGlowSoft)
    }

    /// An imminent calendar event. Uses `instrument` (ice blue) — the token that means
    /// "information", never the mint spotlight, which stays reserved for the one NOW task.
    private func eventRow(_ event: CalendarAccess.UpcomingEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.minutesAway <= 0 ? "NOW" : "IN \(event.minutesAway)M")
                .font(.volar(size: 9.5, weight: .semibold))
                .foregroundStyle(VolarColor.instrument)
                .monospacedDigit()
            Text(event.title)
                .font(.volar(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private var keyHints: some View {
        HStack(spacing: 12) {
            hint("return", activeTask == nil ? "Start" : "Focus")
            // Xong việc ngay trên thẻ (anh Khôi 2026-08-24) — thao tác GHI dữ liệu duy nhất ở đây.
            // ⌘D chứ không phải một chữ trần: thẻ nổi trên app khác, phím không modifier quá dễ
            // bấm nhầm cho một hành động đổi trạng thái task.
            if activeTask != nil {
                hint("⌘D", "Done")
            }
            hint("⌃⌥M", "Speak")
            hint("esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.volar(size: 9.5, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(VolarColor.veil(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.volar(size: 10.5))
                .foregroundStyle(VolarColor.textMut)
        }
    }

    /// The focus session, as a bar rather than a second number competing with the eyebrow's.
    private var progressBar: some View {
        GeometryReader { geo in
            let total = Double(25 * 60)
            let done = max(0, min(1, (total - Double(appState.focusSecondsLeft)) / total))
            ZStack(alignment: .leading) {
                Rectangle().fill(VolarColor.veil(0.05))
                Rectangle().fill(VolarColor.nowAccent).frame(width: geo.size.width * done)
            }
        }
        .frame(height: 2)
    }

    /// Invisible buttons that carry Esc/Return — the same "zero-size button carries the shortcut"
    /// trick `TextCaptureView.escCancelButton` already uses in this codebase.
    @ViewBuilder
    private var shortcutCarriers: some View {
        ZStack {
            Button("") { controller.hide() }
                .keyboardShortcut(.cancelAction)
            Button("") {
                if !appState.focusActive { appState.startFocus() }
                controller.hide()
            }
            .keyboardShortcut(.defaultAction)
            // Đánh dấu xong rồi đóng luôn: thẻ vừa nói "đang làm việc này", giữ nó lại sau khi
            // việc đã xong thì câu đó thành sai.
            if let active = activeTask {
                Button("") {
                    appState.toggleDone(active.id)
                    controller.hide()
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: Content

    /// The same property `TodayView`'s hero card and the menu bar read, so Glance can never name a
    /// different task than the rest of the app.
    private var activeTask: TaskItem? { appState.dashboardActiveTask }

    /// Read live rather than cached: Glance is on screen for a second or two at a time, and a stale
    /// "in 12 minutes" is worse than none. The 45-minute window is the horizon at which a meeting
    /// actually changes what you should pick up — beyond that it is noise on a one-second surface.
    ///
    /// Excludes Volar's own mirror calendar; see `CalendarAccess.nextEvent` for why that matters.
    private var upcomingEvent: CalendarAccess.UpcomingEvent? {
        appState.calendarAccess.nextEvent(
            within: 45 * 60,
            excludingCalendarID: appState.calendarSync.volarCalendarID
        )
    }

    private var isOverdue: Bool {
        guard let deadline = activeTask?.deadline else { return false }
        return deadline < Date()
    }

    private var headerDotColor: Color {
        if activeTask != nil { return VolarColor.nowAccent }
        return appState.openTasks.isEmpty ? VolarColor.done : VolarColor.textMut
    }

    private var eyebrowText: String {
        guard activeTask != nil else {
            return appState.openTasks.isEmpty ? "Today" : "Nothing running"
        }
        guard appState.focusActive else { return "Now" }
        return "Now · \(max(0, appState.focusSecondsLeft) / 60)m left"
    }

    private var titleText: String {
        if let task = activeTask { return task.title }
        return appState.openTasks.isEmpty ? "All clear." : "Nothing started yet."
    }

    private var metaText: String {
        guard let task = activeTask else {
            guard let first = appState.openTasks.first else { return "" }
            return "Press return to start — \(first.title)"
        }
        guard let deadline = task.deadline else { return "" }
        // Chỉ trả về giờ: chữ DUE/OVERDUE đã là nhãn riêng ở `header`. Quá hạn vẫn chỉ được NÊU,
        // không mắng — không đỏ, không dấu chấm than (luật chống-xấu-hổ trong Theme.swift).
        return deadline.formatted(date: .omitted, time: .shortened)
    }
}
