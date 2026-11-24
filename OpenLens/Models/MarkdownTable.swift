import Foundation

/// Turns Markdown into compact one-line previews for collapsed rows and labels.
nonisolated enum MarkdownPreview {
    /// Drops block markers (headings, bullets, quotes, fences, table rules) and
    /// joins lines, keeping inline syntax for an optional inline pass.
    static func flattenedBlockSyntax(_ text: String) -> String {
        var parts: [String] = []
        for rawLine in MarkdownTable.normalizedLines(from: text) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty
                || MarkdownTable.parseCodeFence(rawLine) != nil
                || MarkdownTable.delimiterAlignments(line) != nil
                || MarkdownTable.isThematicBreak(rawLine) {
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    line = String(line.dropFirst(level + 1))
                }
            }
            for marker in ["> ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            if line.contains("|") {
                line = MarkdownTable.splitRow(line).filter { !$0.isEmpty }.joined(separator: " · ")
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: " ")
    }

    /// Visible text with both block and inline Markdown removed.
    static func plainText(_ text: String) -> String {
        MarkdownTable.plainText(flattenedBlockSyntax(text))
    }
}

/// A GitHub-flavored Markdown pipe table, parsed off the main thread and
/// exportable as Markdown, CSV, or TSV.
nonisolated struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    enum Segment: Equatable, Sendable {
        case text(String)
        case table(MarkdownTable)
        case blockquote([Segment])
    }

    private static let lineBreakRegex = try? NSRegularExpression(
        pattern: #"<br\s*/?>"#,
        options: [.caseInsensitive]
    )

    let headers: [String]
    let alignments: [Alignment]
    /// Every row has exactly `columnCount` cells.
    let rows: [[String]]

    var columnCount: Int { headers.count }

    init(headers: [String], alignments: [Alignment], rows: [[String]]) {
        let count = max(headers.count, 1)
        self.headers = Self.normalized(headers, count: count)
        self.alignments = Array((alignments + Array(repeating: .leading, count: count)).prefix(count))
        self.rows = rows.map { Self.normalized($0, count: count) }
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    // MARK: - Shared Block Helpers

    /// Normalizes CRLF (`\r\n`) and CR (`\r`) line endings before splitting.
    static func normalizedLines(from text: String) -> [String] {
        if text.utf8.contains(UInt8(ascii: "\r")) {
            return text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }
        return text.components(separatedBy: "\n")
    }

    /// Normalizes `<br>`, `<br/>`, `<br />`, `<BR>`, etc. into newlines.
    static func normalizeLineBreaks(_ cell: String) -> String {
        guard cell.utf8.contains(UInt8(ascii: "<")), let regex = lineBreakRegex else {
            return cell
        }
        let range = NSRange(cell.startIndex..., in: cell)
        return regex.stringByReplacingMatches(in: cell, options: [], range: range, withTemplate: "\n")
    }

    /// Matches a CommonMark fenced code opener/closer (```` ``` ```` or `~~~`, up to 3 leading spaces).
    static func parseCodeFence(_ line: String) -> (marker: Character, length: Int, info: String)? {
        let stripped = dropUpToThreeSpaces(line)
        guard let marker = stripped.first, marker == "`" || marker == "~" else { return nil }
        let length = stripped.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = stripped.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        if marker == "`", info.contains("`") {
            return nil
        }
        return (marker, length, info)
    }

    /// Strips a leading CommonMark blockquote marker (`>`, `> `, `>|`, up to 3 leading spaces).
    static func stripBlockquotePrefix(_ line: String) -> String? {
        let stripped = dropUpToThreeSpaces(line)
        guard stripped.first == ">" else { return nil }
        let after = stripped.dropFirst()
        if after.first == " " {
            return String(after.dropFirst())
        }
        return String(after)
    }

    /// Matches CommonMark thematic breaks (`---`, `***`, `___` with optional spaces).
    static func isThematicBreak(_ line: String) -> Bool {
        let stripped = dropUpToThreeSpaces(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = stripped.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        var count = 0
        for character in stripped {
            if character == marker {
                count += 1
            } else if character == " " || character == "\t" {
                continue
            } else {
                return false
            }
        }
        return count >= 3
    }

    static func isHeadingLine(_ line: String) -> Bool {
        let stripped = dropUpToThreeSpaces(line)
        guard stripped.hasPrefix("#") else { return false }
        let level = stripped.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return false }
        let remainder = stripped.dropFirst(level)
        return remainder.first?.isWhitespace == true
            && !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isUnorderedListLine(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    static func parseOrderedListItem(_ line: String) -> (ordinal: Int, body: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dot]
        guard !prefix.isEmpty,
              prefix.count <= 3,
              prefix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let ordinal = Int(prefix) else {
            return nil
        }
        let afterDot = line[line.index(after: dot)...]
        guard afterDot.isEmpty || afterDot.first?.isWhitespace == true else {
            return nil
        }
        return (ordinal, afterDot.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func dropUpToThreeSpaces(_ line: String) -> Substring {
        var idx = line.startIndex
        var spaces = 0
        while spaces < 3, idx < line.endIndex, line[idx] == " " {
            idx = line.index(after: idx)
            spaces += 1
        }
        return line[idx...]
    }

    // MARK: - Parsing

    /// Returns a table starting at `index` (header row followed by a delimiter
    /// row) and the index of the first line after it, or nil.
    static func parse(lines: [String], at index: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let rawHeader = lines[index]
        guard parseCodeFence(rawHeader) == nil,
              stripBlockquotePrefix(rawHeader) == nil else {
            return nil
        }
        let headerLine = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headerLine.isEmpty,
              headerLine.contains("|"),
              let alignments = delimiterAlignments(lines[index + 1]) else {
            return nil
        }
        let headers = splitRow(headerLine)
        guard !headers.isEmpty, headers.count == alignments.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let rawLine = lines[cursor]
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.contains("|"),
                  parseCodeFence(rawLine) == nil,
                  stripBlockquotePrefix(rawLine) == nil,
                  !isHeadingLine(rawLine),
                  !isThematicBreak(rawLine),
                  delimiterAlignments(trimmed) == nil,
                  !startsTable(lines: lines, at: cursor) else {
                break
            }
            if !trimmed.hasPrefix("|"),
               isUnorderedListLine(trimmed) || parseOrderedListItem(trimmed) != nil {
                break
            }
            rows.append(splitRow(trimmed))
            cursor += 1
        }

        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), cursor)
    }

    static func startsTable(lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let rawHeader = lines[index]
        guard parseCodeFence(rawHeader) == nil,
              stripBlockquotePrefix(rawHeader) == nil else {
            return false
        }
        let headerLine = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headerLine.isEmpty,
              headerLine.contains("|"),
              let alignments = delimiterAlignments(lines[index + 1]) else {
            return false
        }
        let headers = splitRow(headerLine)
        return !headers.isEmpty && headers.count == alignments.count
    }

    /// Fast fence- and blockquote-aware check for whether `text` contains at
    /// least one valid GFM pipe table.
    static func containsTable(_ text: String) -> Bool {
        containsTable(text, depth: 0)
    }

    private static func containsTable(_ text: String, depth: Int) -> Bool {
        guard depth <= 4,
              text.utf8.contains(UInt8(ascii: "|")),
              text.utf8.contains(UInt8(ascii: "-")) else {
            return false
        }
        let lines = normalizedLines(from: text)
        var index = 0
        var activeFence: (marker: Character, length: Int)?

        while index < lines.count {
            let line = lines[index]
            if let fence = parseCodeFence(line) {
                if let current = activeFence {
                    if fence.marker == current.marker,
                       fence.length >= current.length,
                       fence.info.isEmpty {
                        activeFence = nil
                    }
                } else {
                    activeFence = (fence.marker, fence.length)
                }
                index += 1
                continue
            }

            if activeFence == nil {
                if startsTable(lines: lines, at: index) {
                    return true
                }
                if stripBlockquotePrefix(line) != nil {
                    var quoteLines: [String] = []
                    while index < lines.count, let stripped = stripBlockquotePrefix(lines[index]) {
                        quoteLines.append(stripped)
                        index += 1
                    }
                    if !quoteLines.isEmpty,
                       containsTable(quoteLines.joined(separator: "\n"), depth: depth + 1) {
                        return true
                    }
                    continue
                }
            }
            index += 1
        }
        return false
    }

    /// Splits arbitrary text into alternating prose, blockquote, and Markdown
    /// table segments while respecting fenced code blocks so tables inside code
    /// fences stay verbatim.
    static func splitTextAndTables(_ text: String) -> [Segment] {
        splitTextAndTables(text, depth: 0)
    }

    private static func splitTextAndTables(_ text: String, depth: Int) -> [Segment] {
        guard text.utf8.contains(UInt8(ascii: "|")),
              text.utf8.contains(UInt8(ascii: "-")) else {
            return text.isEmpty ? [] : [.text(text)]
        }

        let lines = normalizedLines(from: text)
        var segments: [Segment] = []
        var textLines: [String] = []
        var activeFence: (marker: Character, length: Int)?
        var index = 0

        func flushText(trimLeading: Bool, trimTrailing: Bool) {
            var slice = textLines[...]
            if trimLeading {
                while let first = slice.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                    slice = slice.dropFirst()
                }
            }
            if trimTrailing {
                while let last = slice.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    slice = slice.dropLast()
                }
            }
            if !slice.isEmpty {
                segments.append(.text(slice.joined(separator: "\n")))
            }
            textLines.removeAll(keepingCapacity: true)
        }

        var hasSeenBlock = false
        while index < lines.count {
            let line = lines[index]
            if let fence = parseCodeFence(line) {
                if let current = activeFence {
                    if fence.marker == current.marker,
                       fence.length >= current.length,
                       fence.info.isEmpty {
                        activeFence = nil
                    }
                } else {
                    activeFence = (fence.marker, fence.length)
                }
                textLines.append(line)
                index += 1
                continue
            }

            if activeFence == nil {
                if let parsed = parse(lines: lines, at: index) {
                    flushText(trimLeading: hasSeenBlock, trimTrailing: true)
                    segments.append(.table(parsed.table))
                    hasSeenBlock = true
                    index = parsed.nextIndex
                    continue
                }

                if depth < 3, stripBlockquotePrefix(line) != nil {
                    let quoteStart = index
                    var quoteLines: [String] = []
                    while index < lines.count, let stripped = stripBlockquotePrefix(lines[index]) {
                        quoteLines.append(stripped)
                        index += 1
                    }
                    let quoteRaw = quoteLines.joined(separator: "\n")
                    if containsTable(quoteRaw, depth: depth + 1) {
                        flushText(trimLeading: hasSeenBlock, trimTrailing: true)
                        let nested = splitTextAndTables(quoteRaw, depth: depth + 1)
                        if depth == 0 {
                            segments.append(.blockquote(nested))
                        } else {
                            segments.append(contentsOf: nested)
                        }
                        hasSeenBlock = true
                    } else {
                        textLines.append(contentsOf: lines[quoteStart..<index])
                    }
                    continue
                }
            }

            textLines.append(line)
            index += 1
        }

        flushText(trimLeading: hasSeenBlock, trimTrailing: false)
        return segments
    }

    /// `| :--- | :---: | ---: |` → alignments; nil for anything else.
    static func delimiterAlignments(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var alignments: [Alignment] = []
        for rawCell in splitRow(trimmed) {
            let cell = rawCell.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            let leadingColon = cell.hasPrefix(":")
            let trailingColon = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(leadingColon ? 1 : 0).dropLast(trailingColon ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// Splits on unescaped pipes outside balanced inline code spans, dropping the
    /// optional outer pipes. `\|` becomes a literal pipe.
    static func splitRow(_ line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") {
            var backslashes = 0
            var scan = content.index(before: content.endIndex)
            while scan > content.startIndex {
                let previous = content.index(before: scan)
                if content[previous] == "\\" {
                    backslashes += 1
                    scan = previous
                } else {
                    break
                }
            }
            if backslashes.isMultiple(of: 2) {
                content = content.dropLast()
            }
        }

        var cells: [String] = []
        var current = ""
        var activeCodeTickCount: Int?
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if character == "\\" {
                let nextIndex = content.index(after: index)
                if nextIndex < content.endIndex {
                    let next = content[nextIndex]
                    if next == "|" {
                        current.append("|")
                    } else {
                        current.append(character)
                        current.append(next)
                    }
                    index = content.index(after: nextIndex)
                    continue
                }
                current.append(character)
                index = nextIndex
                continue
            }

            if character == "`" {
                var runEnd = index
                var runCount = 0
                while runEnd < content.endIndex, content[runEnd] == "`" {
                    runCount += 1
                    runEnd = content.index(after: runEnd)
                }
                if let openCount = activeCodeTickCount {
                    if runCount == openCount {
                        activeCodeTickCount = nil
                    }
                } else if hasClosingBacktickRun(ofLength: runCount, in: content, from: runEnd) {
                    activeCodeTickCount = runCount
                }
                current.append(contentsOf: content[index..<runEnd])
                index = runEnd
                continue
            }

            if character == "|", activeCodeTickCount == nil {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = content.index(after: index)
                continue
            }

            current.append(character)
            index = content.index(after: index)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func hasClosingBacktickRun(
        ofLength target: Int,
        in content: Substring,
        from start: Substring.Index
    ) -> Bool {
        var index = start
        while index < content.endIndex {
            if content[index] == "`" {
                var count = 0
                while index < content.endIndex, content[index] == "`" {
                    count += 1
                    index = content.index(after: index)
                }
                if count == target {
                    return true
                }
            } else {
                index = content.index(after: index)
            }
        }
        return false
    }

    // MARK: - Export

    /// Normalized Markdown with aligned delimiter row and escaped pipes.
    var markdown: String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.map { alignment -> String in
            switch alignment {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }.joined(separator: " | ") + " |"
        return ([row(headers), delimiter] + rows.map(row)).joined(separator: "\n")
    }

    /// RFC 4180 CSV of the cells' visible text (inline Markdown removed).
    var csv: String {
        ([headers] + rows)
            .map { cells in cells.map { Self.csvField(Self.plainText($0)) }.joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    /// Tab-separated visible text, convenient for pasting into spreadsheets.
    var tsv: String {
        ([headers] + rows)
            .map { cells in
                cells.map {
                    Self.plainText($0)
                        .replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                }
                .joined(separator: "\t")
            }
            .joined(separator: "\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A cell's visible text: inline Markdown markers removed, `<br>` as newline.
    static func plainText(_ cell: String) -> String {
        let withBreaks = normalizeLineBreaks(cell)
        guard withBreaks.contains(where: { "*_`[~".contains($0) }),
              let attributed = try? AttributedString(
                  markdown: withBreaks,
                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else {
            return withBreaks
        }
        return String(attributed.characters)
    }

    // MARK: - Layout

    /// Column widths in points at 1× zoom, estimated from visible text so a
    /// table lays out without measuring every cell on the main thread.
    func estimatedColumnWidths(
        characterWidth: Double = 8.4,
        horizontalPadding: Double = 24,
        minimum: Double = 56,
        maximum: Double = 320
    ) -> [Double] {
        (0..<columnCount).map { column in
            let headerLength = Self.longestVisualLineLength(Self.plainText(headers[column])) * 1.08 + 1
            let bodyLength = rows.reduce(0.0) { longest, row in
                max(longest, Self.longestVisualLineLength(Self.plainText(row[column])))
            }
            let characters = max(headerLength, bodyLength)
            return min(max(characters * characterWidth + horizontalPadding, minimum), maximum)
        }
    }

    private static func longestVisualLineLength(_ text: String) -> Double {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0.0) { longest, line in
                var width = 0.0
                for character in line {
                    width += isWideDisplayCharacter(character) ? 1.85 : 1.0
                }
                return max(longest, width)
            }
    }

    private static func isWideDisplayCharacter(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if scalar.properties.isEmojiPresentation
                || (0x1100...0x115F).contains(value)
                || (0x2E80...0xA4CF).contains(value)
                || (0xAC00...0xD7A3).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0xFE10...0xFE6F).contains(value)
                || (0xFF00...0xFF60).contains(value)
                || (0xFFE0...0xFFE6).contains(value)
                || (0x20000...0x2FFFD).contains(value) {
                return true
            }
        }
        return false
    }

    /// Filename-safe stem, e.g. "table-name-status".
    func suggestedFilenameStem() -> String {
        let words = headers.prefix(3)
            .map { Self.plainText($0).lowercased() }
            .joined(separator: "-")
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(words)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let stem = String(collapsed.prefix(40))
        return stem.isEmpty ? "table" : "table-\(stem)"
    }
}
