import SwiftUI

struct MiniWaveformView: View {
    let level: Float

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2.5
    private let seeds: [Double] = [0.7, 1.0, 0.8]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<3, id: \.self) { i in
                let normalized = min(Double(level) * 6.0, 1.0)
                let fraction = 0.15 + 0.85 * normalized * seeds[i]
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.white)
                    .frame(width: barWidth, height: fraction * 14)
            }
        }
        .frame(height: 14)
        .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: level)
    }
}

/// Custom SVG icon shown when a clipboard item is captured during recording.
struct ClipboardRelayIcon: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 16
            let sy = size.height / 16
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)

            // Top line: M1 2.5 h14
            var top = Path()
            top.move(to: CGPoint(x: 1 * sx, y: 2 * sy))
            top.addLine(to: CGPoint(x: 15 * sx, y: 2 * sy))
            context.stroke(top, with: .color(.white.opacity(0.64)), style: style)

            // Middle capsule: M13 6 H3 a2 2 0 1 0 0 4 h10 a2 2 0 1 0 0 -4
            var capsule = Path()
            capsule.move(to: CGPoint(x: 13 * sx, y: 6 * sy))
            capsule.addLine(to: CGPoint(x: 3 * sx, y: 6 * sy))
            capsule.addRelativeArc(
                center: CGPoint(x: 3 * sx, y: 8 * sy),
                radius: 2 * sy,
                startAngle: .degrees(-90),
                delta: .degrees(-180)
            )
            capsule.addLine(to: CGPoint(x: 13 * sx, y: 10 * sy))
            capsule.addRelativeArc(
                center: CGPoint(x: 13 * sx, y: 8 * sy),
                radius: 2 * sy,
                startAngle: .degrees(90),
                delta: .degrees(-180)
            )
            context.stroke(capsule, with: .color(.white), style: style)

            // Bottom line: M1 13.5 h14
            var bottom = Path()
            bottom.move(to: CGPoint(x: 1 * sx, y: 14 * sy))
            bottom.addLine(to: CGPoint(x: 15 * sx, y: 14 * sy))
            context.stroke(bottom, with: .color(.white.opacity(0.64)), style: style)
        }
    }
}

struct RecordingOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovering = false

    private let circleSize: CGFloat = 36

    private enum Mode {
        case waveform, clipboard, stop
    }

    private var mode: Mode {
        if isHovering { return .stop }
        if appState.itemJustAdded { return .clipboard }
        return .waveform
    }

    var body: some View {
        ZStack {
            // Base fill
            Circle()
                .fill(.black.opacity(0.7))
                .frame(width: circleSize, height: circleSize)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            // Outer edge: thin dark ring for definition
            Circle()
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .frame(width: circleSize, height: circleSize)

            // Inner highlight: top-weighted specular edge
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .frame(width: circleSize - 1, height: circleSize - 1)
                .blendMode(.screen)

            switch mode {
            case .waveform:
                MiniWaveformView(level: appState.voiceManager.audioLevel)
                    .transition(.opacity.combined(with: .scale))
            case .clipboard:
                ClipboardRelayIcon()
                    .frame(width: 14, height: 14)
                    .transition(.opacity.combined(with: .scale))
            case .stop:
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: circleSize, height: circleSize)
        .padding(10) // room for shadow
        .contentShape(Circle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            appState.finishDictationAndStop()
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }
}
