import SwiftUI

struct PromptPillView: View {
    let isRecording: Bool
    let audioLevel: Float
    let shortcutDisplay: String
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isRecording {
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
                .transition(.scaleBlur)
            }

            if isRecording {
                WaveformBarsView(level: audioLevel)
                    .frame(height: 20)
                    .transition(.scaleBlur)
            } else {
                Text("Press \(shortcutDisplay) to start recording")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .transition(.scaleBlur)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isRecording ? 0.08 : 0.05))
                .transaction { $0.animation = nil }
        )
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    @Environment(\.colorScheme) private var colorScheme
}

private struct ScaleBlurTransition: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - progress * 0.5)
            .opacity(1 - progress)
            .blur(radius: progress * 3)
    }
}

private extension AnyTransition {
    static var scaleBlur: AnyTransition {
        .modifier(
            active: ScaleBlurTransition(progress: 1),
            identity: ScaleBlurTransition(progress: 0)
        )
    }
}
