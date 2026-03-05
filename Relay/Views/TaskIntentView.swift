import SwiftUI

struct TaskIntentView: View {
    @Binding var taskIntent: String

    var body: some View {
        TextField("What should the AI do?", text: $taskIntent, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Task intent")
    }
}
