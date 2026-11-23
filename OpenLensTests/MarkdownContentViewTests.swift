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
    private func prepareMarkdown(_ text: String) async -> MarkdownContentView.Prepared {
        await withCheckedContinuation { continuation in
            MarkdownContentView.prepare(text) { prepared in
                continuation.resume(returning: prepared)
            }
        }
    }
}
