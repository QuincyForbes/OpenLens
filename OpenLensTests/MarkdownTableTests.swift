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
}
