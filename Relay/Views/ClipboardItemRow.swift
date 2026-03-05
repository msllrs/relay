import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem

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

            Spacer()

            Text(item.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("\(item.contentType.label): \(item.preview)")
    }
}
