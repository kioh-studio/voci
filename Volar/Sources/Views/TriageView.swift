// Sources/Views/TriageView.swift — weekly stale-task triage batch card (Phase 4, T034 §D).
// Presented ONCE per staleness window for the whole batch (FR-018) — never per-task nag
// notifications. Anti-shame per FR-036 + constitution V: no red, no overdue badges, no "you
// failed" copy; "Drop" is styled identically to the other three actions, never as a destructive
// warning. Self-contained: reads only the injected `items` + four action closures, touches no
// app state, no persistence, no other files. Presentation (when/how this is shown, and removing
// acted-on items from `items`) is entirely the caller's (AppState's) job.
//
// UNVERIFIED — authored on Windows, no Swift toolchain available here; not compiled or run.
// Needs a Mac build/SwiftUI preview pass before shipping.
import SwiftUI

struct TriageView: View {
    let items: [TaskItem]
    var onKeep: (TaskItem) -> Void = { _ in }
    var onBreakdown: (TaskItem) -> Void = { _ in }
    var onDefer: (TaskItem) -> Void = { _ in }
    var onDrop: (TaskItem) -> Void = { _ in }

    /// Works when this view is hosted inside a SwiftUI `.sheet`/`.popover` (the expected way an
    /// app-wiring agent would present a one-shot batch card); a harmless no-op otherwise — never
    /// a crash. Lets the user close the batch without acting on every row ("never nag" — FR-018
    /// only asks that the *offer* happen weekly, not that it be inescapable).
    @Environment(\.dismiss) private var dismiss

    private let maxListHeight: CGFloat = 420

    var body: some View {
        // Defensive per spec: an empty batch renders nothing rather than an empty calm-card
        // shell — the presenter is expected to skip mounting this view entirely when there's
        // nothing to triage, but this makes that a non-requirement for correctness.
        if items.isEmpty {
            EmptyView()
        } else {
            card
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            list
            footer
        }
        .padding(16)
        .frame(width: 520)
        .volarGlass(level: .standard, cornerRadius: 16)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WEEKLY CHECK-IN")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)
            Text("A few tasks have been sitting a while")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
            Text("No pressure — keep, break down, defer, or drop each one. Whatever still fits.")
                .font(.system(size: 12))
                .foregroundStyle(VolarColor.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - List

    /// `ScrollView` + `LazyVStack` so an unusually large batch still renders bounded work per
    /// frame instead of laying out every row up front (performance self-review point).
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    TriageRow(
                        item: item,
                        onKeep: onKeep,
                        onBreakdown: onBreakdown,
                        onDefer: onDefer,
                        onDrop: onDrop
                    )
                }
            }
        }
        .frame(maxHeight: maxListHeight)
        // Scroll clipping is content, not chrome — no border/shadow needed beyond the outer
        // glass card's own edge.
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(items.count) task\(items.count == 1 ? "" : "s")")
                .font(.volarMono(size: 11))
                .monospacedDigit()
                .foregroundStyle(VolarColor.textMut)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Text("Maybe later")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Row

/// One stale task + its four equally-weighted actions. Kept as its own view (rather than an
/// inline `ForEach` closure) so each row can own its own hover state without re-evaluating the
/// whole batch card on every mouse move.
private struct TriageRow: View {
    let item: TaskItem
    let onKeep: (TaskItem) -> Void
    let onBreakdown: (TaskItem) -> Void
    let onDefer: (TaskItem) -> Void
    let onDrop: (TaskItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var priorityColor: Color {
        switch item.priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            actionRow
        }
        .padding(12)
        .background(isHovering ? VolarColor.cardHover : VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(VolarMotion.hover) { isHovering = hovering }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Circle().fill(priorityColor).frame(width: 5, height: 5)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let durationLabel = item.durationLabel {
                Text(durationLabel)
                    .font(.volarMono(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    /// All four actions share ONE neutral visual treatment (FR-036 / constitution V) — "Drop" is
    /// not red, not a trash icon, not visually singled out from "Keep". They are simply four
    /// equally legitimate outcomes of a check-in.
    private var actionRow: some View {
        HStack(spacing: 6) {
            actionButton("Keep") { onKeep(item) }
            actionButton("Break down") { onBreakdown(item) }
            actionButton("Defer") { onDefer(item) }
            actionButton("Drop") { onDrop(item) }
        }
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VolarColor.veil(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
        .accessibilityLabel("\(label) — \(item.title)")
    }
}

// MARK: - Previews

#Preview("Batch") {
    TriageView(
        items: [
            TaskItem(title: "Update onboarding flowchart", priority: .medium, when: .later, durationMinutes: 30),
            TaskItem(title: "Reply to design feedback thread", priority: .low, when: .later),
            TaskItem(title: "Renew SSL certificate", priority: .high, when: .later, durationMinutes: 15),
        ]
    )
    .padding()
    .background(VolarColor.bg)
}

#Preview("Empty") {
    TriageView(items: [])
        .padding()
        .background(VolarColor.bg)
}
