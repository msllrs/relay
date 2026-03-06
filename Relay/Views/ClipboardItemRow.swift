import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    var onRemove: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.contentType.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.contentType.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.contentType == .image, let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 40)
                        .cornerRadius(4)
                } else {
                    Text(item.preview)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(item.contentType.label): \(item.preview)")
    }
}
