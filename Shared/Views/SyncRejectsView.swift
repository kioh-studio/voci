// Shared/Views/SyncRejectsView.swift — read-only viewer for `public.sync_rejects`.
//
// UNVERIFIED: written on Windows, never compiled — no Swift/Xcode toolchain on this dev machine.
//
// Opus's one mandatory exception to "no conflict UI this round" (design.md §12, client-contract.md
// §9): LWW at the record level has exactly one data-loss scenario (design.md §5 — two offline
// devices editing different fields of the same task, the older edit gets overwritten), and the
// losing side is kept, verbatim, in `sync_rejects` rather than discarded. A table that holds the
// losing side of a conflict but that nobody can ever open is functionally indistinguishable from
// having actually lost the edit — which is the one thing this whole feature exists to avoid. This
// view is NOT the full conflict-resolution UI design.md §12 defers; it is the minimum "you can at
// least go look" screen: a list, a timestamp, which device it came from, and the raw JSON.
//
// Shared between macOS and iOS — plain SwiftUI only, `#if os(...)` guards around the one place that
// needs a platform pasteboard API.
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SyncRejectsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selected: SyncReject?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(VolarColor.border)
            if appState.syncRejects.isEmpty {
                emptyState
            } else {
                list
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 480)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(VolarColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .volarHairline(cornerRadius: 16)
        .onAppear {
            appState.loadSyncRejects()
        }
        .sheet(item: $selected) { reject in
            SyncRejectDetail(reject: reject)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lost edits")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text("Edits another device's version overwrote during sync. Nothing here was deleted from any device — this is a record of what lost.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                    .padding(6)
                    .background(VolarColor.veil(0.06))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(VolarColor.done)
            Text("Nothing lost")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
            Text("No sync conflicts have happened yet.")
                .font(.system(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(appState.syncRejects) { reject in
                    Button {
                        selected = reject
                    } label: {
                        rejectRow(reject)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func rejectRow(_ reject: SyncReject) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(reject.title ?? "Untitled task")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(reject.rejectedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Font.volarMono(size: 10.5))
                        .monospacedDigit()
                    if let origin = reject.originDevice {
                        Text("· from \(origin)")
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(VolarColor.textMut)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(VolarColor.textMut)
        }
        .padding(12)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }
}

/// The JSON detail for one rejected row — its own sheet (rather than an inline `DisclosureGroup`)
/// so the raw payload gets real room and `.textSelection` works predictably on both platforms.
private struct SyncRejectDetail: View {
    let reject: SyncReject
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(reject.title ?? "Untitled task")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VolarColor.textMut)
                        .padding(6)
                        .background(VolarColor.veil(0.06))
                        .clipShape(Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Rejected \(reject.rejectedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Losing edit was stamped \(reject.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                if let origin = reject.originDevice {
                    Text("From device: \(origin)")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(VolarColor.textSec)

            ScrollView {
                Text(reject.payloadJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VolarColor.textPri)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(VolarColor.surfaceHi)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)

            Button {
                Self.copyToPasteboard(reject.payloadJSON)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy raw JSON")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(18)
        #if os(macOS)
        .frame(width: 420, height: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(VolarColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .volarHairline(cornerRadius: 16)
    }

    /// The one platform-specific line in this file. `sync_rejects`' `payload` can carry
    /// `sourceTranscript` (design.md §9) — this only ever runs from an explicit user tap on "Copy",
    /// never automatically, so it doesn't violate the "never log the payload" rule (copying to the
    /// user's OWN clipboard on their OWN request isn't logging).
    private static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

#Preview {
    SyncRejectsView()
        .environment(AppState())
}
