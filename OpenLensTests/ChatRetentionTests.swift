import Foundation
import Testing
@testable import OpenLens

@MainActor
struct ChatRetentionTests {
    @Test func switchingSessionsReleasesTranscriptAndRestoresOnlyDrafts() {
        let chat = makeChat()
        let first = session("first")
        let second = session("second")
        chat.prepareForOpeningSession(first)
        chat.inputText = "Keep this unsent prompt"

        var message: ChatMessage? = ChatMessage(id: "old-reply", role: .assistant, content: "Server history")
        weak var releasedMessage = message
        chat.replaceTranscript(SessionTranscript(
            messages: [message!], contextEntries: [], entryOrder: ["old-reply"], olderCursor: "older-page"
        ))
        message = nil
        #expect(releasedMessage != nil)
        #expect(chat.hasEarlierMessages)

        chat.prepareForOpeningSession(second)
        #expect(releasedMessage == nil)
        #expect(chat.messages.isEmpty)
        #expect(chat.displayedMessages.isEmpty)
        #expect(chat.transcriptEntryOrder.isEmpty)
        #expect(!chat.hasEarlierMessages)
        #expect(!chat.isStreamSynchronized)
        #expect(chat.inputText.isEmpty)

        chat.prepareForOpeningSession(first)
        #expect(chat.messages.isEmpty)
        #expect(chat.inputText == "Keep this unsent prompt")
        #expect(chat.needsSessionLoad(first))
    }

    @Test func returningToCurrentSessionKeepsItsActiveTranscript() {
        let chat = makeChat()
        let current = session("current")
        chat.prepareForOpeningSession(current)
        let message = ChatMessage(id: "reply", role: .assistant, content: "Current reply")
        chat.replaceTranscript(SessionTranscript(messages: [message], contextEntries: [], entryOrder: [message.id]))
        chat.inputText = "Draft"

        chat.prepareForOpeningSession(current)

        #expect(chat.messages.first === message)
        #expect(chat.inputText == "Draft")
    }

    @Test func clearingADraftDoesNotResurrectItOnTheNextVisit() {
        let chat = makeChat()
        let first = session("first")
        let second = session("second")
        chat.prepareForOpeningSession(first)
        chat.inputText = "Draft"
        chat.prepareForOpeningSession(second)
        chat.prepareForOpeningSession(first)
        #expect(chat.inputText == "Draft")
        chat.inputText = ""
        chat.prepareForOpeningSession(second)
        chat.prepareForOpeningSession(first)
        #expect(chat.inputText.isEmpty)
    }

    @Test func deletingAnInactiveSessionDiscardsItsDraftWithoutUnloadingTheActiveChat() {
        let chat = makeChat()
        let first = session("first")
        let second = session("second")
        chat.prepareForOpeningSession(first)
        chat.inputText = "Deleted session's draft"
        chat.prepareForOpeningSession(second)
        chat.inputText = "Active draft"

        chat.unloadSession(ifMatching: first.id)
        #expect(chat.currentSession?.id == second.id)
        #expect(chat.inputText == "Active draft")
        chat.prepareForOpeningSession(first)
        #expect(chat.inputText.isEmpty)
    }

    @Test func switchingSessionsPreservesDraftAttachmentsForSameDirectoryAndDropsServerFilesWhenMoved() throws {
        let chat = makeChat()
        let first = OCSession(id: "first", directory: "/workspace/Alpha", title: "First", time: .init(created: 0, updated: 0))
        let second = OCSession(id: "second", directory: "/workspace/Beta", title: "Second", time: .init(created: 0, updated: 0))

        chat.prepareForOpeningSession(first)
        let serverRef = try ServerFileReference(path: "/workspace/Alpha/Sources/App.swift", sessionDirectory: "/workspace/Alpha", lines: nil)
        let textFile = try PromptTextFileAttachment(data: Data("Note".utf8), name: "note.txt")
        chat.addComposerAttachment(.serverFile(serverRef))
        chat.addComposerAttachment(.textFile(textFile))
        #expect(chat.composerAttachments.count == 2)

        chat.prepareForOpeningSession(second)
        #expect(chat.composerAttachments.isEmpty)

        chat.prepareForOpeningSession(first)
        #expect(chat.composerAttachments.count == 2)

        // Switching away and returning after the session moved directories keeps phone files but drops relative server files.
        chat.prepareForOpeningSession(second)
        let movedFirst = OCSession(id: "first", directory: "/workspace/MovedAlpha", title: "First", time: .init(created: 0, updated: 0))
        chat.prepareForOpeningSession(movedFirst)
        #expect(chat.composerAttachments.count == 1)
        #expect(chat.composerAttachments.first?.promptFile.name == "note.txt")
    }

    @Test func tapToSelectLineRangeAndDiffQuotingHelpersFormatCleanly() {
        let firstTap = RepositoryFilePicker.updatedLineRange(startLine: "", endLine: "", tappedLine: 18)
        #expect(firstTap.start == "18" && firstTap.end.isEmpty)

        let secondTapReversed = RepositoryFilePicker.updatedLineRange(startLine: firstTap.start, endLine: firstTap.end, tappedLine: 10)
        #expect(secondTapReversed.start == "10" && secondTapReversed.end == "18")

        let resetTap = RepositoryFilePicker.updatedLineRange(startLine: secondTapReversed.start, endLine: secondTapReversed.end, tappedLine: 25)
        #expect(resetTap.start == "25" && resetTap.end.isEmpty)

        let clearSingle = RepositoryFilePicker.updatedLineRange(startLine: resetTap.start, endLine: resetTap.end, tappedLine: 25)
        #expect(clearSingle.start.isEmpty && clearSingle.end.isEmpty)

        let hunk = UnifiedDiffHunk(
            id: "h1",
            header: "@@ -1,2 +1,2 @@",
            lines: [
                UnifiedDiffLine(id: "l1", kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "let old = 1"),
                UnifiedDiffLine(id: "l2", kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "let new = 2")
            ]
        )
        let quote = hunk.formattedChatQuote(filePath: "Sources/Main.swift")
        #expect(quote.contains("In `Sources/Main.swift` (@@ -1,2 +1,2 @@):"))
        #expect(quote.contains("-let old = 1"))
        #expect(quote.contains("+let new = 2"))

        let chat = makeChat()
        chat.appendQuotedDiff(quote)
        #expect(chat.inputText.contains("Sources/Main.swift"))
    }

    private func session(_ id: String) -> OCSession {
        OCSession(id: id, title: id, time: .init(created: 0, updated: 0))
    }

    private func makeChat() -> ChatClient {
        let connection = ConnectionManager()
        return ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
    }
}
