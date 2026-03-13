import SwiftUI

struct TranscriptionTextView: View {
    let text: String
    let items: [ClipboardItem]
    let isRecording: Bool
    var onRemoveRef: ((Int) -> Void)?

    /// Delays re-enabling text animation after recording stops to avoid bounce.
    @State private var animateText = false

    var body: some View {
        FlowLayout(rowSpacing: 4, itemSpacing: 4, minRowHeight: 20) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .word(let word):
                    Text(word)
                        .font(.system(size: 14, weight: .medium))
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
                    .transition(
                        .modifier(
                            active: ChipDismissModifier(progress: 1),
                            identity: ChipDismissModifier(progress: 0)
                        )
                    )
                }
            }
        }
        .animation(animateText ? .snappy(duration: 0.25) : nil, value: text)
        .animation(.snappy(duration: 0.25), value: items.count)
        .onChange(of: isRecording) { _, recording in
            if recording {
                animateText = false
            } else {
                // Delay enabling animation so finalized text swap doesn't bounce
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    animateText = true
                }
            }
        }
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
        let resolved = nonVoiceItems

        let pattern = /\[ref:(\d+)\]/
        var result: [Segment] = []
        var remaining = text[...]
        // Track word occurrences to create stable IDs even for duplicate words
        var wordCounts: [String: Int] = [:]
        // Track which 1-based item indices are referenced in the text
        var referencedIndices: Set<Int> = []

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
                referencedIndices.insert(refIndex)
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

        // Append chips for items not referenced in the text (captured while not recording)
        for (i, item) in resolved.enumerated() {
            let refIndex = i + 1
            if !referencedIndices.contains(refIndex) {
                result.append(Segment(id: "ref_\(item.id.uuidString)", kind: .chip(refIndex)))
            }
        }

        return result
    }

    private func resolveItem(index: Int) -> ClipboardItem? {
        let resolved = nonVoiceItems
        guard index >= 1, index <= resolved.count else { return nil }
        return resolved[index - 1]
    }
}

/// Combines scale, opacity, and blur into a single animatable transition for chip removal.
private struct ChipDismissModifier: ViewModifier, Animatable {
    var progress: Double // 0 = identity, 1 = fully dismissed

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - progress * 0.99, anchor: .leading)
            .opacity(1 - progress)
            .blur(radius: progress * 4)
    }
}
