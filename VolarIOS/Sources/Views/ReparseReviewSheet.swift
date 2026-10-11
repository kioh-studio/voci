// Sources/Views/ReparseReviewSheet.swift — feature 011 contract §7, artboard Reparse-Review.
// Offers to re-parse a capture that was saved title-only while offline. UNVERIFIED: written blind, never compiled.
import SwiftUI

struct ReparseReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(OfflineCaptureCenter.self) private var offline
    @Environment(\.dismiss) private var dismiss

    @State private var parsed: [ParsedTask]?

    private var current: PendingReparse? { offline.pending.first }

    /// Single plain task identical to what was said: nothing to improve.
    private var nothingToTidy: Bool {
        guard let current, let parsed, parsed.count == 1, let only = parsed.first else { return false }
        let said = current.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return only.title == said && only.deadline == nil && only.priority == nil && only.estimateMinutes == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: headerTitle, leading: "Later", trailing: nil, onLeading: { dismiss() })
                .padding(.top, 12)
            if let current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("You said this while offline. Here's what Volar understood \u{2014} keep what's right.")
                            .font(IOSFont.body).foregroundStyle(IOSPalette.fg2).padding(.top, 10)
                        Text("\u{201C}\(current.transcript)\u{201D}")
                            .font(IOSFont.mono(14)).foregroundStyle(IOSPalette.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(IOSPalette.bg2, in: RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous))
                            .padding(.top, 16)
                        content.padding(.top, 24)
                        HomeIndicatorSpacer()
                    }
                    .padding(.horizontal, IOSLayout.screenPadH)
                }
                buttons(for: current).padding(.horizontal, IOSLayout.screenPadH).padding(.bottom, 24)
            } else {
                Spacer()
            }
        }
        .background(IOSPalette.surface)
        // Re-runs for the next capture when the head of `pending` changes.
        .task(id: current?.id) {
            parsed = nil
            guard let current else { return }
            parsed = await appState.reparse(current.transcript)
        }
    }

    private var headerTitle: String {
        let n = offline.pending.count
        return "Tidy up \(max(n, 1)) capture\(n == 1 ? "" : "s")"
    }

    @ViewBuilder private var content: some View {
        if let parsed {
            if nothingToTidy {
                Text("Nothing to tidy \u{2014} it's already a task.")
                    .font(IOSFont.body).foregroundStyle(IOSPalette.fg2)
            } else {
                SectionLabel("Becomes \(parsed.count) task\(parsed.count == 1 ? "" : "s")")
                GroupedCard {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { index, task in
                        if index > 0 { RowDivider(inset: 14) }
                        row(task)
                    }
                }
                .padding(.top, 12)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().tint(IOSPalette.mint)
                Text("Understanding\u{2026} (uses one AI capture)")
                    .font(IOSFont.meta).foregroundStyle(IOSPalette.fg3)
            }
        }
    }

    private func row(_ task: ParsedTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(IOSPalette.mint)
                    .frame(width: 18, height: 18)
                    .background(IOSPalette.mintSur, in: Circle())
                Text(task.title).font(IOSFont.rowTitle).foregroundStyle(IOSPalette.fg)
            }
            let chips = chipTexts(task)
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        MetaChip(chip.text, color: chip.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .frame(minHeight: IOSLayout.minTouch)
    }

    private func chipTexts(_ task: ParsedTask) -> [(text: String, color: Color)] {
        var out: [(text: String, color: Color)] = []
        if let d = task.deadline?.value {
            let cal = Calendar.current
            let day: String = cal.isDateInToday(d) ? "Today"
                : cal.isDateInTomorrow(d) ? "Tomorrow"
                : d.formatted(.dateTime.weekday(.abbreviated))
            out.append((text: day, color: IOSPalette.fg2))
            if cal.component(.hour, from: d) != 0 || cal.component(.minute, from: d) != 0 {
                out.append((text: d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()), color: IOSPalette.med))
            }
        }
        if let p = task.priority?.value, p == 1 { out.append((text: "High", color: IOSPalette.high)) }
        return out
    }

    @ViewBuilder private func buttons(for current: PendingReparse) -> some View {
        VStack(spacing: 6) {
            if parsed != nil {
                if nothingToTidy {
                    PrimaryButton("OK") { finish(current, apply: false) }
                } else {
                    PrimaryButton("Apply") { finish(current, apply: true) }
                    SecondaryButton("Keep as I said it") { finish(current, apply: false) }
                }
            }
        }
    }

    private func finish(_ item: PendingReparse, apply: Bool) {
        if apply, let parsed { appState.applyReparse(taskId: item.id, parsed: parsed) }
        offline.remove(item.id) // no-op if applyReparse already removed it
        if offline.pending.isEmpty { dismiss() } // else `.task(id:)` re-runs for the next capture
    }
}
