import Foundation
import Testing
@testable import OpenLens

struct MarkdownTableTests {
    @Test func splitsRowsRespectingEscapedPipesAndCodeSpans() {
        #expect(MarkdownTable.splitRow("| a | b \\| c | `x|y` |") == ["a", "b | c", "`x|y`"])
        #expect(MarkdownTable.splitRow("a|b") == ["a", "b"])
    }

    @Test func parsesDelimiterAlignments() {
        #expect(MarkdownTable.delimiterAlignments("|:--|:-:|--:|---|") == [.leading, .center, .trailing, .leading])
        #expect(MarkdownTable.delimiterAlignments("---") == nil)
        #expect(MarkdownTable.delimiterAlignments("| a | b |") == nil)
    }

    @Test func normalizesRaggedRowsToHeaderColumnCount() throws {
        let lines = ["| A | B |", "|---|---|", "| 1 |", "| 1 | 2 | 3 |", "", "after"]
        let parsed = try #require(MarkdownTable.parse(lines: lines, at: 0))
        #expect(parsed.nextIndex == 4)
        #expect(parsed.table.rows == [["1", ""], ["1", "2"]])
    }

    @Test func exportsCSVWithQuotingAndPlainText() {
        let table = MarkdownTable(
            headers: ["Name", "Note"],
            alignments: [.leading, .leading],
            rows: [["**Bold**", "a, \"quoted\" value"], ["`code`", "line<br>break"]]
        )
        #expect(table.csv == "Name,Note\r\nBold,\"a, \"\"quoted\"\" value\"\r\ncode,\"line\nbreak\"\r\n")
        #expect(table.tsv == "Name\tNote\nBold\ta, \"quoted\" value\ncode\tline break")
    }

    @Test func exportsNormalizedMarkdownAndFilename() {
        let table = MarkdownTable(
            headers: ["Model", "Cost (USD)"],
            alignments: [.leading, .trailing],
            rows: [["a|b", "1.5"]]
        )
        #expect(table.markdown == "| Model | Cost (USD) |\n| --- | ---: |\n| a\\|b | 1.5 |")
        #expect(table.suggestedFilenameStem() == "table-model-cost-usd")
    }

    @Test func columnWidthsAreBounded() {
        let table = MarkdownTable(
            headers: ["x", "Long"],
            alignments: [],
            rows: [["", String(repeating: "w", count: 400)]]
        )
        let widths = table.estimatedColumnWidths()
        #expect(widths[0] == 56)
        #expect(widths[1] == 320)
    }

    @Test func previewFlattensBlockMarkdown() {
        let report = """
        ## Summary
        - **Fixed** the `parser`
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        #expect(MarkdownPreview.flattenedBlockSyntax(report) == "Summary **Fixed** the `parser` A · B 1 · 2")
        #expect(MarkdownPreview.plainText(report) == "Summary Fixed the parser A · B 1 · 2")
    }

    @Test func parsesCRLFAndCRLineEndings() throws {
        let crlf = "| Name | Value |\r\n| --- | ---: |\r\n| alpha | 10 |\r\n| beta | 20 |\r\n"
        #expect(MarkdownTable.containsTable(crlf))
        let lines = MarkdownTable.normalizedLines(from: crlf)
        let parsed = try #require(MarkdownTable.parse(lines: lines, at: 0))
        #expect(parsed.table.headers == ["Name", "Value"])
        #expect(parsed.table.alignments == [.leading, .trailing])
        #expect(parsed.table.rows == [["alpha", "10"], ["beta", "20"]])
    }

    @Test func splitsMultiBacktickCodeSpansUnclosedBackticksAndEscapedBackslashes() {
        #expect(MarkdownTable.splitRow("| ``a | b`` | c |") == ["``a | b``", "c"])
        #expect(MarkdownTable.splitRow("| unclosed `tick | next |") == ["unclosed `tick", "next"])
        #expect(MarkdownTable.splitRow("| path\\\\ | end |") == ["path\\\\", "end"])
        #expect(MarkdownTable.splitRow("| a | b\\\\|") == ["a", "b\\\\"])
        #expect(MarkdownTable.splitRow("| a | b\\|") == ["a", "b|"])
    }

    @Test func separatesBackToBackTablesAndFollowingBlocksWithPipes() throws {
        let lines = MarkdownTable.normalizedLines(from: """
        | A | B |
        |---|---|
        | 1 | 2 |
        | C | D |
        |---|---|
        | 3 | 4 |
        ## Section A | Section B
        - item X | item Y
        > quoted a | b
        """)
        let first = try #require(MarkdownTable.parse(lines: lines, at: 0))
        #expect(first.table.headers == ["A", "B"])
        #expect(first.table.rows == [["1", "2"]])
        #expect(first.nextIndex == 3)

        let second = try #require(MarkdownTable.parse(lines: lines, at: first.nextIndex))
        #expect(second.table.headers == ["C", "D"])
        #expect(second.table.rows == [["3", "4"]])
        #expect(second.nextIndex == 6)
    }

    @Test func rejectsHeaderDelimiterColumnCountMismatch() {
        let lines = ["| A | B |", "|---|---|---|", "| 1 | 2 | 3 |"]
        #expect(MarkdownTable.parse(lines: lines, at: 0) == nil)
        #expect(!MarkdownTable.startsTable(lines: lines, at: 0))
    }

    @Test func ignoresTablesInsideFencedCodeBlocksAndSplitsProseFromTables() {
        let fenced = """
        ```markdown
        | A | B |
        |---|---|
        | 1 | 2 |
        ```
        """
        #expect(!MarkdownTable.containsTable(fenced))

        let tildeFenced = """
        ~~~md
        | A | B |
        |---|---|
        | 1 | 2 |
        ~~~
        """
        #expect(!MarkdownTable.containsTable(tildeFenced))

        let mixed = """
        Intro text

        | Key | Value |
        | --- | --- |
        | a | 1 |

        Outro text
        """
        #expect(MarkdownTable.containsTable(mixed))
        let segments = MarkdownTable.splitTextAndTables(mixed)
        #expect(segments.count == 3)
        #expect(segments[0] == .text("Intro text"))
        #expect(segments[1] == .table(MarkdownTable(headers: ["Key", "Value"], alignments: [.leading, .leading], rows: [["a", "1"]])))
        #expect(segments[2] == .text("Outro text"))
    }

    @Test func normalizesMixedCaseLineBreakTags() {
        #expect(MarkdownTable.normalizeLineBreaks("one<BR>two<br />three<Br/>four") == "one\ntwo\nthree\nfour")
    }

    @Test func splitsQuotedTableIntoBlockquoteSegment() {
        let quoted = """
        Intro

        > Quoted header
        > | A | B |
        > |---|---|
        > | 1 | 2 |

        Outro
        """
        #expect(MarkdownTable.containsTable(quoted))
        let segments = MarkdownTable.splitTextAndTables(quoted)
        #expect(segments.count == 3)
        #expect(segments[0] == .text("Intro"))
        #expect(segments[2] == .text("Outro"))
        if case let .blockquote(nested) = segments[1] {
            #expect(nested == [
                .text("Quoted header"),
                .table(MarkdownTable(headers: ["A", "B"], alignments: [.leading, .leading], rows: [["1", "2"]]))
            ])
        } else {
            Issue.record("Expected blockquote segment containing nested table")
        }
    }
}
