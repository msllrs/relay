import SwiftUI

struct PromptPillView: View {
    let isRecording: Bool
    let audioLevel: Float
    let shortcutDisplay: String
    var onStart: () -> Void
    var onStop: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Idle label
            Text("Press \(shortcutDisplay) to start recording")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.45))
                .scaleEffect(isRecording ? 0.5 : 1)
                .opacity(isRecording ? 0 : 1)
                .blur(radius: isRecording ? 3 : 0)

            // Recording controls
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
                .scaleEffect(isRecording ? 1 : 0.5)
                .opacity(isRecording ? 0.999 : 0)
                .blur(radius: isRecording ? 0 : 3)
                .allowsHitTesting(isRecording)

                WaveformBarsView(level: audioLevel)
                    .frame(height: 20)
                    .scaleEffect(isRecording ? 1 : 0.5)
                    .opacity(isRecording ? 1 : 0)
                    .blur(radius: isRecording ? 0 : 3)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity((isRecording || isHovered) ? 0.1 : 0.07))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if !isRecording { onStart() }
        }
        .padding(.horizontal, 16)
    }

    @Environment(\.colorScheme) private var colorScheme
}
