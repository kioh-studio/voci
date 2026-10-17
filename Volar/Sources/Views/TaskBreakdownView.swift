// Sources/Views/TaskBreakdownView.swift — AI task-breakdown artboard, ported from
// `design/volar-extras.jsx`'s `VolarTaskBreakdown`.
//
// CHANGE 3 (2026-07-27): this sheet used to show 5 hard-coded sample rows ("Open Framer", "Draft
// headline + subhead", …) under a hard-coded title ("Launch landing page") regardless of which
// task's context menu opened it, with "Save all as tasks" permanently `.disabled(true)` — every
// call site opened the sheet via a bare `appState.showBreakdown = true` with no way to say WHICH
// task, so wiring Save up would have persisted the sample junk into the user's real list. Now:
// every call site routes through `AppState.openBreakdown(for:)`, which records the real task
// (`AppState.breakdownTask`) and kicks off a REAL fetch (`AppState.fetchBreakdown`, routed through
// the same `IntentRouter` cloud parsing already uses) — this view is now a pure function of
// `AppState.breakdownFetchState`: loading while the request is in flight, the real steps once they
// land, or an honest "needs cloud" / "couldn't reach it" line if they don't. See
// `AppState.fetchBreakdown`'s doc comment for exactly how a hard-coded fallback is ruled out before
// ever reaching `.loaded` — this view never has to re-derive that guarantee itself.
import SwiftUI

struct TaskBreakdownView: View {
    var onSave: ([String]) -> Void = { _ in }
    var onClose: () -> Void = {}

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    /// Real steps once (and only once) `breakdownFetchState` is `.loaded` — the ONLY source
    /// `stepsCard`/`summary`/the Save button read from. There is no other array anywhere in this
    /// file a step row could come from, which is itself the guarantee against ever showing sample/
    /// hard-coded content again (self-review point 4).
    private var loadedSteps: [BreakdownStep] {
        if case .loaded(let steps) = appState.breakdownFetchState { return steps }
        return []
    }

    private var isSaveEnabled: Bool {
        !loadedSteps.isEmpty
    }

    private var taskTitle: String {
        appState.breakdownTask?.title ?? "this task"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stepsCard
            summary
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .frame(width: 480, height: 540)
        .volarGlass(level: .standard, cornerRadius: 16)
        // Covers EVERY dismissal path — Cancel, Edit-as-cancel, Esc, the system sheet-close
        // control — not just the two buttons below that call `onClose()`. `VolarApp.swift` (out
        // of this change's allowed files) only flips the bare `showBreakdown` Bool on dismiss and
        // has no way to also call back into `AppState`'s breakdown-specific cleanup, so this view
        // does it here instead: `.onDisappear` fires regardless of WHY the sheet went away. See
        // `AppState.closeBreakdown()`'s doc comment for why this matters (a fetch already in
        // flight for the task just dismissed must never land on the next task's freshly opened
        // sheet).
        .onDisappear { appState.closeBreakdown() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BREAKING DOWN")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.77)
                    .foregroundStyle(VolarColor.textMut)
                Text("\u{201C}\(taskTitle)\u{201D}")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                VolarIcon(.sparkle, size: 11, color: accentColors.solid, weight: .regular)
                Text("AI")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(accentColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Steps card (loading / loaded / unavailable / failed — a pure switch over
    // `appState.breakdownFetchState`, never any content of this view's own)

    @ViewBuilder
    private var stepsCard: some View {
        switch appState.breakdownFetchState {
        case .idle, .loading:
            statusCard {
                ProgressView()
                    .controlSize(.small)
                Text("Breaking it down\u{2026}")
                    .font(.system(size: 13))
                    .foregroundStyle(VolarColor.textSec)
            }
        case .loaded(let steps) where !steps.isEmpty:
            VStack(spacing: 2) {
                ForEach(steps) { step in
                    stepRow(step)
                }
            }
            .padding(6)
            .background(VolarColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)
        case .loaded:
            // Defensive only — `fetchBreakdown` maps an empty result to `.failed`, never
            // `.loaded([])`, but this view still degrades honestly if that guarantee ever slips.
            statusCard {
                Text("Didn't get any steps back.")
                    .font(.system(size: 13))
                    .foregroundStyle(VolarColor.textSec)
            }
        case .unavailable:
            statusCard {
                Text("Breakdown needs cloud parsing.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text("Sign in and turn on cloud parsing in Settings to break this task into steps.")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
            }
        case .failed:
            statusCard {
                Text("Couldn't reach the breakdown service.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text("Check your connection and try again from the task's context menu.")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Shared frame for the three non-`.loaded` states above — same card chrome as the real steps
    /// list so the sheet doesn't visibly jump size between loading/error/success.
    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(16)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }

    private func stepRow(_ step: BreakdownStep) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(VolarColor.textSec).frame(width: 12, height: 1)
                }
            }
            .opacity(0.35)

            Text("\(step.id + 1)")
                .font(.volarMono(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accentColors.solid)
                .frame(width: 22, height: 22)
                .background(accentColors.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5))

            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)

            Spacer(minLength: 8)
            // No per-step duration badge here (the old "10 min"/"5 min" labels were hard-coded
            // sample values) — `IntentRouter.breakdown(title:notes:) -> [String]` (the frozen seam
            // this view is built from) only carries step titles; the backend's `estimateMinutes`
            // never survives that trip (see `BreakdownStep`'s doc comment in `AppState.swift`).
            // Showing an invented number here would be exactly the "generated-looking content
            // that is actually hard-coded" this whole change exists to remove.
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack {
            Text(summaryLabel)
                .font(.volarMono(size: 12))
                .monospacedDigit()
                .foregroundStyle(VolarColor.textSec)
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    private var summaryLabel: String {
        switch appState.breakdownFetchState {
        case .loaded(let steps) where !steps.isEmpty:
            return "\(steps.count) sub-task\(steps.count == 1 ? "" : "s")"
        default:
            return " "
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    onClose()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09).
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .volarHairline(cornerRadius: 6)

                // Enabled ONLY once `breakdownFetchState == .loaded([...])` with real, non-empty
                // steps (`isSaveEnabled`) — never on `.idle`/`.loading`/`.unavailable`/`.failed`.
                // `onSave` forwards straight to `AppState.saveBreakdown(_:)`, unmodified, exactly
                // the titles `fetchBreakdown` put in `loadedSteps` — never a hard-coded array.
                Button {
                    onSave(loadedSteps.map(\.title))
                } label: {
                    HStack(spacing: 8) {
                        Text("Save all as tasks")
                        Text("\u{21A9}").opacity(0.85)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09). Nút chính của cả sheet,
                    // full-width — thiếu dòng này thì cả dải rộng chỉ ăn click ở chỗ chữ.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(accentColors.solid)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: accentColors.glow, radius: 12, y: 4)
                .disabled(!isSaveEnabled)
            }
            // Only for the two states `stepsCard` above doesn't already narrate on its own
            // ("Breaking it down…" during `.idle`/`.loading` would make this line redundant) —
            // `.unavailable`/`.failed` get a second, action-oriented line here specifically.
            if let caption = actionsCaption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    private var actionsCaption: String? {
        switch appState.breakdownFetchState {
        case .unavailable: return "Turn on cloud parsing in Settings to generate real steps."
        case .failed: return "Breakdown failed \u{2014} nothing was saved."
        default: return nil
        }
    }
}

#Preview {
    TaskBreakdownView()
        .environment(AppState())
}
