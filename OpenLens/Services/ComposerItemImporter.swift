@preconcurrency import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Extracts attachable images, local files, and text from `NSItemProvider`s and
/// `UIPasteboard` for composer copy-paste (`Cmd+V` / Paste) and drag-and-drop.
enum ComposerItemImporter {
    enum ImportedItem: Sendable {
        case fileURL(URL)
        case image(data: Data, name: String?)
        case textFile(PromptTextFileAttachment)
        case text(String)
    }

    /// Content types accepted by `.onDrop`, `.onPasteCommand`, and `UIPasteConfiguration`.
    nonisolated static let supportedContentTypes: [UTType] = [
        .fileURL,
        .png,
        .jpeg,
        .gif,
        .webP,
        .heic,
        .tiff,
        .bmp,
        .image,
        .utf8PlainText,
        .plainText,
        .text,
        .sourceCode,
        .json,
        .xml,
        .yaml,
        .shellScript,
        .propertyList,
        .commaSeparatedText,
        .data,
    ]

    nonisolated static var acceptableTypeIdentifiers: [String] {
        var seen = Set<String>()
        return supportedContentTypes.map(\.identifier).filter { seen.insert($0).inserted }
    }

    private nonisolated static let preferredImageTypes: [(type: UTType, ext: String)] = [
        (.png, "png"),
        (.webP, "webp"),
        (.gif, "gif"),
        (.jpeg, "jpg"),
        (.heic, "heic"),
        (.tiff, "tiff"),
        (.bmp, "bmp"),
        (.image, "png"),
    ]

    /// Returns true when a pasteboard item inside the composer text field should
    /// be intercepted as a file or image attachment instead of plain text insertion.
    nonisolated static func shouldInterceptTextFieldPaste(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return true
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            return false
        }
        // Rich text / spreadsheet cells often include both plain text and a TIFF
        // preview; only treat mixed items as images when an explicit raster image
        // representation (like PNG/JPEG/WebP/GIF) is registered without HTML/RTF.
        let identifiers = provider.registeredTypeIdentifiers
        let hasRichDocumentText = identifiers.contains { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .html) || type.conforms(to: .rtf)
        }
        if hasRichDocumentText {
            return false
        }
        let hasPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        if !hasPlainText {
            return true
        }
        // Browser "Copy Image" places both PNG/JPEG/TIFF image bytes and the image's
        // URL string on the pasteboard item.
        let hasURLType = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        let hasExplicitRaster = identifiers.contains { id in
            id == UTType.png.identifier
                || id == UTType.jpeg.identifier
                || id == UTType.gif.identifier
                || id == UTType.webP.identifier
                || id == UTType.heic.identifier
        }
        return hasURLType || hasExplicitRaster
    }

    nonisolated static func extractItems(
        from providers: [NSItemProvider],
        includePlainText: Bool
    ) async -> [ImportedItem] {
        var results: [ImportedItem] = []
        for provider in providers {
            if let item = await extractItem(from: provider, includePlainText: includePlainText) {
                results.append(item)
            }
        }
        return results
    }

    nonisolated static func extractItem(
        from provider: NSItemProvider,
        includePlainText: Bool
    ) async -> ImportedItem? {
        let suggestedName = sanitizedSuggestedName(provider.suggestedName)

        // 1. Local file URLs (Finder Cmd+C/Cmd+V, Files drag-and-drop).
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(from: provider) {
            return .fileURL(url)
        }

        // 2. Raster images (screenshots, Copy Image, dragged image data).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           (!includePlainText || shouldInterceptTextFieldPaste(provider) || !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)),
           let loadedImage = await loadImageData(from: provider, suggestedName: suggestedName) {
            return .image(data: loadedImage.data, name: loadedImage.name)
        }

        // 3. Dropped or copied standalone text/source files with a filename or source-code type.
        let isSourceOrData = provider.hasItemConformingToTypeIdentifier(UTType.sourceCode.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.json.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.xml.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.yaml.identifier)
        if let suggestedName, suggestedName.contains("."),
           let file = await loadNamedAttachment(from: provider, name: suggestedName) {
            return file
        }
        if isSourceOrData, !includePlainText,
           let file = await loadNamedAttachment(from: provider, name: suggestedName ?? "snippet.txt") {
            return file
        }

        // 4. Plain text (when pasting into ChatView outside the focused TextField, or dropped text).
        if includePlainText,
           let text = await loadPlainText(from: provider),
           !text.isEmpty {
            return .text(text)
        }

        // 5. Generic binary/file fallback (e.g. `.data` provider from file drag).
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           let fallback = await loadNamedAttachment(from: provider, name: suggestedName ?? "attachment") {
            return fallback
        }

        return nil
    }

    /// Reads items directly from `UIPasteboard.general` for explicit "Paste from Clipboard" actions.
    @MainActor
    static func extractFromGeneralPasteboard() async -> [ImportedItem] {
        let pasteboard = UIPasteboard.general
        let providers = pasteboard.itemProviders
        if !providers.isEmpty {
            let extracted = await extractItems(from: providers, includePlainText: true)
            if !extracted.isEmpty {
                return extracted
            }
        }
        if let images = pasteboard.images, !images.isEmpty {
            return images.compactMap { image in
                guard let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return nil }
                return .image(data: data, name: "pasted-image.png")
            }
        }
        if let text = pasteboard.string, !text.isEmpty {
            return [.text(text)]
        }
        return []
    }

    // MARK: - Private Loaders

    private nonisolated static func sanitizedSuggestedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return (trimmed as NSString).lastPathComponent
    }

    private nonisolated static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        if let data = await loadData(from: provider, typeIdentifier: UTType.fileURL.identifier) {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url
            }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: text), url.isFileURL {
                return url
            }
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _, _ in
                if let url, url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func loadImageData(
        from provider: NSItemProvider,
        suggestedName: String?
    ) async -> (data: Data, name: String?)? {
        for candidate in preferredImageTypes
            where provider.hasItemConformingToTypeIdentifier(candidate.type.identifier) {
            if let data = await loadData(from: provider, typeIdentifier: candidate.type.identifier),
               PromptImagePreparer.isDecodableImage(data) {
                let name = suggestedName ?? "pasted-image.\(candidate.ext)"
                return (data, name)
            }
        }
        return nil
    }

    private nonisolated static func loadNamedAttachment(
        from provider: NSItemProvider,
        name: String
    ) async -> ImportedItem? {
        // First try file representation so security-scoped or temp files preserve exact bytes.
        let typeID = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        if let payload: LocalComposerFilePayload = await withCheckedContinuation({ continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, _ in
                guard let tempURL,
                      let loaded = try? LocalComposerFilePayload.read(from: tempURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: loaded)
            }
        }) {
            switch payload {
            case let .image(data, loadedName):
                return .image(data: data, name: name.contains(".") ? name : loadedName)
            case let .textFile(file):
                if file.name != name, let renamed = try? PromptTextFileAttachment(id: file.id, data: file.data, name: name) {
                    return .textFile(renamed)
                }
                return .textFile(file)
            }
        }

        if let data = await loadData(from: provider, typeIdentifier: typeID) {
            if PromptImagePreparer.isDecodableImage(data) {
                return .image(data: data, name: name)
            }
            if data.count <= OpenCodeClient.maximumPromptBodyBytes,
               let textFile = try? PromptTextFileAttachment(data: data, name: name) {
                return .textFile(textFile)
            }
        }
        return nil
    }

    private nonisolated static func loadPlainText(from provider: NSItemProvider) async -> String? {
        for type in [UTType.utf8PlainText, UTType.plainText, UTType.text]
            where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(from: provider, typeIdentifier: type.identifier) {
                if let string = String(data: data, encoding: .utf8) {
                    return string
                }
                if let utf16 = String(data: data, encoding: .utf16) {
                    return utf16
                }
            }
        }
        return nil
    }

    private nonisolated static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
