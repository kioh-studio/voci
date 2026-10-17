// Sources/Views/Components.swift — shared components (frozen §5): KeyBadge, PriorityBadge,
// TimeBadge, Spinner, SectionHeader. GlassBackground itself lives in Design/Glass.swift.
//
// KeyBadge/TimeBadge/SectionHeader read the active accent from `@Environment(AppState.self)`
// (so their frozen init signatures don't need an extra color parameter). `VolarApp.swift` injects
// `AppState` via `.environment(appState)` at the Window/MenuBarExtra root, so any Phase-2 view
// mounted inside those scenes gets it for free. Standalone `#Preview`s of these components must
// add `.environment(AppState())` themselves, same as the `@EnvironmentObject` convention.
import SwiftUI
import VolarCore

/// English label for `VolarCore.RankReason` (specs/009-light-mode-list-v2/design.md §5.6.2).
/// `.priority`/`.none` return `nil` on purpose: `TaskRow.titleAndSubrow` already renders a
/// High/Medium/Low dot+label for every open task, so repeating "priority 1" next to it would show
/// the same fact twice — the reason line exists to add information (in-progress/overdue/due-today),
/// not restate what's already on the row.
func rankReasonLabel(_ reason: RankReason) -> String? {
    switch reason {
    case .inProgress:
        return "in progress"
    case .overdue(let interval):
        return "overdue \(formatShortDuration(interval))"
    case .dueToday(let date):
        return "due \(date.formatted(.dateTime.hour().minute()))"
    case .priority:
        return nil
    case .none:
        return nil
    }
}

/// Chấm màu + nhãn của `Priority`. `TaskRow` và `TodayView`'s NOW card dùng bản này; `FocusOverlay`,
/// `TaskDetailView`, `PopoverView` vẫn còn bản `private` riêng (chạy đúng, chưa gom).
func priorityTint(_ priority: Priority) -> Color {
    switch priority {
    case .high: return VolarColor.high
    case .medium: return VolarColor.med
    case .low: return VolarColor.low
    }
}

func priorityName(_ priority: Priority) -> String {
    switch priority {
    case .high: return "High"
    case .medium: return "Medium"
    case .low: return "Low"
    }
}

/// "45m" / "2h" / "3d" — coarse single-unit duration for `rankReasonLabel`'s overdue case only.
/// Not a general-purpose formatter (no `DateComponentsFormatter` dependency for one call site).
private func formatShortDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(1, Int(interval / 60))
    if totalMinutes < 60 { return "\(totalMinutes)m" }
    let totalHours = totalMinutes / 60
    if totalHours < 24 { return "\(totalHours)h" }
    return "\(totalHours / 24)d"
}

/// Blocked/waiting chip — a task with an unsatisfied `VolarCore.Condition` (design.md §5.6.3).
/// Icon note: `Shared/Design/VolarIcon.swift` (not owned by this file) has no lock glyph in its
/// `VolarIconName` case list — falls back to the SF Symbol directly rather than adding a case
/// there; flagged in the handoff.
struct BlockedChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(VolarColor.textMut)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(VolarColor.borderHi, lineWidth: 0.5)
        )
    }
}

/// Small hover-only icon button for `TaskRow`'s quick-action cluster (design.md §5.6.4). Written
/// directly (rather than reusing `ToolButton` below) so the hit area is guaranteed to literally end
/// in `.contentShape(Rectangle())` on a `Button(.plain)`, per the repo-wide "clickable area covers
/// visible area" rule.
struct QuickActionButton: View {
    let icon: VolarIconName
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VolarIcon(icon, size: 12, color: VolarColor.textSec, weight: .medium)
                .frame(width: 22, height: 22)
                .background(isHovering ? VolarColor.veil(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// ⌃ ⌥ Space-style key chip. Ported from `volar-mac.jsx`'s `KeyBadge`.
struct KeyBadge: View {
    let text: String
    var accent: Bool

    @Environment(AppState.self) private var appState: AppState

    init(_ text: String, accent: Bool = false) {
        self.text = text
        self.accent = accent
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(accent ? accentColors.solid : VolarColor.textSec)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(accent ? accentColors.surface : VolarColor.veil(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(accent ? accentColors.solid.opacity(0.33) : VolarColor.veil(0.10), lineWidth: 0.5)
            )
    }
}

/// Dot + High/Medium/Low chip. Ported from `volar-popover.jsx`'s `PriorityBadge`.
struct PriorityBadge: View {
    let priority: Priority

    init(_ priority: Priority) {
        self.priority = priority
    }

    private var style: (dot: Color, background: Color, foreground: Color, label: String) {
        switch priority {
        case .high:
            return (VolarColor.high, VolarColor.high.opacity(0.14), VolarColor.high, "High")
        case .medium:
            return (VolarColor.med, VolarColor.med.opacity(0.14), VolarColor.med, "Medium")
        case .low:
            return (VolarColor.low, VolarColor.veil(0.05), VolarColor.textSec, "Low")
        }
    }

    var body: some View {
        let s = style
        HStack(spacing: 6) {
            Circle().fill(s.dot).frame(width: 6, height: 6)
            Text(s.label)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(s.foreground)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(s.background)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Accent time chip. Ported from `volar-popover.jsx`'s `TimeBadge`; `filled` mirrors the
/// "isActive" solid-fill variant used in `volar-mac.jsx`'s `TaskRow`.
struct TimeBadge: View {
    let text: String
    var filled: Bool
    /// `DeadlineUrgency.tint` — màu đè lên badge khi hạn đã đi quá nửa quãng đường (anh Khôi chốt
    /// 2026-08-20). `nil` (mặc định) giữ nguyên accent như trước, tức là "còn nhiều thời gian"
    /// không có dấu hiệu riêng nào cả: badge cứ là mint như mọi badge khác.
    var tint: Color? = nil

    @Environment(AppState.self) private var appState: AppState

    init(_ text: String, filled: Bool = false, tint: Color? = nil) {
        self.text = text
        self.filled = filled
        self.tint = tint
    }

    private var accentColors: Accent { appState.accent.accent }

    /// Một hue duy nhất cho cả chữ và nền của badge, nên chỉ có ĐÚNG MỘT chỗ quyết định màu.
    private var hue: Color { tint ?? accentColors.solid }

    var body: some View {
        Text(text)
            .font(Font.volarMono(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(filled ? Color.white : hue)
            .padding(.horizontal, 9)
            .frame(height: 22)
            // `accentColors.surface` là token pha sẵn của accent; với màu urgency thì không có
            // token tương ứng nên pha tại chỗ ở cùng độ mờ.
            .background(filled ? hue : (tint == nil ? accentColors.surface : hue.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Rotating ring spinner. Ported from `volar-popover.jsx`'s `Spinner`.
struct Spinner: View {
    let color: Color
    var size: CGFloat = 14

    @State private var isSpinning = false

    init(color: Color, size: CGFloat = 14) {
        self.color = color
        self.size = size
    }

    var body: some View {
        Circle()
            .stroke(color.opacity(0.2), lineWidth: 1.6)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
            )
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

/// "NOW" / "LATER TODAY" / "COMPLETED" section label with a hairline rule + optional count.
/// Ported from `volar-mac.jsx`'s inline section-header markup.
struct SectionHeader: View {
    let title: String
    let count: Int?
    var accent: Bool

    @Environment(AppState.self) private var appState: AppState

    init(_ title: String, count: Int?, accent: Bool = false) {
        self.title = title
        self.count = count
        self.accent = accent
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.735) // 0.07em at 10.5pt
                .textCase(.uppercase)
                .foregroundStyle(accent ? accentColors.solid : VolarColor.textMut)
            Rectangle()
                .fill(VolarColor.border)
                .frame(height: 0.5)
            if let count {
                Text("\(count)")
                    .font(Font.volarMono(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textMut)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}
