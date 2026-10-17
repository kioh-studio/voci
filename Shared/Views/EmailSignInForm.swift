// Sources/Views/EmailSignInForm.swift — the ONE email-OTP sign-in form in the app.
//
// Extracted out of `SettingsView`'s old `signedOutAccountBody` (main-window "Sign in" entry point
// fix, 2026-07-28): that Settings ▸ Account tab used to be the ONLY place a user could sign in,
// which meant a brand-new user had no visible way to ever reach cloud speech/parsing or a Pro
// purchase. Rather than write a SECOND copy of the email-OTP form for the new `SignInSheet` (opened
// from the main window's toolbar, and from `PaywallView`'s "Sign in to subscribe" CTA), this view
// is that form, lifted out verbatim. The macOS `SettingsView.signedOutAccountBody` embeds this view;
// iOS keeps its own copy in `SettingsIOSView`.
//
// Sign in with Apple was removed from Volar entirely on 2026-07-27 — email OTP (one-time 6-digit
// code) is the ONLY sign-in method left. Nothing here should ever grow an Apple/ASAuthorization
// path back in.
import SwiftUI

struct EmailSignInForm: View {
    /// Fired once sign-in actually succeeds (`appState.accountEmail` flips from nil to non-nil).
    /// Lets a caller that presents this inside a sheet — `SignInSheet` — know to dismiss itself.
    /// Default no-op so this view keeps working standalone, exactly as it did embedded directly in
    /// `SettingsView`'s Account tab (which stays open after signing in; nothing there should close).
    var onSignedIn: () -> Void = {}

    // View-local UI-FLOW state only, same split every other Settings tab already follows: the
    // field TEXT and "has a code been sent yet" flag are cosmetic/local; the real network call,
    // busy flag, and error message live on `appState` (`accountBusy`/`accountError`) — this view
    // never invents its own copy of those.
    @State private var emailInput = ""
    @State private var codeInput = ""
    @State private var codeSent = false

    @Environment(AppState.self) private var appState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("you@example.com", text: $emailInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(VolarColor.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .volarHairline(cornerRadius: 5)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                pillButton("Send code") {
                    // Optimistic flip, same as the form this was extracted from: the second field
                    // appears immediately on tap rather than waiting for the network round trip —
                    // if `sendEmailOTP` fails, `appState.accountError` below still surfaces why.
                    codeSent = true
                    appState.sendEmailOTP(email: emailInput)
                }
                .disabled(appState.accountBusy || emailInput.isEmpty)
            }

            if codeSent {
                HStack(spacing: 8) {
                    TextField("6-digit code", text: $codeInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .frame(width: 120)
                        .background(VolarColor.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .volarHairline(cornerRadius: 5)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    pillButton("Verify", solid: true) {
                        appState.verifyEmailOTP(email: emailInput, code: codeInput)
                    }
                    .disabled(appState.accountBusy || codeInput.count != 6)
                }
            }

            if let accountError = appState.accountError {
                Text(accountError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(4)
            }
        }
        // `verifyEmailOTP` is fire-and-forget (AppState runs it on its own `_Concurrency.Task` and
        // mirrors the outcome into `@Observable` state — see AppState.swift's account methods);
        // there is no completion callback to hang `onSignedIn` off of. Watching `accountEmail` flip
        // nil -> non-nil is the same technique `PaywallView` already uses to detect a successful
        // purchase (its `.onChange(of: appState.accountTier)` closing the paywall sheet).
        .onChange(of: appState.accountEmail) { oldEmail, newEmail in
            if oldEmail == nil, newEmail != nil {
                onSignedIn()
            }
        }
    }

    /// Local re-declaration of `SettingsView.settingsPillButton`'s exact visual recipe (font,
    /// padding, corner radius, hairline stroke). That original is `private` to `SettingsView` — a
    /// file this task leaves untouched apart from `signedOutAccountBody` itself — so making it
    /// shared would mean editing a second, unrelated part of that file. Repeating the small style
    /// recipe here is the lower-risk option; any future drift between the two is a pre-existing
    /// styling-duplication risk, not something new introduced by this file.
    private func pillButton(_ title: String, solid: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(solid ? .white : VolarColor.textPri)
                .padding(.horizontal, 14)
                .frame(height: 30)
                // Vùng bấm phải phủ đúng vùng NHÌN THẤY (luật anh Khôi chốt 2026-08-09) — xem
                // `Sidebar.swift`'s `SectionHeaderRow` cho giải thích đầy đủ. Ở đây `.background` nằm
                // sau `.buttonStyle(.plain)` nên viên pill mà mắt thấy không thuộc label; nếu
                // không có dòng này thì chỉ mỗi chữ ăn click, còn 14pt padding hai bên là vùng
                // chết.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(solid ? accentColors.solid : VolarColor.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solid ? VolarColor.veil(0.18) : VolarColor.borderHi, lineWidth: 0.5)
        )
    }
}

#Preview {
    EmailSignInForm()
        .environment(AppState())
        .padding(20)
        .background(VolarColor.bg)
}
