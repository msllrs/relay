import SwiftUI

struct VoiceNoteButton: View {
    @ObservedObject var voiceManager: VoiceManager
    var onTranscription: (String) -> Void
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    voiceManager.toggleRecording { transcription in
                        onTranscription(transcription)
                    }
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            if voiceManager.isRecording {
                                Circle()
                                    .fill(.red.opacity(0.3))
                                    .frame(width: 24, height: 24)
                                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                                    .opacity(isPulsing ? 0.0 : 0.6)
                            }
                            Image(systemName: voiceManager.isRecording ? "stop.circle.fill" : "mic.circle")
                                .font(.title3)
                                .foregroundStyle(voiceManager.isRecording ? .red : .primary)
                        }
                        .frame(width: 24, height: 24)

                        Text(voiceManager.isRecording ? "Stop" : "Voice Note")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceManager.isRecording ? "Stop recording" : "Start voice note")

                Spacer()
            }

            if voiceManager.isRecording, !voiceManager.partialTranscription.isEmpty {
                Text(voiceManager.partialTranscription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = voiceManager.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: voiceManager.isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.default) {
                    isPulsing = false
                }
            }
        }
    }
}
