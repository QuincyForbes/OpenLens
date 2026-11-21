import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Image Viewer Models

/// Where a chat image's lossless bytes come from.
nonisolated enum ChatImageSource: Hashable, Sendable {
    /// Raw image bytes already in memory (composer attachments, queued prompts, loaded images).
    case data(Data)
    /// Inline base64 `data:image/...;base64,...` URI (message parts, tool files, markdown data images).
    case dataURL(String)
    /// Remote `http(s)://` image URL referenced in Markdown.
    case remoteURL(URL)
    /// A tool-returned image file, loaded on demand (supports both inline data URIs and server paths).
    case toolResultFile(ToolResultFile)
}

/// One inspectable, zoomable, downloadable image in the chat transcript or composer.
nonisolated struct ChatImageItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let mime: String?
    let source: ChatImageSource

    init(id: String, title: String, mime: String? = nil, source: ChatImageSource) {
        self.id = id
        self.title = title
        self.mime = mime
        self.source = source
    }

    static func fromPart(_ part: OCPart, fallbackTitle: String = "Attached image") -> ChatImageItem {
        ChatImageItem(
            id: part.id,
            title: part.filename?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTitle,
            mime: part.mime,
            source: .dataURL(part.url ?? "")
        )
    }

    static func fromPromptImage(_ image: PromptImageAttachment) -> ChatImageItem {
        ChatImageItem(
            id: image.id,
            title: image.name,
            mime: image.mime,
            source: .data(image.data)
        )
    }

    static func fromToolResultFile(_ file: ToolResultFile) -> ChatImageItem {
        ChatImageItem(
            id: file.id,
            title: file.title,
            mime: file.mime,
            source: .toolResultFile(file)
        )
    }
}

/// Identifies a gallery presentation and which image inside it to open first.
nonisolated struct ChatImageGallerySelection: Identifiable, Hashable, Sendable {
    let id: String
    let items: [ChatImageItem]
    let initialItemID: String

    init(items: [ChatImageItem], initialItemID: String) {
        self.items = items
        self.initialItemID = initialItemID
        self.id = "\(initialItemID)#\(items.map(\.id).joined(separator: ","))"
    }

    init(single item: ChatImageItem) {
        self.items = [item]
        self.initialItemID = item.id
        self.id = item.id
    }
}

// MARK: - Image Metadata & Payload Inspection

/// Lossless metadata inspected from original image bytes without decoding a full bitmap.
nonisolated struct ChatImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let formatName: String
    let utType: UTType
    let fileExtension: String
    let hasAlpha: Bool

    var dimensionsLabel: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var aspectRatioLabel: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "—" }
        let divisor = Self.greatestCommonDivisor(pixelWidth, pixelHeight)
        let rw = pixelWidth / divisor
        let rh = pixelHeight / divisor
        if rw <= 32 && rh <= 32 {
            return "\(rw):\(rh)"
        }
        return String(format: "%.2f:1", Double(pixelWidth) / Double(pixelHeight))
    }

    var summaryLabel: String {
        "\(dimensionsLabel) · \(formatName) · \(fileSizeLabel)"
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(x, 1)
    }
}

/// Original lossless image bytes paired with inspected metadata and a safe download filename.
nonisolated struct ChatImagePayload: Sendable {
    let data: Data
    let metadata: ChatImageMetadata
    let suggestedFilename: String

    /// Maximum pixel dimension for interactive viewer rendering so huge photos
    /// stay crisp at 4x-8x zoom without exhausting memory.
    static let fullResolutionMaximumPixelSize = 4_096

    /// Maximum bytes fetched for a remote Markdown image URL.
    static let maximumRemoteImageBytes = 16 * 1_024 * 1_024

    /// Decodes a `data:image/...;base64,...` URI into raw bytes and optional MIME type.
    static func decodeDataURL(_ uri: String) -> (data: Data, mime: String?)? {
        guard uri.prefix(5).lowercased() == "data:",
              let comma = uri.firstIndex(of: ",") else {
            return nil
        }
        let header = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<comma])
        let lowerHeader = header.lowercased()
        guard lowerHeader.hasSuffix(";base64") else { return nil }
        let mimePart = header
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let base64 = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            return nil
        }
        return (data, mimePart)
    }

    /// Inspects raw image bytes via `CGImageSource` without allocating a full bitmap.
    static func inspect(
        data: Data,
        preferredTitle: String? = nil,
        fallbackMIME: String? = nil
    ) -> ChatImagePayload? {
        guard !data.isEmpty,
              !data.starts(with: Array("%PDF-".utf8)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0 else {
            return nil
        }

        // Swap reported dimensions when EXIF orientation rotates 90°/270° (values 5...8).
        let exifOrientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let isRotated90 = (5...8).contains(exifOrientation)
        let pixelWidth = isRotated90 ? rawHeight : rawWidth
        let pixelHeight = isRotated90 ? rawWidth : rawHeight
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false

        let format = resolveFormat(
            imageSourceType: CGImageSourceGetType(source) as String?,
            data: data,
            fallbackMIME: fallbackMIME
        )
        let metadata = ChatImageMetadata(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: data.count,
            formatName: format.formatName,
            utType: format.utType,
            fileExtension: format.fileExtension,
            hasAlpha: hasAlpha
        )
        let filename = sanitizedFilename(preferredTitle: preferredTitle, fileExtension: format.fileExtension)
        return ChatImagePayload(data: data, metadata: metadata, suggestedFilename: filename)
    }

    /// Decodes a display-oriented `UIImage` at up to `maximumPixelSize` pixels on its longest edge.
    static func decodeDisplayImage(
        from data: Data,
        maximumPixelSize: Int = fullResolutionMaximumPixelSize
    ) -> UIImage? {
        guard !data.isEmpty,
              !data.starts(with: Array("%PDF-".utf8)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0 else {
            return nil
        }
        let targetMaxDimension = min(max(rawWidth, rawHeight), max(maximumPixelSize, 1))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Produces a clean, cross-platform filename with the image's actual extension.
    static func sanitizedFilename(preferredTitle: String?, fileExtension: String) -> String {
        let normalizedExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let ext = normalizedExt.isEmpty ? "png" : normalizedExt

        guard let raw = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "image.\(ext)"
        }

        // Ignore generic MIME titles like "image/png" or default labels.
        let lowerRaw = raw.lowercased()
        if lowerRaw.hasPrefix("image/") && !lowerRaw.contains(".") {
            return "image.\(ext)"
        }

        let lastComponent = WorkspaceSelectionBuilder.lastPathComponent(of: raw)
        let strippedStem = stripKnownImageExtension(from: lastComponent)
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = strippedStem
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        guard !cleaned.isEmpty else {
            return "image.\(ext)"
        }
        let bounded = cleaned.count > 80 ? String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) : cleaned
        guard !bounded.isEmpty else { return "image.\(ext)" }
        return "\(bounded).\(ext)"
    }

    /// Computes a generous maximum zoom scale so users can inspect fine UI details
    /// even on high-resolution desktop screenshots.
    static func preferredMaximumZoomScale(
        pixelSize: CGSize,
        fittedPointSize: CGSize,
        displayScale: CGFloat
    ) -> CGFloat {
        let actualScale = actualSizeZoomScale(
            pixelSize: pixelSize,
            fittedPointSize: fittedPointSize,
            displayScale: displayScale,
            maximumScale: 16.0
        )
        return min(16.0, max(6.0, actualScale * 2.5))
    }

    /// Scroll-view zoom scale at which 1 image pixel equals 1 screen pixel (1:1 actual size).
    static func actualSizeZoomScale(
        pixelSize: CGSize,
        fittedPointSize: CGSize,
        displayScale: CGFloat,
        maximumScale: CGFloat = 16.0
    ) -> CGFloat {
        guard pixelSize.width > 0, fittedPointSize.width > 0 else { return 1.0 }
        let safeScale = max(displayScale, 1.0)
        let actualPointWidth = pixelSize.width / safeScale
        let rawScale = actualPointWidth / fittedPointSize.width
        return min(max(rawScale, 1.0), max(maximumScale, 1.0))
    }

    private struct ResolvedFormat {
        let formatName: String
        let utType: UTType
        let fileExtension: String
    }

    private static func resolveFormat(
        imageSourceType: String?,
        data: Data,
        fallbackMIME: String?
    ) -> ResolvedFormat {
        // 1. Inspect magic bytes first so container matches the exact lossless bytes.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ResolvedFormat(formatName: "PNG", utType: .png, fileExtension: "png")
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ResolvedFormat(formatName: "JPEG", utType: .jpeg, fileExtension: "jpg")
        }
        if data.starts(with: Array("GIF8".utf8)) {
            return ResolvedFormat(formatName: "GIF", utType: .gif, fileExtension: "gif")
        }
        if data.count >= 12,
           data.prefix(4).elementsEqual("RIFF".utf8),
           data.dropFirst(8).prefix(4).elementsEqual("WEBP".utf8) {
            return ResolvedFormat(formatName: "WebP", utType: .webP, fileExtension: "webp")
        }
        if data.starts(with: [0x42, 0x4D]) {
            return ResolvedFormat(formatName: "BMP", utType: .bmp, fileExtension: "bmp")
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return ResolvedFormat(formatName: "TIFF", utType: .tiff, fileExtension: "tiff")
        }

        // 2. Ask ImageIO UTI (handles HEIC/HEIF and other Apple codecs).
        if let typeID = imageSourceType, let utType = UTType(typeID) {
            return formatDescriptor(for: utType)
        }

        // 3. Fall back to declared MIME type.
        if let mime = fallbackMIME?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
           let utType = UTType(mimeType: mime) {
            return formatDescriptor(for: utType)
        }

        return ResolvedFormat(formatName: "PNG", utType: .png, fileExtension: "png")
    }

    private static func formatDescriptor(for utType: UTType) -> ResolvedFormat {
        if utType.conforms(to: .png) {
            return ResolvedFormat(formatName: "PNG", utType: .png, fileExtension: "png")
        }
        if utType.conforms(to: .jpeg) {
            return ResolvedFormat(formatName: "JPEG", utType: .jpeg, fileExtension: "jpg")
        }
        if utType.conforms(to: .gif) {
            return ResolvedFormat(formatName: "GIF", utType: .gif, fileExtension: "gif")
        }
        if utType.conforms(to: .webP) {
            return ResolvedFormat(formatName: "WebP", utType: .webP, fileExtension: "webp")
        }
        if utType.conforms(to: .heic) {
            return ResolvedFormat(formatName: "HEIC", utType: .heic, fileExtension: "heic")
        }
        if utType.conforms(to: .heif) {
            return ResolvedFormat(formatName: "HEIF", utType: .heif, fileExtension: "heif")
        }
        if utType.conforms(to: .tiff) {
            return ResolvedFormat(formatName: "TIFF", utType: .tiff, fileExtension: "tiff")
        }
        if utType.conforms(to: .bmp) {
            return ResolvedFormat(formatName: "BMP", utType: .bmp, fileExtension: "bmp")
        }
        let ext = utType.preferredFilenameExtension ?? "png"
        return ResolvedFormat(formatName: ext.uppercased(), utType: utType, fileExtension: ext)
    }

    private static func stripKnownImageExtension(from filename: String) -> String {
        let knownExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
        ]
        guard let dot = filename.lastIndex(of: ".") else { return filename }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        if knownExtensions.contains(ext) {
            return String(filename[..<dot])
        }
        return filename
    }
}

// MARK: - Orientation Helper

nonisolated enum ChatImageOrientation {
    /// Applies `quarterTurns` clockwise 90° rotations to a `UIImage.Orientation` in O(1).
    static func rotatedClockwise(
        from orientation: UIImage.Orientation,
        quarterTurns: Int
    ) -> UIImage.Orientation {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns > 0 else { return orientation }

        let standardCycle: [UIImage.Orientation] = [.up, .right, .down, .left]
        if let index = standardCycle.firstIndex(of: orientation) {
            return standardCycle[(index + turns) % 4]
        }
        let mirroredCycle: [UIImage.Orientation] = [.upMirrored, .rightMirrored, .downMirrored, .leftMirrored]
        if let index = mirroredCycle.firstIndex(of: orientation) {
            return mirroredCycle[(index + turns) % 4]
        }
        return orientation
    }

    /// Returns a view-rotated `UIImage` sharing the same backing `CGImage` (zero pixel copy).
    static func rotatedImage(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns > 0, let cgImage = image.cgImage else { return image }
        let nextOrientation = rotatedClockwise(from: image.imageOrientation, quarterTurns: turns)
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: nextOrientation)
    }
}

// MARK: - File Export & Share Transferable

/// Lossless `FileDocument` for saving chat images through the system Files / macOS Save panel.
nonisolated struct ChatImageExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] {
        [.image, .png, .jpeg, .gif, .webP, .heic, .tiff, .bmp, .data]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Shareable original image file preserving filename and lossless format for AirDrop & Share Sheet.
nonisolated struct ChatImageShareFile: Transferable, Sendable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            let fileURL = try Self.writeTemporaryFile(data: item.data, filename: item.filename)
            return SentTransferredFile(fileURL)
        }
    }

    static func writeTemporaryFile(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLensSharedImages", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

/// Lazily materializes a chat image into a shareable file only when the user actually taps Share.
nonisolated struct LazyChatImageShareItem: Transferable, Sendable {
    let source: ChatImageSource
    let title: String
    let mime: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            let data: Data
            switch item.source {
            case let .data(bytes):
                data = bytes
            case let .dataURL(uri):
                guard let decoded = ChatImagePayload.decodeDataURL(uri)?.data else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data = decoded
            case let .remoteURL(url):
                let (bytes, _) = try await ChatImageLoader.fetchRemoteData(from: url)
                data = bytes
            case let .toolResultFile(file):
                if case let .dataURI(uri) = file.source,
                   let decoded = ChatImagePayload.decodeDataURL(uri)?.data {
                    data = decoded
                } else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
            }
            let payload = ChatImagePayload.inspect(data: data, preferredTitle: item.title, fallbackMIME: item.mime)
            let filename = payload?.suggestedFilename ?? ChatImagePayload.sanitizedFilename(preferredTitle: item.title, fileExtension: "png")
            let fileURL = try ChatImageShareFile.writeTemporaryFile(data: data, filename: filename)
            return SentTransferredFile(fileURL)
        }
    }
}

// MARK: - Loading, Caching, Clipboard & Photo Library Saving

enum ChatImageLoader {
    private static let displayImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    private static let remoteDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    struct LoadedImage {
        let payload: ChatImagePayload
        let image: UIImage
    }

    nonisolated enum LoadError: LocalizedError, Sendable {
        case unreadable
        case remoteTooLarge
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: AppText.toolFileUnreadable
            case .remoteTooLarge: AppText.toolFileTooLarge
            case let .failed(message): message
            }
        }
    }

    /// Loads lossless bytes and a full-resolution display `UIImage` off the main actor.
    @MainActor
    static func load(
        item: ChatImageItem,
        workspaceService: WorkspaceService,
        sessionDirectory: String?
    ) async throws -> LoadedImage {
        let rawData: Data
        let fallbackMIME: String?

        switch item.source {
        case let .data(bytes):
            rawData = bytes
            fallbackMIME = item.mime

        case let .dataURL(uri):
            let decoded = await Task.detached(priority: .userInitiated) {
                ChatImagePayload.decodeDataURL(uri)
            }.value
            guard let decoded else { throw LoadError.unreadable }
            rawData = decoded.data
            fallbackMIME = decoded.mime ?? item.mime

        case let .remoteURL(url):
            let (bytes, mime) = try await fetchRemoteData(from: url)
            rawData = bytes
            fallbackMIME = mime ?? item.mime

        case let .toolResultFile(file):
            let content = try await workspaceService.loadToolResultFile(file, sessionDirectory: sessionDirectory)
            guard case let .image(bytes) = content else {
                throw LoadError.unreadable
            }
            rawData = bytes
            fallbackMIME = file.mime
        }

        let cacheKey = "\(item.id)-\(rawData.count)" as NSString
        let cachedDisplayImage = displayImageCache.object(forKey: cacheKey)
        let shouldDecodeDisplayImage = cachedDisplayImage == nil
        let title = item.title

        let inspected: (ChatImagePayload, UIImage?)? = await Task.detached(priority: .userInitiated) {
            guard let payload = ChatImagePayload.inspect(
                data: rawData,
                preferredTitle: title,
                fallbackMIME: fallbackMIME
            ) else {
                return nil
            }
            if shouldDecodeDisplayImage {
                guard let decodedImage = ChatImagePayload.decodeDisplayImage(from: rawData) else {
                    return nil
                }
                return (payload, decodedImage)
            }
            return (payload, nil)
        }.value

        guard let (payload, decodedImage) = inspected,
              let image = cachedDisplayImage ?? decodedImage else {
            throw LoadError.unreadable
        }

        if cachedDisplayImage == nil {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? max(rawData.count * 4, 1)
            displayImageCache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
        }
        return LoadedImage(payload: payload, image: image)
    }

    /// Fetches and caches raw bytes for an `http(s)://` image URL with size & timeout bounds.
    nonisolated static func fetchRemoteData(from url: URL) async throws -> (Data, String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw LoadError.unreadable
        }
        let keyString = url.absoluteString
        if let cached = await MainActor.run(body: { remoteDataCache.object(forKey: keyString as NSString) as Data? }) {
            return (cached, nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.failed("HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else { throw LoadError.unreadable }
        guard data.count <= ChatImagePayload.maximumRemoteImageBytes else {
            throw LoadError.remoteTooLarge
        }
        await MainActor.run {
            remoteDataCache.setObject(data as NSData, forKey: keyString as NSString, cost: max(data.count, 1))
        }
        return (data, response.mimeType)
    }
}

enum ChatImageSaver {
    nonisolated enum PhotoSaveOutcome: Equatable, Sendable {
        case saved
        case permissionDenied
        case failed(String)
    }

    /// Copies the image to the system pasteboard, preserving lossless PNG/JPEG/GIF data when possible.
    @MainActor
    static func copyToPasteboard(payload: ChatImagePayload, image: UIImage) {
        let utType = payload.metadata.utType
        if utType == .png || utType == .jpeg || utType == .gif {
            UIPasteboard.general.setData(payload.data, forPasteboardType: utType.identifier)
        } else {
            UIPasteboard.general.image = image
        }
    }

    /// Saves lossless image bytes directly to the user's Photo Library (add-only permission).
    nonisolated static func saveToPhotoLibrary(data: Data) async -> PhotoSaveOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .permissionDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
