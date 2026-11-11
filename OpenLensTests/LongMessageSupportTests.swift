import Foundation
import Testing
@testable import OpenLens

@MainActor
struct LongMessageSupportTests {

    // MARK: - ComposerPasteExtractor

    @Test func largePasteIntoEmptyFieldExtractsSnippetAndLeavesFieldClean() {
        let largePaste = String(repeating: "Frame generation and DLSS 5 frame pacing analysis.\n", count: 40)

        let extraction = ComposerPasteExtractor.extractLargePaste(previous: "", updated: largePaste)

        #expect(extraction != nil)
        #expect(extraction?.remainingInputText == "")
        #expect(extraction?.pastedText == largePaste)
    }

    @Test func largePasteInsideExistingTypedPromptPreservesTypedPrefixAndSuffix() {
        let prefix = "Summarize this crash log: "
        let suffix = " Focus on thread 0."
        let pastedLog = String(repeating: "0x104a8f000 + 1248 [SSEClient.swift:142]\n", count: 36)

        let extraction = ComposerPasteExtractor.extractLargePaste(
            previous: prefix + suffix,
            updated: prefix + pastedLog + suffix
        )

        #expect(extraction?.remainingInputText == prefix + suffix)
        #expect(extraction?.pastedText == pastedLog)
    }

    @Test func manyShortLinesExtractAsSnippetEvenUnderByteThreshold() {
        let paddedLines = (1...24).map { "step \($0): check state transition" }.joined(separator: "\n")
        #expect(paddedLines.utf8.count < ComposerPasteExtractor.minimumPastedUTF8Bytes)
        #expect(paddedLines.utf8.count >= ComposerPasteExtractor.minimumSingleStepInsertionUTF8Bytes)

        let extraction = ComposerPasteExtractor.extractLargePaste(previous: "", updated: paddedLines)

        #expect(extraction?.remainingInputText == "")
        #expect(extraction?.pastedText == paddedLines)
    }

    @Test func normalTypingAndSmallPastesStayInline() {
        let existing = String(repeating: "a", count: 995)
        let typedOneChar = existing + "b"

        #expect(ComposerPasteExtractor.extractLargePaste(previous: existing, updated: typedOneChar) == nil)
        #expect(ComposerPasteExtractor.extractLargePaste(previous: "Hello", updated: "Hello world, how are you?") == nil)
    }

    @Test func pastingSlashCommandWithHugePayloadKeepsCommandInField() {
        let payload = String(repeating: "diff --git a/App.swift b/App.swift\n+let value = 42\n", count: 35)
        let pasted = "/review " + payload

        let extraction = ComposerPasteExtractor.extractLargePaste(previous: "", updated: pasted)

        #expect(extraction?.remainingInputText == "/review")
        #expect(extraction?.pastedText == payload)
    }

    @Test func composePromptPlacesTypedInstructionAheadOfPastedSnippets() {
        let snippetA = ComposerPastedSnippet(text: String(repeating: "alpha ", count: 220))
        let snippetB = ComposerPastedSnippet(text: String(repeating: "beta ", count: 220))

        let withInstruction = ComposerPasteExtractor.composePrompt(
            inputText: "Compare these two traces:",
            snippets: [snippetA, snippetB]
        )
        #expect(withInstruction.hasPrefix("Compare these two traces:\n\nalpha "))
        #expect(withInstruction.hasSuffix("beta"))

        let snippetOnly = ComposerPasteExtractor.composePrompt(
            inputText: ComposerPasteExtractor.focusResetSentinel,
            snippets: [snippetA]
        )
        #expect(snippetOnly == BoundedTextInspection.trimOuterWhitespaceAndNewlines(snippetA.text))
    }

    // MARK: - ChatClient Composer Integration

    @Test func reuseTextInComposerRoutesShortInlineAndLongAsSnippet() {
        let chat = makeChat()
        let shortText = "Explain the reconnect backoff."
        let longText = String(repeating: "Detailed transcript line with telemetry metrics.\n", count: 40)

        chat.reuseTextInComposer(shortText)
        #expect(chat.inputText == shortText)
        #expect(chat.composerPastedSnippets.isEmpty)

        chat.inputText = ""
        chat.reuseTextInComposer(longText)
        #expect(chat.inputText.isEmpty)
        #expect(chat.composerPastedSnippets.count == 1)
        #expect(chat.composedPromptText() == BoundedTextInspection.trimOuterWhitespaceAndNewlines(longText))
    }

    @Test func sessionDraftSwitchingPreservesPastedSnippetsPerSession() {
        let chat = makeChat()
        let sessionA = OCSession(id: "ses_a", title: "Session A", time: .init(created: 0, updated: 0))
        let sessionB = OCSession(id: "ses_b", title: "Session B", time: .init(created: 0, updated: 0))
        let longSnippet = String(repeating: "Long architecture notes for session A.\n", count: 40)

        chat.prepareForOpeningSession(sessionA)
        chat.inputText = "Summarize:"
        #expect(chat.addComposerPastedSnippet(longSnippet))
        #expect(chat.composerPastedSnippets.count == 1)

        chat.prepareForOpeningSession(sessionB)
        #expect(chat.inputText.isEmpty)
        #expect(chat.composerPastedSnippets.isEmpty)

        chat.prepareForOpeningSession(sessionA)
        #expect(chat.inputText == "Summarize:")
        #expect(chat.composerPastedSnippets.count == 1)
        #expect(chat.composerPastedSnippets.first?.text == longSnippet)
    }

    @Test func oversizedPasteExceedingSafetyCeilingIsRefusedCleanly() {
        let chat = makeChat()
        let oversized = String(repeating: "x", count: ComposerPastedSnippet.maximumAllowedUTF8Bytes + 1_024)

        let added = chat.addComposerPastedSnippet(oversized)

        #expect(!added)
        #expect(chat.composerPastedSnippets.isEmpty)
        #expect(chat.errorMessage?.contains("too large") == true)
    }

    // MARK: - UserMessagePresentation

    @Test func shortUserMessageRendersFullWithoutCollapsing() {
        let short = "Can we check why frame pacing spikes on cellular?"
        #expect(UserMessagePresentation.make(for: short) == .full(short))
    }

    @Test func hugeUserMessageCollapsesWithBoundedPreviewAndDisablesInlineExpand() {
        let huge = String(repeating: "Frame generation and DLSS 5 latency analysis line.\n", count: 1_500)

        let mode = UserMessagePresentation.make(for: huge)
        guard case let .collapsible(preview, metrics, canExpandInline) = mode else {
            Issue.record("Expected huge user message to be collapsible")
            return
        }

        #expect(!canExpandInline)
        #expect(preview.count <= UserMessagePresentation.collapsedPreviewCharacterLimit + 2)
        #expect(metrics.byteCount == huge.utf8.count)

        let exact = LongTextMetrics.computeExact(for: huge)
        #expect(exact.lineCount == 1_501)
        #expect(!exact.isLineCountApproximate)
    }

    @Test func mediumLongUserMessageSupportsBoundedInlineChunks() {
        let medium = (1...30)
            .map { "Paragraph \($0): Verify that TextKit never lays out an unbounded user bubble." }
            .joined(separator: "\n")
        #expect(medium.utf8.count > ComposerPasteExtractor.minimumPastedUTF8Bytes)
        #expect(medium.utf8.count <= UserMessagePresentation.inlineExpansionMaximumUTF8Bytes)

        let mode = UserMessagePresentation.make(for: medium)
        guard case let .collapsible(_, _, canExpandInline) = mode else {
            Issue.record("Expected medium-long user message to collapse initially")
            return
        }
        #expect(canExpandInline)

        let chunks = UserMessagePresentation.prepareInlineChunks(medium)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.text.count <= UserMessagePresentation.inlineChunkCharacterLimit })
        #expect(chunks.map(\.text).joined() == medium)
    }

    @Test func reminderInspectionChecksEdgesWithoutScanningHugeMiddlePayload() {
        let body = String(repeating: "stack trace line without triggers\n", count: 5_000)
        let leadingReminder = "Please remind me in 10 minutes after checking:\n\n" + body
        let trailingReminder = body + "\nRemind us when this finishes."

        #expect(ChatNotificationService.containsReminderRequest(leadingReminder))
        #expect(ChatNotificationService.parseRelativeReminderDelaySeconds(from: leadingReminder) == 600)
        #expect(ChatNotificationService.containsReminderRequest(trailingReminder))
        #expect(!ChatNotificationService.containsReminderRequest(body))
    }

    @Test func structuralSamePartsComparesNestedToolPayloadsWithoutJSONSerialization() {
        let base = OCPart(
            id: "part_1",
            sessionID: "ses_1",
            messageID: "msg_1",
            type: .tool,
            metadata: ["nested": AnyCodable(["attempt": 1, "tags": ["fast", "safe"]])],
            callID: "call_1",
            tool: "bash",
            state: OCToolState(status: .completed, input: AnyCodable(["cmd": "ls"]), output: "ok")
        )
        let identical = OCPart(
            id: "part_1",
            sessionID: "ses_1",
            messageID: "msg_1",
            type: .tool,
            metadata: ["nested": AnyCodable(["attempt": 1, "tags": ["fast", "safe"]])],
            callID: "call_1",
            tool: "bash",
            state: OCToolState(status: .completed, input: AnyCodable(["cmd": "ls"]), output: "ok")
        )
        let changed = OCPart(
            id: "part_1",
            sessionID: "ses_1",
            messageID: "msg_1",
            type: .tool,
            metadata: ["nested": AnyCodable(["attempt": 2, "tags": ["fast", "safe"]])],
            callID: "call_1",
            tool: "bash",
            state: OCToolState(status: .completed, input: AnyCodable(["cmd": "ls"]), output: "ok")
        )

        #expect(ChatClient.sameParts([base], [identical]))
        #expect(!ChatClient.sameParts([base], [changed]))
    }

    @Test func largeFileDiffUsesMyersFallbackWithoutMatrixExplosion() {
        let before = (1...650).map { "func line\($0)() { print(\($0)) }" }.joined(separator: "\n")
        var afterArray = (1...650).map { "func line\($0)() { print(\($0)) }" }
        afterArray[10] = "func line11() { print(\"updated\") }"
        afterArray[620] = "func line621() { print(\"updatedTail\") }"
        let after = afterArray.joined(separator: "\n")

        let file = ReviewFileChange(
            path: "Large.swift",
            status: "M",
            additions: 2,
            deletions: 2,
            beforeText: before,
            afterText: after
        )
        let hunks = UnifiedDiffBuilder.makeHunks(file: file)

        #expect(hunks.count == 2)
        #expect(hunks.flatMap(\.lines).contains { $0.kind == .added && $0.text.contains("updated") })
        #expect(hunks.flatMap(\.lines).contains { $0.kind == .added && $0.text.contains("updatedTail") })
    }

    private func makeChat() -> ChatClient {
        let connection = ConnectionManager()
        return ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection),
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
            recordedReplayStore: RecordedReplayStore()
        )
    }
}
