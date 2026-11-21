import ImageIO
import SwiftUI
import UIKit

/// A square thumbnail decoded off the main actor from image bytes or a
/// `data:` URL, downsampled so large photos don't hold full-size bitmaps.
struct PromptImageThumbnail: View {
    let cacheKey: String
    let source: Source
    let side: CGFloat
    var showsZoomBadge: Bool = false

    enum Source: Sendable {
        case data(Data)
        case dataURL(String)
    }

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsZoomBadge && image != nil {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(isHovered ? 0.68 : 0.45), in: Circle())
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: cacheKey) {
            image = await PromptImageThumbnailCache.thumbnail(
                key: cacheKey,
                source: source,
                maximumPixelSize: Int(side * displayScale)
            )
        }
    }
}

enum PromptImageThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    @MainActor
    static func thumbnail(key: String, source: PromptImageThumbnail.Source, maximumPixelSize: Int) async -> UIImage? {
        let cacheKey = "\(key)@\(maximumPixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let image = await Task.detached(priority: .userInitiated) {
            decode(source, maximumPixelSize: maximumPixelSize)
        }.value
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? (maximumPixelSize * maximumPixelSize * 4)
            cache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
        }
        return image
    }

    private nonisolated static func decode(_ source: PromptImageThumbnail.Source, maximumPixelSize: Int) -> UIImage? {
        let data: Data?
        switch source {
        case let .data(bytes):
            data = bytes
        case let .dataURL(url):
            data = url.range(of: ";base64,").flatMap { Data(base64Encoded: String(url[$0.upperBound...])) }
        }
        guard let data,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}

/// Images and files attached to a chat message, shown above its text.
struct MessageAttachmentsRow: View {
    let images: [OCPart]
    let files: [OCPart]
    var alignment: HorizontalAlignment = .trailing

    @State private var gallerySelection: ChatImageGallerySelection?

    private var imageItems: [ChatImageItem] {
        images.map { ChatImageItem.fromPart($0, fallbackTitle: AppText.attachedImage) }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if !images.isEmpty {
                let items = imageItems
                let thumbnailSide: CGFloat = images.count == 1 ? 180 : 104
                let rowContent = HStack(spacing: 6) {
                    ForEach(Array(zip(images, items)), id: \.0.id) { part, item in
                        Button {
                            gallerySelection = ChatImageGallerySelection(items: items, initialItemID: item.id)
                        } label: {
                            PromptImageThumbnail(
                                cacheKey: part.id,
                                source: .dataURL(part.url ?? ""),
                                side: thumbnailSide,
                                showsZoomBadge: true
                            )
                        }
                        .buttonStyle(.plain)
                        .chatImageContextMenu(item: item) {
                            gallerySelection = ChatImageGallerySelection(items: items, initialItemID: item.id)
                        }
                        .accessibilityLabel(item.title)
                        .accessibilityHint(AppText.imageViewAndZoom)
                    }
                }

                if images.count > 2 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        rowContent
                    }
                } else {
                    rowContent
                }
            }
            ForEach(files, id: \.id) { part in
                PromptAttachmentChip(
                    title: part.filename ?? part.mime ?? AppText.attachedFile,
                    kind: part.url?.hasPrefix("file:") == true ? .serverFile : .textFile
                )
            }
        }
        .adaptiveImageViewerPresentation(selection: $gallerySelection)
    }
}

/// A named file attachment: phone text sent inline, or a reference the
/// server reads from the session's folder.
struct PromptAttachmentChip: View {
    enum Kind {
        case textFile
        case serverFile

        var systemImage: String {
            switch self {
            case .textFile: "doc.text"
            case .serverFile: "chevron.left.forwardslash.chevron.right"
            }
        }

        var accessibilityPrefix: String {
            switch self {
            case .textFile: AppText.attachedFile
            case .serverFile: AppText.repositoryFileReference
            }
        }
    }

    let title: String
    let kind: Kind
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppText.removeAttachment)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.accessibilityPrefix): \(title)")
    }
}

/// Attachments and pasted text snippets waiting in the composer, each removable
/// before sending. Text files and pasted snippets can be opened to check or edit content.
struct ComposerAttachmentStrip: View {
    var pastedSnippets: [ComposerPastedSnippet] = []
    let attachments: [PromptAttachment]
    let isPreparing: Bool
    var onRemoveSnippet: ((String) -> Void)? = nil
    var onSelectSnippet: ((ComposerPastedSnippet) -> Void)? = nil
    let onRemove: (String) -> Void
    let onPreview: (PromptTextFileAttachment) -> Void

    @State private var gallerySelection: ChatImageGallerySelection?

    private var composerImageItems: [ChatImageItem] {
        attachments.compactMap { attachment in
            guard case let .image(image) = attachment else { return nil }
            return ChatImageItem.fromPromptImage(image)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pastedSnippets) { snippet in
                    ComposerPastedSnippetCard(
                        snippet: snippet,
                        onTap: { onSelectSnippet?(snippet) },
                        onRemove: { onRemoveSnippet?(snippet.id) }
                    )
                }
                ForEach(attachments) { attachment in
                    item(for: attachment)
                }
                if isPreparing {
                    ProgressView()
                        .frame(width: 56, height: 56)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(AppText.preparingImage)
                }
            }
            .padding(.vertical, 2)
        }
        .adaptiveImageViewerPresentation(selection: $gallerySelection)
    }

    @ViewBuilder
    private func item(for attachment: PromptAttachment) -> some View {
        switch attachment {
        case let .image(image):
            let imageItem = ChatImageItem.fromPromptImage(image)
            let openViewer = {
                let items = composerImageItems
                gallerySelection = ChatImageGallerySelection(
                    items: items.isEmpty ? [imageItem] : items,
                    initialItemID: image.id
                )
            }
            PromptImageThumbnail(cacheKey: image.id, source: .data(image.data), side: 56)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture(perform: openViewer)
                .chatImageContextMenu(item: imageItem, onOpenViewer: openViewer) {
                    onRemove(image.id)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        onRemove(image.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                    .accessibilityLabel(AppText.removeAttachedImage)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(AppText.attachedImage): \(image.name)")
        case let .textFile(file):
            PromptAttachmentChip(title: file.name, kind: .textFile) { onRemove(file.id) }
                .macHoverHighlight(cornerRadius: 14)
                .contentShape(Capsule())
                .onTapGesture { onPreview(file) }
                .accessibilityAction(named: AppText.previewAttachment) { onPreview(file) }
        case let .serverFile(reference):
            PromptAttachmentChip(title: reference.displayName, kind: .serverFile) { onRemove(reference.id) }
        }
    }
}

struct PreviewedImageItem: Identifiable {
    let id: String
    let title: String
    let source: PromptImageThumbnail.Source

    var asChatImageItem: ChatImageItem {
        switch source {
        case let .data(bytes):
            ChatImageItem(id: id, title: title, source: .data(bytes))
        case let .dataURL(uri):
            ChatImageItem(id: id, title: title, source: .dataURL(uri))
        }
    }
}

/// Full-size zoomable preview for attached or sent images with download, copy, and share actions.
struct ImageAttachmentPreview: View {
    let item: PreviewedImageItem

    var body: some View {
        ChatImageViewer(selection: ChatImageGallerySelection(single: item.asChatImageItem))
    }
}

/// Read-only content of a text file picked from Files, before it is sent.
struct TextAttachmentPreview: View {
    let file: PromptTextFileAttachment

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(AttachmentPreviewText.truncated(file.text))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
    }
}

enum AttachmentPreviewText {
    static let maximumCharacters = 40_000

    /// Very long files are previewed only in part to keep the sheet responsive.
    static func truncated(_ text: String) -> String {
        guard let cut = text.index(text.startIndex, offsetBy: maximumCharacters, limitedBy: text.endIndex),
              cut < text.endIndex else {
            return text
        }
        return String(text[..<cut]) + "\n\n" + AppText.previewTruncated
    }
}

/// Compact card representing a large block of pasted text parked in the composer.
struct ComposerPastedSnippetCard: View {
    let snippet: ComposerPastedSnippet
    let onTap: () -> Void
    let onRemove: () -> Void

    @Environment(\.chatEasterEgg) private var chatEasterEgg

    private var isRetro: Bool {
        chatEasterEgg.visualMode.isRetro
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isRetro ? RetroChatStyle.blueAccent : Color.appAccent)

                Text("Pasted")
                    .font(isRetro ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRetro ? RetroChatStyle.ink : Color.appPrimary)

                Text(snippet.metricsLabel)
                    .font(isRetro ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : Color.appSecondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove pasted text")
            }

            Text(snippet.preview)
                .font(isRetro ? RetroChatStyle.smallFont : .system(size: 12))
                .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : Color.appSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 224, height: 56, alignment: .leading)
        .background(
            isRetro ? RetroChatStyle.paperWarm : Color.appSurface,
            in: RoundedRectangle(cornerRadius: isRetro ? 6 : 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isRetro ? 6 : 12, style: .continuous)
                .stroke(
                    isRetro ? RetroChatStyle.ink : Color.appSeparator,
                    lineWidth: isRetro ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: isRetro ? 6 : 12, style: .continuous))
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pasted text, \(snippet.metricsLabel)")
        .accessibilityAction(named: AppText.previewAttachment, onTap)
    }
}
