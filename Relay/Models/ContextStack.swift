import Foundation

@MainActor
final class ContextStack: ObservableObject {
    static let maxItems = 20

    @Published var items: [ClipboardItem] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var isNearLimit: Bool { items.count >= Self.maxItems - 2 }
    var isAtLimit: Bool { items.count >= Self.maxItems }

    func add(_ item: ClipboardItem) {
        if items.count >= Self.maxItems {
            items.removeFirst()
        }
        items.append(item)
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        items.removeAll()
    }
}
