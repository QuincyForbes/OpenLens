import Foundation

/// Turns Markdown into compact one-line previews for collapsed rows and labels.
nonisolated enum MarkdownPreview {
    /// Drops block markers (headings, bullets, quotes, fences, table rules) and
    /// joins lines, keeping inline syntax for an optional inline pass.
    static func flattenedBlockSyntax(_ text: String) -> String {
        var parts: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || MarkdownTable.delimiterAlignments(line) != nil {
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

    // MARK: - Parsing

    /// Returns a table starting at `index` (header row followed by a delimiter
    /// row) and the index of the first line after it, or nil.
    static func parse(lines: [String], at index: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let alignments = delimiterAlignments(lines[index + 1]) else {
            return nil
        }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|") else { return nil }
        let headers = splitRow(headerLine)
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|"), !trimmed.hasPrefix("```") else { break }
            rows.append(splitRow(trimmed))
            cursor += 1
        }

        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), cursor)
    }

    static func startsTable(lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count,
              lines[index].contains("|"),
              delimiterAlignments(lines[index + 1]) != nil else {
            return false
        }
        return true
    }

    /// `| :--- | :---: | ---: |` → alignments; nil for anything else.
    static func delimiterAlignments(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
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

    /// Splits on unescaped pipes outside inline code spans, dropping the
    /// optional outer pipes. `\|` becomes a literal pipe.
    static func splitRow(_ line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") && !content.hasSuffix("\\|") { content = content.dropLast() }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var iterator = content.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\\":
                if let next = iterator.next() {
                    if next == "|" {
                        current.append("|")
                    } else {
                        current.append(character)
                        current.append(next)
                    }
                } else {
                    current.append(character)
                }
            case "`":
                inCode.toggle()
                current.append(character)
            case "|" where !inCode:
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
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
        let withBreaks = cell
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
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
            let headerLength = Self.longestLineLength(Self.plainText(headers[column])) + 1
            let bodyLength = rows.reduce(0) { longest, row in
                max(longest, Self.longestLineLength(Self.plainText(row[column])))
            }
            let characters = Double(max(headerLength, bodyLength))
            return min(max(characters * characterWidth + horizontalPadding, minimum), maximum)
        }
    }

    private static func longestLineLength(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { max($0, $1.count) }
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
