import SwiftUI

struct PromptPillView: View {
    let isRecording: Bool
    let audioLevel: Float
    let shortcutDisplay: String
    var onStop: () -> Void

    var body: some View {
        Group {
            if isRecording {
                recordingPill
            } else {
                idlePill
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var idlePill: some View {
        Text("Press \(shortcutDisplay) to start recording")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
            )
    }

    private var recordingPill: some View {
        HStack(spacing: 10) {
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 20, height: 20)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorScheme == .dark ? Color.black : Color.white)
                        .frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)

            WaveformBarsView(level: audioLevel)
                .frame(height: 20)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.08))
        )
    }
}
