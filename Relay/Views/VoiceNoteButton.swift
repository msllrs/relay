import SwiftUI

struct VoiceNoteButton: View {
    @ObservedObject var voiceManager: VoiceManager
    var onTranscription: (String) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    voiceManager.toggleRecording { transcription in
                        onTranscription(transcription)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: voiceManager.isRecording ? "stop.circle.fill" : "mic.circle")
                            .font(.title3)
                            .foregroundStyle(voiceManager.isRecording ? .red : .primary)
                            .symbolEffect(.pulse, isActive: voiceManager.isRecording)

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
    }
}
