// Composes App Store marketing screenshots (1320 × 2868, 6.9" iPhone) from raw
// app screenshots. Usage:
//   swift scripts/make-app-store-screenshots.swift <raw-screenshots-dir> <output-dir>
// Raw screenshots must be named as in `pages` below.

import AppKit
import UniformTypeIdentifiers

struct Page {
    let raw: String
    let output: String
    let title: String
    let subtitle: String
}

let pages = [
    Page(raw: "1-portra", output: "01-shoot-on-film", title: "Shoot on film.", subtitle: "Hundreds of classic film looks,\nlive in your viewfinder."),
    Page(raw: "2-bw", output: "02-black-and-white", title: "Timeless\nblack & white.", subtitle: "Real grain that moves like film."),
    Page(raw: "3-library", output: "03-every-film", title: "Every film.\nOffline.", subtitle: "Browse the whole collection and\ndownload your favorites."),
    Page(raw: "4-adjust", output: "04-glow-halation", title: "Glow & halation.", subtitle: "Fine-tune tone, color and film\neffects, all live."),
    Page(raw: "5-velvia", output: "05-what-you-see", title: "What you see\nis what you get.", subtitle: "Full-resolution photos,\nrendered on-device with Metal."),
]

let width: CGFloat = 1320
let height: CGFloat = 2868

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ page: Page, rawDir: URL, outDir: URL) throws {
    guard let screenshot = NSImage(contentsOf: rawDir.appending(path: "\(page.raw).png")) else {
        throw NSError(domain: "screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(page.raw).png"])
    }
    // Opaque 32-bit context: App Store screenshots must not have an alpha channel.
    let cg = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin.
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // Background: warm dark gradient with a soft gold glow behind the device.
    NSGradient(colors: [color(0x2E2A21), color(0x16130B), color(0x0D0B06)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    NSGradient(colors: [color(0xE4C36C, 0.28), color(0xE4C36C, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: width / 2, y: 1500), radius: 0, toCenter: NSPoint(x: width / 2, y: 1500), radius: 900, options: [])

    // Text
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    centered.lineHeightMultiple = 0.95
    let title = NSAttributedString(string: page.title, attributes: [
        .font: NSFont.systemFont(ofSize: 124, weight: .bold),
        .foregroundColor: color(0xFFF8F1),
        .paragraphStyle: centered,
        .kern: -2,
    ])
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineSpacing = 8
    let subtitle = NSAttributedString(string: page.subtitle, attributes: [
        .font: NSFont.systemFont(ofSize: 56, weight: .medium),
        .foregroundColor: color(0xE4C36C),
        .paragraphStyle: subtitleStyle,
    ])
    let textWidth = width - 160
    let titleRect = title.boundingRect(with: NSSize(width: textWidth, height: 800), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let top: CGFloat = 200
    title.draw(with: NSRect(x: 80, y: top, width: textWidth, height: titleRect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let subtitleTop = top + titleRect.height + 40
    let subtitleRect = subtitle.boundingRect(with: NSSize(width: textWidth, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
    subtitle.draw(with: NSRect(x: 80, y: subtitleTop, width: textWidth, height: subtitleRect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])

    // Device: the screenshot in a thin frame, bleeding off the bottom edge.
    let deviceTop = max(subtitleTop + subtitleRect.height + 90, 760)
    let screenWidth: CGFloat = 1000
    let screenHeight = screenWidth * screenshot.size.height / screenshot.size.width
    let screen = NSRect(x: (width - screenWidth) / 2, y: deviceTop, width: screenWidth, height: screenHeight)
    let screenRadius: CGFloat = 138
    let bezel: CGFloat = 20

    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.6)
    shadow.shadowBlurRadius = 80
    shadow.shadowOffset = NSSize(width: 0, height: 30)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let frame = NSBezierPath(roundedRect: screen.insetBy(dx: -bezel, dy: -bezel), xRadius: screenRadius + bezel, yRadius: screenRadius + bezel)
    color(0x0B0906).setFill()
    frame.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x5A5344).setStroke()
    frame.lineWidth = 4
    frame.stroke()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: screenRadius, yRadius: screenRadius).addClip()
    screenshot.draw(in: screen, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appending(path: "\(page.output).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "screenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't write \(url.path)"])
    }
    print("wrote \(page.output).png")
}

let args = CommandLine.arguments
let rawDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for page in pages { try render(page, rawDir: rawDir, outDir: outDir) }
