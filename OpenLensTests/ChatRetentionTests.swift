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
