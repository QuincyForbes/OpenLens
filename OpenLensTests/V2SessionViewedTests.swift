import Foundation
import SwiftUI
import Testing
import UIKit
@testable import OpenLens

@MainActor
struct V2SessionViewedTests {
    @Test func canonicalViewedMarkerSurvivesDecodingAndSessionCopies() throws {
        let session = try JSONDecoder().decode(OCSession.self, from: Data(#"{"id":"ses_1","outcome":"failed","time":{"created":1000,"updated":2100,"idle":2000,"viewed":1900}}"#.utf8))
        for copy in [session, session.withSelection(agent: "build", model: nil), session.withoutExecutionOutcome()] {
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
            #expect((json["time"] as? [String: Any])?["viewed"] as? Double == 1900)
        }
    }

    @Test func viewingAcknowledgesOnlyTheObservedCompletionThroughTheV2Transport() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        #expect(observed.hasUnreadResult)
        let recovered = try await service.viewResult(observed)
        #expect(!recovered.hasUnreadResult)
        #expect(recovered.time.viewed == 2000)
        let request = try #require(await server.viewRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/session/ses_1/view")
        #expect(request.url?.query == nil)
        let requestBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Double])
        #expect(payload == ["idle": 2000])
        #expect(try await service.listSessions().first?.hasUnreadResult == false)
    }

    @Test func aNewerCompletionDuringAcknowledgementRemainsUnread() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.completeDuringView()
        let recovered = try await service.viewResult(observed)
        #expect(recovered.time.idle == 3000)
        #expect(recovered.time.viewed == 2000)
        #expect(recovered.hasUnreadResult)
        #expect(try await service.listSessions().first?.hasUnreadResult == true)
    }

    @Test(arguments: [true, false])
    func aLostResponseUsesCanonicalEvidenceInsteadOfGuessing(committed: Bool) async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.loseResponse(committed: committed)
        if committed {
            let recovered = try await service.viewResult(observed)
            #expect(!recovered.hasUnreadResult)
            #expect(recovered.time.viewed == 2000)
        } else {
            await #expect(throws: (any Error).self) { try await service.viewResult(observed) }
            #expect(try await service.getSession(id: "ses_1").hasUnreadResult)
            await server.allowView()
            #expect(try await service.viewResult(observed).hasUnreadResult == false)
        }
    }

    @Test func aSuccessfulResponseWithoutTheCanonicalMarkerIsNotConfirmation() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.ignoreView()
        await #expect(throws: (any Error).self) { try await service.viewResult(observed) }
        #expect(try await service.getSession(id: "ses_1").hasUnreadResult)
    }

    @Test func aDesktopViewAndLaterCompletionSurviveListAndForegroundRefresh() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let listed = try await service.listSessions()
        await server.desktopViewed(2000)
        let read = await service.refreshSessionOutcomes(in: listed, previousStatuses: [:], refreshInactive: true)
        #expect(read.sessions.first?.hasUnreadResult == false)
        await server.complete(3000)
        let unread = await service.refreshSessionOutcomes(in: read.sessions, previousStatuses: [:], refreshInactive: true)
        #expect(unread.sessions.first?.hasUnreadResult == true)
        #expect(unread.sessions.first?.time.viewed == 2000)
        #expect(await server.viewRequests.isEmpty)
    }

    @Test func aDesktopViewedEventReconcilesRatherThanGuessingFromItsPayload() throws {
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event(["type": "session.viewed", "data": ["sessionID": "ses_1", "idle": 2000]], directory: nil))
        #expect(event.type == "session.reconcile")
        let data = try #require(event.properties?.value as? [String: Any])
        #expect(data["sessionID"] as? String == "ses_1")
    }

    @Test func chatDoesNotReplaceANewerVisibleCompletionWithAnOldViewResponse() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.holdView()
        let viewing = Task { await chat.viewCurrentResult(observed) }
        try await waitForView(server)
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        await server.releaseView()
        await viewing.value
        #expect(chat.currentSession?.time.idle == 3000)
        #expect(chat.currentSession?.time.viewed == 2000)
        #expect(chat.currentSession?.hasUnreadResult == true)
    }

    @Test(arguments: [false, true])
    func failedOrCancelledViewingKeepsChatUnreadAndDoesNotReportConfirmation(cancelled: Bool) async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        if cancelled {
            await server.holdView()
            let viewing = Task { await chat.viewCurrentResult(observed) }
            try await waitForView(server)
            viewing.cancel()
            await server.releaseView()
            await viewing.value
            #expect(chat.errorMessage == nil)
        } else {
            await server.loseResponse(committed: false)
            await chat.viewCurrentResult(observed)
            #expect(chat.resultViewingError != nil)
            #expect(chat.currentSession?.time.viewed == nil)
            await server.allowView()
            await chat.viewCurrentResult(observed)
            #expect(chat.currentSession?.hasUnreadResult == false)
            #expect(chat.resultViewingError == nil)
            return
        }
        #expect(chat.currentSession?.hasUnreadResult == true)
        #expect(chat.currentSession?.time.viewed == nil)
    }

    @Test func failedCanonicalReadAfterAcknowledgementCanRetryWithoutGuessing() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.failReadAfterView()
        await chat.viewCurrentResult(observed)
        #expect(chat.currentSession?.hasUnreadResult == true)
        #expect(chat.currentSession?.time.viewed == nil)
        #expect(chat.resultViewingError != nil)
        await server.allowReads()
        await chat.viewCurrentResult(observed)
        #expect(chat.currentSession?.time.viewed == 2000)
        #expect(chat.resultViewingError == nil)
    }

    @Test func aLaterCanonicalConfirmationClearsTheViewErrorWithoutAnotherMutation() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.failReadAfterView()
        await chat.viewCurrentResult(observed)
        #expect(chat.resultViewingError != nil)
        await server.allowReads()
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        await chat.viewCurrentResult(try #require(chat.currentSession))
        #expect(chat.currentSession?.hasUnreadResult == false)
        #expect(chat.resultViewingError == nil)
        #expect(await server.viewRequests.count == 1)
    }

    @Test func aDelayedViewResponseCannotChangeAnotherChat() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.holdView()
        let viewing = Task { await chat.viewCurrentResult(observed) }
        try await waitForView(server)
        chat.unloadSession(ifMatching: "ses_1")
        chat.currentSession = OCSession(id: "ses_2", title: "Other", time: .init(created: 1000, updated: 4000, idle: 4000))
        await server.releaseView()
        await viewing.value
        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.currentSession?.time.viewed == nil)
        #expect(chat.errorMessage == nil)
    }

    @Test func unreadUsesIdleRatherThanTitleUpdateTimeAndHandlesMalformedViewedFields() throws {
        let fields = [
            (#""idle":2000"#, true),
            (#""idle":2000,"viewed":1900"#, true),
            (#""idle":2000,"viewed":2000"#, false),
            (#""idle":2000,"viewed":3000"#, false),
            (#""viewed":1900"#, false),
            (#""idle":0"#, false),
            (#""idle":-1"#, false),
            (#""idle":2000,"viewed":"invalid""#, true)
        ]
        for (time, unread) in fields {
            let session = try JSONDecoder().decode(OCSession.self, from: Data(#"{"id":"ses_1","time":{"created":1000,"updated":9999,\#(time)}}"#.utf8))
            #expect(session.hasUnreadResult == unread)
        }
        let first = OCSession(id: "ses_1", title: "Result", time: .init(created: 1000, updated: 2100, idle: 2000))
        #expect(first != first.withViewedMarker(2000))
    }

    @Test func legacyViewingAndAlreadyViewedOrMissingIdleDoNotSendV2Mutations() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        let read = observed.withViewedMarker(2000)
        #expect(try await service.viewResult(read) == read)
        let empty = OCSession(id: "ses_1", title: "New", time: .init(created: 1000, updated: 1000))
        #expect(try await service.viewResult(empty) == empty)
        await server.useLegacy()
        let legacy = try await makeService(server)
        #expect(try await legacy.viewResult(observed) == observed)
        #expect(await server.viewRequests.isEmpty)
    }

    @Test func onlyTheVisibleForegroundChatAcknowledgesAPresentedResult() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewedChatHarness(chat: chat, visibility: visibility)
            .environment(\.connection, connection)
            .environment(\.workspaceService, WorkspaceService(connection: connection)))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.viewRequests.isEmpty)
        visibility.isActive = true
        for _ in 0..<200 {
            if chat.currentSession?.time.viewed == 2000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.currentSession?.hasUnreadResult == false)
        #expect(await server.viewRequests.count == 1)
    }

    @Test func aNewCompletionDuringVisibleViewingWaitsUntilTheNextVisit() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        visibility.isActive = true
        await server.holdView()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewedChatHarness(chat: chat, visibility: visibility)
            .environment(\.connection, connection)
            .environment(\.workspaceService, WorkspaceService(connection: connection)))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForView(server)
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        // Let the updated view react while the old acknowledgement is held.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.viewRequests.count == 1)
        await server.releaseView()
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.currentSession?.hasUnreadResult == true)
        #expect(try await makeService(server).getSession(id: "ses_1").time.viewed == 2000)
        visibility.isActive = false
        try await Task.sleep(for: .milliseconds(100))
        visibility.isActive = true
        for _ in 0..<200 {
            if chat.currentSession?.time.viewed == 3000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.currentSession?.hasUnreadResult == false)
        #expect(await server.viewRequests.count == 2)
    }

    private func makeChat(_ server: ViewedTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = SessionsService(connection: connection)
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: service, messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = try await service.getSession(id: "ses_1")
        return chat
    }

    private func waitForView(_ server: ViewedTransport) async throws {
        for _ in 0..<200 {
            if await server.isWaiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for view acknowledgement")
    }

    private func makeService(_ server: ViewedTransport) async throws -> SessionsService {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/workspace", transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        return SessionsService(connection: connection)
    }
}

private actor ViewedTransport: OpenCodeTransport {
    var idle: Double = 2000
    var viewed: Double?
    var viewRequests: [URLRequest] = []
    var completesDuringView = false
    var commitsView = true
    var losesResponse = false
    var holdsView = false
    var failsReadAfterView = false
    var failsReads = false
    var usesV2 = true
    var waiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }

    func completeDuringView() { completesDuringView = true }
    func complete(_ idle: Double) { self.idle = idle }
    func desktopViewed(_ viewed: Double) { self.viewed = viewed }
    func ignoreView() { commitsView = false }
    func loseResponse(committed: Bool) { losesResponse = true; commitsView = committed }
    func allowView() { losesResponse = false; commitsView = true }
    func holdView() { holdsView = true }
    func releaseView() { holdsView = false; waiters.forEach { $0.resume() }; waiters = [] }
    func failReadAfterView() { failsReadAfterView = true }
    func allowReads() { failsReads = false; failsReadAfterView = false }
    func useLegacy() { usesV2 = false }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body: String
        var status = 200
        switch url.path {
        case "/api/info":
            body = #"{"version":"2.0.23"}"#
            if !usesV2 { status = 404 }
        case "/global/health": body = #"{"healthy":true,"version":"1.2.0"}"#
        case "/api/session/ses_1/view":
            viewRequests.append(request)
            if holdsView { await withCheckedContinuation { waiters.append($0) } }
            if completesDuringView { idle = 3000 }
            let requestBody = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Double])
            if commitsView { viewed = max(viewed ?? 0, min(idle, try #require(payload["idle"]))) }
            if failsReadAfterView { failsReads = true }
            if losesResponse { throw URLError(.networkConnectionLost) }
            body = ""
            status = 204
        case "/api/session/ses_1", "/api/session":
            if failsReads { throw URLError(.networkConnectionLost) }
            var time: [String: Double] = ["created": 1000, "updated": 2100, "idle": idle]
            time["viewed"] = viewed
            let session: [String: Any] = ["id": "ses_1", "title": "Result", "time": time, "outcome": "failed"]
            let response: [String: Any] = url.path == "/api/session" ? ["data": [session], "cursor": ["next": NSNull()]] : ["data": session]
            body = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        case "/api/session/active": body = #"{"data":{}}"#
        case "/api/session/ses_1/message": body = #"{"data":[],"cursor":{"next":null}}"#
        case "/api/session/ses_1/inbox", "/api/session/ses_1/permission", "/api/session/ses_1/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ViewedUnusedStream()
    }
}

private final class ViewedUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}; func suspend() {}; func resume() {}; func cancel() {}
}

@MainActor @Observable
private final class ViewedChatVisibility {
    var isActive = false
}

private struct ViewedChatHarness: View {
    let chat: ChatClient
    let visibility: ViewedChatVisibility
    var body: some View {
        ChatView(chatClient: chat, initialSession: chat.currentSession)
            .environment(\.scenePhase, visibility.isActive ? .active : .background)
    }
}
