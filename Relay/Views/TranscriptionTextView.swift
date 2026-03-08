import SwiftUI

struct TranscriptionTextView: View {
    let text: String
    let items: [ClipboardItem]
    var onRemoveRef: ((Int) -> Void)?

    var body: some View {
        FlowLayout(rowSpacing: 6, itemSpacing: 4, minRowHeight: 22) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .word(let word):
                    Text(word)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                case .chip(let index):
                    let item = resolveItem(index: index)
                    RefChipView(
                        label: item?.contentType.label ?? "Ref \(index)",
                        contentType: item?.contentType ?? .text,
                        previewText: item?.textContent,
                        previewImage: item?.thumbnail,
                        onRemove: { onRemoveRef?(index) }
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: text)
    }

    private enum SegmentKind {
        case word(String)
        case chip(Int)
    }

    private struct Segment: Identifiable {
        let id: String
        let kind: SegmentKind
    }

    /// Non-voice-note items, cached for resolving refs.
    private var nonVoiceItems: [ClipboardItem] {
        items.filter { $0.contentType != .voiceNote }
    }

    private var segments: [Segment] {
        // Limit displayed text for performance
        let displayText = text.count > 500 ? String(text.suffix(500)) : text
        let resolved = nonVoiceItems

        let pattern = /\[ref:(\d+)\]/
        var result: [Segment] = []
        var remaining = displayText[...]
        // Track word occurrences to create stable IDs even for duplicate words
        var wordCounts: [String: Int] = [:]

        while let match = remaining.firstMatch(of: pattern) {
            // Text before the match → split into words
            let before = remaining[remaining.startIndex..<match.range.lowerBound]
            let words = before.split(separator: " ", omittingEmptySubsequences: true)
            for word in words {
                let w = String(word)
                let count = wordCounts[w, default: 0]
                wordCounts[w] = count + 1
                result.append(Segment(id: "w_\(w)_\(count)", kind: .word(w)))
            }

            // Use the item's UUID as stable identity so renumbering doesn't confuse SwiftUI
            if let refIndex = Int(match.output.1) {
                let itemID = (refIndex >= 1 && refIndex <= resolved.count)
                    ? resolved[refIndex - 1].id.uuidString
                    : "unknown\(refIndex)"
                result.append(Segment(id: "ref_\(itemID)", kind: .chip(refIndex)))
            }

            remaining = remaining[match.range.upperBound...]
        }

        // Remaining text after last match
        let words = remaining.split(separator: " ", omittingEmptySubsequences: true)
        for word in words {
            let w = String(word)
            let count = wordCounts[w, default: 0]
            wordCounts[w] = count + 1
            result.append(Segment(id: "w_\(w)_\(count)", kind: .word(w)))
        }

        return result
    }

    private func resolveItem(index: Int) -> ClipboardItem? {
        let resolved = nonVoiceItems
        guard index >= 1, index <= resolved.count else { return nil }
        return resolved[index - 1]
    }
}
