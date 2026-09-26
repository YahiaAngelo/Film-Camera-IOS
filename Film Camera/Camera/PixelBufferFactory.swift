//
//  PixelBufferFactory.swift
//  Film Camera
//

import CoreGraphics
import CoreVideo

nonisolated enum PixelBufferFactory {
    /// Draws a CGImage into a new Metal-compatible BGRA pixel buffer,
    /// optionally center-cropping it to `size`.
    static func make(from image: CGImage, size: CGSize? = nil) -> CVPixelBuffer? {
        let width = Int(size?.width ?? CGFloat(image.width))
        let height = Int(size?.height ?? CGFloat(image.height))
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Aspect-fill the image into the buffer.
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (CGFloat(width) - drawSize.width) / 2, y: (CGFloat(height) - drawSize.height) / 2)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
        return buffer
    }
}
