// Sources/Design/IOSComponents.swift — shared iOS companion components (feature 011, contract §3).
// Pixel specs: design/ios-companion/SPEC.md "Shared components". `RewardIcon` lives in
// Shared/Model/RewardRecord.swift (agent C1); this file only reads `icon?.systemImage`.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(IOSFont.button)
            .foregroundStyle(IOSPalette.onMint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: IOSLayout.primaryHeight)
            .background(IOSPalette.primaryGradient, in: RoundedRectangle(cornerRadius: IOSLayout.buttonRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(IOSFont.ui(16, .medium))
            .foregroundStyle(IOSPalette.fg)
            .frame(maxWidth: .infinity)
            .frame(minHeight: IOSLayout.secondaryHeight)
            .background(IOSPalette.surfaceHi, in: RoundedRectangle(cornerRadius: IOSLayout.buttonRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: IOSLayout.buttonRadius, style: .continuous).stroke(IOSPalette.borderHi, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips & labels

struct NowChip: View {
    init() {}
    var body: some View {
        Text("NOW")
            .font(IOSFont.nowChip)
            .tracking(IOSFont.nowChipTracking)
            .foregroundStyle(IOSPalette.onMint)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(IOSPalette.mint, in: Capsule())
    }
}

struct MetaChip: View {
    let text: String
    var color: Color
    var dot: Color?

    init(_ text: String, color: Color = IOSPalette.fg2, dot: Color? = nil) {
        self.text = text
        self.color = color
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(IOSFont.chip)
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(IOSFont.sectionLabel)
            .textCase(.uppercase)
            .tracking(IOSFont.sectionTracking)
            .foregroundStyle(IOSPalette.fg2)
    }
}

struct ScreenHeader: View {
    let title: String
    var meta: String?
    init(_ title: String, meta: String? = nil) {
        self.title = title
        self.meta = meta
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(IOSFont.screenTitle)
                .tracking(IOSFont.screenTitleTracking)
                .foregroundStyle(IOSPalette.fg)
            if let meta {
                Text(meta)
                    .font(IOSFont.mono(13))
                    .foregroundStyle(IOSPalette.fg3)
            }
        }
    }
}

struct RewardChip: View {
    let title: String
    let minutes: Int?
    let icon: RewardIcon?
    var highlighted: Bool

    init(title: String, minutes: Int?, icon: RewardIcon?, highlighted: Bool = false) {
        self.title = title
        self.minutes = minutes
        self.icon = icon
        self.highlighted = highlighted
    }

    var body: some View {
        HStack(spacing: 6) {
            if let name = icon?.systemImage {
                Image(systemName: name).font(.system(size: 14, weight: .regular))
            }
            Text(minutes.map { "\(title) · \($0)m" } ?? title)
        }
        .font(IOSFont.mono(12))
        .foregroundStyle(highlighted ? IOSPalette.mint : IOSPalette.fg2)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(highlighted ? IOSPalette.mintSur : IOSPalette.surfaceHi, in: Capsule())
        .overlay(Capsule().stroke(IOSPalette.border, lineWidth: 1))
    }
}

// MARK: - Grouped list

/// Plain container: surface fill, radius 14, 1px border. Callers put `RowDivider()` between children.
struct GroupedCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(IOSPalette.surface, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous).stroke(IOSPalette.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
    }
}

/// Hairline between `GroupedCard` children, inset to align with the row title (16 pad + 20 icon + 12 gap).
struct RowDivider: View {
    var inset: CGFloat = 48
    var body: some View {
        Rectangle().fill(IOSPalette.border).frame(height: 1).padding(.leading, inset)
    }
}

private struct RowLeading: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(IOSPalette.fg2)
                .frame(width: 20)
            Text(title)
                .font(IOSFont.rowTitle)
                .foregroundStyle(IOSPalette.fg)
        }
    }
}

struct ValueRow: View {
    let icon: String
    let title: String
    let value: String?
    var valueColor: Color
    var chevron: Bool
    var action: (() -> Void)?

    init(icon: String, title: String, value: String?, valueColor: Color = IOSPalette.fg2,
         chevron: Bool = true, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.chevron = chevron
        self.action = action
    }

    private var row: some View {
        HStack(spacing: 8) {
            RowLeading(icon: icon, title: title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(IOSFont.mono(13))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSPalette.fg3)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    init(icon: String, title: String, isOn: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            RowLeading(icon: icon, title: title)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(IOSPalette.mint)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

// MARK: - Sheet header

struct SheetHeader: View {
    let title: String
    var leading: String
    let trailing: String?
    let onLeading: () -> Void
    var onTrailing: (() -> Void)?
    var trailingEnabled: Bool

    init(title: String, leading: String = "Cancel", trailing: String?,
         onLeading: @escaping () -> Void, onTrailing: (() -> Void)? = nil, trailingEnabled: Bool = true) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
        self.onLeading = onLeading
        self.onTrailing = onTrailing
        self.trailingEnabled = trailingEnabled
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(IOSFont.ui(17, .semibold))
                .foregroundStyle(IOSPalette.fg)
            HStack {
                Button(action: onLeading) {
                    Text(leading).font(IOSFont.ui(17)).foregroundStyle(IOSPalette.mint)
                        .frame(minHeight: IOSLayout.minTouch).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if let trailing {
                    Button { onTrailing?() } label: {
                        Text(trailing).font(IOSFont.ui(17, .semibold))
                            .foregroundStyle(trailingEnabled ? IOSPalette.mint : IOSPalette.fg3)
                            .frame(minHeight: IOSLayout.minTouch).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!trailingEnabled)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Helpers

/// 24pt bottom spacer for scroll views (clears the home indicator).
struct HomeIndicatorSpacer: View {
    var body: some View { Color.clear.frame(height: 24) }
}

extension View {
    func iosScreenBackground() -> some View {
        background(IOSPalette.bg.ignoresSafeArea())
    }
}

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader("Now", meta: "Sat, Oct 4")
            NowChip()
            HStack {
                MetaChip("High", dot: IOSPalette.high)
                MetaChip("17:00", color: IOSPalette.med)
                MetaChip("45m")
            }
            SectionLabel("Today's goals")
            HStack {
                RewardChip(title: "Game", minutes: 30, icon: .gamepad)
                RewardChip(title: "Game", minutes: 30, icon: .gamepad, highlighted: true)
            }
            GroupedCard {
                ValueRow(icon: "clock", title: "Time", value: "17:00", valueColor: IOSPalette.med, action: {})
                RowDivider()
                ToggleRow(icon: "bell", title: "Remind me", isOn: .constant(true))
            }
            SheetHeader(title: "Reward", trailing: "Save", onLeading: {}, onTrailing: {})
            PrimaryButton("Start focus", systemImage: "play.fill") {}
            SecondaryButton("Switch") {}
            HomeIndicatorSpacer()
        }
        .padding(.horizontal, IOSLayout.screenPadH)
    }
    .iosScreenBackground()
    .preferredColorScheme(.dark)
}
