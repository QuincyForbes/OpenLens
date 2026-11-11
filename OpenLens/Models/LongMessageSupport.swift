import Foundation

/// A large block of text pasted or reused into the chat composer.
///
/// Keeping large text in a dedicated snippet prevents SwiftUI's `TextField` and
/// UIKit's inline text layout from laying out tens of thousands of characters
/// inside the compact input bar while preserving the exact text sent to OpenCode.
nonisolated struct ComposerPastedSnippet: Identifiable, Hashable, Sendable {
    /// Safe upper bound for a single pasted prompt so encoding and upload stay responsive.
    static let maximumAllowedUTF8Bytes = 1_800_000
    /// Snippets up to this size can be edited directly in the preview sheet.
    static let maximumEditableUTF8Bytes = 120_000
    /// Moderate snippets can optionally be expanded back into the inline text field.
    static let maximumExpandToFieldUTF8Bytes = 3_200
    private static let previewCharacterLimit = 140
    private static let synchronousLineScanLimitBytes = 262_144

    let id: String
    let text: String
    let preview: String
    let metrics: LongTextMetrics

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
        self.preview = Self.makePreview(from: text)
        self.metrics = LongTextMetrics.computeBounded(
            for: text,
            maxScannedUTF8Bytes: Self.synchronousLineScanLimitBytes
        )
    }

    var lineCount: Int { metrics.lineCount }
    var byteCount: Int { metrics.byteCount }
    var isLineCountApproximate: Bool { metrics.isLineCountApproximate }
    var metricsLabel: String { metrics.summaryLabel }

    var canExpandIntoTextField: Bool {
        byteCount <= Self.maximumExpandToFieldUTF8Bytes
    }

    var isEditableInSheet: Bool {
        byteCount <= Self.maximumEditableUTF8Bytes
    }

    func updatingText(_ updatedText: String) -> ComposerPastedSnippet? {
        guard BoundedTextInspection.hasNonWhitespace(updatedText) else { return nil }
        return ComposerPastedSnippet(id: id, text: updatedText)
    }

    private static func makePreview(from text: String) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, previewCharacterLimit + 4))
        var inspected = 0
        var visible = 0
        var started = false
        var previousWasSpace = false

        for character in text {
            guard inspected < 2_048 else {
                return result.isEmpty ? "Pasted text" : result + "…"
            }
            inspected += 1

            if !started {
                guard !character.isWhitespace else { continue }
                started = true
            }

            if character.isWhitespace || character.isNewline {
                if !previousWasSpace {
                    previousWasSpace = true
                }
                continue
            }

            if previousWasSpace, !result.isEmpty {
                guard visible + 1 < previewCharacterLimit else {
                    return result + "…"
                }
                result.append(" ")
                visible += 1
                previousWasSpace = false
            }

            guard visible < previewCharacterLimit else {
                return result + "…"
            }

            result.append(character)
            visible += 1
        }

        return result.isEmpty ? "Pasted text" : result
    }
}

/// Bounded line and byte metrics for large user messages and pasted snippets.
nonisolated struct LongTextMetrics: Hashable, Sendable {
    let lineCount: Int
    let byteCount: Int
    let characterSampleCount: Int?
    let isLineCountApproximate: Bool

    static func computeBounded(
        for text: String,
        maxScannedUTF8Bytes: Int = 65_536
    ) -> LongTextMetrics {
        let totalBytes = text.utf8.count
        guard totalBytes > 0 else {
            return LongTextMetrics(
                lineCount: 1,
                byteCount: 0,
                characterSampleCount: 0,
                isLineCountApproximate: false
            )
        }

        var scannedBytes = 0
        var newlines = 0
        var isApproximate = false

        for byte in text.utf8 {
            if scannedBytes >= maxScannedUTF8Bytes {
                isApproximate = true
                break
            }
            if byte == UInt8(ascii: "\n") {
                newlines += 1
            }
            scannedBytes += 1
        }

        let estimatedLines: Int
        if isApproximate, scannedBytes > 0 {
            let projected = Int((Double(newlines) * (Double(totalBytes) / Double(scannedBytes))).rounded())
            estimatedLines = max(newlines + 1, projected + 1)
        } else {
            estimatedLines = newlines + 1
        }

        let charCount = totalBytes <= 4_096 ? text.count : nil
        return LongTextMetrics(
            lineCount: estimatedLines,
            byteCount: totalBytes,
            characterSampleCount: charCount,
            isLineCountApproximate: isApproximate
        )
    }

    static func computeExact(for text: String) -> LongTextMetrics {
        let totalBytes = text.utf8.count
        guard totalBytes > 0 else {
            return LongTextMetrics(
                lineCount: 1,
                byteCount: 0,
                characterSampleCount: 0,
                isLineCountApproximate: false
            )
        }

        var newlines = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            newlines += 1
        }

        return LongTextMetrics(
            lineCount: newlines + 1,
            byteCount: totalBytes,
            characterSampleCount: totalBytes <= 4_096 ? text.count : nil,
            isLineCountApproximate: false
        )
    }

    var summaryLabel: String {
        let sizeText = Self.formatByteSize(byteCount, characterSampleCount: characterSampleCount)
        guard lineCount > 1 else {
            return sizeText
        }
        let linePrefix = isLineCountApproximate ? "~\(Self.formatInteger(lineCount))" : Self.formatInteger(lineCount)
        return "\(linePrefix) lines · \(sizeText)"
    }

    private static func formatByteSize(_ bytes: Int, characterSampleCount: Int?) -> String {
        if bytes < 1_024, let chars = characterSampleCount {
            return "\(formatInteger(chars)) chars"
        }
        if bytes >= 1_024 * 1_024 {
            return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
        }
        if bytes >= 10 * 1_024 {
            return String(format: "%.0f KB", Double(bytes) / 1_024)
        }
        return String(format: "%.1f KB", Double(bytes) / 1_024)
    }

    private static func formatInteger(_ value: Int) -> String {
        guard value >= 1_000 else { return String(value) }
        let digits = Array(String(value))
        var output = ""
        output.reserveCapacity(digits.count + digits.count / 3)
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) {
                output.append(",")
            }
            output.append(digit)
        }
        return output
    }
}

/// Detects bulk pastes in the composer and combines pasted snippets with typed text on send.
nonisolated enum ComposerPasteExtractor {
    static let minimumPastedUTF8Bytes = 1_000
    static let minimumPastedLines = 18
    static let minimumSingleStepInsertionUTF8Bytes = 400
    /// Temporary 1-scalar marker used to force SwiftUI's `TextField` to flush an
    /// intercepted large paste when the remaining text equals the previous value.
    static let focusResetSentinel = "\u{200B}"

    nonisolated struct Extraction: Equatable, Sendable {
        let remainingInputText: String
        let pastedText: String
    }

    static func sanitizedInput(_ text: String) -> String {
        guard text.utf8.contains(0xE2) else { return text }
        guard text.contains(focusResetSentinel) else { return text }
        return text.replacingOccurrences(of: focusResetSentinel, with: "")
    }

    static func shouldStoreAsSnippet(_ text: String) -> Bool {
        let clean = sanitizedInput(text)
        if clean.utf8.count >= minimumPastedUTF8Bytes {
            return true
        }
        return BoundedTextInspection.hasAtLeastLines(clean, minimumLines: minimumPastedLines)
    }

    /// Inspects a single input transition from `previous` to `updated`.
    /// Normal typing or small pastes return `nil` so inline editing feels completely native.
    static func extractLargePaste(previous rawPrevious: String, updated rawUpdated: String) -> Extraction? {
        let previous = sanitizedInput(rawPrevious)
        let updated = sanitizedInput(rawUpdated)

        let addedBytes = updated.utf8.count - previous.utf8.count
        guard addedBytes >= minimumSingleStepInsertionUTF8Bytes else {
            return nil
        }

        // Locate common prefix between `previous` and `updated`.
        var prevPrefixEnd = previous.startIndex
        var updPrefixEnd = updated.startIndex
        while prevPrefixEnd < previous.endIndex,
              updPrefixEnd < updated.endIndex,
              previous[prevPrefixEnd] == updated[updPrefixEnd] {
            prevPrefixEnd = previous.index(after: prevPrefixEnd)
            updPrefixEnd = updated.index(after: updPrefixEnd)
        }

        // Locate common suffix without crossing the common prefix.
        var prevSuffixStart = previous.endIndex
        var updSuffixStart = updated.endIndex
        while prevSuffixStart > prevPrefixEnd,
              updSuffixStart > updPrefixEnd {
            let prevBefore = previous.index(before: prevSuffixStart)
            let updBefore = updated.index(before: updSuffixStart)
            guard previous[prevBefore] == updated[updBefore] else { break }
            prevSuffixStart = prevBefore
            updSuffixStart = updBefore
        }

        let insertedSlice = updated[updPrefixEnd..<updSuffixStart]
        let inserted = String(insertedSlice)
        guard shouldStoreAsSnippet(inserted) else {
            return nil
        }

        // If the composer was empty and the pasted text starts with a `/command ` token,
        // keep the `/command` token in the field and extract only its large arguments.
        if previous.isEmpty,
           inserted.hasPrefix("/"),
           let splitCommand = splitLeadingSlashToken(from: inserted),
           shouldStoreAsSnippet(splitCommand.arguments) {
            return Extraction(
                remainingInputText: splitCommand.commandToken,
                pastedText: splitCommand.arguments
            )
        }

        let remaining = String(previous[..<prevPrefixEnd]) + String(previous[prevSuffixStart...])
        return Extraction(
            remainingInputText: remaining,
            pastedText: inserted
        )
    }

    /// Combines typed composer text and any attached pasted snippets into the final prompt.
    /// Typed instructions come first so `/command`, `@skill`, and the user's question appear
    /// at the top of the prompt and at the top of the collapsed chat bubble preview.
    static func composePrompt(inputText: String, snippets: [ComposerPastedSnippet]) -> String {
        let cleanInput = BoundedTextInspection.trimOuterWhitespaceAndNewlines(sanitizedInput(inputText))
        guard !snippets.isEmpty else {
            return cleanInput
        }

        var parts: [String] = []
        parts.reserveCapacity(snippets.count + 1)
        if !cleanInput.isEmpty {
            parts.append(cleanInput)
        }
        for snippet in snippets {
            let cleanSnippet = BoundedTextInspection.trimOuterWhitespaceAndNewlines(snippet.text)
            if !cleanSnippet.isEmpty {
                parts.append(cleanSnippet)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func splitLeadingSlashToken(from text: String) -> (commandToken: String, arguments: String)? {
        let afterSlash = text.dropFirst()
        guard let whitespaceIndex = afterSlash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }
        let commandHead = text[..<whitespaceIndex]
        guard commandHead.count >= 2, commandHead.count <= 40 else {
            return nil
        }
        let remainder = text[whitespaceIndex...].drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard !remainder.isEmpty else { return nil }
        return (String(commandHead), String(remainder))
    }
}

/// Bounded display preparation for user messages and queued prompts in the chat timeline.
///
/// Guarantees that SwiftUI never attempts to lay out a multi-thousand-line user bubble
/// as a single `Text` node (which causes main-thread hangs and exceeds Metal's backing
/// texture height limit, turning huge bubbles blank).
nonisolated enum UserMessagePresentation {
    static let collapseCharacterLimit = 600
    static let collapseLineLimit = 12
    static let collapsedPreviewCharacterLimit = 460
    static let collapsedPreviewLineLimit = 8
    static let inlineExpansionMaximumUTF8Bytes = 4_800
    static let inlineChunkCharacterLimit = 1_200

    static let queuedCollapseCharacterLimit = 320
    static let queuedCollapseLineLimit = 6
    static let queuedPreviewCharacterLimit = 260
    static let queuedPreviewLineLimit = 4

    nonisolated struct InlineChunk: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
    }

    nonisolated enum Mode: Equatable, Sendable {
        case full(String)
        case collapsible(preview: String, initialMetrics: LongTextMetrics, canExpandInline: Bool)
    }

    static func make(for text: String) -> Mode {
        make(
            for: text,
            characterLimit: collapseCharacterLimit,
            lineLimit: collapseLineLimit,
            previewCharacterLimit: collapsedPreviewCharacterLimit,
            previewLineLimit: collapsedPreviewLineLimit,
            allowInlineExpansion: true
        )
    }

    static func makeQueuedPreview(for text: String) -> Mode {
        make(
            for: text,
            characterLimit: queuedCollapseCharacterLimit,
            lineLimit: queuedCollapseLineLimit,
            previewCharacterLimit: queuedPreviewCharacterLimit,
            previewLineLimit: queuedPreviewLineLimit,
            allowInlineExpansion: false
        )
    }

    private static func make(
        for text: String,
        characterLimit: Int,
        lineLimit: Int,
        previewCharacterLimit: Int,
        previewLineLimit: Int,
        allowInlineExpansion: Bool
    ) -> Mode {
        guard !text.isEmpty else {
            return .full(text)
        }

        // Walk at most `characterLimit + 1` characters so MainActor cost is strictly O(1).
        var index = text.startIndex
        var charCount = 0
        var lineCount = 1
        var previewEndIndex: String.Index?
        var lastPreviewWordBoundary: String.Index?

        while index < text.endIndex {
            let ch = text[index]
            let nextIndex = text.index(after: index)
            charCount += 1

            if ch == "\n" {
                lineCount += 1
            }

            if previewEndIndex == nil {
                if ch.isWhitespace || ch == "\n" {
                    lastPreviewWordBoundary = index
                }
                if charCount >= previewCharacterLimit || lineCount > previewLineLimit {
                    if ch == "\n" {
                        previewEndIndex = index
                    } else if let boundary = lastPreviewWordBoundary,
                              text.distance(from: text.startIndex, to: boundary) >= previewCharacterLimit / 2 {
                        previewEndIndex = boundary
                    } else {
                        previewEndIndex = nextIndex
                    }
                }
            }

            if charCount > characterLimit || lineCount > lineLimit {
                let cutIndex = previewEndIndex ?? index
                let rawPreview = String(text[..<cutIndex])
                let trimmedPreview = BoundedTextInspection.trimTrailingWhitespaceAndNewlines(rawPreview)
                let preview = trimmedPreview.isEmpty ? String(text.prefix(previewCharacterLimit)) : trimmedPreview + "…"
                let metrics = LongTextMetrics.computeBounded(for: text)
                let canExpandInline = allowInlineExpansion && text.utf8.count <= inlineExpansionMaximumUTF8Bytes
                return .collapsible(
                    preview: preview,
                    initialMetrics: metrics,
                    canExpandInline: canExpandInline
                )
            }

            index = nextIndex
        }

        return .full(text)
    }

    /// Splits medium-long messages into bounded chunks so inline expansion never
    /// creates an oversized single `Text` layout pass.
    static func prepareInlineChunks(_ text: String) -> [InlineChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [InlineChunk] = []
        var start = text.startIndex
        var nextID = 0

        while start < text.endIndex {
            let hardEnd = text.index(
                start,
                offsetBy: inlineChunkCharacterLimit,
                limitedBy: text.endIndex
            ) ?? text.endIndex

            if hardEnd == text.endIndex {
                chunks.append(InlineChunk(id: nextID, text: String(text[start..<text.endIndex])))
                break
            }

            let candidate = text[start..<hardEnd]
            let end = candidate.lastIndex(of: "\n")
                .map { text.index(after: $0) }
                ?? candidate.lastIndex(where: { $0.isWhitespace })
                    .map { text.index(after: $0) }
                ?? hardEnd

            chunks.append(InlineChunk(id: nextID, text: String(text[start..<end])))
            nextID += 1
            start = end
        }

        return chunks
    }

    /// O(1) bounded snippet for context-menu previews so long-pressing a huge message
    /// never trims or copies the full string on MainActor.
    static func boundedContextPreview(_ text: String, characterLimit: Int = 600) -> String {
        guard !text.isEmpty, characterLimit > 0 else { return "" }
        var index = text.startIndex
        var inspected = 0

        // Skip leading whitespace with a bounded lookahead.
        while index < text.endIndex, text[index].isWhitespace {
            inspected += 1
            if inspected >= 4_096 { return "" }
            index = text.index(after: index)
        }

        guard index < text.endIndex else { return "" }
        let start = index
        var count = 0
        while index < text.endIndex, count < characterLimit {
            index = text.index(after: index)
            count += 1
        }

        let slice = BoundedTextInspection.trimTrailingWhitespaceAndNewlines(String(text[start..<index]))
        guard index < text.endIndex else { return slice }
        return slice + "…"
    }
}

/// Fast string helpers that avoid O(N) full-string copies when checking or trimming large strings.
nonisolated enum BoundedTextInspection {
    static func hasNonWhitespace(_ text: String, maxInspectedCharacters: Int = 4_096) -> Bool {
        var inspected = 0
        for ch in text {
            if !ch.isWhitespace { return true }
            inspected += 1
            if inspected >= maxInspectedCharacters {
                break
            }
        }
        return text.utf8.contains { byte in
            byte != 0x20 && byte != 0x0A && byte != 0x0D && byte != 0x09
        }
    }

    static func hasAtLeastLines(_ text: String, minimumLines: Int) -> Bool {
        guard minimumLines > 1 else { return !text.isEmpty }
        var lines = 1
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            lines += 1
            if lines >= minimumLines {
                return true
            }
        }
        return false
    }

    static func trimOuterWhitespaceAndNewlines(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let first = text.first, !first.isWhitespace,
           let last = text.last, !last.isWhitespace {
            return text
        }
        var start = text.startIndex
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        guard start < text.endIndex else { return "" }
        var end = text.endIndex
        while end > start {
            let before = text.index(before: end)
            guard text[before].isWhitespace else { break }
            end = before
        }
        return String(text[start..<end])
    }

    static func trimTrailingWhitespaceAndNewlines(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        if let last = text.last, !last.isWhitespace {
            return text
        }
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before].isWhitespace else { break }
            end = before
        }
        return String(text[..<end])
    }
}
