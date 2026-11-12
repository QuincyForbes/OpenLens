import Foundation

/// Formats tool names and state into human-readable labels for the activity card
/// and Live Activity display.
nonisolated enum ToolLabelFormatter {

    private static let maximumInspectedCharacters = 2_048
    private static let maximumPathCharacters = 180
    private static let maximumTitleCharacters = 80

    /// Build a short label describing what the tool is doing (e.g. "Read main.swift").
    static func label(toolName: String, state: OCToolState) -> String {
        liveActivityLabel(
            toolName: toolName,
            title: state.title,
            input: state.input?.value as? [String: Any]
        )
    }

    /// Thread-safe formatter usable directly from SSE background workers as well as MainActor.
    static func liveActivityLabel(
        toolName: String,
        title: String?,
        input: [String: Any]?
    ) -> String {
        // Tool names are ordinarily tiny, but keep the fallback itself bounded
        // when handling untrusted server payloads.
        let normalizedToolName = String(toolName.prefix(64))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedToolName {
        case "read":
            if let path = toolPath(input) {
                return "Read \(compactPath(path))"
            }
        case "write":
            if let path = toolPath(input) {
                return "Write \(compactPath(path))"
            }
        case "edit":
            if let path = toolPath(input) {
                return "Edit \(compactPath(path))"
            }
        case "glob":
            if let pattern = boundedPreview(input?["pattern"] as? String, limit: 40) {
                let scope = compactScope(input?["path"] as? String)
                return scope == "." ? "Glob \"\(pattern)\"" : "Glob \"\(pattern)\" in \(scope)"
            }
        case "grep":
            if let pattern = boundedPreview(input?["pattern"] as? String, limit: 40) {
                let scope = compactScope(input?["path"] as? String)
                return scope == "." ? "Grep \"\(pattern)\"" : "Grep \"\(pattern)\" in \(scope)"
            }
        case "bash":
            if let command = commandPreview(input?["command"] as? String) {
                return "Bash \(command)"
            }
        case "shell":
            if let command = commandPreview(input?["command"] as? String) {
                return "Shell \(command)"
            }
        case "subagent", "task":
            if let description = boundedPreview(input?["description"] as? String, limit: 56) {
                return "Subagent · \(description)"
            }
            if let agent = boundedPreview(input?["agent"] as? String, limit: 32) {
                return "Subagent (\(agent))"
            }
        case "execute":
            return "Run code script"
        case "websearch":
            if let query = boundedPreview(input?["query"] as? String, limit: 44) {
                return "Web search \"\(query)\""
            }
        case "webfetch":
            if let url = boundedPreview(input?["url"] as? String, limit: 48) {
                return "Fetch \(url)"
            }
        case "question":
            if let title = boundedPreview(title, limit: maximumTitleCharacters) {
                return title
            }
            return "Question"
        case "todowrite", "todo_write", "todo":
            return "Update todos"
        default:
            break
        }

        if let query = boundedPreview(input?["query"] as? String, limit: 40) {
            return "Search \(query)"
        }

        if let pattern = boundedPreview(input?["pattern"] as? String, limit: 40) {
            return "Find \(pattern)"
        }

        if let title = boundedPreview(title, limit: maximumTitleCharacters) {
            return title
        }
        return normalizedToolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Build a bounded path detail for the activity state.
    static func detail(state: OCToolState) -> String {
        if let input = state.input?.value as? [String: Any],
           let path = toolPath(input) {
            return path
        }
        return ""
    }

    private static func toolPath(_ input: [String: Any]?) -> String? {
        boundedPreview(input?["filePath"] as? String, limit: maximumPathCharacters)
            ?? boundedPreview(input?["path"] as? String, limit: maximumPathCharacters)
    }

    private static func compactPath(_ path: String) -> String {
        let usesBackslash = WorkspaceSelectionBuilder.isWindowsAbsolutePath(path) || (path.contains("\\") && !path.contains("/"))
        let separator: Character = usesBackslash ? "\\" : "/"
        let parts = path.split { $0 == "/" || $0 == "\\" }.map(String.init)
        guard parts.count > 3 else { return path }
        return parts.suffix(3).joined(separator: String(separator))
    }

    private static func compactScope(_ path: String?) -> String {
        guard let path = boundedPreview(path, limit: maximumPathCharacters) else {
            return "."
        }

        if path == "." {
            return path
        }

        let compact = compactPath(path)
        let last = WorkspaceSelectionBuilder.lastPathComponent(of: compact)
        return last.isEmpty ? compact : last
    }

    private static func commandPreview(_ command: String?) -> String? {
        boundedPreview(command, limit: 52)
    }

    /// A small, display-ready prefix that never calls `trimmingCharacters` or
    /// `count` over a full untrusted command/path. This formatter is invoked by
    /// streamed tool updates on MainActor, so both input inspection and output
    /// allocation stay bounded.
    private static func boundedPreview(_ text: String?, limit: Int) -> String? {
        guard let text, limit > 0 else { return nil }

        var preview = ""
        preview.reserveCapacity(limit + 3)
        var inspectedCharacters = 0
        var visibleCharacters = 0
        var hasStarted = false
        var isTruncated = false

        for character in text {
            guard inspectedCharacters < maximumInspectedCharacters else {
                isTruncated = true
                break
            }
            inspectedCharacters += 1

            if !hasStarted {
                guard !character.isWhitespace else { continue }
                hasStarted = true
            }

            guard visibleCharacters < limit else {
                isTruncated = true
                break
            }

            preview.append(character)
            visibleCharacters += 1
        }

        while let last = preview.last, last.isWhitespace {
            preview.removeLast()
        }

        guard !preview.isEmpty else { return nil }
        return isTruncated ? preview + "..." : preview
    }
}
