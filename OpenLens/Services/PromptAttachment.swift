import Foundation
import UniformTypeIdentifiers

/// Something attached to a v2 prompt. Content from the phone travels as a
/// `data:` URI; a repository reference is a `file:` URI the server reads from
/// the session's folder. The two are never interchangeable.
nonisolated enum PromptAttachment: Identifiable, Hashable, Sendable {
    case image(PromptImageAttachment)
    case textFile(PromptTextFileAttachment)
    case serverFile(ServerFileReference)

    var id: String {
        switch self {
        case let .image(image): image.id
        case let .textFile(file): file.id
        case let .serverFile(reference): reference.id
        }
    }

    var promptFile: OCV2PromptFile {
        switch self {
        case let .image(image): image.promptFile
        case let .textFile(file): file.promptFile
        case let .serverFile(reference): reference.promptFile
        }
    }

    var image: PromptImageAttachment? {
        if case let .image(image) = self { image } else { nil }
    }

    /// The local row's file part, in the same shape history reload produces.
    func part(id partID: String, sessionID: String, messageID: String) -> OCPart {
        switch self {
        case let .image(image):
            OCPart(id: partID, sessionID: sessionID, messageID: messageID, type: .file,
                   mime: image.mime, filename: image.name, url: image.dataURI)
        case let .textFile(file):
            OCPart(id: partID, sessionID: sessionID, messageID: messageID, type: .file,
                   mime: PromptTextFileAttachment.mime, filename: file.name, url: file.dataURI)
        case let .serverFile(reference):
            OCPart(id: partID, sessionID: sessionID, messageID: messageID, type: .file,
                   mime: PromptTextFileAttachment.mime, filename: reference.displayName, url: reference.uri)
        }
    }
}

/// A UTF-8 text file picked from Files on the phone.
nonisolated struct PromptTextFileAttachment: Identifiable, Hashable, Sendable {
    static let mime = "text/plain"

    let id: String
    let name: String
    /// The exact bytes sent, so a retry resends identical content.
    let data: Data
    let dataURI: String

    init(id: String = UUID().uuidString, data: Data, name: String) throws {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw PromptAttachmentError.unsupportedTextFile(name: name)
        }
        self.id = id
        self.name = name
        self.data = data
        self.dataURI = "data:\(Self.mime);charset=utf-8;base64,\(data.base64EncodedString())"
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    /// Reads a file picked from Files, which may sit outside the app's
    /// sandbox. Files that could never fit in a prompt request aren't loaded.
    static func read(from url: URL) throws -> PromptTextFileAttachment {
        let name = url.lastPathComponent
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PromptAttachmentError.unreadableFile(name: name)
        }
        guard size <= OpenCodeClient.maximumPromptBodyBytes else {
            throw PromptAttachmentError.textFileTooLarge(name: name)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw PromptAttachmentError.unreadableFile(name: name)
        }
        return try PromptTextFileAttachment(data: data, name: name)
    }

    var promptFile: OCV2PromptFile {
        OCV2PromptFile(uri: dataURI, name: name)
    }
}

/// Classifies a local file from Files, Finder, pasteboard, or drag-and-drop as
/// either a preparable image or an inline UTF-8 text file.
nonisolated enum LocalComposerFilePayload: Sendable {
    case image(data: Data, name: String)
    case textFile(PromptTextFileAttachment)

    /// Maximum raw source image size read from disk before `PromptImagePreparer`
    /// downsamples and compresses it to fit the 2 MiB prompt request.
    static let maximumSourceImageBytes = 32 * 1_024 * 1_024

    static func read(from url: URL) throws -> LocalComposerFilePayload {
        let rawName = url.lastPathComponent
        let name = rawName.isEmpty ? "attachment" : rawName
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            throw PromptAttachmentError.unreadableFile(name: name)
        }
        guard let size = values?.fileSize else {
            throw PromptAttachmentError.unreadableFile(name: name)
        }

        let extType = url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension)
        let declaredType = values?.contentType ?? extType
        let isDeclaredImage = declaredType?.conforms(to: .image) == true

        if isDeclaredImage {
            guard size <= maximumSourceImageBytes else {
                throw PromptAttachmentError.imageTooLarge
            }
            guard let data = try? Data(contentsOf: url) else {
                throw PromptAttachmentError.unreadableFile(name: name)
            }
            guard PromptImagePreparer.isDecodableImage(data) else {
                throw PromptAttachmentError.unsupportedImage
            }
            return .image(data: data, name: name)
        }

        if size > OpenCodeClient.maximumPromptBodyBytes {
            // Check whether an extensionless file is actually an image within the
            // image byte ceiling before reporting textFileTooLarge.
            if size <= maximumSourceImageBytes,
               declaredType == nil || declaredType == .data,
               let data = try? Data(contentsOf: url),
               PromptImagePreparer.isDecodableImage(data) {
                return .image(data: data, name: name)
            }
            throw PromptAttachmentError.textFileTooLarge(name: name)
        }

        guard let data = try? Data(contentsOf: url) else {
            throw PromptAttachmentError.unreadableFile(name: name)
        }
        if PromptImagePreparer.isDecodableImage(data) {
            return .image(data: data, name: name)
        }
        return .textFile(try PromptTextFileAttachment(data: data, name: name))
    }
}

/// A file in the session's folder on the computer running OpenCode, read by
/// the server when the prompt is admitted. Optionally limited to a line range.
nonisolated struct ServerFileReference: Identifiable, Hashable, Sendable {
    struct LineRange: Hashable, Sendable {
        let start: Int
        let end: Int?

        init(start: Int, end: Int? = nil) throws {
            guard start >= 1, end.map({ $0 >= start }) ?? true else {
                throw PromptAttachmentError.invalidLineRange
            }
            self.start = start
            self.end = end
        }

        /// Without an end, the server reads from `start` to the end of the file.
        var label: String {
            guard let end else { return AppText.lineRangeToEnd(start) }
            return end == start ? "\(start)" : "\(start)–\(end)"
        }
    }

    let id: String
    /// Absolute path on the server, inside the session's folder.
    let path: String
    let lines: LineRange?

    /// `path` must be an absolute path inside `sessionDirectory`, the folder
    /// the session runs in on the server. Phone paths, URLs, and paths that
    /// step outside the folder are refused.
    init(id: String = UUID().uuidString, path: String, sessionDirectory: String, lines: LineRange? = nil) throws {
        let isWindowsSession = Self.isWindowsServerPath(sessionDirectory)
        guard let directory = Self.normalizedURLPath(sessionDirectory, allowWindows: isWindowsSession),
              let urlPath = Self.normalizedURLPath(path, allowWindows: isWindowsSession),
              Self.isInsideSession(urlPath: urlPath, directoryURLPath: directory, caseInsensitiveDrive: isWindowsSession)
        else {
            throw PromptAttachmentError.fileOutsideSession
        }
        self.id = id
        self.path = urlPath
        self.lines = lines
    }

    var name: String { WorkspaceSelectionBuilder.lastPathComponent(of: path) }

    /// `path` relative to `sessionDirectory`, the folder it was checked against.
    func relativePath(in sessionDirectory: String) -> String? {
        let isWindowsSession = Self.isWindowsServerPath(sessionDirectory)
        guard let directory = Self.normalizedURLPath(sessionDirectory, allowWindows: isWindowsSession),
              Self.isInsideSession(urlPath: path, directoryURLPath: directory, caseInsensitiveDrive: isWindowsSession) else {
            return nil
        }
        let prefixCount = directory == "/" ? 1 : directory.count + 1
        return String(path.dropFirst(prefixCount))
    }

    var displayName: String {
        lines.map { "\(name):\($0.label)" } ?? name
    }

    var uri: String {
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = path
        if let lines {
            components.queryItems = [URLQueryItem(name: "start", value: String(lines.start))]
                + (lines.end.map { [URLQueryItem(name: "end", value: String($0))] } ?? [])
        }
        return components.string ?? "file://\(path)"
    }

    var promptFile: OCV2PromptFile {
        OCV2PromptFile(uri: uri, name: displayName)
    }

    /// The absolute path of `relativePath` inside `directory`.
    static func path(_ relativePath: String, in directory: String) -> String {
        if isWindowsServerPath(directory) {
            var base = directory.replacingOccurrences(of: "\\", with: "/")
            if base.hasPrefix("/") { base.removeFirst() }
            while base.count > 2, base.hasSuffix("/") { base.removeLast() }
            let cleanRelative = relativePath.replacingOccurrences(of: "\\", with: "/")
            return base + "/" + cleanRelative
        }
        var base = directory
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base == "/" ? "/" + relativePath : base + "/" + relativePath
    }

    private static func isWindowsServerPath(_ value: String) -> Bool {
        if WorkspaceSelectionBuilder.isWindowsAbsolutePath(value) {
            return true
        }
        if value.hasPrefix("/"), WorkspaceSelectionBuilder.isWindowsAbsolutePath(String(value.dropFirst())) {
            return true
        }
        return false
    }

    private static func isInsideSession(
        urlPath: String,
        directoryURLPath: String,
        caseInsensitiveDrive: Bool
    ) -> Bool {
        let prefix = directoryURLPath == "/" ? "/" : directoryURLPath + "/"
        guard urlPath != directoryURLPath else { return false }
        if caseInsensitiveDrive {
            return urlPath.lowercased().hasPrefix(prefix.lowercased())
        }
        return urlPath.hasPrefix(prefix)
    }

    private static func normalizedURLPath(_ rawPath: String, allowWindows: Bool) -> String? {
        guard !rawPath.contains("\0") else { return nil }
        if allowWindows && isWindowsServerPath(rawPath) {
            var working = rawPath.replacingOccurrences(of: "\\", with: "/")
            if working.hasPrefix("/") { working.removeFirst() }
            guard WorkspaceSelectionBuilder.isWindowsAbsolutePath(working) else { return nil }
            let drive = String(working.prefix(1)).uppercased()
            var trimmed = "/\(drive):" + working.dropFirst(2)
            while trimmed.count > 3, trimmed.hasSuffix("/") { trimmed.removeLast() }
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2)
            guard trimmed.count == 3 || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                return nil
            }
            return trimmed
        }
        guard !allowWindows, rawPath.hasPrefix("/"), !rawPath.contains("\\") else { return nil }
        var trimmed = rawPath
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard trimmed == "/" || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return trimmed
    }
}

nonisolated enum PromptAttachmentError: LocalizedError, Equatable, Sendable {
    case unsupportedImage
    case imageTooLarge
    case unsupportedTextFile(name: String)
    case textFileTooLarge(name: String)
    case unreadableFile(name: String)
    case invalidLineRange
    case fileOutsideSession
    case promptTooLarge
    case modelDoesNotAcceptImages(modelName: String)
    case attachmentsRequireV2
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: AppText.unsupportedImageAttachment
        case .imageTooLarge: AppText.imageAttachmentTooLarge
        case let .unsupportedTextFile(name): AppText.unsupportedTextFileAttachment(name)
        case let .textFileTooLarge(name): AppText.textFileAttachmentTooLarge(name)
        case let .unreadableFile(name): AppText.unreadableFileAttachment(name)
        case .invalidLineRange: AppText.invalidLineRange
        case .fileOutsideSession: AppText.fileOutsideSession
        case .promptTooLarge: AppText.attachmentsTooLarge
        case let .modelDoesNotAcceptImages(modelName): AppText.modelDoesNotAcceptImages(modelName)
        case .attachmentsRequireV2: AppText.attachmentsRequireV2
        case let .rejected(message): AppText.attachmentRejected(message)
        }
    }
}
