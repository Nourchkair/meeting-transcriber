import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenContextCaptureError: LocalizedError {
    case noDisplayAvailable
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "Sawti could not find a screen to capture. Check Screen Recording permission in System Settings."
        case .imageEncodingFailed:
            "Sawti captured the screen but could not prepare the image for the AI request."
        }
    }
}

/// Captures the main display for one-time questions or opt-in screen awareness.
/// Frames stay in memory and are sent only with the user's next assistant
/// question. Sawti's own windows are excluded from the capture.
@MainActor
final class ScreenContextCapture {
    func captureMainDisplayJPEG() async throws -> Data {
        let content = try await SCShareableContent.current
        let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
            ?? content.displays.first else {
            throw ScreenContextCaptureError.noDisplayAvailable
        }

        let app = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: app.map { [$0] } ?? [],
            exceptingWindows: [],
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration,
        )
        return try Self.jpegData(from: image)
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let maxDimension = 1600
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else {
            throw ScreenContextCaptureError.imageEncodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw ScreenContextCaptureError.imageEncodingFailed
        }
        let representation = NSBitmapImageRep(cgImage: resized)
        guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw ScreenContextCaptureError.imageEncodingFailed
        }
        return data
    }
}
