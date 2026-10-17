// Sources/Views/MorningFrogView.swift — "Good morning" daily-frog modal, ported from
// `design/volar-extras.jsx`'s `VolarMorningFrog`. Candidates are sourced live from
// `appState.openTasks` (title + "urgent" flag when priority == .high) instead of the prototype's
// static sample list. Phase 3: mounted as a daily first-launch sheet from `VolarApp.swift`;
// picking a candidate calls `AppState.pickFrog(_:)` (sets it as today's frog + dismisses),
// "Skip today" / the voice CTA call `AppState.dismissMorningFrog()`.
import SwiftUI

struct MorningFrogView: View {
    @State private var picked: UUID?

    var onPick: (UUID) -> Void = { _ in }
    var onSkip: () -> Void = {}

    @Environment(AppState.self) private var appState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack {
            // Dimmed background suggestion (the real Today window sits behind this modal).
            LinearGradient(colors: [VolarColor.bg, VolarColor.surface], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            modal
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var modal: some View {
        VStack(spacing: 16) {
            Text("Good morning.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VolarColor.textPri)

            Text("What's the one task that, if you finished it today, would make today a win?")
                .font(.system(size: 16))
                .foregroundStyle(VolarColor.textPri)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            voiceCTA
                .padding(.top, 4)

            divider

            candidateList

            Button {
                onSkip()
            } label: {
                Text("Skip today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                    .frame(height: 32)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .volarGlass(level: .standard, cornerRadius: 16)
    }

    // MARK: - Voice CTA

    @State private var pulse = false

    private var voiceCTA: some View {
        Button {
            // Answer by voice, then dismiss this modal the same way "Skip today" does. Stays on
            // `toggleCapture()`: this prompt asks the user to SPEAK an answer, so the one thing it
            // must never do is silently save some unrelated draft that happened to still be open.
            // `handleHotkey()` is for the bare ⌃⌥M keypress only — see its own doc comment.
            appState.toggleCapture()
            onSkip()
        } label: {
            HStack(spacing: 10) {
                VolarIcon(.mic, size: 16, color: accentColors.solid, weight: .regular)
                Text("Tap")
                    .font(.system(size: 14, weight: .medium))
                KeyBadge("M", accent: true)
                Text("to answer")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
        )
        .shadow(color: accentColors.glow.opacity(pulse ? 0.55 : 0), radius: pulse ? 14 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var divider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
            Text("or")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textMut)
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }

    // MARK: - Candidates

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PICK FROM YOUR LIST")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            if appState.openTasks.isEmpty {
                Text("Nothing open today \u{2014} enjoy it.")
                    .font(.system(size: 13))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(appState.openTasks) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: TaskItem) -> some View {
        let selected = picked == candidate.id
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(selected ? accentColors.solid : VolarColor.veil(0.28), lineWidth: 1.5)
                    .background(Circle().fill(selected ? accentColors.solid : Color.clear))
                    .frame(width: 14, height: 14)
                if selected {
                    VolarIcon(.check, size: 9, color: .white, weight: .bold)
                }
            }

            Text(candidate.title)
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)

            Spacer(minLength: 8)

            if candidate.priority == .high {
                HStack(spacing: 5) {
                    Circle().fill(VolarColor.high).frame(width: 5, height: 5)
                    Text("urgent")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(VolarColor.high)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(VolarColor.high.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? accentColors.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? accentColors.solid.opacity(0.27) : .clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            picked = candidate.id
            onPick(candidate.id)
        }
    }
}

#Preview {
    MorningFrogView()
        .environment(AppState())
}
