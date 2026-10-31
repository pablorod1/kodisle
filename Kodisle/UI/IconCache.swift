import AppKit

/// App/file icons rasterized once at the exact size they're shown.
///
/// `NSWorkspace.icon(forFile:)` returns a multi-representation image (up to 1024 px, some
/// drawn on the fly with blurred shadows). Drawing it in SwiftUI re-renders that work on every
/// view update; a small cached bitmap costs nothing to draw and a fraction of the memory.
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    static func icon(forFile path: String, size: CGFloat) -> NSImage {
        image(key: "f:\(path)", size: size) { NSWorkspace.shared.icon(forFile: path) }
    }

    static func named(_ name: NSImage.Name, size: CGFloat) -> NSImage {
        image(key: "n:\(name)", size: size) { NSImage(named: name) ?? NSImage() }
    }

    private static func image(key: String, size: CGFloat, source: () -> NSImage) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((size * scale).rounded())
        let cacheKey = "\(key)@\(pixels)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        let original = source()
        guard pixels > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return original }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        original.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSImage(size: NSSize(width: size, height: size))
        bitmap.addRepresentation(rep)
        cache.setObject(bitmap, forKey: cacheKey)
        return bitmap
    }

    static func flush() { cache.removeAllObjects() }
}
