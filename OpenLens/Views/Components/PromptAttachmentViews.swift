import ImageIO
import SwiftUI
import UIKit

/// A square thumbnail decoded off the main actor from image bytes or a
/// `data:` URL, downsampled so large photos don't hold full-size bitmaps.
struct PromptImageThumbnail: View {
    let cacheKey: String
    let source: Source
    let side: CGFloat

    enum Source: Sendable {
        case data(Data)
        case dataURL(String)
    }

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

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

/// Images and files attached to a user prompt, shown above its text.
struct MessageAttachmentsRow: View {
    let images: [OCPart]
    let files: [OCPart]

    @State private var previewedImage: PreviewedImageItem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images, id: \.id) { part in
                        Button {
                            previewedImage = PreviewedImageItem(
                                id: part.id,
                                title: part.filename ?? AppText.attachedImage,
                                source: .dataURL(part.url ?? "")
                            )
                        } label: {
                            PromptImageThumbnail(
                                cacheKey: part.id,
                                source: .dataURL(part.url ?? ""),
                                side: images.count == 1 ? 160 : 96
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(part.filename ?? AppText.attachedImage)
                    }
                }
            }
            ForEach(files, id: \.id) { part in
                PromptAttachmentChip(
                    title: part.filename ?? part.mime ?? AppText.attachedFile,
                    kind: part.url?.hasPrefix("file:") == true ? .serverFile : .textFile
                )
            }
        }
        .sheet(item: $previewedImage) { item in
            ImageAttachmentPreview(item: item)
        }
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

    @State private var previewedImage: PreviewedImageItem?

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
        .sheet(item: $previewedImage) { item in
            ImageAttachmentPreview(item: item)
        }
    }

    @ViewBuilder
    private func item(for attachment: PromptAttachment) -> some View {
        switch attachment {
        case let .image(image):
            PromptImageThumbnail(cacheKey: image.id, source: .data(image.data), side: 56)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture {
                    previewedImage = PreviewedImageItem(
                        id: image.id,
                        title: image.name,
                        source: .data(image.data)
                    )
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
}

/// Full-size preview sheet for attached or sent images with Copy Image action.
struct ImageAttachmentPreview: View {
    let item: PreviewedImageItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ScrollView([.vertical, .horizontal]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame(.horizontal)
                            .padding()
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.appBackground)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.image = image
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy Image", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
            .task(id: item.id) {
                image = await PromptImageThumbnailCache.thumbnail(
                    key: "\(item.id)-full",
                    source: item.source,
                    maximumPixelSize: 2_400
                )
            }
        }
        .adaptiveSheetDragIndicator()
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
