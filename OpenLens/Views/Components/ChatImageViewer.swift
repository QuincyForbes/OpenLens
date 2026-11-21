import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Presentation & Context Menu Helpers

extension View {
    /// Presents the zoomable image lightbox edge-to-edge on iOS/iPadOS and as a
    /// spacious resizable desktop modal on Mac Catalyst.
    @ViewBuilder
    func adaptiveImageViewerPresentation(selection: Binding<ChatImageGallerySelection?>) -> some View {
        #if targetEnvironment(macCatalyst)
        self.sheet(item: selection) { gallery in
            ChatImageViewer(selection: gallery)
                .frame(minWidth: 760, idealWidth: 980, minHeight: 560, idealHeight: 740)
        }
        #else
        self.fullScreenCover(item: selection) { gallery in
            ChatImageViewer(selection: gallery)
        }
        #endif
    }

    /// Adds quick long-press / right-click image actions (View & Zoom, Copy,
    /// Save to Photos, Save to Files, Share) directly onto chat image thumbnails.
    func chatImageContextMenu(
        item: ChatImageItem,
        onOpenViewer: @escaping () -> Void,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ChatImageContextMenuModifier(
                item: item,
                onOpenViewer: onOpenViewer,
                onRemove: onRemove
            )
        )
    }
}

private struct ChatImageContextMenuModifier: ViewModifier {
    let item: ChatImageItem
    let onOpenViewer: () -> Void
    let onRemove: (() -> Void)?

    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.chatSessionDirectory) private var sessionDirectory

    @State private var isExportingFile = false
    @State private var exportDocument: ChatImageExportDocument?
    @State private var exportContentType: UTType = .png
    @State private var exportFilename = "image.png"

    private var canShareDirectly: Bool {
        switch item.source {
        case .data, .dataURL, .remoteURL:
            return true
        case let .toolResultFile(file):
            if case .dataURI = file.source { return true }
            return false
        }
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    onOpenViewer()
                } label: {
                    Label(AppText.imageViewAndZoom, systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Divider()

                Button {
                    copyImage()
                } label: {
                    Label(AppText.imageCopy, systemImage: "doc.on.doc")
                }

                Button {
                    saveToPhotos()
                } label: {
                    Label(AppText.imageSaveToPhotos, systemImage: "square.and.arrow.down")
                }

                Button {
                    exportToFiles()
                } label: {
                    Label(AppText.imageSaveToFiles, systemImage: "arrow.down.doc")
                }

                if canShareDirectly {
                    ShareLink(
                        item: LazyChatImageShareItem(
                            source: item.source,
                            title: item.title,
                            mime: item.mime
                        ),
                        preview: SharePreview(item.title)
                    ) {
                        Label(AppText.imageShare, systemImage: "square.and.arrow.up")
                    }
                }

                if let onRemove {
                    Divider()
                    Button(role: .destructive, action: onRemove) {
                        Label(AppText.removeAttachedImage, systemImage: "trash")
                    }
                }
            }
            .fileExporter(
                isPresented: $isExportingFile,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { _ in
                exportDocument = nil
            }
    }

    private func copyImage() {
        Task {
            guard let loaded = try? await ChatImageLoader.load(
                item: item,
                workspaceService: workspaceService,
                sessionDirectory: sessionDirectory
            ) else {
                return
            }
            ChatImageSaver.copyToPasteboard(payload: loaded.payload, image: loaded.image)
            #if !targetEnvironment(macCatalyst)
            if AppPreferences.hapticsEnabled {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            #endif
        }
    }

    private func saveToPhotos() {
        Task {
            guard let loaded = try? await ChatImageLoader.load(
                item: item,
                workspaceService: workspaceService,
                sessionDirectory: sessionDirectory
            ) else {
                return
            }
            let outcome = await ChatImageSaver.saveToPhotoLibrary(data: loaded.payload.data)
            #if !targetEnvironment(macCatalyst)
            if AppPreferences.hapticsEnabled {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(outcome == .saved ? .success : .warning)
            }
            #endif
        }
    }

    private func exportToFiles() {
        Task {
            guard let loaded = try? await ChatImageLoader.load(
                item: item,
                workspaceService: workspaceService,
                sessionDirectory: sessionDirectory
            ) else {
                return
            }
            exportDocument = ChatImageExportDocument(data: loaded.payload.data)
            exportContentType = loaded.payload.metadata.utType
            exportFilename = loaded.payload.suggestedFilename
            isExportingFile = true
        }
    }
}

// MARK: - Backdrop Style

enum ChatImageBackdrop: CaseIterable, Equatable {
    case dark
    case light
    case checkerboard

    var next: ChatImageBackdrop {
        switch self {
        case .dark: .light
        case .light: .checkerboard
        case .checkerboard: .dark
        }
    }

    var systemImage: String {
        switch self {
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        case .checkerboard: "checkerboard.rectangle"
        }
    }

    var label: String {
        switch self {
        case .dark: AppText.imageBackdropDark
        case .light: AppText.imageBackdropLight
        case .checkerboard: AppText.imageBackdropCheckerboard
        }
    }

    var usesLightChrome: Bool {
        self == .dark
    }
}

private struct ChatImageBackdropView: View {
    let backdrop: ChatImageBackdrop

    var body: some View {
        switch backdrop {
        case .dark:
            Color(red: 0.05, green: 0.05, blue: 0.07)
        case .light:
            Color(red: 0.95, green: 0.95, blue: 0.97)
        case .checkerboard:
            Canvas { context, size in
                let tile: CGFloat = 14
                let light = Color(white: 0.88)
                let dark = Color(white: 0.74)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
                let cols = Int(ceil(size.width / tile))
                let rows = Int(ceil(size.height / tile))
                for row in 0..<rows {
                    for col in 0..<cols where (row + col).isMultiple(of: 2) {
                        let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                        context.fill(Path(rect), with: .color(dark))
                    }
                }
            }
        }
    }
}

// MARK: - Full Zoomable Image Viewer

/// Interactive zoomable image lightbox & gallery for all chat images (user/assistant
/// attachments, tool-returned images, composer items, queued prompts, and Markdown images).
struct ChatImageViewer: View {
    let selection: ChatImageGallerySelection

    private enum PageLoadState {
        case loading
        case loaded(ChatImageLoader.LoadedImage)
        case failed(String)
    }

    private struct ToastState: Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
        let isError: Bool
        let showSettingsAction: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.chatSessionDirectory) private var sessionDirectory
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    @State private var selectedItemID: String
    @State private var pageStates: [String: PageLoadState] = [:]
    @State private var zoomScale: CGFloat = 1.0
    @State private var maxZoomScale: CGFloat = 6.0
    @State private var zoomCommand: ZoomableImageScrollView.ZoomCommand?
    @State private var rotationQuarterTurns: Int = 0
    @State private var backdrop: ChatImageBackdrop = .dark
    @State private var isChromeVisible = true
    @State private var showInfoSheet = false
    @State private var dragOffsetY: CGFloat = 0

    @State private var toast: ToastState?
    @State private var toastTask: Task<Void, Never>?
    @State private var didCopyCurrent = false
    @State private var isSavingToPhotos = false
    @State private var isExportingFile = false
    @State private var exportDocument: ChatImageExportDocument?
    @State private var exportContentType: UTType = .png
    @State private var exportFilename = "image.png"

    init(selection: ChatImageGallerySelection) {
        self.selection = selection
        let validInitial = selection.items.contains(where: { $0.id == selection.initialItemID })
            ? selection.initialItemID
            : (selection.items.first?.id ?? selection.initialItemID)
        _selectedItemID = State(initialValue: validInitial)
    }

    private var items: [ChatImageItem] {
        selection.items
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selectedItemID }) ?? 0
    }

    private var currentItem: ChatImageItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : items.first
    }

    private var currentLoaded: ChatImageLoader.LoadedImage? {
        guard let item = currentItem,
              case let .loaded(loaded) = pageStates[item.id] else {
            return nil
        }
        return loaded
    }

    private var canGoPrevious: Bool {
        currentIndex > 0
    }

    private var canGoNext: Bool {
        currentIndex + 1 < items.count
    }

    private var isZoomedIn: Bool {
        zoomScale > 1.02
    }

    private var chromeForeground: Color {
        backdrop.usesLightChrome ? .white : .primary
    }

    private var chromeSecondary: Color {
        backdrop.usesLightChrome ? .white.opacity(0.72) : .secondary
    }

    private var dismissProgress: CGFloat {
        min(max(dragOffsetY / 260, 0), 1)
    }

    var body: some View {
        ZStack {
            ChatImageBackdropView(backdrop: backdrop)
                .ignoresSafeArea()
                .opacity(Double(1.0 - dismissProgress * 0.45))

            galleryCanvas
                .offset(y: dragOffsetY)
                .scaleEffect(1.0 - dismissProgress * 0.1)
                #if !targetEnvironment(macCatalyst)
                .simultaneousGesture(pullToDismissGesture)
                #endif

            if isChromeVisible && dragOffsetY == 0 {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomDock
                }
                .transition(.opacity)
            }

            if let toast {
                VStack {
                    toastBanner(toast)
                        .padding(.top, isChromeVisible ? 66 : 20)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .preferredColorScheme(backdrop == .dark ? .dark : .light)
        #if !targetEnvironment(macCatalyst)
        .statusBarHidden(!isChromeVisible)
        #endif
        .task(id: selectedItemID) {
            await loadSelectedAndAdjacent()
        }
        .onChange(of: selectedItemID) { _, _ in
            zoomScale = 1.0
            rotationQuarterTurns = 0
            didCopyCurrent = false
        }
        .sheet(isPresented: $showInfoSheet) {
            if let item = currentItem, let loaded = currentLoaded {
                ChatImageInfoSheet(
                    title: item.title,
                    payload: loaded.payload,
                    zoomScale: zoomScale,
                    rotationDegrees: (rotationQuarterTurns % 4) * 90
                )
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                showToast(AppText.imageSavedFile(exportFilename), systemImage: "checkmark.circle.fill")
                playSuccessHaptic()
            case let .failure(error):
                let nsError = error as NSError
                if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
                    showToast(AppText.imageSaveFailed(error.localizedDescription), systemImage: "exclamationmark.triangle.fill", isError: true)
                }
            }
            exportDocument = nil
        }
        .background {
            keyboardShortcutLayer
        }
    }

    // MARK: - Gallery Canvas

    @ViewBuilder
    private var galleryCanvas: some View {
        if items.count <= 1, let item = items.first {
            pageView(for: item)
                .ignoresSafeArea()
        } else {
            TabView(selection: $selectedItemID) {
                ForEach(items) { item in
                    pageView(for: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func pageView(for item: ChatImageItem) -> some View {
        switch pageStates[item.id] ?? .loading {
        case .loading:
            ProgressView()
                .tint(chromeForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleChrome()
                }

        case let .failed(message):
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(chromeSecondary)
                Text(AppText.imageLoadFailed)
                    .font(.headline)
                    .foregroundStyle(chromeForeground)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(chromeSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(AppText.tryAgain) {
                    pageStates[item.id] = .loading
                    Task { await load(item: item) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(loaded):
            let isActivePage = item.id == selectedItemID
            ZoomableImageScrollView(
                image: loaded.image,
                pixelSize: CGSize(
                    width: CGFloat(loaded.payload.metadata.pixelWidth),
                    height: CGFloat(loaded.payload.metadata.pixelHeight)
                ),
                rotationQuarterTurns: isActivePage ? rotationQuarterTurns : 0,
                zoomCommand: isActivePage ? zoomCommand : nil,
                onSingleTap: toggleChrome,
                onZoomScaleChanged: { scale, maxScale in
                    guard isActivePage else { return }
                    zoomScale = scale
                    maxZoomScale = maxScale
                }
            )
            .accessibilityLabel(item.title)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chromeForeground)
                    .frame(width: 36, height: 36)
                    .background(chromePillMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.imageClose)

            VStack(spacing: 2) {
                Text(currentItem?.title ?? AppText.image)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chromeForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(chromeSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(chromePillMaterial, in: Capsule())
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        backdrop = backdrop.next
                    }
                    playSelectionHaptic()
                } label: {
                    Image(systemName: backdrop.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(chromeForeground)
                        .frame(width: 36, height: 36)
                        .background(chromePillMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(backdrop.label)
                .help(backdrop.label)

                Button {
                    rotateImage()
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(chromeForeground)
                        .frame(width: 36, height: 36)
                        .background(chromePillMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(currentLoaded == nil)
                .accessibilityLabel(AppText.imageRotate)
                .help(AppText.imageRotate)

                Menu {
                    if currentLoaded != nil {
                        Button {
                            showInfoSheet = true
                        } label: {
                            Label(AppText.imageInfo, systemImage: "info.circle")
                        }

                        Divider()

                        Button {
                            sendZoomCommand(.resetFit)
                        } label: {
                            Label(AppText.imageZoomFit, systemImage: "arrow.down.right.and.arrow.up.left")
                        }

                        Button {
                            sendZoomCommand(.toggleActualSize)
                        } label: {
                            Label(AppText.imageZoomActualSize, systemImage: "1.magnifyingglass")
                        }

                        if rotationQuarterTurns % 4 != 0 || isZoomedIn {
                            Button {
                                rotationQuarterTurns = 0
                                sendZoomCommand(.resetFit)
                            } label: {
                                Label(AppText.imageResetView, systemImage: "arrow.counterclockwise")
                            }
                        }

                        Divider()
                    }

                    Menu {
                        ForEach(ChatImageBackdrop.allCases, id: \.self) { option in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    backdrop = option
                                }
                            } label: {
                                if backdrop == option {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Label(option.label, systemImage: option.systemImage)
                                }
                            }
                        }
                    } label: {
                        Label(backdrop.label, systemImage: backdrop.systemImage)
                    }

                    if items.count > 1 {
                        Divider()
                        Button {
                            saveAllToPhotos()
                        } label: {
                            Label(AppText.imageSaveAllToPhotos(items.count), systemImage: "square.and.arrow.down.on.square")
                        }
                        .disabled(isSavingToPhotos)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(chromeForeground)
                        .frame(width: 36, height: 36)
                        .background(chromePillMaterial, in: Circle())
                }
                .accessibilityLabel("More image options")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    backdrop.usesLightChrome ? Color.black.opacity(0.52) : Color.white.opacity(0.62),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var headerSubtitle: String? {
        var parts: [String] = []
        if items.count > 1 {
            parts.append(AppText.imageGalleryPosition(currentIndex + 1, total: items.count))
        }
        if let meta = currentLoaded?.payload.metadata {
            parts.append(meta.summaryLabel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Bottom Dock

    private var bottomDock: some View {
        VStack(spacing: 10) {
            if items.count > 1 {
                galleryFilmstrip
            }

            if horizontalSizeClass == .compact {
                VStack(spacing: 10) {
                    zoomControlPill
                    compactActionDock
                }
            } else {
                HStack(spacing: 14) {
                    zoomControlPill
                    Spacer(minLength: 8)
                    regularActionDock
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [
                    .clear,
                    backdrop.usesLightChrome ? Color.black.opacity(0.56) : Color.white.opacity(0.68),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var zoomControlPill: some View {
        HStack(spacing: 2) {
            Button {
                sendZoomCommand(.zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isZoomedIn ? chromeForeground : chromeSecondary.opacity(0.45))
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!isZoomedIn || currentLoaded == nil)
            .accessibilityLabel(AppText.imageZoomOut)

            Button {
                if isZoomedIn {
                    sendZoomCommand(.resetFit)
                } else {
                    sendZoomCommand(.toggleActualSize)
                }
            } label: {
                Text("\(Int(round(zoomScale * 100)))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(chromeForeground)
                    .frame(minWidth: 48, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil)
            .accessibilityLabel(isZoomedIn ? AppText.imageZoomFit : AppText.imageZoomActualSize)
            .help(isZoomedIn ? AppText.imageZoomFit : AppText.imageZoomActualSize)

            Button {
                sendZoomCommand(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(zoomScale < maxZoomScale - 0.05 ? chromeForeground : chromeSecondary.opacity(0.45))
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(zoomScale >= maxZoomScale - 0.05 || currentLoaded == nil)
            .accessibilityLabel(AppText.imageZoomIn)
        }
        .padding(.horizontal, 6)
        .background(chromePillMaterial, in: Capsule())
    }

    private var compactActionDock: some View {
        HStack(spacing: 6) {
            if let loaded = currentLoaded {
                ShareLink(
                    item: ChatImageShareFile(
                        data: loaded.payload.data,
                        filename: loaded.payload.suggestedFilename
                    ),
                    preview: SharePreview(
                        loaded.payload.suggestedFilename,
                        image: Image(uiImage: loaded.image)
                    )
                ) {
                    compactActionLabel(AppText.imageShare, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } else {
                compactActionLabel(AppText.imageShare, systemImage: "square.and.arrow.up")
                    .opacity(0.4)
            }

            Button {
                copyCurrentImage()
            } label: {
                compactActionLabel(
                    didCopyCurrent ? "Copied" : "Copy",
                    systemImage: didCopyCurrent ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil)

            Button {
                exportCurrentImage()
            } label: {
                compactActionLabel("Files", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil)

            Button {
                saveCurrentToPhotos()
            } label: {
                compactActionLabel(
                    "Photos",
                    systemImage: isSavingToPhotos ? "hourglass" : "square.and.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil || isSavingToPhotos)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chromePillMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(chromeForeground)
        .frame(minWidth: 66, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var regularActionDock: some View {
        HStack(spacing: 8) {
            if let loaded = currentLoaded {
                ShareLink(
                    item: ChatImageShareFile(
                        data: loaded.payload.data,
                        filename: loaded.payload.suggestedFilename
                    ),
                    preview: SharePreview(
                        loaded.payload.suggestedFilename,
                        image: Image(uiImage: loaded.image)
                    )
                ) {
                    regularActionPill(AppText.imageShare, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } else {
                regularActionPill(AppText.imageShare, systemImage: "square.and.arrow.up")
                    .opacity(0.4)
            }

            Button {
                copyCurrentImage()
            } label: {
                regularActionPill(
                    didCopyCurrent ? "Copied" : "Copy",
                    systemImage: didCopyCurrent ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil)

            Button {
                saveCurrentToPhotos()
            } label: {
                regularActionPill(
                    AppText.imageSaveToPhotos,
                    systemImage: isSavingToPhotos ? "hourglass" : "square.and.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil || isSavingToPhotos)

            Button {
                exportCurrentImage()
            } label: {
                Label(AppText.imageDownload, systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.appAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(currentLoaded == nil)
        }
    }

    private func regularActionPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(chromeForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(chromePillMaterial, in: Capsule())
    }

    private var galleryFilmstrip: some View {
        HStack(spacing: 8) {
            Button {
                selectPrevious()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canGoPrevious ? chromeForeground : chromeSecondary.opacity(0.35))
                    .frame(width: 30, height: 30)
                    .background(chromePillMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevious)
            .accessibilityLabel(AppText.imagePrevious)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            let isSelected = item.id == selectedItemID
                            Button {
                                withAnimation(.snappy(duration: 0.22)) {
                                    selectedItemID = item.id
                                }
                            } label: {
                                filmstripThumbnail(for: item)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(
                                                isSelected ? Color.appAccent : chromeForeground.opacity(0.22),
                                                lineWidth: isSelected ? 2.5 : 1
                                            )
                                    }
                                    .scaleEffect(isSelected ? 1.05 : 0.94)
                                    .opacity(isSelected ? 1.0 : 0.72)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .accessibilityLabel(item.title)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .onChange(of: selectedItemID) { _, newID in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: 360)

            Button {
                selectNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canGoNext ? chromeForeground : chromeSecondary.opacity(0.35))
                    .frame(width: 30, height: 30)
                    .background(chromePillMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .accessibilityLabel(AppText.imageNext)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func filmstripThumbnail(for item: ChatImageItem) -> some View {
        if case let .loaded(loaded) = pageStates[item.id] {
            Image(uiImage: loaded.image)
                .resizable()
                .scaledToFill()
        } else {
            switch item.source {
            case let .data(bytes):
                PromptImageThumbnail(cacheKey: item.id, source: .data(bytes), side: 40)
            case let .dataURL(uri):
                PromptImageThumbnail(cacheKey: item.id, source: .dataURL(uri), side: 40)
            case let .toolResultFile(file):
                if case let .dataURI(uri) = file.source {
                    PromptImageThumbnail(cacheKey: item.id, source: .dataURL(uri), side: 40)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.25)
                        Image(systemName: "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(chromeSecondary)
                    }
                }
            case .remoteURL:
                ZStack {
                    Color.secondary.opacity(0.25)
                    Image(systemName: "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(chromeSecondary)
                }
            }
        }
    }

    private func toastBanner(_ toast: ToastState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chromeForeground)
                .lineLimit(2)
            if toast.showSettingsAction {
                Button(AppText.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(chromePillMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .padding(.horizontal, 20)
    }

    private var chromePillMaterial: some ShapeStyle {
        backdrop.usesLightChrome
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(.regularMaterial)
    }

    // MARK: - Keyboard Shortcuts (Mac Catalyst & Hardware Keyboard)

    private var keyboardShortcutLayer: some View {
        Group {
            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("") { sendZoomCommand(.zoomIn) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { sendZoomCommand(.zoomIn) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { sendZoomCommand(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { sendZoomCommand(.resetFit) }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { copyCurrentImage() }
                .keyboardShortcut("c", modifiers: .command)
            Button("") { exportCurrentImage() }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { rotateImage() }
                .keyboardShortcut("r", modifiers: [])
            Button("") { selectPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { selectNext() }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .labelsHidden()
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Pull-to-Dismiss Gesture (iOS)

    #if !targetEnvironment(macCatalyst)
    private var pullToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard !isZoomedIn else { return }
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                guard vertical > 0, vertical > horizontal * 1.25 else {
                    if dragOffsetY > 0 { dragOffsetY = 0 }
                    return
                }
                dragOffsetY = vertical
            }
            .onEnded { value in
                guard dragOffsetY > 0 else { return }
                let projected = value.predictedEndTranslation.height
                if dragOffsetY > 120 || projected > 240 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffsetY = 0
                    }
                }
            }
    }
    #endif

    // MARK: - Actions

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isChromeVisible.toggle()
        }
    }

    private func sendZoomCommand(_ action: ZoomableImageScrollView.ZoomAction) {
        guard currentLoaded != nil else { return }
        zoomCommand = ZoomableImageScrollView.ZoomCommand(action: action)
    }

    private func rotateImage() {
        guard currentLoaded != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        }
        zoomScale = 1.0
        playSelectionHaptic()
    }

    private func selectPrevious() {
        guard canGoPrevious else { return }
        withAnimation(.snappy(duration: 0.22)) {
            selectedItemID = items[currentIndex - 1].id
        }
    }

    private func selectNext() {
        guard canGoNext else { return }
        withAnimation(.snappy(duration: 0.22)) {
            selectedItemID = items[currentIndex + 1].id
        }
    }

    private func copyCurrentImage() {
        guard let loaded = currentLoaded else { return }
        ChatImageSaver.copyToPasteboard(payload: loaded.payload, image: loaded.image)
        didCopyCurrent = true
        showToast(AppText.imageCopied, systemImage: "checkmark.circle.fill")
        playSuccessHaptic()
    }

    private func exportCurrentImage() {
        guard let loaded = currentLoaded else { return }
        exportDocument = ChatImageExportDocument(data: loaded.payload.data)
        exportContentType = loaded.payload.metadata.utType
        exportFilename = loaded.payload.suggestedFilename
        isExportingFile = true
    }

    private func saveCurrentToPhotos() {
        guard let loaded = currentLoaded, !isSavingToPhotos else { return }
        isSavingToPhotos = true
        Task {
            defer { isSavingToPhotos = false }
            let outcome = await ChatImageSaver.saveToPhotoLibrary(data: loaded.payload.data)
            switch outcome {
            case .saved:
                showToast(AppText.imageSavedToPhotos, systemImage: "checkmark.circle.fill")
                playSuccessHaptic()
            case .permissionDenied:
                showToast(
                    AppText.imagePhotosAccessDenied,
                    systemImage: "exclamationmark.triangle.fill",
                    isError: true,
                    showSettingsAction: true
                )
            case let .failed(message):
                showToast(
                    AppText.imageSaveFailed(message),
                    systemImage: "exclamationmark.triangle.fill",
                    isError: true
                )
            }
        }
    }

    private func saveAllToPhotos() {
        guard !isSavingToPhotos, items.count > 1 else { return }
        isSavingToPhotos = true
        Task {
            defer { isSavingToPhotos = false }
            var savedCount = 0
            var denied = false
            var lastError: String?

            for item in items {
                let loaded: ChatImageLoader.LoadedImage
                if case let .loaded(existing) = pageStates[item.id] {
                    loaded = existing
                } else if let fetched = try? await ChatImageLoader.load(
                    item: item,
                    workspaceService: workspaceService,
                    sessionDirectory: sessionDirectory
                ) {
                    pageStates[item.id] = .loaded(fetched)
                    loaded = fetched
                } else {
                    continue
                }

                let outcome = await ChatImageSaver.saveToPhotoLibrary(data: loaded.payload.data)
                switch outcome {
                case .saved:
                    savedCount += 1
                case .permissionDenied:
                    denied = true
                case let .failed(message):
                    lastError = message
                }
                if denied { break }
            }

            if denied {
                showToast(
                    AppText.imagePhotosAccessDenied,
                    systemImage: "exclamationmark.triangle.fill",
                    isError: true,
                    showSettingsAction: true
                )
            } else if savedCount > 0 {
                showToast(AppText.imageSavedMultipleToPhotos(savedCount), systemImage: "checkmark.circle.fill")
                playSuccessHaptic()
            } else if let lastError {
                showToast(AppText.imageSaveFailed(lastError), systemImage: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func showToast(
        _ message: String,
        systemImage: String,
        isError: Bool = false,
        showSettingsAction: Bool = false
    ) {
        toastTask?.cancel()
        withAnimation(.snappy(duration: 0.25)) {
            toast = ToastState(
                message: message,
                systemImage: systemImage,
                isError: isError,
                showSettingsAction: showSettingsAction
            )
        }
        let duration: Duration = showSettingsAction ? .seconds(4.2) : .seconds(2.2)
        toastTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toast = nil
            }
        }
    }

    private func loadSelectedAndAdjacent() async {
        guard let item = currentItem else { return }
        await load(item: item)
        // Warm the immediate neighbor pages so swiping feels instantaneous.
        if canGoNext {
            let nextItem = items[currentIndex + 1]
            if pageStates[nextItem.id] == nil {
                await load(item: nextItem)
            }
        }
        if canGoPrevious {
            let prevItem = items[currentIndex - 1]
            if pageStates[prevItem.id] == nil {
                await load(item: prevItem)
            }
        }
    }

    private func load(item: ChatImageItem) async {
        if case .loaded = pageStates[item.id] { return }
        pageStates[item.id] = .loading
        do {
            let loaded = try await ChatImageLoader.load(
                item: item,
                workspaceService: workspaceService,
                sessionDirectory: sessionDirectory
            )
            guard !Task.isCancelled else { return }
            pageStates[item.id] = .loaded(loaded)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? AppText.toolFileUnreadable
            pageStates[item.id] = .failed(message)
        }
    }

    private func playSuccessHaptic() {
        #if !targetEnvironment(macCatalyst)
        if AppPreferences.hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
    }

    private func playSelectionHaptic() {
        #if !targetEnvironment(macCatalyst)
        if AppPreferences.hapticsEnabled {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        #endif
    }
}

// MARK: - Image Metadata Sheet

private struct ChatImageInfoSheet: View {
    let title: String
    let payload: ChatImagePayload
    let zoomScale: CGFloat
    let rotationDegrees: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Title", value: title)
                    LabeledContent("Download Name", value: payload.suggestedFilename)
                    LabeledContent("Format", value: payload.metadata.formatName)
                    LabeledContent("Size", value: payload.metadata.fileSizeLabel)
                }

                Section("Dimensions") {
                    LabeledContent("Resolution", value: "\(payload.metadata.dimensionsLabel) px")
                    LabeledContent("Aspect Ratio", value: payload.metadata.aspectRatioLabel)
                    LabeledContent("Transparency", value: payload.metadata.hasAlpha ? "Yes (Alpha)" : "Opaque")
                }

                Section("Viewer") {
                    LabeledContent("Zoom", value: "\(Int(round(zoomScale * 100)))%")
                    if rotationDegrees != 0 {
                        LabeledContent("Rotation", value: "\(rotationDegrees)°")
                    }
                }
            }
            .navigationTitle(AppText.imageInfo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .adaptiveSheetDragIndicator()
    }
}

// MARK: - UIScrollView Pinch/Double-Tap Zoomable Image View

/// Native `UIScrollView`-backed zoomable image surface with pinch-to-zoom,
/// momentum panning, double-tap point zoom, single-tap chrome toggle,
/// and Mac Catalyst trackpad zoom support.
struct ZoomableImageScrollView: UIViewRepresentable {
    enum ZoomAction: Equatable {
        case zoomIn
        case zoomOut
        case resetFit
        case toggleActualSize
    }

    struct ZoomCommand: Equatable {
        let id = UUID()
        let action: ZoomAction
    }

    let image: UIImage
    let pixelSize: CGSize
    var rotationQuarterTurns: Int = 0
    var zoomCommand: ZoomCommand? = nil
    var onSingleTap: () -> Void = {}
    var onZoomScaleChanged: (CGFloat, CGFloat) -> Void = { _, _ in }

    @Environment(\.displayScale) private var displayScale

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onZoomScaleChanged: onZoomScaleChanged
        )
    }

    func makeUIView(context: Context) -> CenteringImageScrollView {
        let scrollView = CenteringImageScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.scrollView = scrollView
        scrollView.apply(
            sourceImage: image,
            pixelSize: pixelSize,
            rotationQuarterTurns: rotationQuarterTurns,
            displayScale: displayScale
        )
        return scrollView
    }

    func updateUIView(_ scrollView: CenteringImageScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomScaleChanged = onZoomScaleChanged

        scrollView.apply(
            sourceImage: image,
            pixelSize: pixelSize,
            rotationQuarterTurns: rotationQuarterTurns,
            displayScale: displayScale
        )

        if let command = zoomCommand, command.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = command.id
            context.coordinator.perform(command.action)
        }
    }

    final class CenteringImageScrollView: UIScrollView {
        let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            return view
        }()

        private weak var sourceImageRef: UIImage?
        private var currentRotationQuarterTurns: Int = 0
        private var currentPixelSize: CGSize = .zero
        private var currentDisplayScale: CGFloat = 2.0
        private var lastLaidOutBoundsSize: CGSize = .zero
        private(set) var fittedPointSize: CGSize = .zero
        private(set) var actualSizeScale: CGFloat = 1.0

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func apply(
            sourceImage: UIImage,
            pixelSize: CGSize,
            rotationQuarterTurns: Int,
            displayScale: CGFloat
        ) {
            let normalizedTurns = ((rotationQuarterTurns % 4) + 4) % 4
            let imageChanged = sourceImageRef !== sourceImage
                || currentRotationQuarterTurns != normalizedTurns
                || currentPixelSize != pixelSize

            currentDisplayScale = max(displayScale, 1.0)
            guard imageChanged else { return }

            sourceImageRef = sourceImage
            currentRotationQuarterTurns = normalizedTurns
            currentPixelSize = pixelSize
            imageView.image = ChatImageOrientation.rotatedImage(sourceImage, quarterTurns: normalizedTurns)
            resetLayoutForCurrentBounds()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size.width > 0, bounds.size.height > 0 else { return }
            if bounds.size != lastLaidOutBoundsSize {
                resetLayoutForCurrentBounds()
            } else {
                centerImageView()
            }
        }

        func resetLayoutForCurrentBounds() {
            guard bounds.size.width > 0, bounds.size.height > 0, let displayed = imageView.image else {
                return
            }
            lastLaidOutBoundsSize = bounds.size

            let imageAspectSize = displayed.size
            guard imageAspectSize.width > 0, imageAspectSize.height > 0 else { return }

            let widthRatio = bounds.size.width / imageAspectSize.width
            let heightRatio = bounds.size.height / imageAspectSize.height
            let fitRatio = min(widthRatio, heightRatio)
            let fitted = CGSize(
                width: max(floor(imageAspectSize.width * fitRatio), 1),
                height: max(floor(imageAspectSize.height * fitRatio), 1)
            )
            fittedPointSize = fitted

            let rotatedPixels = (currentRotationQuarterTurns % 2 == 1)
                ? CGSize(width: currentPixelSize.height, height: currentPixelSize.width)
                : currentPixelSize

            let maxScale = ChatImagePayload.preferredMaximumZoomScale(
                pixelSize: rotatedPixels,
                fittedPointSize: fitted,
                displayScale: currentDisplayScale
            )
            actualSizeScale = ChatImagePayload.actualSizeZoomScale(
                pixelSize: rotatedPixels,
                fittedPointSize: fitted,
                displayScale: currentDisplayScale,
                maximumScale: maxScale
            )

            minimumZoomScale = 1.0
            maximumZoomScale = maxScale
            zoomScale = 1.0
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            centerImageView()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            (delegate as? Coordinator)?.syncScaleAfterLayout(self)
        }

        func centerImageView() {
            let boundsSize = bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }
            let contentW = imageView.frame.width
            let contentH = imageView.frame.height
            let insetX = max((boundsSize.width - contentW) * 0.5, 0)
            let insetY = max((boundsSize.height - contentH) * 0.5, 0)
            let newInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
            if contentInset != newInset {
                contentInset = newInset
            }
            #if targetEnvironment(macCatalyst)
            let showIndicators = zoomScale > 1.02
            if showsHorizontalScrollIndicator != showIndicators {
                showsHorizontalScrollIndicator = showIndicators
                showsVerticalScrollIndicator = showIndicators
            }
            #endif
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: CenteringImageScrollView?
        var onSingleTap: () -> Void
        var onZoomScaleChanged: (CGFloat, CGFloat) -> Void
        var lastCommandID: UUID?

        private var lastReportedScale: CGFloat = 1.0
        private var lastReportedMaxScale: CGFloat = 6.0

        init(
            onSingleTap: @escaping () -> Void,
            onZoomScaleChanged: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onZoomScaleChanged = onZoomScaleChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringImageScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let centering = scrollView as? CenteringImageScrollView else { return }
            centering.centerImageView()
            reportScaleIfNeeded(centering)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard let centering = scrollView as? CenteringImageScrollView else { return }
            centering.centerImageView()
            reportScaleIfNeeded(centering, force: true)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let targetScale = min(
                    scrollView.maximumZoomScale,
                    min(max(2.5, scrollView.actualSizeScale), 4.0)
                )
                let tapPoint = gesture.location(in: scrollView.imageView)
                let visibleSize = scrollView.bounds.size
                let rectWidth = visibleSize.width / targetScale
                let rectHeight = visibleSize.height / targetScale
                let zoomRect = CGRect(
                    x: tapPoint.x - rectWidth * 0.5,
                    y: tapPoint.y - rectHeight * 0.5,
                    width: rectWidth,
                    height: rectHeight
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        func perform(_ action: ZoomAction) {
            guard let scrollView else { return }
            switch action {
            case .zoomIn:
                let next = min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.6)
                scrollView.setZoomScale(next, animated: true)
            case .zoomOut:
                let next = max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.6)
                scrollView.setZoomScale(next, animated: true)
            case .resetFit:
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            case .toggleActualSize:
                let target = max(scrollView.actualSizeScale, 2.0)
                let clamped = min(scrollView.maximumZoomScale, target)
                if abs(scrollView.zoomScale - clamped) < 0.12 {
                    scrollView.setZoomScale(1.0, animated: true)
                } else {
                    scrollView.setZoomScale(clamped, animated: true)
                }
            }
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.reportScaleIfNeeded(scrollView, force: true)
            }
        }

        func syncScaleAfterLayout(_ scrollView: CenteringImageScrollView) {
            reportScaleIfNeeded(scrollView, force: true)
        }

        private func reportScaleIfNeeded(_ scrollView: CenteringImageScrollView, force: Bool = false) {
            let scale = scrollView.zoomScale
            let maxScale = scrollView.maximumZoomScale
            let crossedZoomThreshold = (scale <= 1.02) != (lastReportedScale <= 1.02)
            let changedSignificantly = abs(scale - lastReportedScale) >= 0.02
                || abs(maxScale - lastReportedMaxScale) >= 0.1
            if force || crossedZoomThreshold || changedSignificantly {
                lastReportedScale = scale
                lastReportedMaxScale = maxScale
                let callback = onZoomScaleChanged
                DispatchQueue.main.async {
                    callback(scale, maxScale)
                }
            }
        }
    }
}
