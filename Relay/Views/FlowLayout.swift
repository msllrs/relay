import SwiftUI

struct FlowLayout: Layout {
    var rowSpacing: CGFloat = 6
    var itemSpacing: CGFloat = 4
    /// Minimum height for every row, preventing layout shift when taller elements are removed.
    var minRowHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = max(minRowHeight, row.map { $0.size.height }.max() ?? 0)
            height += rowHeight
            if i < rows.count - 1 {
                height += rowSpacing
            }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            let rowHeight = max(minRowHeight, row.map { $0.size.height }.max() ?? 0)
            var x = bounds.minX
            for item in row {
                let subview = subviews[item.index]
                let yOffset = (rowHeight - item.size.height) / 2
                subview.place(at: CGPoint(x: x, y: y + yOffset), proposal: ProposedViewSize(item.size))
                x += item.size.width + itemSpacing
            }
            y += rowHeight
            if i < rows.count - 1 {
                y += rowSpacing
            }
        }
    }

    private struct LayoutItem {
        let index: Int
        let size: CGSize
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutItem]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = currentRowWidth > 0 ? size.width + itemSpacing : size.width

            if currentRowWidth + neededWidth > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }

            rows[rows.count - 1].append(LayoutItem(index: index, size: size))
            currentRowWidth += currentRowWidth > 0 ? size.width + itemSpacing : size.width
        }

        return rows
    }
}
