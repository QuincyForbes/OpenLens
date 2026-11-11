import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image prepared on the phone for a v2 prompt. `data` holds the exact
/// bytes sent, so a retry of the same submission resends identical content.
nonisolated struct PromptImageAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let data: Data
    let mime: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let dataURI: String

    init(
        id: String = UUID().uuidString,
        data: Data,
        mime: String,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.data = data
        self.mime = mime
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
    }

    var promptFile: OCV2PromptFile {
        OCV2PromptFile(uri: dataURI, name: name)
    }
}

/// Turns picked photos and screenshots into data the model can read.
///
/// OpenCode passes PNG, JPEG, GIF, and WebP images to models and ignores other
/// formats, so iOS formats such as HEIC are exported to JPEG. Camera photos
/// are always re-encoded so their location and other metadata stay on the
/// phone. Images are bounded to the size models resize to anyway, then
/// compressed until they fit the byte budget of the prompt request.
nonisolated enum PromptImagePreparer {
    static let maximumPixelDimension = 2_000
    /// Leaves room for several images within the 2 MiB prompt body.
    static let defaultMaximumBytes = 600_000
    /// Generous single-image budget when the composer has plenty of room, so
    /// crisp desktop/mobile PNG screenshots pass through without lossy re-encoding.
    static let singleImageMaximumBytes = 950_000

    private static let minimumPixelDimension = 320
    private static let jpegQualities: [Double] = [0.85, 0.7, 0.55, 0.4]

    static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        // Reject PDFs that CGImageSource might inspect on some OS versions;
        // OpenCode image attachments only accept raster images.
        if data.starts(with: Array("%PDF-".utf8)) {
            return false
        }
        return width > 0 && height > 0
    }

    private enum Format {
        case png, jpeg, gif, webp, other

        init(_ data: Data) {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                self = .png
            } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                self = .jpeg
            } else if data.starts(with: Array("GIF8".utf8)) {
                self = .gif
            } else if data.count >= 12,
                      data.prefix(4).elementsEqual("RIFF".utf8),
                      data.dropFirst(8).prefix(4).elementsEqual("WEBP".utf8) {
                self = .webp
            } else {
                self = .other
            }
        }

        /// Formats sent byte-for-byte when small enough: screenshots keep
        /// their lossless pixels and animations are preserved.
        var passthrough: (mime: String, ext: String)? {
            switch self {
            case .png: ("image/png", "png")
            case .gif: ("image/gif", "gif")
            case .webp: ("image/webp", "webp")
            case .jpeg, .other: nil
            }
        }
    }

    static func prepare(
        _ data: Data,
        maximumBytes: Int = defaultMaximumBytes,
        id: String = UUID().uuidString,
        preferredName: String? = nil
    ) throws -> PromptImageAttachment {
        guard !data.starts(with: Array("%PDF-".utf8)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw PromptAttachmentError.unsupportedImage
        }

        let format = Format(data)
        if let passthrough = format.passthrough,
           data.count <= maximumBytes,
           max(width, height) <= maximumPixelDimension {
            return PromptImageAttachment(
                id: id,
                data: data,
                mime: passthrough.mime,
                name: resolvedName(preferredName: preferredName, ext: passthrough.ext),
                pixelWidth: width,
                pixelHeight: height
            )
        }

        var dimension = min(max(width, height), maximumPixelDimension)
        let smallestDimension = min(minimumPixelDimension, dimension)
        while dimension >= smallestDimension {
            guard let image = thumbnail(from: source, maximumDimension: dimension) else {
                throw PromptAttachmentError.unsupportedImage
            }
            let opaque = flattened(image)
            for quality in jpegQualities {
                if let jpeg = encodeJPEG(opaque, quality: quality), jpeg.count <= maximumBytes {
                    return PromptImageAttachment(
                        id: id,
                        data: jpeg,
                        mime: "image/jpeg",
                        name: resolvedName(preferredName: preferredName, ext: "jpg"),
                        pixelWidth: opaque.width,
                        pixelHeight: opaque.height
                    )
                }
            }
            dimension = dimension * 3 / 4
        }
        throw PromptAttachmentError.imageTooLarge
    }

    private static func resolvedName(preferredName: String?, ext: String) -> String {
        guard let raw = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "image.\(ext)"
        }
        let filename = (raw as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != "." else {
            return "image.\(ext)"
        }
        return "\(stem).\(ext)"
    }

    private static func thumbnail(from source: CGImageSource, maximumDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG has no alpha channel; transparent areas become white, not black.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    /// Only the pixels are written, so source metadata such as GPS is dropped.
    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
