// Sources/Views/MicFAB.swift — floating mic capture button (feature 011, Main.dc.html FAB).
// Tap-to-toggle; `AppState.captureState` is the only source of truth.
// UNVERIFIED: written blind on Windows, never compiled.
import SwiftUI

struct MicFAB: View {
    @Environment(AppState.self) private var appState: AppState

    private var isRecording: Bool { appState.captureState == .recording }

    var body: some View {
        Button {
            appState.toggleCapture()
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 28))
                .foregroundStyle(IOSPalette.onMint)
                .frame(width: IOSLayout.fabSize, height: IOSLayout.fabSize)
                .background(IOSPalette.mint, in: Circle())
                .shadow(color: IOSPalette.mintGlow, radius: 12, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(FABPressStyle())
        .accessibilityLabel(isRecording ? "Stop recording" : "Add task by voice")
    }
}

/// Press scale 0.94 via `configuration.isPressed` (no gesture fighting the Button's own tap).
private struct FABPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
