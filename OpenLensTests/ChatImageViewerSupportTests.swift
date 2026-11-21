import CoreGraphics
@preconcurrency import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import OpenLens

@MainActor
struct ChatImageViewerSupportTests {

    // MARK: - Payload Inspection & Metadata

    @Test func inspectsPNGWithAlphaAndJPEGWithoutAlpha() throws {
        let pngData = Self.makeImageData(width: 640, height: 360, type: .png, hasAlpha: true)
        let pngPayload = try #require(
            ChatImagePayload.inspect(data: pngData, preferredTitle: "UI Screenshot", fallbackMIME: nil)
        )
        #expect(pngPayload.metadata.pixelWidth == 640)
        #expect(pngPayload.metadata.pixelHeight == 360)
        #expect(pngPayload.metadata.formatName == "PNG")
        #expect(pngPayload.metadata.utType == .png)
        #expect(pngPayload.metadata.fileExtension == "png")
        #expect(pngPayload.metadata.hasAlpha == true)
        #expect(pngPayload.metadata.dimensionsLabel == "640 × 360")
        #expect(pngPayload.metadata.aspectRatioLabel == "16:9")
        #expect(pngPayload.metadata.byteCount == pngData.count)
        #expect(pngPayload.suggestedFilename == "UI Screenshot.png")

        let jpegData = Self.makeImageData(width: 400, height: 400, type: .jpeg, hasAlpha: false)
        let jpegPayload = try #require(
            ChatImagePayload.inspect(data: jpegData, preferredTitle: "/work/photo.jpeg", fallbackMIME: nil)
        )
        #expect(jpegPayload.metadata.pixelWidth == 400)
        #expect(jpegPayload.metadata.pixelHeight == 400)
        #expect(jpegPayload.metadata.formatName == "JPEG")
        #expect(jpegPayload.metadata.utType == .jpeg)
        #expect(jpegPayload.metadata.fileExtension == "jpg")
        #expect(jpegPayload.metadata.hasAlpha == false)
        #expect(jpegPayload.metadata.aspectRatioLabel == "1:1")
        #expect(jpegPayload.suggestedFilename == "photo.jpg")
    }

    @Test func rejectsPDFAndCorruptDataWhenInspecting() {
        #expect(ChatImagePayload.inspect(data: Data("%PDF-1.4\n".utf8)) == nil)
        #expect(ChatImagePayload.inspect(data: Data("not an image".utf8)) == nil)
        #expect(ChatImagePayload.inspect(data: Data()) == nil)
    }

    // MARK: - Data URL Decoding

    @Test func decodesValidBase64DataURLsAndRejectsInvalidOnes() throws {
        let pngData = Self.makeImageData(width: 32, height: 24, type: .png, hasAlpha: true)
        let uri = "data:image/png;base64,\(pngData.base64EncodedString())"
        let decoded = try #require(ChatImagePayload.decodeDataURL(uri))
        #expect(decoded.data == pngData)
        #expect(decoded.mime == "image/png")

        // Whitespace / line breaks in base64 payload should still decode cleanly.
        let chunkedBase64 = pngData.base64EncodedString(options: .lineLength64Characters)
        let chunked = try #require(ChatImagePayload.decodeDataURL("DATA:image/png;BASE64,\(chunkedBase64)"))
        #expect(chunked.data == pngData)

        #expect(ChatImagePayload.decodeDataURL("data:image/png,raw-not-base64") == nil)
        #expect(ChatImagePayload.decodeDataURL("https://example.com/a.png") == nil)
        #expect(ChatImagePayload.decodeDataURL("data:image/png;base64,") == nil)
    }

    // MARK: - Filename Sanitization

    @Test func sanitizesDownloadFilenamesAcrossUnixWindowsAndMIMETitles() {
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "shot.png", fileExtension: "png") == "shot.png")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "shot.jpeg", fileExtension: "jpg") == "shot.jpg")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "/Users/me/Desktop/diagram.png", fileExtension: "png") == "diagram.png")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: #"C:\Users\Admin\shot.png"#, fileExtension: "png") == "shot.png")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "image/png", fileExtension: "png") == "image.png")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "my:bad*name?.png", fileExtension: "png") == "my-bad-name-.png")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: "   ", fileExtension: "webp") == "image.webp")
        #expect(ChatImagePayload.sanitizedFilename(preferredTitle: nil, fileExtension: ".JPG") == "image.jpg")
    }

    // MARK: - Zoom & Orientation Math

    @Test func zoomScaleMathScalesUpForHighResolutionScreenshots() {
        // 3840x2160 screenshot fitted into a 390pt-wide iPhone screen at 3x display scale:
        // actual point width = 3840 / 3 = 1280pt -> 1:1 scale = 1280 / 390 ~= 3.28x.
        let actualScale = ChatImagePayload.actualSizeZoomScale(
            pixelSize: CGSize(width: 3840, height: 2160),
            fittedPointSize: CGSize(width: 390, height: 219),
            displayScale: 3.0
        )
        #expect(actualScale > 3.2 && actualScale < 3.4)

        let maxScale = ChatImagePayload.preferredMaximumZoomScale(
            pixelSize: CGSize(width: 3840, height: 2160),
            fittedPointSize: CGSize(width: 390, height: 219),
            displayScale: 3.0
        )
        #expect(maxScale >= 8.0 && maxScale <= 16.0)

        // Small icon still gets at least 6x zoom for close inspection.
        let smallMax = ChatImagePayload.preferredMaximumZoomScale(
            pixelSize: CGSize(width: 120, height: 120),
            fittedPointSize: CGSize(width: 300, height: 300),
            displayScale: 2.0
        )
        #expect(smallMax == 6.0)
    }

    @Test func clockwiseOrientationRotationCyclesCleanly() {
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: 0) == .up)
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: 1) == .right)
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: 2) == .down)
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: 3) == .left)
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: 4) == .up)
        #expect(ChatImageOrientation.rotatedClockwise(from: .up, quarterTurns: -1) == .left)

        #expect(ChatImageOrientation.rotatedClockwise(from: .upMirrored, quarterTurns: 1) == .rightMirrored)
        #expect(ChatImageOrientation.rotatedClockwise(from: .rightMirrored, quarterTurns: 2) == .leftMirrored)
    }

    @Test func decodesDisplayImageAndPreservesExportDocumentBytes() throws {
        let pngData = Self.makeImageData(width: 240, height: 120, type: .png, hasAlpha: true)
        let image = try #require(ChatImagePayload.decodeDisplayImage(from: pngData))
        #expect(Int(image.size.width) == 240)
        #expect(Int(image.size.height) == 120)

        let rotated = ChatImageOrientation.rotatedImage(image, quarterTurns: 1)
        #expect(rotated.imageOrientation == .right)

        let doc = ChatImageExportDocument(data: pngData)
        #expect(doc.data == pngData)
    }

    // MARK: - Markdown Image Block Parsing

    @Test func parsesStandaloneMarkdownImagesBetweenParagraphs() async {
        let pngData = Self.makeImageData(width: 16, height: 16, type: .png, hasAlpha: false)
        let dataURI = "data:image/png;base64,\(pngData.base64EncodedString())"
        let markdown = """
        Here is the architecture diagram:
        ![Architecture](https://example.com/arch.png "Diagram")
        And an inline screenshot:
        ![Inline Shot](\(dataURI))
        Done!
        """

        let prepared = await prepareMarkdown(markdown)
        let imageBlocks: [(alt: String, url: String)] = prepared.blocks.compactMap { block in
            guard case let .image(alt, urlString) = block.kind else { return nil }
            return (alt, urlString)
        }

        #expect(imageBlocks.count == 2)
        #expect(imageBlocks[0].alt == "Architecture")
        #expect(imageBlocks[0].url == "https://example.com/arch.png")
        #expect(imageBlocks[1].alt == "Inline Shot")
        #expect(imageBlocks[1].url == dataURI)
        #expect(prepared.blocks.count == 5)
    }

    @Test func ignoresUnsupportedSchemesInMarkdownImages() async {
        let markdown = "![Unsafe](javascript:alert(1))\n![Relative](./local.png)"
        let prepared = await prepareMarkdown(markdown)
        let hasImageBlock = prepared.blocks.contains { block in
            if case .image = block.kind { return true }
            return false
        }
        #expect(!hasImageBlock)
    }

    // MARK: - Helpers

    private func prepareMarkdown(_ text: String) async -> MarkdownContentView.Prepared {
        await withCheckedContinuation { continuation in
            MarkdownContentView.prepare(text) { prepared in
                continuation.resume(returning: prepared)
            }
        }
    }

    private static func makeImageData(width: Int, height: Int, type: UTType, hasAlpha: Bool) -> Data {
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: hasAlpha ? 0.8 : 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
