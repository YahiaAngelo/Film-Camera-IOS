//
//  PhotoWriter.swift
//  Film Camera
//

import CoreGraphics
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

nonisolated enum PhotoWriter {
    enum WriteError: LocalizedError {
        case encodingFailed
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .encodingFailed: "The photo could not be encoded."
            case .notAuthorized: "Film Camera needs permission to add photos to your library."
            }
        }
    }

    /// Encodes the processed image as HEIC (falling back to JPEG), carrying over
    /// the capture metadata such as EXIF and orientation.
    static func encode(_ image: CGImage, metadata: [String: Any]) throws -> Data {
        var properties = metadata
        // Pixel dimensions come from the image itself.
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        var software = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        software[kCGImagePropertyTIFFSoftware as String] = "Film Camera"
        properties[kCGImagePropertyTIFFDictionary as String] = software

        for type in [UTType.heic, UTType.jpeg] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) { return data as Data }
        }
        throw WriteError.encodingFailed
    }

    static func saveToLibrary(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw WriteError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    static func orientation(from metadata: [String: Any]) -> UIImage.Orientation {
        let raw = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        switch CGImagePropertyOrientation(rawValue: raw) ?? .up {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }
}
