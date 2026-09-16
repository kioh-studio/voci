// Sources/Views/TodayView.swift — main window content: sidebar + Today list + greeting + frog/focus pill
// Ported from `design/volar-mac.jsx`'s `VolarMacApp`. Owns the in-window overlay stack (focus, ambient).
//
// FLOATING CAPTURE PANEL (feature 002 gap fix): `PopoverView` used to mount HERE, gated on
// `appState.captureState != .idle`, alongside a click-outside-to-cancel dimming scrim. Since this
// window is normally CLOSED (Volar is an `LSUIElement` menu-bar app), that made the ⌃⌥M capture UI
// invisible whenever the user wasn't already looking at the main window — see
// `Sources/Views/CapturePanel.swift`'s header for the full story. `PopoverView` now mounts in a
// floating `NSPanel` instead (driven by `AppDelegate` in `VolarApp.swift`), which is why both the
// scrim and the `PopoverView()` call are gone from this file; the panel is a system-wide overlay,
// so an in-window dim no longer makes sense (and cancel-on-click-outside was deliberately dropped
// too — the panel brief calls for recording to survive the user clicking elsewhere).
//
// STUDIO DARK RETHEME (2026-07) dựng màn này thành lưới NOW/NEXT/LATER: một task được chiếu sáng,
// một hàng "next" mờ, một ngăn "Later" gập sẵn.
//
// 2026-08-22 (anh Khôi: "làm nó y chang như cái tab detail bên Linear") bỏ hai phần sau của lưới
// đó. Today nay LÀ trang detail của việc đang phải làm — cùng bộ xương với `TaskDetailView`: nội
// dung bên trái, rail thuộc tính 240pt bên phải. Hàng NEXT và ngăn "Later" thay bằng
// `relatedSection` (việc đang chặn / bị chặn bởi việc này); ngăn "Completed" thành một section
// riêng trong sidebar (`NavSection.completed`). `NextPeekRow` và `CollapsibleTaskSection` xoá theo
// vì không còn chỗ gọi. Không có gì ngoài file này đổi, trừ `NavSection` (+`completed`) và hai hàm
// `priorityTint`/`priorityName` mới trong `Components.swift`.
import SwiftUI
import VolarCore

struct TodayView: View {
    @Environment(AppState.self) private var appState: AppState

    /// Drives `SignInSheet` (main-window Sign-in entry point fix, 2026-07-28) — Settings ▸ Account
    /// used to be the ONLY place to sign in, which a brand-new user has no reason to ever open, so
    /// they'd never discover cloud speech/parsing or Pro. This flag backs a toolbar pill that's
    /// visible only while signed out (see the `ToolbarItemGroup` below).
    @State private var showSignInSheet = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack {
            if appState.ambient != .none {
                AmbientBackground(mode: appState.ambient, imageURL: appState.customImageURL, intensity: 0.7)
                    .ignoresSafeArea()
            }

            // Panel-refactor (specs/005-cursor-retheme/panel-refactor.md §5 item 3): task detail
            // là một CHILD của `HStack` này, không phải overlay — nó không tham gia, và không được
            // phá, thứ tự "tour overlay phải nằm cuối" mà comment dài bên dưới (chỗ
            // `.overlayPreferenceValue`) khoá lại. `FocusOverlay()` bên dưới là anh em của cả
            // `HStack` này trong `ZStack` ngoài cùng, nên nó vốn đã phủ lên mọi cột khi focus mode
            // bật — detail không bao giờ đứng cạnh nó.
            HStack(spacing: 0) {
                Sidebar()
                // 2026-08-22 (anh Khôi: "lấy như cái trang của Linear luôn"): detail THAY CHỖ
                // `mainColumn` chứ không còn dock cạnh nó. Nó nay là một trang hai cột (nội dung +
                // rail thuộc tính 240pt); cửa sổ rộng tối thiểu 920pt trừ sidebar 220 và rail 240
                // chỉ còn 460 cho phần nội dung, nên giữ cả `mainColumn` bên cạnh là bóp cả hai
                // cột xuống dưới ngưỡng đọc được.
                if appState.detailTask != nil {
                    TaskDetailView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    mainColumn
                }
            }
            .animation(VolarMotion.state, value: appState.detailTaskID)

            if appState.focusActive {
                FocusOverlay()
            }
        }
        // 006-cues-and-waiting (design.md §2 Việc B): the "natural touch point" trigger for
        // `CueFiring.pending` — design.md's own words: "Ở điểm chạm tự nhiên (mở popover)". The
        // main window becoming visible is the closest equivalent this app has to that (see
        // `AppState.noteNaturalCueTouch`'s own doc comment for why `PopoverView`'s capture-flow
        // popup was deliberately NOT used instead). Not overlay-producing, so — unlike the two
        // `.overlay`/`.overlayPreferenceValue` modifiers below — its position in this chain carries
        // no z-order meaning; placed here, right after the `ZStack` closes, purely because it reads
        // most naturally as "the very first thing that happens once this view is on screen."
        .onAppear { appState.noteNaturalCueTouch() }
        // Reminder banner (`NotificationView`): a plain `.overlay`, attached BEFORE the guided
        // tour's `.overlayPreferenceValue` below — see that block's own comment for why ORDER
        // (not `.zIndex`) is what actually decides which of the two draws on top here.
        .overlay(alignment: .topTrailing) {
            if let banner = appState.reminderBanner {
                NotificationView(
                    title: banner.title,
                    timing: banner.timing,
                    onDone: { appState.dismissBanner() },
                    onSnooze: { appState.dismissBanner() },
                    onReschedule: { appState.dismissBanner() }
                )
                .padding(.top, 44)
                .padding(.trailing, 20)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                .zIndex(20)
                .task(id: appState.reminderBanner?.id) {
                    guard appState.reminderBanner != nil else { return }
                    try? await _Concurrency.Task.sleep(for: .seconds(5))
                    appState.dismissBanner()
                }
            }
        }
        .animation(VolarMotion.state, value: appState.reminderBanner)
        // Guided tour (`Sources/Views/Tour/*`): every `.tourAnchor(_:)` call site this feature adds
        // (Sidebar's capture button + key badges, `mainColumn`'s task-list region, the two
        // "Start focus"/"Focus" buttons above) lives inside the `HStack`/`ZStack` above, so
        // attaching `.overlayPreferenceValue(TourAnchorKey.self)` HERE — on that same `ZStack` — is
        // what lets `TourAnchorKey.reduce` collect every one of them into a single `anchors`
        // dictionary before `TourOverlay` ever reads it. FIX 5 (z-order): `.zIndex` only orders
        // SIBLINGS within the same container — it does nothing across two separately-chained view
        // modifiers like this `.overlayPreferenceValue` and the reminder banner's `.overlay`
        // above, each of which wraps the accumulated view in a NEW view with its own content drawn
        // on top. What actually decides stacking order between the two is ATTACHMENT ORDER: this
        // block must be the LAST overlay-producing modifier in the chain (after both `if
        // appState.focusActive { FocusOverlay() }` above AND the reminder-banner `.overlay` right
        // above this comment) so the tour is unconditionally the topmost layer — otherwise a
        // reminder banner can render on top of the tour's own scrim, which previously happened
        // because this block was attached BEFORE the banner's `.overlay`. Keep this LAST among the
        // overlay-producing modifiers on this view if anything else is ever added here.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if appState.tourActive {
                GeometryReader { proxy in
                    TourOverlay(anchors: anchors, proxy: proxy)
                }
                .transition(.opacity)
                .zIndex(60)
            }
        }
        .animation(VolarMotion.state, value: appState.tourActive)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // 2026-08-24 (anh Khôi): thanh trên cùng dọn sạch, còn đúng Sign in + Settings.
                //   - search: bỏ hẳn. Nó là `ToolButton(icon: .search) {}` — closure RỖNG từ lúc
                //     dựng, bấm không làm gì; một nút không phản hồi tệ hơn là không có nút.
                //   - ambient sound + read-day-aloud: dời vào menu dưới nút Settings, chúng là việc
                //     thỉnh thoảng mới làm.
                //   - "+" capture: bỏ nốt. Cùng một việc đã có ba đường khác và đường nào cũng to
                //     hơn: nút "Tap to speak" chiếm nguyên đầu sidebar, hotkey ⌃⌥M gọi được từ bất
                //     kỳ app nào, và menu bar. Một nút thứ tư nhỏ xíu trên titlebar không thêm gì.
                // Sign-in entry point from the main window (fix, 2026-07-28): before this, signing
                // in was reachable ONLY through Settings ▸ Account, which a first-time user has no
                // reason to ever open — so cloud speech/parsing and Pro were effectively
                // undiscoverable. Text pill (not a bare icon): `VolarIconName` has no "person/
                // account" glyph (see `SettingsView`'s `.account` tab-icon comment for the same gap),
                // and even if it did, a brand-new user has no learned association for it yet — the
                // word "Sign in" needs no icon to be understood. Hidden entirely once signed in
                // (Việc 3's brief: no avatar/email replacement, that's out of scope here).
                if appState.accountEmail == nil {
                    SignInToolPill { showSignInSheet = true }
                }
                // Settings entry point from the main window: previously reachable ONLY via the
                // menu-bar dropdown or the ⌘, shortcut (which requires the window to already be
                // key). See `SettingsToolButton`'s own doc comment below for why this isn't just
                // `ToolButton` with a `SettingsLink`-flavored action.
                SettingsToolButton()
            }
        }
        // 2026-08-20, anh Khôi: "header phải cùng màu — dark thì đen, light thì trắng".
        // `WindowChrome` đã sơn `NSWindow.backgroundColor` và bật `titlebarAppearsTransparent`,
        // nhưng cái đó CHỈ lộ nền window ở phần titlebar TRỐNG. Cửa sổ này có `.toolbar` (ngay
        // trên), và toolbar tự vẽ nền vật liệu riêng của nó đè lên — đó là dải sáng còn sót lại
        // trong ảnh anh gửi. `.hidden` bỏ hẳn nền đó để lộ `VolarColor.bg` bên dưới, tức là
        // titlebar + toolbar + thân app thành đúng một màu ở cả hai chế độ.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet()
        }
    }

    // MARK: - Detail panel

    /// Task-detail inspector column (panel-refactor.md §5 item 3) — replaces the old `.sheet`
    /// (`VolarApp.swift` used to present `TaskDetailView` modally; that `.sheet` is gone). `@ViewBuilder`
    /// `if` (not a ternary/`opacity`) so the column is fully absent from the `HStack`'s layout when
    /// `detailTask` is `nil`, rather than reserving 340pt of empty space — and so the
    /// `.transition`/`.animation(VolarMotion.state, value: appState.detailTaskID)` pair on the
    /// `HStack` above actually has an insertion/removal edge to animate.
    ///
    /// Fixed 340pt width, `VolarColor.surface` background, 0.5pt `VolarColor.border` hairline on the
    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            greetingHeader
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // Guided tour, stop 2 (`Sources/Views/Tour/*`): tagged as ONE `Group` wrapping every
            // branch — rather than tagging only the `ScrollView` branch — so the anchor still
            // resolves for a brand-new user with zero tasks (`EmptyTodayCard`), which is exactly
            // the audience this stop most needs to reach. `Group` adds no layout of its own, so
            // this changes nothing about how any branch renders; `.tourAnchor` sits on `Group`
            // itself (not inside the `switch`) so it reads unambiguously as "this whole region is
            // the anchor," and so it stays outside the switch's own brace nesting.
            //
            // Section switch (2026-07-27, port of Windows TodayView.xaml.cs's own "Section switch"
            // comment): the main column now hosts three sections, not just Today. Archived/Completed
            // reuse the same `TaskRow` every drawer below already uses — no new row view — and get
            // their own plain-text empty state (`sectionEmptyView`), distinct from Today's
            // mic-icon `EmptyTodayCard`.
            Group {
                switch appState.selectedSection {
                case .today:
                    if appState.openTasks.isEmpty {
                        EmptyTodayCard()
                    } else {
                        todayScrollView
                    }
                case .archived, .completed:
                    if isSectionEmpty {
                        sectionEmptyView
                    } else {
                        sectionScrollView
                    }
                }
            }
            .tourAnchor(.taskList)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(mainBackground)
    }

    /// Today's NOW/NEXT/Later/Completed stack — unchanged content, just extracted out of
    /// `mainColumn`'s body so the Archived/Completed branches (`sectionScrollView`) can sit
    /// alongside it in the section `switch` above without duplicating this scroll view's shape.
    private var todayScrollView: some View {
        // 2026-08-22 (anh Khôi: "làm nó y chang như cái tab detail bên Linear"): Today không còn là
        // một cột danh sách có card NOW ở đầu. Nó LÀ trang của việc đang phải làm. Cái card bo tròn
        // `nowSurface` biến mất cùng lúc: một trang không tự đóng khung chính nó.
        //
        // 2026-08-24 (anh Khôi, ảnh chụp app thật): rail thuộc tính 240pt bên phải cũng bỏ nốt —
        // "để ngay dưới tên task là được, không cần tách sidebar riêng". Một cột 240pt chỉ để chở
        // ba dòng ngắn là đổi 1/4 bề ngang cửa sổ lấy thứ vừa đúng một hàng chữ; và nó bắt mắt
        // nhảy ngang giữa chừng khi đang đọc từ trên xuống. `TaskDetailView` giữ rail của nó —
        // ở đó mọi field đều SỬA được nên một cột riêng có việc thật để làm.
        ScrollView {
            VStack(alignment: .leading, spacing: appState.density.sectionGap) {
                nowSpotlight

                // Park & resume (anh Khôi 2026-09-06): the ONE line about the task set aside, shown
                // only while something is actually parked — it disappears by itself the moment the
                // spotlight is handed back. Deliberately an editable field and not read-only text,
                // unlike the hero's `details` right above: that field has its own editor on the
                // detail page (two editors for one field = two places to fix it), whereas
                // `resumeNote` has none outside `FocusOverlay`, so anyone not running a focus
                // session had nowhere at all to type "làm tới đâu". `AppState.park` has already
                // seeded it with a "dừng lúc nào, vì việc gì" breadcrumb; this is where that gets
                // overwritten with the half a machine can't know.
                if let parkedID = appState.parkedTaskID,
                   let parked = appState.tasks.first(where: { $0.id == parkedID }) {
                    ParkedNoteRow(task: parked)
                        .id(parkedID)
                }

                // 006-cues-and-waiting (design.md §2 Việc B/C, §3): the two new ambient surfaces
                // this feature adds, both "renders nothing when there's nothing to show" like every
                // other banner in this stack. `cueBanner` prefers a just-fired `.wake` cue (set by
                // `AppState.recordAppBecameActive`, driven off real app activation) but also carries
                // a `.pending` dayEnd/unknown cue surfaced at this exact natural touch point — see
                // `.onAppear` below.
                if let banner = appState.cueBanner {
                    CueReminderRow(banner: banner)
                }
                if let decision = appState.waitingModeDecision {
                    WaitingModeRow(
                        decision: decision,
                        suggestedTitle: decision.suggestedTaskId.flatMap { id in
                            appState.tasks.first { $0.id == id }?.title
                        }
                    )
                }

                // FR-030: the one-time "want to split this up?" invite, whenever one's pending —
                // shared with `FocusOverlay`'s own copy of the same banner (both read the exact
                // same `AppState.switchBreakdownSuggestion`; see `SwitchBreakdownSuggestionBanner`,
                // `Sources/Views/FocusOverlay.swift`). Same "renders nothing when there's nothing to
                // show" convention.
                if let suggestion = appState.switchBreakdownSuggestion {
                    SwitchBreakdownSuggestionBanner(task: suggestion)
                }



                // Ngăn "Later" (anh Khôi 2026-08-22: "show những task khác trong mục Later là
                // không cần thiết") và hàng NEXT đã bỏ. Chỗ của chúng là `relatedSection` — không
                // phải "vài việc khác trong ngày" mà đúng những việc DÍNH tới việc đang làm: cái gì
                // đang chặn nó, và nó đang chặn cái gì. Một danh sách để lướt thì kéo mắt ra khỏi
                // câu trả lời; một danh sách quan hệ thì trả lời tiếp chính câu đó.
                //
                // Ngăn "Completed" cũng rời khỏi đây — nay là một section riêng trong sidebar,
                // ngang hàng Today (`NavSection.completed`).
                relatedSection

                hotkeyFooter
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .animation(VolarMotion.list, value: appState.tasks)
        }
    }

    /// Archived/Completed body — cùng `TaskRow` mà mọi danh sách khác dùng, nên một task trông và
    /// cư xử y hệt nhau ở mọi chỗ nó xuất hiện. Cả hai đều là danh sách phẳng: một việc đã cất đi
    /// hoặc đã xong thì không còn hạn lẫn thứ hạng nào để nhóm theo.
    @ViewBuilder
    private var sectionScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appState.density.rowGap) {
                ForEach(sectionRows) { task in
                    TaskRow(task: task, isActive: false)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }

    private var sectionRows: [TaskItem] {
        switch appState.selectedSection {
        case .archived: return appState.archivedTasks
        case .completed: return appState.doneTasks
        case .today: return []
        }
    }

    /// Archived/Completed empty state — plain centered text, distinct from Today's mic-icon
    /// `EmptyTodayCard` (neither section has anything to illustrate beyond the copy itself).
    /// Mirrors Windows TodayView.xaml's `SectionEmptyText`.
    private var sectionEmptyView: some View {
        Text(sectionEmptyText)
            .font(.system(size: 13.5))
            .foregroundStyle(VolarColor.textSec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// NEW (retheme): "deep ink stage" — a faint top-down radial lift over the flat ink base so the
    /// window reads as a stage with depth rather than a flat fill, matching `command-deck.html`'s
    /// `body` background. Built only from existing `VolarColor` tokens (`bg`/`surface`) — no new hex.
    @ViewBuilder
    private var mainBackground: some View {
        if appState.ambient != .none {
            Color.black.opacity(0.30)
        } else {
            ZStack {
                VolarColor.bg
                RadialGradient(
                    colors: [VolarColor.surface.opacity(0.55), Color.clear],
                    center: UnitPoint(x: 0.5, y: -0.15),
                    startRadius: 40,
                    endRadius: 640
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Related tasks (anh Khôi 2026-08-22)
    //
    // Thay chỗ hàng NEXT và ngăn Later. Đây KHÔNG phải "vài việc khác trong ngày" mà đúng những
    // việc dính tới việc đang làm, theo chính quan hệ phụ thuộc engine dùng để xếp thứ tự
    // (`VolarCore.Condition.taskDone`). Hai chiều, và chúng không cùng một chuyện:
    //
    //   - "Waiting on" — việc này đang chờ cái gì xong. Đọc thẳng từ `conditions` của nó.
    //   - "Blocking"   — việc này đang chặn cái gì. Phải quét ngược cả `tasks`, vì quan hệ chỉ
    //     được lưu ở MỘT đầu: đầu bị chặn. Không có danh sách "tôi đang chặn ai" ở đâu cả.
    //
    // Cả hai chiều đều lọc bỏ việc đã xong: một việc `done` không còn chặn ai và cũng không còn
    // chờ ai, để nó nằm lại chỉ làm mục này dài ra bằng những quan hệ đã hết hiệu lực.
    //
    // ponytail: quét ngược là O(số task × số điều kiện) mỗi lần vẽ lại. Với quy mô một ngày làm
    // việc thì rẻ hơn hẳn một chỉ mục ngược — mà chỉ mục ngược lại là thứ phải tự đồng bộ mỗi lần
    // ai đó sửa/xoá một điều kiện. Dựng chỉ mục nếu có ngày danh sách task lên tới hàng nghìn.

    private func waitingOnTasks(for task: TaskItem) -> [TaskItem] {
        task.conditions.compactMap { condition in
            guard case .taskDone(let id) = condition else { return nil }
            guard let referenced = appState.tasks.first(where: { $0.id == id }), !referenced.done else { return nil }
            return referenced
        }
    }

    private func tasksBlocked(by task: TaskItem) -> [TaskItem] {
        appState.tasks.filter { other in
            guard other.id != task.id, !other.done else { return false }
            return other.conditions.contains { condition in
                if case .taskDone(let id) = condition { return id == task.id }
                return false
            }
        }
    }

    /// Không có quan hệ nào thì mục này biến mất hẳn, không hiện "Nothing related" — đó là trạng
    /// thái BÌNH THƯỜNG của phần lớn task, và một dòng báo rỗng lặp lại mỗi ngày chỉ là nhiễu.
    @ViewBuilder
    private var relatedSection: some View {
        if let active = appState.dashboardActiveTask {
            let waitingOn = waitingOnTasks(for: active)
            let blocking = tasksBlocked(by: active)
            if !waitingOn.isEmpty || !blocking.isEmpty {
                // Nhỏ hẳn lại (anh Khôi 2026-08-24: "chiếm spotlight của task rồi kìa"). Trước đây
                // mục này dùng `TaskRow` đầy đủ — cùng cỡ chữ, cùng chấm ưu tiên, cùng dòng meta
                // với danh sách chính — nên hai ba việc PHỤ trông ngang hàng với việc đang phải
                // làm ngay phía trên. Nay là `RelatedTaskRow`: một dòng, chữ nhỏ hơn, không chấm
                // ưu tiên, không dòng meta.
                VStack(alignment: .leading, spacing: 8) {
                    if !waitingOn.isEmpty {
                        relatedGroup("Waiting on", tasks: waitingOn)
                    }
                    if !blocking.isEmpty {
                        relatedGroup("Blocking", tasks: blocking)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    /// KHÔNG dùng `TaskRow` (dù nó là hàng chuẩn của Archived/Completed): mấy việc ở đây là
    /// THAM CHIẾU tới chỗ khác, không phải danh sách chính của màn này, nên chúng phải đọc ra nhẹ
    /// hơn hẳn việc đang phải làm ở trên. Xem `RelatedTaskRow`.
    private func relatedGroup(_ label: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Font.volarMono(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(VolarColor.textMut)
                .padding(.leading, 2)
                .padding(.bottom, 2)
            ForEach(tasks) { task in
                RelatedTaskRow(task: task)
            }
        }
    }

    // MARK: - NOW spotlight

    /// The hero treatment for `appState.dashboardActiveTask` — the one thing on screen allowed to be
    /// amber. Bespoke (not `TaskRow`) because the design calls for a big centered title + chip row +
    /// primary action that `TaskRow`'s compact horizontal layout has no room for; every action
    /// `TaskRow` would have offered (tap-to-open-detail, mark done, breakdown, delete) is still wired
    /// here via the same `appState` calls, PLUS the new "Switch" action. Reads `dashboardActiveTask`
    /// rather than the raw engine `activeTask` so a Switch actually moves what this card shows (see
    /// that property's own doc comment for why the plain engine pick alone can never change here).
    /// Falls back to a calm placeholder if there's nothing eligible at all (never crashes/force-
    /// unwraps).
    @ViewBuilder
    private var nowSpotlight: some View {
        if let active = appState.dashboardActiveTask {
            // 2026-08-22 (anh Khôi): "chỗ Today là để user biết task hiện tại của mình là gì, phải
            // làm gì, và description là để họ nhớ lại context". Card NOW vì thế không còn là một
            // tấm poster căn giữa gồm tít + mấy chip nữa mà mang đúng hình dạng trang detail: cột
            // trái đọc từ trên xuống (tít → lý do → mô tả → hành động), rail thuộc tính bên phải.
            //
            // Đổi từ căn giữa sang CĂN TRÁI là bắt buộc chứ không phải thẩm mỹ: mô tả nhiều dòng
            // căn giữa thì mỗi dòng bắt đầu ở một chỗ khác nhau, mắt phải dò lại đầu dòng mỗi lần
            // xuống hàng — đúng thứ không được phép bắt một người đang cố nhớ lại việc phải làm.
            VStack(alignment: .leading, spacing: 14) {
                    // List v2 (design.md §5.3): "NOW" is a small chip, not a colored text label — the
                    // hero's saturation budget is spent on this chip + the 3px leading bar in
                    // `.background` below, never on a text color or a full-row fill.
                    Text("NOW")
                        .font(Font.volarMono(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(VolarColor.bg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(VolarColor.nowAccent)
                        .clipShape(Capsule())

                    Text(active.title)
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.7)
                        .foregroundStyle(VolarColor.textPri)
                        .shadow(color: VolarColor.nowGlow, radius: 18)
                        .lineLimit(3)

                    // Thuộc tính nằm NGAY DƯỚI tên task (anh Khôi 2026-08-24), trước cả dòng lý do:
                    // đọc xong tên việc thì thứ cần biết tiếp là hạn với thời lượng, không phải
                    // vì sao engine xếp nó đầu.
                    heroMetaRow(for: active)

                    // List v2 (design.md §5.6.1): NOW là chỗ "vì sao việc này đứng đầu" đáng nói
                    // nhất, và nó không phải `TaskRow` nên lúc đầu không có dòng lý do. Dùng lại
                    // `rankReasonLabel` (`Components.swift`) chứ không viết formatter thứ hai —
                    // cùng luật mà `TaskRow` đang theo.
                    //
                    // `!showsDueInReasonLine` — luật cũ, chỗ dùng mới. Với task đến hạn hôm nay
                    // `rankReasonLabel(.dueToday)` trả "due 09:00", mà hàng meta NGAY TRÊN đã có
                    // mục Deadline 09:00: cùng một sự thật in hai lần cách nhau một dòng. Dòng lý
                    // do tồn tại để THÊM thông tin, không phải nhắc lại.
                    if let label = rankReasonLabel(volarRankReason(for: active)),
                       !showsDueInReasonLine(active) {
                        Text(label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(VolarColor.textSec)
                    }

                    // Mô tả — thứ anh Khôi gọi là "để họ nhớ lại context, làm như thế nào".
                    // CHỈ ĐỌC ở đây: bấm vào card là mở đúng trang detail để sửa, nên dựng thêm một
                    // ô nhập thứ hai vào card này chỉ tạo ra hai chỗ sửa cùng một field.
                    // `lineLimit(8)` là cái trần: một mô tả dài không được phép đẩy hàng nút xuống
                    // khỏi tầm nhìn — phần còn lại đọc tiếp ở trang detail.
                    if !active.details.isEmpty {
                        Text(active.details)
                            .font(.system(size: 13.5))
                            .lineSpacing(4)
                            .foregroundStyle(VolarColor.textSec)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Một hàng, ba nút — đúng ba việc làm được với CHÍNH task này: bắt đầu, đánh
                    // dấu xong, đổi sang việc khác. "Delegate to Claude" và cả tính năng "Stuck?"
                    // đã bỏ hẳn khỏi app (anh Khôi 2026-08-22).
                    HStack(spacing: 8) {
                        if !appState.focusActive {
                            Button {
                                appState.startFocus()
                            } label: {
                                Text("Start focus")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(VolarColor.bg)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09).
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                LinearGradient(
                                    colors: [VolarColor.nowAccentSoft, VolarColor.nowAccent],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            // Guided tour, stop 3 primary anchor (`Sources/Views/Tour/*`): only ever
                            // rendered while `!appState.focusActive` (this whole `Button` sits inside
                            // that guard, immediately above), i.e. only while there's an eligible NOW
                            // task to focus on — see `TourAnchorID.focusPrimary`'s doc comment for why
                            // `frogPill`'s "Focus" button below is tagged as this stop's fallback.
                            .tourAnchor(.focusPrimary)
                        }

                        Button {
                            appState.toggleDone(active.id)
                        } label: {
                            Text(active.done ? "Mark not done" : "Done")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(VolarColor.textPri)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(VolarColor.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(VolarColor.borderHi, lineWidth: 0.5)
                        )

                        // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain here — this Switch
                        // button, its context-menu twin below, and the `dashboardActiveTask` rewiring
                        // above have not been compiled, run, or seen on screen. Needs a Mac visual pass
                        // (see final report's verify checklist) before shipping.
                        //
                        // Switch ("đổi gió") — equal footing with "Done" right above, not a secondary/
                        // hidden action (also mirrored in the context menu below, same as "Mark done"
                        // already is, but this button row is the primary, always-visible home for it).
                        // Deliberately the SAME neutral styling as "Done" (no accent fill, no icon, no
                        // red) — this is a completely normal thing to tap, not an admission of anything.
                        // Disabled (not hidden) when there's nowhere else open to switch to.
                        if !active.done {
                            Button {
                                appState.switchDashboardActiveTask()
                            } label: {
                                Text("Switch")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(VolarColor.textPri)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(VolarColor.surfaceHi)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(VolarColor.borderHi, lineWidth: 0.5)
                            )
                            .opacity(appState.canSwitchDashboardActiveTask ? 1 : 0.4)
                            .disabled(!appState.canSwitchDashboardActiveTask)
                            .help("Move on to something else — this task isn't done, it just steps out for now.")
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            // Vỏ card đã bỏ (2026-08-22): không còn nền `nowSurface`, không còn viền bo 22pt,
            // không còn thanh accent 3px lẫn `volarSpotlight`. Cả bốn thứ đó tồn tại để tách MỘT
            // card ra khỏi danh sách quanh nó — mà nay không còn danh sách nào quanh nó, cả cột này
            // đã là việc đó rồi. Chip "NOW" ở trên là dấu hiệu duy nhất còn cần.
            //
            // Today chỉ ĐỌC mô tả; sửa thì mở trang detail. Tap đặt trên cả khối nội dung vì đó là
            // đường sửa duy nhất từ màn này — mấy nút bên trong là `Button` riêng nên chúng ăn tap
            // của mình trước, không rơi xuống đây.
            .contentShape(Rectangle())
            .onTapGesture { appState.openDetail(active.id) }
            .contextMenu {
                Button("Break down into steps…") { appState.openBreakdown(for: active) }
                Button(active.done ? "Mark not done" : "Mark done") { appState.toggleDone(active.id) }
                if !active.done {
                    // Mirrors the button row's Switch exactly (same `AppState` call, same
                    // disabled-when-nowhere-else-to-go rule) — the button row is the primary,
                    // always-visible home for Switch; this is just the same convenience-duplicate
                    // treatment "Mark done" already gets here.
                    Button("Switch") { appState.switchDashboardActiveTask() }
                        .disabled(!appState.canSwitchDashboardActiveTask)
                    Button("Archive") { appState.archiveTask(active.id) }
                }
                Divider()
                Button("Delete", role: .destructive) { appState.deleteTask(active.id) }
            }
        } else {
            VStack(spacing: 8) {
                Text("Nothing ready right now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Text("Everything open is waiting on something else.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textMut)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(VolarColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
        }
    }

    /// Chip row under the NOW title — remaining estimate, deadline, frog marker, dependency note.
    /// All derived from existing `TaskItem` fields (`durationLabel`/`timeBadge`/`frog`/`conditions`)
    /// already used elsewhere (`TaskRow`) — no new data/logic, just a different presentation.
    /// Thuộc tính của việc đang làm — MỘT HÀNG ngang ngay dưới tên task (anh Khôi 2026-08-24),
    /// không còn là cột rail riêng. Cùng bộ icon với rail của `TaskDetailView` (cờ hạn chót, lịch,
    /// play, đồng hồ) nên một task vẫn đọc ra giống nhau ở hai màn, chỉ khác hướng xếp.
    ///
    /// Vẫn CHỈ ĐỌC: bấm vào khối nội dung là mở trang detail, nơi mọi field sửa được. Hàng nào
    /// chưa có giá trị thì biến mất hẳn, không hiện "Add …" — đây là chỗ đọc để nhớ ra việc, không
    /// phải chỗ điền. `Priority` luôn có giá trị nên hàng này không bao giờ rỗng.
    ///
    /// Gộp luôn hai chip cũ (`frog`, `waiting on`) vào cùng hàng thay vì để chúng thành một hàng
    /// riêng bên dưới: chúng cũng là thuộc tính của đúng task đó, tách ra chỉ tạo hai dải meta
    /// chồng nhau nói cùng một chuyện.
    private func heroMetaRow(for task: TaskItem) -> some View {
        HStack(spacing: 14) {
            metaItem(.flag, "Priority") {
                HStack(spacing: 6) {
                    Circle().fill(priorityTint(task.priority)).frame(width: 6, height: 6)
                    Text(priorityName(task.priority))
                }
            }
            if let due = task.timeBadge {
                // Hạn để VÀNG (anh Khôi 2026-08-24) — `VolarColor.med`, token vàng/hổ phách duy
                // nhất đã có sẵn cặp light/dark. Chỉ đổi ở hàng meta của Today và ở mục Related;
                // badge `due` trong `TaskRow` (Archived/Completed) vẫn đi qua `DeadlineUrgency.tint`,
                // tức đổi màu theo tỉ lệ thời gian còn lại — luật anh Khôi chốt 2026-08-20, không
                // đụng vào trong lần này.
                metaItem(.today, "Deadline") {
                    Text(due)
                        .font(Font.volarMono(size: 12.5))
                        .foregroundStyle(VolarColor.med)
                }
            }
            if let start = task.startTime {
                metaItem(.play, "Start time") {
                    Text(start.formatted(.dateTime.hour().minute())).font(Font.volarMono(size: 12.5))
                }
            }
            if let duration = task.durationLabel {
                metaItem(.clock, "Duration") { Text(duration).font(Font.volarMono(size: 12.5)) }
            }
            if task.frog {
                metaItem(.flag, "Hardest task today") {
                    Text("Hardest today").foregroundStyle(VolarColor.high)
                }
            }
            if !task.conditions.isEmpty {
                metaItem(.clock, "Waiting on other work") { Text("waiting on other work") }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(VolarColor.textSec)
        .lineLimit(1)
    }

    /// Một mục trong hàng meta. `label` không vẽ ra chữ nào — nó vào `.help` (tooltip) và vào
    /// `.accessibilityLabel` của riêng cái ICON, đúng lý lẽ đã ghi ở `TaskDetailView.railRow`:
    /// gộp cả mục thành một phần tử rồi đặt nhãn "Deadline" sẽ nuốt mất chính giá trị bên cạnh.
    private func metaItem<Value: View>(
        _ icon: VolarIconName,
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 6) {
            VolarIcon(icon, size: 11, color: VolarColor.textMut)
                .accessibilityLabel(label)
            value()
        }
        .help(label)
    }

    /// `true` khi dòng lý do của task này chính là "due …", tức là nó chỉ nhắc lại hàng Deadline
    /// mà hàng meta đã hiện — xem chỗ dùng trong `nowSpotlight`.
    private func showsDueInReasonLine(_ task: TaskItem) -> Bool {
        if case .dueToday = volarRankReason(for: task) { return true }
        return false
    }

    // MARK: - Greeting header

    private var greetingHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                // Section switch (2026-07-27, port of Windows TodayView.xaml.cs's own "Section
                // switch" comment): title now tracks `appState.selectedSection`.
                Text(sectionTitle)
                    .font(.system(size: 26, weight: .medium))
                    .tracking(-0.52)
                    .foregroundStyle(VolarColor.textPri)
                // Today keeps its own date + open/done counters; Archived/Completed have no
                // "date · N open · N done" shape to fill, so they show `sectionSubtitleText`
                // instead (mirrors Windows `TodaySubtitleRow`/`SectionSubtitleText`'s mutually
                // exclusive visibility in TodayView.xaml.cs's `UpdateVisual`).
                if appState.selectedSection == .today {
                    // Counts are instrument readouts (mono, per the retheme brief) — same
                    // `appState.openTasks.count`/`appState.doneTasks.count` bindings as before, just
                    // split into separate `Text` fragments so the numbers can take `Font.volarMono`.
                    HStack(spacing: 4) {
                        Text(todayDateLabel)
                            .font(Font.volarMono(size: 12.5))
                            .monospacedDigit()
                        Text("·").foregroundStyle(VolarColor.textMut)
                        Text("\(appState.openTasks.count)")
                            .font(Font.volarMono(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.instrument)
                        Text("open")
                        Text("·").foregroundStyle(VolarColor.textMut)
                        Text("\(appState.doneTasks.count)")
                            .font(Font.volarMono(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.done)
                        Text("done")
                    }
                    .font(.system(size: 12.5))
                    .tracking(-0.0625)
                    .foregroundStyle(VolarColor.textSec)
                    .lineLimit(1)
                } else if let subtitle = sectionSubtitleText {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .tracking(-0.0625)
                        .foregroundStyle(VolarColor.textSec)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if appState.focusActive {
                runningFocusPill
            } else {
                frogPill
            }
        }
    }

    // MARK: - Section switch: Today / Archived / Completed — port of Windows
    // TodayViewModel.SectionTitle/SectionSubtitle/SectionEmptyText/IsSectionEmpty
    // (ViewModels/TodayViewModel.cs:364-396). Copy is byte-for-byte identical to that source.

    private var sectionTitle: String {
        switch appState.selectedSection {
        // "Now" chứ không "Today" (anh Khôi 2026-08-24) — màn này trả lời "việc phải làm NGAY BÂY
        // GIỜ là gì", không phải "hôm nay có những gì". Case enum vẫn tên `.today`.
        case .today: return "Now"
        case .archived: return "Archived"
        case .completed: return "Completed"
        }
    }

    private var sectionSubtitleText: String? {
        switch appState.selectedSection {
        case .today:
            return nil
        case .archived:
            return appState.archivedNavCount == 0
                ? "Nothing archived"
                : "\(appState.archivedNavCount) archived"
        case .completed:
            return appState.completedNavCount == 0
                ? "Nothing finished yet today"
                : "\(appState.completedNavCount) done"
        }
    }

    private var sectionEmptyText: String {
        switch appState.selectedSection {
        case .archived:
            return "Nothing archived. Cất một việc đi khi anh không làm nó nữa nhưng chưa muốn xoá."
        default:
            return "Nothing finished yet. Tick something off and it moves here."
        }
    }

    private var isSectionEmpty: Bool {
        switch appState.selectedSection {
        case .archived: return appState.archivedTasks.isEmpty
        case .completed: return appState.doneTasks.isEmpty
        case .today: return false
        }
    }

    private var todayDateLabel: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var runningFocusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accentColors.solid)
                .frame(width: 5, height: 5)
                .shadow(color: accentColors.glow, radius: 4)
                .opacity(appState.focusPaused ? 1 : (pulseTick ? 0.35 : 1))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseTick = true
                    }
                }

            Text(appState.frogTask?.title ?? "Focus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)

            Text(fmtClock(appState.focusSecondsLeft))
                .font(Font.volarMono(size: 13, weight: .semibold))
                .monospacedDigit()
                .tracking(0.26)
                .foregroundStyle(accentColors.solid)

            Button {
                appState.toggleFocusPause()
            } label: {
                VolarIcon(appState.focusPaused ? .play : .pause, size: 10, color: VolarColor.textPri)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.08))
            .clipShape(Circle())

            Button {
                appState.endFocus()
            } label: {
                VolarIcon(.stop, size: 9, color: VolarColor.textSec)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.08))
            .clipShape(Circle())
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VolarColor.textSec)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
        )
        .shadow(color: accentColors.glow.opacity(0.25), radius: 22)
    }

    private var frogPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(VolarColor.high)
                .frame(width: 5, height: 5)
                .shadow(color: VolarColor.high.opacity(0.5), radius: 3)

            // BUG 2026-08-20 (anh Khôi gửi ảnh): chỗ này từng là
            // `appState.frogTask?.title ?? "Ship the auth fix"` — khi chưa có frog nào, app BỊA ra
            // một task không tồn tại và hiện nó như thật. Trong ảnh anh gửi, hai task thật đều là
            // tiếng Việt còn cái pill vẫn nói "Ship the auth fix". Chuỗi đó là dữ liệu mẫu của
            // `SampleData`, lọt vào đường hiển thị thật.
            if let frog = appState.frogTask {
                HStack(spacing: 4) {
                    Text("Frog").fontWeight(.medium).foregroundStyle(VolarColor.textPri)
                    Text("· \(frog.title)").lineLimit(1).truncationMode(.tail)
                }
            } else {
                Text("No frog today").foregroundStyle(VolarColor.textSec)
            }

            Button {
                appState.startFocus()
            } label: {
                HStack(spacing: 5) {
                    VolarIcon(.play, size: 8, color: .white)
                    Text("Focus")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            // Guided tour, stop 3 fallback anchor: `frogPill` (unlike `nowSpotlight`'s "Start
            // focus" button above) has no `appState.activeTask`/`focusActive` guard, so this
            // "Focus" button is always on screen whenever the running-focus pill isn't — including
            // a brand-new user's empty-task state, which is exactly the case `.focusPrimary` can't
            // cover.
            .tourAnchor(.focusFallback)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VolarColor.textSec)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        // Retheme: was a hardcoded red (0xFF6B6B) — both "no red, ever" and "no hardcoded hex" are
        // hard rules now, so this reuses the existing `VolarColor.high` (clay/terracotta) token,
        // which is also what the frog dot above already uses. Deliberately NOT `nowAccent` — amber
        // is reserved for the NOW spotlight alone, and this pill isn't it.
        .background(VolarColor.high.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(VolarColor.high.opacity(0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Hotkey footer

    private var hotkeyFooter: some View {
        HStack(spacing: 10) {
            VolarIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
            Text("Press")
            KeyBadge("⌃", accent: true)
            KeyBadge("⌥", accent: true)
            KeyBadge("M", accent: true)
            Text("and speak to add a task by voice.")
        }
        .font(.system(size: 12))
        .foregroundStyle(VolarColor.textSec)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColors.solid.opacity(0.33), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
        )
    }

    /// Drives the running-focus pill's pulsing dot. Kept as an `@State` on the view (rather than
    /// `AppState`) since it's pure presentation, not app state.
    @State private var pulseTick = false

    private func fmtClock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// Gear entry point into Settings from the main window's toolbar. Visually matches
/// `Components.swift`'s `ToolButton` (28x28 hit target, 5pt-rounded hover tint, subtle press
/// scale) so it reads as one more tool alongside ambient/read-aloud/search/capture — but it wraps
/// `SettingsLink` (macOS 14+, opens the app's `Settings` scene) instead of a plain `Button`, for
/// two reasons: `SettingsLink` owns its action outright and has no `action:` closure parameter to
/// plug into `ToolButton`, and `ToolButton`/`ToolButtonStyle` both live in `Components.swift`,
/// which is frozen/off-limits for this task. `SettingsLink { Text(...) }` mirrors the exact usage
/// already in `VolarApp.swift`'s `MenuBarMenuContent` per the task brief; `ToolButtonStyle`'s
/// press-scale is small enough to re-declare locally (`SettingsToolButtonStyle` below) rather than
/// touching that file to make it non-private.
///
/// UNVERIFIED: whether `SettingsLink` actually honors a custom `ButtonStyle`/hover-driven
/// background the way a plain `Button` does isn't confirmed on this machine (no Xcode/Swift
/// toolchain to render it) — if it silently ignores `.buttonStyle(_:)` at runtime, the gear would
/// still open Settings correctly, just without the hover/press affordance matching its siblings.
private struct SettingsToolButton: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    var body: some View {
        Menu {
            // Hai việc dời từ thanh công cụ vào đây (anh Khôi 2026-08-24). Chúng là HÀNH ĐỘNG chứ
            // không phải cấu hình, nên nằm trong menu này chứ không nằm trong màn Settings — bấm
            // "đọc to ngày hôm nay" trong một trang cấu hình là sai chỗ.
            Button(appState.ambientSound.isPlaying ? "Stop ambient sound" : "Play ambient sound") {
                appState.toggleAmbientSound()
            }
            Button("Read my day aloud") {
                appState.readDayAloud()
            }
            Divider()
            // `SettingsLink` chứ không phải `Button` gọi tay: nó là API duy nhất mở được cửa sổ
            // Settings của SwiftUI mà không đi vòng qua selector `showSettingsWindow:` đã bị bỏ.
            SettingsLink { Text("Settings…") }
        } label: {
            VolarIcon(.settings, size: 14, color: VolarColor.textSec, weight: .regular)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(isHovering ? VolarColor.veil(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel("Settings and more")
    }
}

/// Press-scale dùng chung cho `SignInToolPill` (và trước đây cho `SettingsToolButton`, nay đã đổi
/// sang `Menu` nên không cần `ButtonStyle` nữa). Bản khai lại tại chỗ của `ToolButtonStyle` trong
/// `Components.swift` — xem chú thích ở `SettingsToolButton` cho lý do không dùng thẳng bản đó.
private struct SettingsToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// Toolbar "Sign in" pill — the new main-window entry point into `SignInSheet` (see this file's
/// `.toolbar` block above; visible only while `appState.accountEmail == nil`). Text rather than a
/// bare icon: `VolarIconName` has no person/account glyph (same gap `SettingsView`'s Account tab
/// works around), and a brand-new user wouldn't recognize one yet even if it existed — "Sign in"
/// reads on its own.
///
/// RETHEME (Graphite, spec §3.2, revised by design-owner follow-up): was an always-filled accent
/// capsule; a first pass flattened it to no fill at all, matching the icon-only `ToolButton`s
/// beside it — but that went too far. Before this pill existed, sign-in was only reachable through
/// Settings and was effectively undiscoverable, which is the whole reason the fill was added in the
/// first place. So this stays deliberately the one toolbar item carrying a fill at rest: a subtle
/// ~15% accent tint (`accent.surface`) with a soft accent-tinted border, not the solid capsule of
/// the old design and not the flat/borderless treatment of its `SettingsToolButton` sibling.
private struct SignInToolPill: View {
    let action: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Button(action: action) {
            Text("Sign in")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsToolButtonStyle())
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(accentColors.solid.opacity(isHovering ? 0.5 : 0.3), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel("Sign in")
    }
}

/// "All clear." empty state shown when there are no open tasks. Ported from `volar-mac.jsx`'s
/// `EmptyToday`. Private to `TodayView` — not part of the frozen component surface.
private struct EmptyTodayCard: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: accentColors.glow.opacity(0.30), radius: 30)
                VolarIcon(.mic, size: 28, color: accentColors.solid, weight: .light)
            }

            Text("All clear.")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.33)
                .foregroundStyle(VolarColor.textPri)

            HStack(spacing: 4) {
                Text("Press")
                KeyBadge("⌃")
                KeyBadge("⌥")
                KeyBadge("M")
                Text("when you need to remember something.")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(VolarColor.textSec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Một dòng trong mục Related — nhẹ hơn hẳn `TaskRow`, và cư xử khác nó ở hai chỗ có chủ đích
/// (anh Khôi 2026-08-24):
///
/// 1. **Tên task là LINK, không phải chữ thường.** Mấy việc ở đây là tham chiếu tới chỗ khác, nên
///    chúng phải TRÔNG như bấm được: chữ đổi sang màu accent + gạch chân khi rê chuột. `TaskRow`
///    cũng mở detail khi bấm, nhưng nó không có tín hiệu nào cho biết điều đó — chấp nhận được với
///    một danh sách (ở đó bấm dòng là chuyện hiển nhiên), không chấp nhận được với một tham chiếu
///    lọt giữa một trang chữ.
///
///    Cố ý KHÔNG đổi con trỏ chuột: `NSCursor.pointingHand.push()/pop()` phải khớp cặp, mà hàng
///    này biến mất ngay khi task hết chặn — unmount lúc con trỏ còn đang ở trên nó là kẹt con trỏ
///    hình bàn tay khắp app. `.pointerStyle(.link)` thì đòi macOS 15, sàn của bản này là 14.
///
/// 2. **Ô tick hỏi lại trước khi đánh dấu xong.** Đây không phải việc đang làm; người dùng tới đây
///    để ĐỌC xem cái gì đang chặn cái gì, nên một cú bấm trượt sang ô tick sẽ đánh dấu xong một
///    việc họ còn chẳng nghĩ tới. Ở danh sách chính thì tick-là-xong đúng (đó là thao tác họ chủ
///    động làm); ở đây thì không. Dùng `.confirmationDialog` chứ không tự dựng popup — cùng lý lẽ
///    "đừng viết lại thứ hệ thống đã có" mà `DateBufferControl` đã theo.
private struct RelatedTaskRow: View {
    let task: TaskItem

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false
    @State private var isHoveringTitle = false
    @State private var confirmingDone = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 9) {
            Button { confirmingDone = true } label: {
                Circle()
                    .strokeBorder(VolarColor.textMut, lineWidth: 1.2)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark done — hỏi lại trước khi ghi")
            .confirmationDialog(
                "Mark \u{201C}\(task.title)\u{201D} as done?",
                isPresented: $confirmingDone,
                titleVisibility: .visible
            ) {
                Button("Mark done") { appState.toggleDone(task.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Việc này không phải việc đang làm — Volar hỏi lại để một cú bấm trượt không đánh dấu nhầm.")
            }

            Button { appState.openDetail(task.id) } label: {
                Text(task.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isHoveringTitle ? accentColors.solid : VolarColor.textSec)
                    .underline(isHoveringTitle, color: accentColors.solid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .help("Mở task này")

            Spacer(minLength: 8)

            if let due = task.timeBadge {
                Text(due)
                    .font(Font.volarMono(size: 11))
                    .monospacedDigit()
                    // Vàng (anh Khôi 2026-08-24). `VolarColor.med` là token vàng/hổ phách duy nhất
                    // đã có sẵn cặp light/dark trong `Theme.swift` — không đẻ thêm hex mới cho một
                    // chỗ dùng. Cố ý KHÔNG đi qua `DeadlineUrgency.tint`: mấy việc ở đây không phải
                    // việc đang làm, nên một cái hạn đỏ rực ở mục phụ là đúng thứ kéo mắt sai chỗ.
                    .foregroundStyle(VolarColor.med)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isHovering ? VolarColor.cardHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// List v2 (design.md §5.6.1/§6): the row-list "why does this rank here" reason — shared by
/// `nowSpotlight` và `TaskRow`. Reuses `TaskItem.snapshot()` — the
/// exact `TaskItem` -> `VolarCore.Task` mapping `AppState.eligibleOrder`
/// (`Shared/App/AppState.swift`) already uses — instead of a second hand-rolled mapping; that
/// duplication is exactly the mistake `AppState.eligibleOrder`'s own doc comment says the codebase
/// already paid for once.
///
/// `now: Date()` read fresh on every call (coordinator follow-up 2026-08-19: checked for a shared
/// clock first) — `AppState.clock` exists but is `private`, this file has no other view-level
/// "now", and every caller here is a
/// small, infrequently-recomputed set, not a hot loop — so a fresh `Date()` per call is the
/// simplest correct option, same as `AppState.eligibleOrder`'s own callers each pass their own
/// `now`. Revisit only if `AppState` ever exposes a public `now`/tick for views generally.
private func volarRankReason(for task: TaskItem) -> RankReason {
    VolarCore.rankReason(for: task.snapshot(), now: Date(), calendar: .current)
}

// MARK: - 006-cues-and-waiting: cue reminder + waiting-mode holder (T5, wire UI)
//
// Hai row bên dưới dùng chung một vỏ card (`VolarColor.card` + hairline `VolarColor.border`, bo
// 8pt) để các mặt ambient trong file này đọc ra một họ, không phải mấy kiểu đánh nhau. Không row
// nào mang icon/màu — design.md §3's anti-shame/anti-nag rule ("Cấm đỏ,
// cấm badge... giọng chữ điềm tĩnh") is why this is plain text with no accent tint at all, closer
// to `SweepView`'s calm copy than to an instrument-tinted status card.

/// `AppState.cueBanner`, read back verbatim — design.md §2 Việc B: "hiện đúng MỘT việc, kèm trích
/// NGUYÊN VĂN lời user." Never renders `CueKind`/`kind` (`CueBanner` itself doesn't even carry
/// one — see that struct's own doc comment) — only `verbatim`, plus a date-aware lead-in so the
/// copy never overclaims ("Tối qua anh nói…" only when `createdAt` really was yesterday).
private struct CueReminderRow: View {
    let banner: CueBanner

    /// UNVERIFIED (product-phrasing judgment call, not a Mac-only concern): design.md §2's own
    /// worked example is fixed as "Tối qua anh nói…", which reads naturally for the common case
    /// this cue exists for (say it near bedtime, `.wake` fires on the next ≥6h-gap session — almost
    /// always the next morning). But a cue can sit unfired for up to `TaskCue.expiresAt`'s 48h floor,
    /// so a literal "Tối qua" would be a false claim outside that common case. This checks the real
    /// day relationship instead of hardcoding the phrase, falling back to a time-neutral "Anh nói…"
    /// whenever "last night" isn't actually true — never a bug fix Mac verification would catch (no
    /// crash either way), just a calm-voice-accuracy call flagged for review.
    private var leadIn: String {
        Calendar.current.isDateInYesterday(banner.createdAt) ? "Tối qua anh nói" : "Anh nói"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(leadIn): \u{201C}\(banner.verbatim)\u{201D}")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// `AppState.waitingModeDecision`, read as one calm line — design.md §2 Việc C: "một dòng điềm
/// tĩnh: mốc đang được giữ + thời gian còn lại." Three distinct phrasings, matching
/// `WaitingMode.Decision.suggestedTaskId`'s own doc comment on why the "anchor is itself eligible"
/// case is NOT the same thing as "nothing fits":
///   - anchor is itself actionable right now (`anchorIsEligible`) → just the hold line, no second
///     suggestion (suggesting a substitute against the user's own deadline is the exact bug
///     `WaitingMode.swift`'s header comment documents fixing).
///   - a task fits the remaining time → name it, as an invitation ("Có thể tranh thủ…"), never an
///     instruction.
///   - nothing fits → say so plainly ("Chưa có việc nào khít") and stop — design.md §2: "không ép."
private struct WaitingModeRow: View {
    let decision: WaitingMode.Decision
    let suggestedTitle: String?

    private var lineText: String {
        let time = decision.anchorAt.formatted(.dateTime.hour().minute())
        let holding = "Đang giữ mốc \u{201C}\(decision.anchorTitle)\u{201D} lúc \(time) — còn \(decision.minutesUntil) phút."
        if decision.anchorIsEligible {
            return holding
        }
        guard let suggestedTitle else {
            return holding + " Chưa có việc nào khít."
        }
        return holding + " Có thể tranh thủ \u{201C}\(suggestedTitle)\u{201D}."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(lineText)
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}


/// The "PAUSED — <task>" row `TodayView` shows while `AppState.parkedTaskID` names something.
/// Same write-on-Enter-or-blur contract as `FocusOverlay`'s `ResumeNoteField` (never per keystroke:
/// `setResumeNote` hits the store and nudges sync), just themed for the window instead of the
/// focus scrim. `.id(task.id)` at the call site is what resets `draft` when a different task
/// becomes the parked one.
private struct ParkedNoteRow: View {
    @Environment(AppState.self) private var appState: AppState
    let task: TaskItem
    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PAUSED — \(task.title)")
                .font(Font.volarMono(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
            TextField("Where you left off\u{2026}", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(3)
                .focused($editing)
                .onAppear { draft = task.resumeNote ?? "" }
                .onSubmit { appState.setResumeNote(task.id, draft) }
                .onChange(of: editing) { _, isEditing in
                    if !isEditing { appState.setResumeNote(task.id, draft) }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
    }
}
