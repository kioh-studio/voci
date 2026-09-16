// Sources/Views/OnboardingView.swift — 4-step first-run onboarding, ported from
// `design/volar-extras.jsx`'s `VolarOnboardingStep`. Native-first: no faux titlebar (a real window
// already has real traffic lights), just the step content + dots + footer. Step advancement here
// is purely cosmetic UI state; real permission requests are Phase 3.
//
// CHANGE 2 (2026-07-27, cloud-first privacy sweep): step 2 used to claim "Audio is processed
// on-device using Apple's Speech framework. Nothing is uploaded. Nothing is stored." — false under
// the cloud-first product direction (Change 1: cloud parsing is now the default, and a signed-in
// Pro user's audio can go to Groq too), and it was the FIRST screen a new user saw, directly
// contradicting the App Store privacy label this app must declare (Audio Data + User Content).
// That line, step 1's "No typing, no menus" (wrong since today's ⌃⌥T typed-capture hotkey), and the
// step-2 "On-device · No network calls" badge are all deleted/reworded below — see each step's own
// comment for the specific old->new text. A brand-new step 3 (cloud-parsing consent) replaces the
// silent-default approach with a real, visible, PRE-SELECTED-ON toggle wired to the exact same
// `cloudParseConsent` flag (`AppState.cloudParseConsentKey`) every other consent surface in this
// app already reads and writes (`AppState.setParseEngine`, the Settings picker, the in-flow
// voice-capture consent popover) — never a second, independently-tracked consent bit.
import SwiftUI

struct OnboardingView: View {
    @State private var step: Int
    /// Local UI mirror of the step-3 cloud-consent toggle, pre-selected `true` per the product
    /// decision ("ask during onboarding, cloud pre-selected" — a real visible choice, not a silent
    /// default and not fine print). Re-read from `appState.cloudParseConsent` in `stepThree`'s
    /// `.onAppear` so a user who somehow re-onboards (e.g. a future onboarding-version bump) after
    /// already having made an explicit choice elsewhere sees THEIR choice reflected here instead of
    /// being silently reset to `true` — "never overwrite a stored value" applies to this screen
    /// exactly as it does to `AppState`'s own persisted-default resolution (Change 1).
    @State private var cloudConsentOn = true
    var onComplete: () -> Void = {}

    @Environment(AppState.self) private var appState

    init(step: Int = 1, onComplete: @escaping () -> Void = {}) {
        _step = State(initialValue: step)
        self.onComplete = onComplete
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer()
                stepContent
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(40)
                Spacer()
                footer
            }
            stepDots
                .padding(.top, 20)
                .padding(.trailing, 24)
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(VolarColor.bg)
    }

    // MARK: - Step dots

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? accentColors.solid : VolarColor.veil(0.15))
                    .frame(width: i == step ? 18 : 6, height: 6)
                    .animation(VolarMotion.hover, value: step)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Step \(step) of 4")
                .foregroundStyle(VolarColor.textMut)
            Spacer()
            Text("volar.app")
                .foregroundStyle(VolarColor.textSec)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: stepOne
        case 2: stepTwo
        case 3: stepThree
        default: stepFour
        }
    }

    private func title(_ text: Text) -> some View {
        text
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(VolarColor.textPri)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(VolarColor.textSec)
            .lineSpacing(4)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step 1: hotkey intro

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 84)
                .overlay { VolarIcon(.mic, size: 42, color: .white, weight: .regular) }
                .shadow(color: accentColors.glow, radius: 24, y: 10)
                .padding(.bottom, 28)

            HStack(spacing: 8) {
                Text("Press")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                KeyBadge("\u{2303}", accent: true)
                KeyBadge("\u{2325}", accent: true)
                KeyBadge("M", accent: true)
                Text(".")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
            }
            .padding(.bottom, 2)

            title(Text("Speak. Done."))
                .padding(.bottom, 14)

            // OLD: "Volar is a voice-first task manager. No typing, no menus — just press the
            // hotkey from anywhere on your Mac and say what you need to do." Wrong as of today: a
            // typed-capture hotkey (⌃⌥T) shipped, so "no typing, no menus" is no longer true.
            subtitle("Volar is a voice-first task manager. Press the hotkey from anywhere on your Mac and say what you need to do \u{2014} or type it instead with \u{2303}\u{2325}T when talking isn't an option.")
                .padding(.bottom, 30)

            Button {
                withAnimation { step = 2 }
            } label: {
                HStack(spacing: 6) {
                    Text("Get started")
                    Text("\u{2192}")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: accentColors.glow, radius: 20, y: 6)
        }
    }

    // MARK: - Step 2: mic permission

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(1..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accentColors.solid.opacity(0.15 / Double(i)), lineWidth: 1)
                        .frame(width: 84 + CGFloat(i) * 12, height: 84 + CGFloat(i) * 12)
                }
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 84, height: 84)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.33), lineWidth: 0.5)
                    }
                    .overlay { VolarIcon(.mic, size: 42, color: accentColors.solid, weight: .regular) }
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 28)

            title(Text("Volar needs your microphone."))
                .padding(.bottom, 14)

            // OLD (deleted — false under cloud-first): "Audio is processed on-device using
            // Apple's Speech framework. Nothing is uploaded. Nothing is stored. The waveform
            // stays on your Mac." This was the first privacy claim a new user saw, and it no
            // longer holds: cloud parsing is now the default (step 3, next), and a signed-in Pro
            // user's audio can go to Groq's cloud speech engine too. Replaced with a slogan that
            // makes no locality claim at all — the actual, accurate cloud-vs-on-device story is
            // told once, properly, on the dedicated consent step instead of restated (and
            // potentially re-broken) here.
            subtitle("This unlocks hands-free capture: press the hotkey, say what's on your mind, and Volar turns it into a task.")
                .padding(.bottom, 30)

            HStack(spacing: 10) {
                Button {
                    Task {
                        _ = await appState.speech.requestAuthorization()
                        withAnimation { step = 3 }
                    }
                } label: {
                    Text("Allow microphone")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .background(accentColors.solid)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: accentColors.glow, radius: 20, y: 6)

                Button {
                    withAnimation { step = 3 }
                } label: {
                    Text("Not now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .volarHairline(cornerRadius: 11)
            }
            .padding(.bottom, 22)

            // OLD (deleted — false under cloud-first): "On-device · No network calls". Speech
            // recognition itself DOES still run on-device by default for a free/signed-out
            // user (`AppState.selectedEngine`: Groq only activates once `GroqEngine.isConfigured`
            // — a signed-in Pro session — so this remains genuinely true for a fresh install at
            // exactly this moment), but stating it as a blanket, permanent badge here would
            // mislead anyone who later signs in for Pro cloud speech, and duplicates the honest
            // disclosure the new step 3 already gives about text/task parsing.
            HStack(spacing: 8) {
                Circle().fill(VolarColor.done).frame(width: 6, height: 6)
                Text("Speech recognition runs on-device unless you sign in for cloud transcription later.")
            }
            .font(.system(size: 12))
            .foregroundStyle(VolarColor.textMut)
        }
    }

    // MARK: - Step 3: cloud-parsing consent (NEW — Change 2)
    //
    // Replaces a silent cloud-first default with a real, visible, pre-selected-ON toggle (product
    // decision: "ask during onboarding, cloud pre-selected" over silently enabling upload, which
    // would violate the project's opt-in principle and mis-state the privacy label). The toggle is
    // wired DIRECTLY to `appState.setParseEngine(_:)` — the SAME method the Settings picker uses,
    // which persists to the SAME `cloudParseConsent` / `AppState.cloudParseConsentKey` the rest of
    // the app already reads (`parseEnginePreference`, `DefaultCloudParseGate.isOptedIn()`).
    // 2026-09-06: `proceedToCapture`'s one-time consent gate is gone (cloud is the default on every
    // entry point, unanswered = yes), so this toggle is now the only macOS surface that can write
    // the opt-OUT — the flag it writes is still honoured on every path. No second consent flag is
    // introduced anywhere in this
    // file — two flags that could disagree is exactly how an app ends up uploading for a user who
    // said no.

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(accentColors.surface)
                .frame(width: 84, height: 84)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accentColors.solid.opacity(0.33), lineWidth: 0.5)
                }
                .overlay { VolarIcon(.sparkle, size: 38, color: accentColors.solid, weight: .regular) }
                .padding(.bottom, 28)

            title(Text("Turn your words into tasks."))
                .padding(.bottom, 14)

            // Honest, short — says what actually happens (text goes to Volar's server to be
            // parsed) without a second overclaim in the other direction ("your data is safe" /
            // "we never store anything" — nothing here asserts either, since nothing in this
            // file can guarantee it). Full detail lives in the toggle row + its caption below,
            // not crammed into this one line.
            subtitle("What you say \u{2014} or type \u{2014} is sent to Volar's server and turned into tasks. You're in control of that below, and can change it anytime in Settings.")
                .padding(.bottom, 22)

            HStack(alignment: .top, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { cloudConsentOn },
                    set: { cloudConsentOn = $0 }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accentColors.solid)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Send to Volar's cloud for parsing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                    // Live caption — always names the CURRENT state of the toggle, not just the
                    // pre-selected default, so flipping it off before continuing is truthful too.
                    Text(cloudConsentOn
                         ? "On \u{2014} better understanding of tricky phrasing. Only the TEXT of what you say/type is sent — never raw audio."
                         : "Off \u{2014} Volar parses on-device instead. The text of what you say/type never leaves your Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(VolarColor.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: 460, alignment: .leading)
            .background(VolarColor.veil(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)
            .padding(.bottom, 30)

            Button {
                // THE actual consent write: same `AppState.setParseEngine(_:)` the Settings
                // picker uses, persisting to the SAME `cloudParseConsent` /
                // `cloudParseConsentKey` every other consent surface in the app reads. Whatever
                // `cloudConsentOn` holds right now — the pre-selected `true` default if
                // untouched, or whatever the user flipped it to — becomes the user's real,
                // persisted choice the instant they continue past this screen.
                appState.setParseEngine(cloudConsentOn ? .cloud : .onDevice)
                withAnimation { step = 4 }
            } label: {
                HStack(spacing: 6) {
                    Text("Continue")
                    Text("\u{2192}")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: accentColors.glow, radius: 20, y: 6)
        }
        .onAppear {
            // Re-onboarding edge case (a future onboarding-version bump could show this screen
            // again to a user who already made this choice — in Settings, or via the in-flow
            // voice-capture consent popover): reflect their EXISTING persisted decision instead
            // of silently re-defaulting to ON, so simply continuing through this screen again can
            // only reproduce their choice, never flip it. A brand-new install has no persisted
            // value yet (`cloudParseConsent == nil`), so the `?? true` fallback below is what
            // actually delivers the "pre-selected ON" requirement.
            cloudConsentOn = appState.cloudParseConsent ?? true
        }
    }

    // MARK: - Step 4: try it

    private var stepFour: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KeyBadge("\u{2303}", accent: true)
                KeyBadge("\u{2325}", accent: true)
                KeyBadge("M", accent: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(accentColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
            )
            .padding(.bottom, 32)

            title(Text("Try it now."))
                .padding(.bottom, 14)

            subtitle("Press the hotkey and say your first task. We'll parse the time, priority, and project for you.")
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 4) {
                Text("TRY SAYING")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(VolarColor.textMut)
                Text("\u{201C}Call John tomorrow at 3pm, high priority\u{201D}")
                    .font(.system(size: 14))
                    .foregroundStyle(VolarColor.textPri)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(VolarColor.veil(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)
            .padding(.bottom, 22)

            Button {
                onComplete()
            } label: {
                HStack(spacing: 6) {
                    Text("Start using Volar")
                    Text("\u{2192}")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: accentColors.glow, radius: 20, y: 6)
            .padding(.bottom, 10)

            Button {
                onComplete()
            } label: {
                Text("Skip for now")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .frame(height: 36)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}

#Preview("Step 2") {
    OnboardingView(step: 2)
        .environment(AppState())
}

#Preview("Step 3 (cloud consent)") {
    OnboardingView(step: 3)
        .environment(AppState())
}

#Preview("Step 4") {
    OnboardingView(step: 4)
        .environment(AppState())
}
