import SwiftUI

struct ContextStackView: View {
    @ObservedObject var stack: ContextStack

    var body: some View {
        List {
            ForEach(stack.items) { item in
                ClipboardItemRow(item: item)
            }
            .onDelete { offsets in
                stack.remove(at: offsets)
            }
            .onMove { source, destination in
                stack.move(from: source, to: destination)
            }
        }
        .listStyle(.plain)
    }
}
