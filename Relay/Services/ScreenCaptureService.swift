import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures full-screen images via ScreenCaptureKit and crops them to an
/// annotation region. Mirrors the temp-file convention in `ClipboardMonitor`
/// (`relay-images/<uuid>.png`) so `MCPBridgeWriter` stabilization and orphan
/// cleanup apply to annotation crops unchanged.
@MainActor
final class ScreenCaptureService {

    enum CaptureError: Error { case noDisplay, captureFailed, blankImage }

    /// Short-lived cache so multiple strokes drawn in quick succession reuse a
    /// single screen grab rather than re-capturing per stroke.
    private struct Cached {
        let image: CGImage
        let displayID: CGDirectDisplayID
        let time: Date
    }
    private var cached: Cached?
    private let cacheTTL: TimeInterval = 0.4

    // MARK: - Permission

    /// True if screen-recording access is already granted (no prompt).
    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen-recording access. Triggers the system TCC prompt on first
    /// use; the grant only takes effect for captures made after the user allows,
    /// so callers should treat a `false` return as "ask the user to retry".
    @discardableResult
    func requestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    /// Capture the full contents of `screen`, using the recent cache when valid.
    func captureFullScreen(of screen: NSScreen) async throws -> CGImage {
        let displayID = screen.displayID
        if let c = cached, c.displayID == displayID, Date().timeIntervalSince(c.time) < cacheTTL {
            return c.image
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = Int(screen.backingScaleFactor)
        config.width = display.width * scale
        config.height = display.height * scale
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // Stale-TCC guard: after a Sparkle update the grant can go stale and
        // yield an all-black frame even though preflight reports access.
        if isLikelyBlank(image) { throw CaptureError.blankImage }

        cached = Cached(image: image, displayID: displayID, time: Date())
        return image
    }

    /// Crop a full-screen image to a pixel rect, optionally burn the drawn
    /// strokes onto it, and save it as a PNG in the shared `relay-images/` temp
    /// dir. `strokes` are in screen-local points (bottom-left); they are mapped
    /// into the cropped image's pixel space so the mark stays pixel-accurate.
    func cropAndSave(_ full: CGImage, pixelRect: CGRect, strokes: [[CGPoint]] = [], screen: NSScreen? = nil) -> String? {
        let clamped = pixelRect.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = full.cropping(to: clamped) else { return nil }

        let png: Data?
        if strokes.isEmpty || screen == nil {
            png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        } else {
            png = renderStrokes(strokes, onto: cropped, cropPixelRect: clamped, screen: screen!)
        }
        guard let png else { return nil }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    /// Draw the strokes onto the cropped image and return PNG data. Works in the
    /// cropped image's pixel space (top-left origin): each screen point is mapped
    /// to full-image pixels (Y-flip + scale), then offset by the crop origin.
    private func renderStrokes(_ strokes: [[CGPoint]], onto cropped: CGImage, cropPixelRect: CGRect, screen: NSScreen) -> Data? {
        let w = cropped.width, h = cropped.height
        let scale = screen.backingScaleFactor
        let screenHeight = screen.frame.height

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        }

        // CGContext is bottom-left origin; the cropped CGImage is top-left. Drawing
        // the image fills the context right-side-up.
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Map a screen point (bottom-left) into this context's space (bottom-left,
        // pixels, relative to the crop).
        func mapped(_ p: CGPoint) -> CGPoint {
            let pxX = p.x * scale - cropPixelRect.minX
            // full-image top-left Y of the point:
            let topY = (screenHeight - p.y) * scale
            // context (bottom-left) Y within the crop:
            let ctxY = CGFloat(h) - (topY - cropPixelRect.minY)
            return CGPoint(x: pxX, y: ctxY)
        }

        ctx.setStrokeColor(NSColor.systemOrange.cgColor)
        ctx.setLineWidth(3 * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            ctx.beginPath()
            ctx.move(to: mapped(first))
            for pt in stroke.dropFirst() { ctx.addLine(to: mapped(pt)) }
            ctx.strokePath()
        }

        guard let marked = ctx.makeImage() else {
            return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        }
        return NSBitmapImageRep(cgImage: marked).representation(using: .png, properties: [:])
    }

    func invalidateCache() { cached = nil }

    // MARK: - Coordinate conversion

    /// Convert a rect expressed in panel-local points (bottom-left origin, the
    /// panel spanning `screen`) into pixel coordinates of the captured CGImage
    /// (top-left origin). Accounts for the screen's frame origin, the Y flip,
    /// and the Retina backing scale.
    static func toPixelRect(_ rectInPanel: CGRect, screen: NSScreen) -> CGRect {
        toPixelRect(rectInPanel, screenHeight: screen.frame.height, scale: screen.backingScaleFactor)
    }

    /// The full pixel bounds of a screen (origin .zero, size = points × scale).
    static func fullScreenPixelRect(_ screen: NSScreen) -> CGRect {
        let scale = screen.backingScaleFactor
        return CGRect(x: 0, y: 0, width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    /// Pure form of the conversion (no NSScreen) so the Y-flip + Retina scaling
    /// math can be unit-tested directly.
    static func toPixelRect(_ rectInPanel: CGRect, screenHeight: CGFloat, scale: CGFloat) -> CGRect {
        // The annotation panel spans the screen, so panel-local == screen-local.
        // Flip Y from bottom-left (AppKit) to top-left (CGImage) origin.
        let yTop = screenHeight - (rectInPanel.origin.y + rectInPanel.height)
        return CGRect(
            x: rectInPanel.origin.x * scale,
            y: yTop * scale,
            width: rectInPanel.width * scale,
            height: rectInPanel.height * scale
        ).integral
    }

    // MARK: - Helpers

    /// Cheap heuristic: sample a handful of pixels; if every sample is fully
    /// black/transparent the capture is almost certainly a stale-TCC blank.
    private func isLikelyBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        guard length > 0 else { return true }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let samples = 16
        let stride = max(bytesPerPixel, (length / samples / bytesPerPixel) * bytesPerPixel)
        var offset = 0
        var sawNonBlack = false
        while offset + bytesPerPixel <= length {
            for b in 0..<min(3, bytesPerPixel) where ptr[offset + b] != 0 {
                sawNonBlack = true
                break
            }
            if sawNonBlack { break }
            offset += stride
        }
        return !sawNonBlack
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
