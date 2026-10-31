// Renders the Kodisle app icon from the vector mark in docs/brand (mark-k.pdf + mark-bar.pdf).
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
func C(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])! }
func grad(_ c: [CGColor], _ l: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: cs, colors: c as CFArray, locations: l)! }
let dir = "docs/brand"
let kPage = CGPDFDocument(URL(fileURLWithPath: dir + "/mark-k.pdf") as CFURL)!.page(at: 1)!
let barPage = CGPDFDocument(URL(fileURLWithPath: dir + "/mark-bar.pdf") as CFURL)!.page(at: 1)!
/// Renders a PDF page as an alpha mask at `scale`, placed at `origin` in a 1024² canvas.
func mask(_ page: CGPDFPage, scale: CGFloat, origin: CGPoint) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: Int(S), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    ctx.translateBy(x: origin.x, y: origin.y); ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(page)
    // potrace PDFs are black-on-transparent: invert into a white-on-black mask
    let img = ctx.makeImage()!
    return img
}
func bbox(_ img: CGImage) -> CGRect {   // bounds of drawn (dark) pixels
    let w = img.width, h = img.height
    let data = CFDataGetBytePtr(img.dataProvider!.data)!
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w where data[y * img.bytesPerRow + x] < 128 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX, height: maxY - minY)
}
func invert(_ img: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height)
    for i in 0..<(img.width * img.height) { p[i] = 255 - p[i] }
    return ctx.makeImage()!
}
func asMask(_ img: CGImage) -> CGImage {
    CGImage(maskWidth: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: img.bytesPerRow, provider: img.dataProvider!, decode: nil, shouldInterpolate: true)!
}

// Fit the mark (K + bar) to ~50% of the icon body, optically centred.
let probe = mask(kPage, scale: 1, origin: .zero)
let probeBar = mask(barPage, scale: 1, origin: .zero)
let kb = bbox(probe).union(bbox(probeBar))
let scale = 440 / kb.height
let origin = CGPoint(x: 512 - (kb.midX * scale), y: 512 - (kb.midY * scale) + 6)
let kMask = invert(mask(kPage, scale: scale, origin: origin))
let barMask = invert(mask(barPage, scale: scale, origin: origin))
// Image masks: white = paint. CGContext.clip(to:mask:) uses a grayscale image where white = visible.

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

struct Style { let bg: [CGColor]; let k: [CGColor]; let bar: [CGColor]; let rim: (CGFloat, CGFloat); let kShadow: CGFloat; let barGlow: CGColor? }

func render(_ st: Style) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: C(0, 0.4))
    ctx.addPath(squircle); ctx.setFillColor(st.bg.last!); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad(st.bg), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(grad([C(0xFFFFFF, 0.10), C(0xFFFFFF, 0)]), startCenter: CGPoint(x: 400, y: 860), startRadius: 0, endCenter: CGPoint(x: 400, y: 860), endRadius: 560, options: [])
    ctx.restoreGState()
    // rim
    let inner = CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil)
    ctx.saveGState(); ctx.addPath(inner.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 4)); ctx.clip()
    ctx.drawLinearGradient(grad([C(0xFFFFFF, st.rim.0), C(0xFFFFFF, st.rim.1)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    let full = CGRect(x: 0, y: 0, width: S, height: S)
    // K shadow: draw the mask offset & blurred via a shadowed fill layer
    if st.kShadow > 0 {
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: C(0, st.kShadow))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: full, mask: kMask); ctx.setFillColor(st.k.last!); ctx.fill(full)
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    ctx.saveGState(); ctx.clip(to: full, mask: kMask)
    ctx.drawLinearGradient(grad(st.k), start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 260), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    if let glow = st.barGlow {
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 26, color: glow)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: full, mask: barMask); ctx.setFillColor(st.bar.first!); ctx.fill(full)
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    ctx.saveGState(); ctx.clip(to: full, mask: barMask)
    ctx.drawLinearGradient(grad(st.bar), start: CGPoint(x: 512, y: 340), end: CGPoint(x: 512, y: 260), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    return ctx.makeImage()!
}

let style = Style(bg: [C(0xFFFFFF), C(0xEDEEF1)], k: [C(0x2A2B30), C(0x0E0E10)], bar: [C(0xB4BCC5), C(0x99A2AC)],
                  rim: (0.9, 0.2), kShadow: 0.18, barGlow: nil)
let icon = render(style)

func write(_ image: CGImage, px: Int, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: target)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g
    rep.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! target.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = "Kodisle/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var entries: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        write(icon, px: base * scale, to: "\(out)/\(name)")
        entries.append("{\"idiom\":\"mac\",\"size\":\"\(base)x\(base)\",\"scale\":\"\(scale)x\",\"filename\":\"\(name)\"}")
    }
}
try! "{\"images\":[\(entries.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}"
    .write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
write(icon, px: 1024, to: "docs/brand/icon.png")
print("✓ app icon + docs/brand/icon.png")
