import AppKit
import QuartzCore
import SwiftUI

private enum ProgressiveBlurEdge: Equatable {
    case top
    case bottom
}

extension View {
    func progressiveEdgeBlur(
        top: Bool,
        bottom: Bool,
        topHeight: CGFloat = 36,
        bottomHeight: CGFloat = 36,
        radius: CGFloat = 18
    ) -> some View {
        modifier(
            ProgressiveEdgeBlurModifier(
                top: top,
                bottom: bottom,
                topHeight: topHeight,
                bottomHeight: bottomHeight,
                radius: radius
            )
        )
    }
}

struct ProgressiveEdgeBlurModifier: ViewModifier {
    let top: Bool
    let bottom: Bool
    let topHeight: CGFloat
    let bottomHeight: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ProgressiveEdgeBlurView(edge: .top, radius: radius)
                    .frame(height: top ? topHeight : 0)
                    .opacity(top ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.12), value: top)
            }
            .overlay(alignment: .bottom) {
                ProgressiveEdgeBlurView(edge: .bottom, radius: radius)
                    .frame(height: bottom ? bottomHeight : 0)
                    .opacity(bottom ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.12), value: bottom)
            }
    }
}

private struct ProgressiveEdgeBlurView: NSViewRepresentable {
    let edge: ProgressiveBlurEdge
    let radius: CGFloat

    func makeNSView(context: Context) -> ProgressiveEdgeBlurNSView {
        let view = ProgressiveEdgeBlurNSView()
        view.configure(edge: edge, radius: radius)
        return view
    }

    func updateNSView(_ nsView: ProgressiveEdgeBlurNSView, context: Context) {
        nsView.configure(edge: edge, radius: radius)
    }
}

private final class ProgressiveEdgeBlurNSView: NSVisualEffectView {
    private let edgeMaskLayer = CAGradientLayer()
    private var edge: ProgressiveBlurEdge = .top
    private var blurRadius: CGFloat = 18
    private var lastFilterSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .popover
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = edgeMaskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    func configure(edge: ProgressiveBlurEdge, radius: CGFloat) {
        let changed = self.edge != edge || blurRadius != radius
        self.edge = edge
        blurRadius = radius
        if changed {
            updateGradientMask()
            updateVariableBlurFilterIfNeeded(force: true)
        }
    }

    override func layout() {
        super.layout()
        updateGradientMask()
        updateVariableBlurFilterIfNeeded(force: false)
    }

    private func updateGradientMask() {
        edgeMaskLayer.frame = bounds
        edgeMaskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        edgeMaskLayer.endPoint = CGPoint(x: 0.5, y: 1)

        switch edge {
        case .top:
            edgeMaskLayer.colors = [
                NSColor.black.cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ]
        case .bottom:
            edgeMaskLayer.colors = [
                NSColor.black.withAlphaComponent(0).cgColor,
                NSColor.black.cgColor,
            ]
        }
    }

    private func updateVariableBlurFilterIfNeeded(force: Bool) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard force || bounds.size != lastFilterSize else { return }
        lastFilterSize = bounds.size

        guard let maskImage = Self.makeVariableBlurMask(
            size: bounds.size,
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            edge: edge
        ), let filter = Self.makeVariableBlurFilter(radius: blurRadius, maskImage: maskImage) else {
            layer?.backgroundFilters = nil
            return
        }

        layer?.backgroundFilters = [filter]
    }

    private static func makeVariableBlurFilter(radius: CGFloat, maskImage: CGImage) -> Any? {
        // CAFilter is private API, so keep it behind runtime lookup and let
        // NSVisualEffectView's normal material handle unsupported systems.
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            return nil
        }

        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let unmanagedFilter = filterClass.perform(selector, with: "variableBlur") else {
            return nil
        }

        let filter = unmanagedFilter.takeUnretainedValue() as? NSObject
        filter?.setValue(radius, forKey: "inputRadius")
        filter?.setValue(maskImage, forKey: "inputMaskImage")
        filter?.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    private static func makeVariableBlurMask(
        size: CGSize,
        scale: CGFloat,
        edge: ProgressiveBlurEdge
    ) -> CGImage? {
        let pixelWidth = max(1, Int(size.width * scale))
        let pixelHeight = max(1, Int(size.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let opaque = NSColor.white.cgColor
        let transparent = NSColor.black.cgColor
        let colors: [CGColor]
        switch edge {
        case .top:
            colors = [opaque, transparent]
        case .bottom:
            colors = [transparent, opaque]
        }

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else {
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: pixelHeight),
            options: []
        )
        return context.makeImage()
    }
}
