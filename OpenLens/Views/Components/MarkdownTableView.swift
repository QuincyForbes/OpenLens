import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Inline Table Block

enum MarkdownTablePresentationStyle: Equatable {
    case standard
    case embeddedOnAccent
}

/// Renders text with embedded Markdown tables cleanly in contexts that do not
/// run a full Markdown document pass (user bubbles, streaming text, tool output,
/// reasoning, queued prompts). When no pipe table is present, it takes a zero-
/// allocation fast path directly to `prose(text)`.
struct TableAwareTextView<ProseContent: View>: View {
    let text: String
    let usesRetroTypography: Bool
    var tableStyle: MarkdownTablePresentationStyle = .standard
    var spacing: CGFloat = 10
    @ViewBuilder let prose: (String) -> ProseContent

    var body: some View {
        if MarkdownTable.containsTable(text) {
            let segments = MarkdownTable.splitTextAndTables(text)
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
                    switch segment {
                    case .text(let chunk):
                        prose(chunk)
                    case .table(let table):
                        MarkdownTableBlockView(
                            table: MarkdownContentView.prepareTable(table, id: offset),
                            usesRetroTypography: usesRetroTypography,
                            presentationStyle: tableStyle
                        )
                    case .blockquote(let nested):
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle()
                                .fill(usesRetroTypography ? RetroChatStyle.mutedInk : Color(.systemGray3))
                                .frame(width: 3)

                            VStack(alignment: .leading, spacing: spacing) {
                                ForEach(Array(nested.enumerated()), id: \.offset) { nestedOffset, child in
                                    switch child {
                                    case .text(let chunk):
                                        prose(chunk)
                                    case .table(let table):
                                        MarkdownTableBlockView(
                                            table: MarkdownContentView.prepareTable(
                                                table,
                                                id: offset * 1_000 + nestedOffset + 1
                                            ),
                                            usesRetroTypography: usesRetroTypography,
                                            presentationStyle: tableStyle
                                        )
                                    case .blockquote:
                                        EmptyView()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                        }
                    }
                }
            }
        } else {
            prose(text)
        }
    }
}

/// A Markdown table inside a chat bubble: a scrollable striped grid with a
/// header bar for opening the zoomable viewer, copying, and downloading.
struct MarkdownTableBlockView: View {
    private static let initialRowLimit = 20
    private static let expandStep = 40

    let table: MarkdownContentView.PreparedTable
    let usesRetroTypography: Bool
    var presentationStyle: MarkdownTablePresentationStyle = .standard

    @State private var visibleRowCount: Int?
    @State private var isViewerPresented = false
    @State private var export: MarkdownTableExport?
    @State private var confirmation: String?
    @State private var containerWidth: CGFloat = 0

    private var shownRowCount: Int {
        min(visibleRowCount ?? Self.initialRowLimit, table.rows.count)
    }

    private var cornerRadius: CGFloat {
        usesRetroTypography ? 6 : 10
    }

    private var cardBackground: Color {
        if usesRetroTypography {
            return RetroChatStyle.paper
        }
        switch presentationStyle {
        case .standard:
            return Color(.secondarySystemBackground)
        case .embeddedOnAccent:
            return Color(.systemBackground)
        }
    }

    private var headerBarBackground: Color {
        if usesRetroTypography {
            return RetroChatStyle.paperWarm
        }
        return Color.primary.opacity(0.04)
    }

    private var borderColor: Color {
        if usesRetroTypography {
            return RetroChatStyle.ink.opacity(0.75)
        }
        switch presentationStyle {
        case .standard:
            return Color.primary.opacity(0.18)
        case .embeddedOnAccent:
            return Color.primary.opacity(0.22)
        }
    }

    private var chromeDividerColor: Color {
        if usesRetroTypography {
            return RetroChatStyle.ink.opacity(0.45)
        }
        return Color.primary.opacity(0.16)
    }

    private var primaryTextColor: Color {
        usesRetroTypography ? RetroChatStyle.ink : Color.primary
    }

    private var secondaryTextColor: Color {
        usesRetroTypography ? RetroChatStyle.secondaryInk : Color.secondary
    }

    private var actionPillFill: Color {
        if usesRetroTypography {
            return RetroChatStyle.paper.opacity(0.9)
        }
        return Color(.systemGray5).opacity(0.85)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Rectangle()
                .fill(chromeDividerColor)
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                MarkdownTableGrid(
                    table: table,
                    rowLimit: shownRowCount,
                    zoom: 1,
                    usesRetroTypography: usesRetroTypography,
                    minimumTotalWidth: containerWidth
                )
            }

            if shownRowCount < table.rows.count {
                Rectangle()
                    .fill(chromeDividerColor)
                    .frame(height: 1)

                Button {
                    visibleRowCount = min(shownRowCount + Self.expandStep, table.rows.count)
                } label: {
                    Text(AppText.tableShowMoreRows(table.rows.count - shownRowCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if abs(containerWidth - newWidth) > 0.5 {
                containerWidth = newWidth
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: usesRetroTypography ? 1.5 : 1)
        }
        .adaptiveTableViewerPresentation(isPresented: $isViewerPresented, table: table)
        .markdownTableExporter($export)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AppText.table), \(AppText.tableDimensions(rows: table.rows.count, columns: table.table.columnCount))")
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                isViewerPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 11, weight: .semibold))
                    Text(confirmation ?? AppText.tableDimensions(rows: table.rows.count, columns: table.table.columnCount))
                        .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(confirmation == nil ? secondaryTextColor : Color.green)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Menu {
                MarkdownTableActions(
                    table: table.table,
                    onCopied: showConfirmation,
                    onExport: { export = MarkdownTableExport(table: table.table, format: $0) }
                )
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 26, height: 22)
                    .background(actionPillFill, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.tableActions)

            Button {
                isViewerPresented = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 26, height: 22)
                    .background(actionPillFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.tableOpen)
            .help(AppText.tableOpen)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(headerBarBackground)
    }

    private func showConfirmation(_ message: String) {
        confirmation = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            confirmation = nil
        }
    }
}

// MARK: - Grid

/// Fixed column widths (estimated at parse time) keep every row aligned
/// without a measuring pass, so rows can also be laid out lazily.
struct MarkdownTableGrid: View {
    let table: MarkdownContentView.PreparedTable
    let rowLimit: Int
    let zoom: CGFloat
    let usesRetroTypography: Bool
    var lazyRows = false
    var minimumTotalWidth: CGFloat = 0

    private var horizontalPadding: CGFloat { 12 * zoom }
    private var verticalPadding: CGFloat { 9 * zoom }

    private var visibleRowCount: Int {
        min(rowLimit, table.rows.count)
    }

    private var resolvedWidths: [CGFloat] {
        let baseWidths = table.columnWidths.map { $0 * zoom }
        guard !baseWidths.isEmpty else { return [] }
        let totalBase = baseWidths.reduce(0, +)
        guard minimumTotalWidth > totalBase, totalBase > 0 else {
            return baseWidths
        }
        let scale = minimumTotalWidth / totalBase
        var scaled = baseWidths.map { ($0 * scale).rounded(.down) }
        let remainder = minimumTotalWidth - scaled.reduce(0, +)
        scaled[scaled.count - 1] += remainder
        return scaled
    }

    private var headerDividerColor: Color {
        usesRetroTypography ? RetroChatStyle.ink.opacity(0.65) : Color.primary.opacity(0.24)
    }

    private var columnDividerColor: Color {
        usesRetroTypography ? RetroChatStyle.ink.opacity(0.35) : Color.primary.opacity(0.15)
    }

    private var rowDividerColor: Color {
        usesRetroTypography ? RetroChatStyle.ink.opacity(0.28) : Color.primary.opacity(0.12)
    }

    var body: some View {
        let widths = resolvedWidths
        let totalWidth = widths.reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            row(table.header, index: -1, widths: widths, showsBottomDivider: false)

            if visibleRowCount > 0 {
                Rectangle()
                    .fill(headerDividerColor)
                    .frame(width: totalWidth, height: 1.5)

                if lazyRows {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        bodyRows(widths: widths)
                    }
                } else {
                    bodyRows(widths: widths)
                }
            }
        }
    }

    @ViewBuilder
    private func bodyRows(widths: [CGFloat]) -> some View {
        let count = visibleRowCount
        ForEach(0..<count, id: \.self) { index in
            row(
                table.rows[index],
                index: index,
                widths: widths,
                showsBottomDivider: index < count - 1
            )
        }
    }

    private func row(
        _ cells: [MarkdownContentView.PreparedTable.Cell],
        index: Int,
        widths: [CGFloat],
        showsBottomDivider: Bool
    ) -> some View {
        let isHeader = index < 0
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { column in
                cellText(cells[column], isHeader: isHeader)
                    .multilineTextAlignment(textAlignment(column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(widths[column] - horizontalPadding * 2, 1), alignment: frameAlignment(column))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
            }
        }
        .background(alignment: .leading) {
            columnSeparators(widths: widths)
        }
        .background(rowFill(index))
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(rowDividerColor)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func cellText(_ cell: MarkdownContentView.PreparedTable.Cell, isHeader: Bool) -> some View {
        Group {
            if let attributed = cell.attributed {
                Text(attributed)
            } else {
                Text(cell.raw)
            }
        }
        .font(cellFont(isHeader: isHeader))
        .foregroundStyle(usesRetroTypography ? RetroChatStyle.ink : Color.primary)
        .tint(usesRetroTypography ? RetroChatStyle.blueAccent : Color.appAccent)
        .macInlineTextSelection()
    }

    private func cellFont(isHeader: Bool) -> Font {
        if usesRetroTypography && zoom == 1 {
            return isHeader ? RetroChatStyle.bodyFont.bold() : RetroChatStyle.bodyFont
        }
        return .system(size: 15 * zoom, weight: isHeader ? .semibold : .regular)
    }

    private func columnSeparators(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { column in
                Color.clear
                    .frame(width: widths[column])
                    .overlay(alignment: .trailing) {
                        if column < widths.count - 1 {
                            Rectangle()
                                .fill(columnDividerColor)
                                .frame(width: 1)
                        }
                    }
            }
        }
    }

    private func rowFill(_ index: Int) -> Color {
        if usesRetroTypography {
            if index < 0 { return RetroChatStyle.playerFill.opacity(0.35) }
            return index.isMultiple(of: 2) ? RetroChatStyle.paper : RetroChatStyle.paperWarm.opacity(0.55)
        }
        if index < 0 { return Color.primary.opacity(0.08) }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.table.alignments[column] {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Actions Menu

/// Copy, download, and share actions shared by the inline block and viewer.
struct MarkdownTableActions: View {
    let table: MarkdownTable
    let onCopied: (String) -> Void
    let onExport: (MarkdownTableExportFormat) -> Void

    var body: some View {
        Button {
            UIPasteboard.general.string = table.markdown
            onCopied(AppText.tableCopiedMarkdown)
        } label: {
            Label(AppText.tableCopyMarkdown, systemImage: "doc.on.doc")
        }

        Button {
            UIPasteboard.general.string = table.tsv
            onCopied(AppText.tableCopiedSpreadsheet)
        } label: {
            Label(AppText.tableCopySpreadsheet, systemImage: "tablecells")
        }

        Divider()

        ForEach(MarkdownTableExportFormat.allCases) { format in
            Button {
                onExport(format)
            } label: {
                Label(format.downloadLabel, systemImage: "arrow.down.doc")
            }
        }

        let filename = table.suggestedFilenameStem() + ".csv"
        ShareLink(
            item: MarkdownTableShareFile(table: table, filename: filename),
            preview: SharePreview(filename)
        ) {
            Label(AppText.tableShareCSV, systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Full-Screen Viewer

/// Zoomable, selectable full-screen table with download and share actions.
struct MarkdownTableViewer: View {
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3
    private static let zoomStep: CGFloat = 0.25
    /// Keeps a pathological table from building thousands of rows at once.
    private static let maximumDisplayedRows = 5_000

    let table: MarkdownContentView.PreparedTable

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var export: MarkdownTableExport?
    @State private var toast: Toast?

    private struct Toast: Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private var displayedRowCount: Int {
        min(table.rows.count, Self.maximumDisplayedRows)
    }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    if displayedRowCount < table.rows.count {
                        Label(
                            AppText.tableRowsLimited(displayedRowCount, total: table.rows.count),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    MarkdownTableGrid(
                        table: table,
                        rowLimit: displayedRowCount,
                        zoom: zoom,
                        usesRetroTypography: false,
                        lazyRows: true
                    )
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    }
                    .textSelection(.enabled)
                }
                .scaleEffect(pinch, anchor: .topLeading)
                .padding(16)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in
                        state = clampedZoom(zoom * value.magnification) / zoom
                    }
                    .onEnded { value in
                        zoom = clampedZoom(zoom * value.magnification)
                    }
            )
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) {
                controlBar
            }
            .overlay(alignment: .top) {
                if let toast {
                    toastView(toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(AppText.table)
                            .font(.headline)
                        Text(AppText.tableDimensions(rows: table.rows.count, columns: table.table.columnCount))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppText.done) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .background {
                keyboardShortcutLayer
            }
        }
        .markdownTableExporter($export) { result in
            switch result {
            case let .success(url):
                showToast(AppText.imageSavedFile(url.lastPathComponent))
            case let .failure(error):
                let nsError = error as NSError
                if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
                    showToast(AppText.tableSaveFailed(error.localizedDescription), isError: true)
                }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                setZoom(zoom - Self.zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= Self.zoomRange.lowerBound)
            .accessibilityLabel(AppText.imageZoomOut)

            Button {
                setZoom(1)
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(minWidth: 48)
            }
            .accessibilityLabel(AppText.tableZoomReset)

            Button {
                setZoom(zoom + Self.zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= Self.zoomRange.upperBound)
            .accessibilityLabel(AppText.imageZoomIn)

            Divider()
                .frame(height: 20)

            Menu {
                MarkdownTableActions(
                    table: table.table,
                    onCopied: { showToast($0) },
                    onExport: { export = MarkdownTableExport(table: table.table, format: $0) }
                )
            } label: {
                Label(AppText.imageDownload, systemImage: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
            }
            .accessibilityLabel(AppText.tableActions)
        }
        .font(.system(size: 17, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.bottom, 8)
    }

    private var keyboardShortcutLayer: some View {
        Group {
            Button("") { setZoom(zoom + Self.zoomStep) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { setZoom(zoom + Self.zoomStep) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(zoom - Self.zoomStep) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { setZoom(1) }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { export = MarkdownTableExport(table: table.table, format: .csv) }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toastView(_ toast: Toast) -> some View {
        Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(toast.isError ? Color.orange : Color.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            zoom = clampedZoom(value)
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        let next = Toast(message: message, isError: isError)
        withAnimation { toast = next }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == next {
                withAnimation { toast = nil }
            }
        }
    }
}

extension View {
    /// Full-screen on iOS/iPadOS, a spacious resizable sheet on Mac Catalyst.
    @ViewBuilder
    func adaptiveTableViewerPresentation(
        isPresented: Binding<Bool>,
        table: MarkdownContentView.PreparedTable
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        self.sheet(isPresented: isPresented) {
            MarkdownTableViewer(table: table)
                .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 720)
        }
        #else
        self.fullScreenCover(isPresented: isPresented) {
            MarkdownTableViewer(table: table)
        }
        #endif
    }

    func markdownTableExporter(
        _ export: Binding<MarkdownTableExport?>,
        onCompletion: @escaping (Result<URL, Error>) -> Void = { _ in }
    ) -> some View {
        fileExporter(
            isPresented: Binding(
                get: { export.wrappedValue != nil },
                set: { if !$0 { export.wrappedValue = nil } }
            ),
            document: export.wrappedValue?.document,
            contentType: export.wrappedValue?.format.contentType ?? .commaSeparatedText,
            defaultFilename: export.wrappedValue?.filename
        ) { result in
            onCompletion(result)
            export.wrappedValue = nil
        }
    }
}

// MARK: - Export

enum MarkdownTableExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case markdown

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .markdown: MarkdownTableExportDocument.markdownType
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .markdown: "md"
        }
    }

    var downloadLabel: String {
        switch self {
        case .csv: AppText.tableDownloadCSV
        case .markdown: AppText.tableDownloadMarkdown
        }
    }

    func data(for table: MarkdownTable) -> Data {
        switch self {
        case .csv: Data(table.csv.utf8)
        case .markdown: Data((table.markdown + "\n").utf8)
        }
    }
}

struct MarkdownTableExport {
    let document: MarkdownTableExportDocument
    let format: MarkdownTableExportFormat
    let filename: String

    init(table: MarkdownTable, format: MarkdownTableExportFormat) {
        self.document = MarkdownTableExportDocument(data: format.data(for: table))
        self.format = format
        self.filename = table.suggestedFilenameStem() + "." + format.fileExtension
    }
}

nonisolated struct MarkdownTableExportDocument: FileDocument, Sendable {
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    static var readableContentTypes: [UTType] {
        [.commaSeparatedText, markdownType, .plainText]
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

/// A CSV file for the share sheet (AirDrop, Mail, Numbers), built on demand.
nonisolated struct MarkdownTableShareFile: Transferable, Sendable {
    let table: MarkdownTable
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            let fileURL = try ChatImageShareFile.writeTemporaryFile(
                data: Data(item.table.csv.utf8),
                filename: item.filename
            )
            return SentTransferredFile(fileURL)
        }
    }
}
