import Foundation
import Testing
@testable import OpenLens

struct MarkdownContentViewTests {

    @MainActor
    @Test func longBlockquoteIsPreparedAsBoundedFragments() async {
        let quotedText = String(repeating: "quoted response fragment ", count: 500)
        let prepared = await prepareMarkdown("> \(quotedText)")

        guard case let .blockquote(fragments) = prepared.blocks.first?.kind else {
            Issue.record("Expected a blockquote")
            return
        }

        #expect(fragments.count > 1)
        #expect(fragments.allSatisfy { $0.raw.count <= 1_600 })
    }

    @MainActor
    @Test func longListItemUsesBoundedContinuationFragments() async {
        let longItem = String(repeating: "long list item fragment ", count: 500)
        let prepared = await prepareMarkdown("- \(longItem)\n- final item")

        guard case let .unorderedList(fragments) = prepared.blocks.first?.kind else {
            Issue.record("Expected an unordered list")
            return
        }

        #expect(fragments.count > 2)
        #expect(fragments.allSatisfy { $0.raw.count <= 1_600 })
        #expect(fragments.first?.marker == "•")
        #expect(fragments.dropFirst().contains { $0.marker == nil })
        #expect(fragments.last?.marker == "•")
    }

    @MainActor
    @Test func longHeadingIsPreparedAsBoundedBlocks() async {
        let heading = "# " + String(repeating: "heading fragment ", count: 500)
        let prepared = await prepareMarkdown(heading)
        let headingTexts = prepared.blocks.compactMap { block -> String? in
            guard case let .heading(_, text) = block.kind else { return nil }
            return text
        }

        #expect(headingTexts.count > 1)
        #expect(headingTexts.allSatisfy { $0.count <= 1_600 })
    }

    @MainActor
    @Test func fencedCodeLanguageLabelIsBounded() async {
        let language = String(repeating: "swift", count: 100)
        let prepared = await prepareMarkdown("```\(language)\nlet answer = 42\n```")

        guard case let .codeBlock(label, _) = prepared.blocks.first?.kind else {
            Issue.record("Expected a code block")
            return
        }

        #expect(label?.count == 83)
        #expect(label?.hasSuffix("...") == true)
    }

    @MainActor
    @Test func pipeTableBetweenParagraphsIsPreparedAsTableBlock() async {
        let prepared = await prepareMarkdown("""
        Here are the results:
        | Name | Status | Count |
        | :--- | :----: | ----: |
        | **api** | `ok` | 12 |
        | web | down | 3 |
        That's all.
        """)

        #expect(prepared.blocks.count == 3)
        guard prepared.blocks.count == 3,
              case let .table(table) = prepared.blocks[1].kind else {
            Issue.record("Expected paragraph, table, paragraph")
            return
        }
        #expect(table.table.headers == ["Name", "Status", "Count"])
        #expect(table.table.alignments == [.leading, .center, .trailing])
        #expect(table.rows.count == 2)
        #expect(table.columnWidths.count == 3)
        #expect(table.rows[0][0].attributed.map { String($0.characters) } == "api")
        if case let .paragraph(_, raw) = prepared.blocks[2].kind {
            #expect(raw == "That's all.")
        } else {
            Issue.record("Expected trailing paragraph")
        }
    }

    @MainActor
    @Test func pipeTextWithoutDelimiterRowStaysParagraph() async {
        let prepared = await prepareMarkdown("a | b\nc | d")
        guard case .paragraph = prepared.blocks.first?.kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(prepared.blocks.count == 1)
    }

    @MainActor
    @Test func tableInsideBlockquoteIsPreparedAsRichBlockquote() async {
        let prepared = await prepareMarkdown("""
        > Summary:
        > | Key | Value |
        > | --- | ---: |
        > | CPU | 42% |
        """)
        #expect(prepared.blocks.count == 1)
        guard case let .richBlockquote(nested) = prepared.blocks.first?.kind else {
            Issue.record("Expected a richBlockquote containing a table")
            return
        }
        #expect(nested.count == 2)
        guard case let .table(table) = nested[1].kind else {
            Issue.record("Expected a nested table inside blockquote")
            return
        }
        #expect(table.table.headers == ["Key", "Value"])
        #expect(table.table.alignments == [.leading, .trailing])
        #expect(table.table.rows == [["CPU", "42%"]])
    }

    @MainActor
    @Test func backToBackTablesAndCRLFAndThematicBreakSeparateCleanly() async {
        let markdown = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n| C | D |\r\n| --- | --- |\r\n| 3 | 4 |\r\n---\r\n## Next | Section"
        let prepared = await prepareMarkdown(markdown)
        #expect(prepared.blocks.count == 4)
        if case let .table(first) = prepared.blocks[0].kind {
            #expect(first.table.headers == ["A", "B"])
            #expect(first.table.rows == [["1", "2"]])
        } else {
            Issue.record("Expected first table")
        }
        if case let .table(second) = prepared.blocks[1].kind {
            #expect(second.table.headers == ["C", "D"])
            #expect(second.table.rows == [["3", "4"]])
        } else {
            Issue.record("Expected second table")
        }
        if case .thematicBreak = prepared.blocks[2].kind {
            // ok
        } else {
            Issue.record("Expected thematic break")
        }
        if case let .heading(level, text) = prepared.blocks[3].kind {
            #expect(level == 2)
            #expect(text == "Next | Section")
        } else {
            Issue.record("Expected trailing heading")
        }
    }

    @MainActor
    @Test func pipeTableStartingWithListMarkerWithoutOuterPipesParsesAsTable() async {
        let prepared = await prepareMarkdown("""
        1. Step | Status
        --- | ---
        Build | Pass
        """)
        #expect(prepared.blocks.count == 1)
        guard case let .table(table) = prepared.blocks.first?.kind else {
            Issue.record("Expected table instead of ordered list")
            return
        }
        #expect(table.table.headers == ["1. Step", "Status"])
        #expect(table.table.rows == [["Build", "Pass"]])
    }

    @MainActor
    private func prepareMarkdown(_ text: String) async -> MarkdownContentView.Prepared {
        await withCheckedContinuation { continuation in
            MarkdownContentView.prepare(text) { prepared in
                continuation.resume(returning: prepared)
            }
        }
    }
}
