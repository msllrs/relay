import SwiftUI

struct WaveformBarsView: View {
    let level: Float

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minBarFraction: CGFloat = 0.15

    @State private var seeds: [Double] = (0..<60).map { _ in Double.random(in: 0.5...1.0) }

    var body: some View {
        GeometryReader { geo in
            let barCount = max(1, Int(geo.size.width / (barWidth + barSpacing)))
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let seed = i < seeds.count ? seeds[i] : 0.7
                    let normalized = min(Double(level) * 6.0, 1.0)
                    let fraction = minBarFraction + (1 - minBarFraction) * normalized * seed
                    let barHeight = fraction * Double(geo.size.height)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(Color.primary.opacity(0.16 + 0.34 * normalized * seed))
                        .frame(width: barWidth, height: barHeight)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: level)
        .onChange(of: level) { _, _ in
            for i in 0..<seeds.count {
                seeds[i] = Double.random(in: 0.4...1.0)
            }
        }
    }
}
