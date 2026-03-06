import SwiftUI

struct EmptyStateView: View {
    var isMonitoring: Bool
    var shortcutDisplay: String = KeyboardShortcutModel.load().displayString

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)

            if isMonitoring {
                Text("Copy something to get started")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Relay captures clipboard changes automatically")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Monitoring is paused")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Press Resume or \(shortcutDisplay) to start capturing")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
