import SwiftUI

/// Browses the session's folder on the server and picks a file to reference
/// in a prompt, optionally limited to a range of lines.
struct RepositoryFilePicker: View {
    let directory: String
    let onAttach: (_ relativePath: String, _ lines: ServerFileReference.LineRange?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RepositoryFolderList(directory: directory, relativePath: "", onAttach: attach)
                .navigationDestination(for: RepositoryEntry.self) { entry in
                    if entry.isDirectory {
                        RepositoryFolderList(directory: directory, relativePath: entry.path, onAttach: attach)
                    } else {
                        RepositoryFileRangeView(directory: directory, entry: entry, onAttach: attach)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppText.cancel) { dismiss() }
                    }
                }
        }
    }

    private func attach(_ relativePath: String, _ lines: ServerFileReference.LineRange?) {
        onAttach(relativePath, lines)
        dismiss()
    }
}

private struct RepositoryFolderList: View {
    private enum LoadState {
        case loading
        case loaded([RepositoryEntry])
        case error(String)
    }

    let directory: String
    let relativePath: String
    let onAttach: (String, ServerFileReference.LineRange?) -> Void

    @Environment(\.workspaceService) private var workspaceService
    @State private var loadState: LoadState = .loading
    @State private var searchQuery = ""

    private func filteredEntries(_ entries: [RepositoryEntry]) -> [RepositoryEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.path.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .navigationTitle(relativePath.isEmpty ? AppText.repositoryFiles : (relativePath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Filter files")
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .tint(Color.appAccent)
        case let .error(message):
            ContentUnavailableView {
                Label(AppText.repositoryFolderUnavailable, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(AppText.tryAgain) { Task { await load() } }
            }
        case let .loaded(entries):
            let visible = filteredEntries(entries)
            if entries.isEmpty {
                ContentUnavailableView(AppText.repositoryFolderEmpty, systemImage: "folder")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            } else {
                List(visible) { entry in
                    NavigationLink(value: entry) {
                        Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(Color.appPrimary)
                    }
                    .listRowBackground(Color.appSurface)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await workspaceService.loadRepositoryEntries(at: relativePath, in: directory))
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }
}

/// Previews a repository file with line numbers and lets the user choose
/// an optional start and end line before attaching a reference to it.
struct RepositoryFileRangeView: View {
    private enum LoadState {
        case loading
        case loaded([String])
        case error(String)
    }

    let directory: String
    let entry: RepositoryEntry
    let onAttach: (String, ServerFileReference.LineRange?) -> Void

    @Environment(\.workspaceService) private var workspaceService
    @State private var loadState: LoadState = .loading
    @State private var startLine = ""
    @State private var endLine = ""
    @State private var lineSearchQuery = ""

    private static let maximumPreviewLines = 2_000

    nonisolated static func updatedLineRange(
        startLine: String,
        endLine: String,
        tappedLine: Int
    ) -> (start: String, end: String) {
        let start = Int(startLine.trimmingCharacters(in: .whitespaces))
        let end = Int(endLine.trimmingCharacters(in: .whitespaces))
        guard let start else {
            return ("\(tappedLine)", "")
        }
        if end != nil {
            return ("\(tappedLine)", "")
        }
        if tappedLine == start {
            return ("", "")
        }
        if tappedLine > start {
            return ("\(start)", "\(tappedLine)")
        }
        return ("\(tappedLine)", "\(start)")
    }

    var body: some View {
        VStack(spacing: 0) {
            rangeFields
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appBackground)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppText.attach) {
                    if case let .valid(lines) = selection {
                        onAttach(entry.path, lines)
                    }
                }
                .disabled(!selection.isValid)
            }
        }
        .task { await load() }
    }

    private var rangeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.path)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                if !startLine.isEmpty || !endLine.isEmpty {
                    Button("Clear range") {
                        startLine = ""
                        endLine = ""
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                }
            }
            HStack(spacing: 12) {
                TextField(AppText.startLine, text: $startLine)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                TextField(AppText.endLine, text: $endLine)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Find text in file…", text: $lineSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            Text("\(selection.message) Tap any two lines below to select a range.")
                .font(.caption)
                .foregroundStyle(selection.isInvalid ? Color.red : Color.appSecondary)
        }
        .padding(16)
        .background(Color.appSurface)
    }

    @ViewBuilder
    private var preview: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .tint(Color.appAccent)
        case let .error(message):
            ContentUnavailableView(AppText.repositoryFileUnavailable, systemImage: "doc", description: Text(message))
        case let .loaded(lines):
            let trimmedSearch = lineSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(Self.maximumPreviewLines).enumerated()), id: \.offset) { index, line in
                        let lineNumber = index + 1
                        let matchesSearch = !trimmedSearch.isEmpty && line.localizedCaseInsensitiveContains(trimmedSearch)
                        Button {
                            let updated = Self.updatedLineRange(
                                startLine: startLine,
                                endLine: endLine,
                                tappedLine: lineNumber
                            )
                            startLine = updated.start
                            endLine = updated.end
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(lineNumber)")
                                    .foregroundStyle(isSelected(lineNumber) ? Color.appAccent : Color.appSecondary)
                                    .fontWeight(isSelected(lineNumber) ? .bold : .regular)
                                    .frame(minWidth: 36, alignment: .trailing)
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(Color.appPrimary)
                                    .fixedSize()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected(lineNumber)
                                    ? Color.appAccent.opacity(0.16)
                                    : (matchesSearch ? Color.yellow.opacity(0.18) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 8)
            }
        }
    }

    private enum Selection {
        case valid(ServerFileReference.LineRange?)
        case unavailable
        case invalid(String)

        var isValid: Bool {
            if case .valid = self { true } else { false }
        }

        var isInvalid: Bool {
            if case .invalid = self { true } else { false }
        }

        var message: String {
            switch self {
            case .valid(nil), .unavailable: AppText.wholeFileReference
            case let .valid(lines?): AppText.lineRangeReference(lines.label)
            case let .invalid(message): message
            }
        }
    }

    /// Only a file that loaded as text can be referenced, and its range
    /// must fall within the lines it has.
    private var selection: Selection {
        guard case let .loaded(fileLines) = loadState else { return .unavailable }
        let lineCount = fileLines.last == "" ? fileLines.count - 1 : fileLines.count
        let start = startLine.trimmingCharacters(in: .whitespaces)
        let end = endLine.trimmingCharacters(in: .whitespaces)
        let invalidRange = Selection.invalid(PromptAttachmentError.invalidLineRange.errorDescription ?? "")
        if start.isEmpty, end.isEmpty { return .valid(nil) }
        guard let startValue = start.isEmpty ? 1 : Int(start) else { return invalidRange }
        let endValue: Int?
        if end.isEmpty {
            endValue = nil
        } else if let value = Int(end) {
            endValue = value
        } else {
            return invalidRange
        }
        guard let lines = try? ServerFileReference.LineRange(start: startValue, end: endValue) else { return invalidRange }
        guard (lines.end ?? lines.start) <= max(lineCount, 1) else {
            return .invalid(AppText.lineRangePastEnd(lineCount))
        }
        return .valid(lines)
    }

    private func isSelected(_ line: Int) -> Bool {
        guard case let .valid(lines?) = selection else { return false }
        return line >= lines.start && line <= (lines.end ?? .max)
    }

    private func load() async {
        loadState = .loading
        do {
            let text = try await workspaceService.readRepositoryFile(at: entry.path, in: directory)
            loadState = .loaded(text.components(separatedBy: "\n"))
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }
}
