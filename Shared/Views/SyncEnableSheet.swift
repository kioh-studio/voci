// Shared/Views/SyncEnableSheet.swift — the "turn sync on" confirmation sheet.
//
// UNVERIFIED: written on Windows, never compiled — no Swift/Xcode toolchain on this dev machine.
//
// Group C's most important screen (task brief). Shown by `SettingsView` (macOS) / `SettingsIOSView`
// (iOS) whenever the "Sync across devices" toggle is flipped from OFF to ON while the account is
// Pro — never on the OFF path (turning sync off never needs confirmation, design.md §8.3), and
// never when the account isn't Pro (that path routes to the upgrade flow instead, since enabling
// would just 403 with `sync_pro_required`).
//
// THREE THINGS THIS SCREEN MUST SAY, VERBATIM IN SPIRIT (design.md §8.1, client-contract.md's task
// brief — "không được làm mềm đi"):
//   1. Turning this on uploads EVERY task on this device, including `sourceTranscript` (the user's
//      raw spoken words), to Volar's server.
//   2. The switch is ACCOUNT-level: every other device signed in to this account starts uploading
//      too, and so does every device that signs in later — without asking again.
//   3. Turning it back off does not delete what's already uploaded — there's a separate button for
//      that (`SettingsView`'s "Delete data on server" row, which calls `AppState.purgeSyncData()`).
//
// Deliberately does NOT list which devices are signed in to this account (design.md §8.1 / §12):
// listing them would require every device to have already pinged the server BEFORE the user
// consents, which defeats the point of asking first. The real device list is `SyncState.devices`,
// shown in Settings only AFTER sync is on.
//
// Shared between macOS and iOS (`Shared/Views/`) — plain SwiftUI only, no AppKit/UIKit import, no
// API that isn't available on both platforms without an `#if os(macOS)` guard.
import SwiftUI

struct SyncEnableSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            closeRow
            header
            bulletList
            if let error = appState.syncError {
                Text(error)
                    .font(.system(size: 11.5))
                    // Status/warning text, not an irreversible-action label — same "no red for
                    // status" rule every other inline error in this app follows
                    // (`PaywallView.accountError`, `SettingsView.accountCard`'s equivalent row).
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(4)
            }
            actionButtons
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(VolarColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .volarHairline(cornerRadius: 16)
        // A successful enable flips `appState.syncState.syncEnabled` — close automatically so the
        // CTA's own success path doesn't need to know anything about sheet presentation, same
        // pattern `PaywallView`'s `.onChange(of: appState.accountTier)` already uses.
        .onChange(of: appState.syncState.syncEnabled) { _, enabled in
            if enabled { dismiss() }
        }
    }

    // MARK: - Close

    private var closeRow: some View {
        HStack {
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
                    // Vùng bấm phải phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09) —
                    // `.background`/`.clipShape` ở trên nằm trong label nên thực ra label ĐÃ vẽ đầy
                    // hình tròn; `.contentShape` vẫn đặt tường minh ở đây để không phụ thuộc vào
                    // việc label có luôn vẽ đầy vùng nó chiếm hay không (xem `Sidebar.swift`'s
                    // `SectionHeaderRow` cho lý do đầy đủ của luật này).
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 18, weight: .medium))
                    // Informational icon, not the NOW spotlight — `VolarColor.instrument` (ice
                    // blue), never `nowAccent` (mint is reserved exclusively for the NOW task).
                    .foregroundStyle(VolarColor.instrument)
                Text("Turn on sync across devices?")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
            }
            Text("Read this before you turn it on — it can't be quietly undone.")
                .font(.system(size: 12))
                .foregroundStyle(VolarColor.textSec)
        }
    }

    // MARK: - The three mandatory points

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet(
                icon: "text.bubble",
                text: "Uploads **every task on this device** to Volar's server — including your source transcript, the exact words you spoke to create it."
            )
            bullet(
                icon: "person.2",
                text: "This switch is for your **whole account**. Every other device signed in to it starts uploading its own tasks too — and so will any device that signs in later, without asking again."
            )
            bullet(
                icon: "arrow.uturn.backward",
                text: "You can turn this off anytime, but **turning it off does not delete what's already uploaded**. Deleting server data is a separate button."
            )
        }
        .padding(14)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .volarHairline(cornerRadius: 10)
    }

    private func bullet(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
                .padding(.top, 1)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    // Luật `.contentShape` cuối label — `.background` ngay dưới nằm NGOÀI Button.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button {
                appState.setSyncEnabled(true)
            } label: {
                HStack(spacing: 8) {
                    if appState.syncBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Turn on sync")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                // Same rule, same reasoning as `PaywallView.ctaButton` (commit 356b72f) — this is
                // the confirming action of the whole sheet, so a dead-feeling miss here is exactly
                // the family of bug that commit fixed.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .disabled(appState.syncBusy)
        }
    }
}

#Preview {
    SyncEnableSheet()
        .environment(AppState())
}
