import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2ActiveContextTests {
    @Test(arguments: [false, true])
    func activeContextAndHistoryKeepUniqueIDsInOriginalOrderWithLatestValues(active: Bool) async throws {
        let wire = #"""
        {"data":[
          {"id":"msg_system","type":"system","text":"Old instruction"},
          {"id":"msg_user","type":"user","text":"Old prompt"},
          {"type":"future","text":{}},
          {"id":"msg_system","type":"system","text":"Current instruction"},
          {"id":"msg_user","type":"user","text":"Current prompt"},
          {"id":"msg_reply","type":"assistant","content":[{"type":"text","text":"Current reply"}]}
        ],"cursor":{"next":null}}
        """#
        let transport = ActiveContextTransport()
        await transport.setContext(wire)
        await transport.setHistory(wire)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = MessagesService(connection: connection)
        let result = try #require(try await (active
            ? service.loadActiveContext(sessionID: "ses_1")
            : service.loadTranscript(sessionID: "ses_1")))
        #expect(result.entryOrder == ["msg_system", "msg_user", "msg_reply"])
        #expect(result.contextEntries.map(\.details) == ["Current instruction"])
        #expect(result.messages.map(\.content) == ["Current prompt", "Current reply"])
    }

    @Test func missingSessionSelectionIsAFailureRatherThanUnsupportedContext() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        await #expect(throws: OpenCodeError.self) { try await chat.loadActiveContext() }
        #expect(await transport.contextRequests().isEmpty)
    }

    @Test func failedChatSynchronizationDoesNotBlockContextReadOrRetry() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        chat.synchronizeCurrentSessionFromServer()
        for _ in 0..<300 where chat.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.errorMessage?.hasPrefix("Failed to synchronize chat:") == true)
        #expect(!chat.isStreamSynchronized)
        await transport.setContext(#"{"_tag":"UnknownError","message":"Context temporarily offline"}"#, status: 500)
        await #expect(throws: OpenCodeError.self) { try await chat.loadActiveContext() }
        await transport.setContext(#"{"data":[{"id":"msg_current","type":"user","text":"Current context"}]}"#)
        let result = try #require(try await chat.loadActiveContext())
        #expect(result.messages.first?.content == "Current context")
        #expect(!chat.isStreamSynchronized)
        #expect(await transport.contextRequests().count == 2)
    }

    @Test func legacyContextReadIsUnavailableAndExistingUsageStaysAvailable() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 404, body: Data()),
            "/global/health": .init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse)
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        chat.messages = [ChatMessage(role: .assistant, content: "Legacy reply",
            tokens: .init(input: 100, output: 20, reasoning: nil, cache: nil))]
        #expect(!chat.showsActiveContext)
        #expect(chat.contextUsageSummary?.usedTokens == 120)
        #expect(try await chat.loadActiveContext() == nil)
        #expect(await transport.recordedPaths() == ["/api/info", "/global/health"])
    }

    @Test func malformedContextFailsWithoutSubstitutingHistoryAndRetryRecovers() async throws {
        let transport = ActiveContextTransport()
        await transport.setContext(#"{"data":{"unexpected":true}}"#)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        await #expect(throws: DecodingError.self) { try await chat.loadActiveContext() }
        #expect(chat.messages.isEmpty)
        await transport.setContext(#"{"data":[{"id":"msg_new","type":"user","text":"Current"}]}"#)
        #expect(try await chat.loadActiveContext()?.messages.first?.content == "Current")
        #expect(chat.messages.isEmpty)
    }

    @Test func switchingSessionsReadsTheNewProjectionWithoutReplacingEitherConversation() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        let firstScope = chat.activeContextScope
        let first = try #require(try await chat.loadActiveContext())
        chat.currentSession = session("ses_2")
        let second = try #require(try await chat.loadActiveContext())
        #expect(chat.activeContextScope != firstScope)
        #expect(first.entryOrder == ["msg_summary", "msg_user", "msg_reply"])
        #expect(second.entryOrder == ["msg_other"])
        #expect(chat.messages.isEmpty)
        #expect(await transport.contextRequests().map { $0.url?.path } == ["/api/session/ses_1/context", "/api/session/ses_2/context"])
    }

    @Test func currentProjectionRetainsInstructionsSkillsAndToolResults() async throws {
        let transport = ActiveContextTransport()
        await transport.setContext(#"""
        {"data":[
          {"id":"msg_system","type":"system","description":"Current instructions","text":"Use Swift Testing."},
          {"id":"msg_skill","type":"skill","name":"review","text":"Review the current branch."},
          {"id":"msg_shell","type":"shell","command":"swift test","status":"completed","exit":0,"output":"Passed."},
          {"id":"msg_tool","type":"assistant","content":[{"id":"call_1","type":"tool","name":"read","state":{"status":"completed","input":{"path":"App.swift"},"content":[{"type":"text","text":"Current file"}]}},{"type":"text","text":"Ready."}]}
        ]}
        """#)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let active = try #require(try await MessagesService(connection: connection).loadActiveContext(sessionID: "ses_1"))
        #expect(active.entryOrder == ["msg_system", "msg_skill", "msg_shell", "msg_tool"])
        #expect(active.contextEntries.map(\.details) == ["Use Swift Testing.", "Review the current branch.", "Exit code: 0\n\nPassed."])
        #expect(active.messages.first?.persistedToolSteps.first?.toolName == "read")
        #expect(active.messages.first?.parts.first?.state?.output == "Current file")
        #expect(active.messages.first?.persistedToolSteps.first?.outputPreview == "App.swift")
    }

    @Test(arguments: ["none", "session", "roundTrip", "unload", "location", "binding", "disconnect", "cancel", "refresh", "model"], [false, true])
    func delayedContextCannotEscapeItsSelectedSessionAndBinding(_ change: String, failed: Bool) async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/work", transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        let scope = chat.activeContextScope
        if failed { await transport.setContext(#"{"_tag":"UnknownError","message":"Provider offline"}"#, status: 500) }
        await transport.holdContext()
        let read = Task { try await chat.loadActiveContext() }
        for _ in 0..<300 {
            if await transport.isHeld { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.isHeld)
        switch change {
        case "session": chat.currentSession = session("ses_2")
        case "roundTrip": chat.currentSession = session("ses_2"); chat.currentSession = session("ses_1")
        case "unload": chat.unloadSession(ifMatching: "ses_1")
        case "location": chat.currentSession = OCSession(id: "ses_1", directory: "/new", title: "Moved", time: .init(created: 0, updated: 0))
        case "binding": await api.updateContextDirectory("/new"); await api.updateContextDirectory("/work")
        case "disconnect": connection.disconnect()
        case "cancel": read.cancel()
        case "refresh": chat.replaceTranscript(.init(messages: [], contextEntries: [], entryOrder: []))
        case "model": chat.currentSession = OCSession(id: "ses_1", title: "Context", time: .init(created: 0, updated: 0), model: .init(id: "gpt", providerID: "openai", variant: nil))
        default: break
        }
        await transport.releaseContext()
        if change == "none" {
            #expect(chat.activeContextScope == scope)
            if failed {
                await #expect(throws: OpenCodeError.self) { try await read.value }
            } else {
                let result = try #require(try await read.value)
                #expect(result.entryOrder == ["msg_summary", "msg_user", "msg_reply"])
                #expect(result.messages.map(\.content) == ["Continue.", "Ready."])
            }
        } else if change == "binding" {
            #expect(chat.activeContextScope == scope)
            do {
                _ = try await read.value
                Issue.record("Expected a retryable context failure")
            } catch {
                #expect(error is OpenCodeError)
                #expect(error.localizedDescription == "Context changed while it was loading. Try again.")
            }
            await transport.setContext(#"{"data":[{"id":"msg_retried","type":"user","text":"Fresh context"}]}"#)
            #expect(try await chat.loadActiveContext()?.entryOrder == ["msg_retried"])
        } else {
            await #expect(throws: CancellationError.self) { try await read.value }
        }
        #expect(chat.contextEntries.isEmpty)
        #expect(chat.messages.isEmpty)
    }

    @Test(arguments: [404, 405, 501])
    func unsupportedContextEndpointIsUnavailableWithoutHistoryFallback(_ status: Int) async throws {
        let transport = ActiveContextTransport()
        await transport.setContext("", status: status)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let result = try await MessagesService(connection: connection).loadActiveContext(sessionID: "ses_1")
        #expect(result == nil)
        #expect(await transport.contextRequests().count == 1)
    }

    @Test(arguments: [401, 404, 500])
    func contextFailuresKeepServerReasonAndCanBeRetried(_ status: Int) async throws {
        let transport = ActiveContextTransport()
        await transport.setContext(#"{"_tag":"SessionNotFoundError","message":"Session is unavailable"}"#, status: status)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        do {
            _ = try await chat.loadActiveContext()
            Issue.record("Expected the server failure")
        } catch {
            #expect(error.localizedDescription == "Session is unavailable")
        }
        await transport.setContext(#"{"data":[]}"#)
        let result = try #require(try await chat.loadActiveContext())
        #expect(result.entryOrder.isEmpty)
        #expect(chat.messages.isEmpty)
    }

    @Test func historicalReplyUsageNeverBecomesV2ContextOccupancy() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        chat.providers = ScreenshotFixtures.providersResult.providers
        let reply = try JSONDecoder().decode(OCV2SessionMessage.self, from: Data(#"{"id":"msg_reply","type":"assistant","model":{"providerID":"anthropic","id":"claude-sonnet-4-20250514"},"tokens":{"input":90000,"output":10000,"cache":{"read":50000,"write":5000}},"content":[{"type":"text","text":"Old reply"}]}"#.utf8))
        chat.messages = [MessagesService.convert(try #require(reply.asMessage(sessionID: "ses_1")))]
        #expect(chat.contextUsageSummary == nil)
        #expect(chat.showsActiveContext)
    }

    @Test func disconnectedV2SessionKeepsUnknownOccupancyAndItsContextInspector() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = makeChat(connection)
        chat.currentSession = session("ses_1")
        chat.messages = [ChatMessage(role: .assistant, content: "Historical reply",
            tokens: .init(input: 90000, output: 10000, reasoning: nil, cache: nil))]
        connection.disconnect()
        #expect(chat.showsActiveContext)
        #expect(chat.contextUsageSummary == nil)
        await #expect(throws: OpenCodeError.self) { try await chat.loadActiveContext() }
    }

    private func session(_ id: String) -> OCSession {
        OCSession(id: id, title: "Context", time: .init(created: 0, updated: 0))
    }

    private func makeChat(_ connection: ConnectionManager) -> ChatClient {
        ChatClient(connection: connection, liveActivity: TestLiveActivityProvider(),
                   sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
                   providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
                   savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore())
    }

    @Test func activeProjectionIsSeparateFromFullHistoryAndRefreshesInServerOrder() async throws {
        let transport = ActiveContextTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, authHeader: "Bearer fixture",
                                 contextDirectory: "/work", transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = MessagesService(connection: connection)
        let history = try await service.loadTranscript(sessionID: "ses_1")
        let active = try await service.loadActiveContext(sessionID: "ses_1")
        #expect(history.entryOrder == ["msg_old"])
        #expect(active?.entryOrder == ["msg_summary", "msg_user", "msg_reply"])
        #expect(active?.contextEntries.first?.details == "Keep the feature branch.")
        #expect(active?.messages.map(\.content) == ["Continue.", "Ready."])
        await transport.setContext(#"{"data":[{"id":"msg_new","type":"user","text":"Updated on desktop."}]}"#)
        let refreshed = try await service.loadActiveContext(sessionID: "ses_1")
        #expect(refreshed?.entryOrder == ["msg_new"])
        #expect(history.entryOrder == ["msg_old"])
        let request = try #require(await transport.contextRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/session/ses_1/context")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    }
}

private actor ActiveContextTransport: OpenCodeTransport {
    private var context = #"{"data":[{"id":"msg_summary","type":"compaction","status":"completed","summary":"Keep the feature branch."},{"id":"msg_user","type":"user","text":"Continue."},{"type":"future","text":{}},{"id":"msg_reply","type":"assistant","content":[{"type":"text","text":"Ready."}]}]}"#
    private var requests: [URLRequest] = []
    private var history = #"{"data":[{"id":"msg_old","type":"user","text":"Old history."}],"cursor":{"next":null}}"#
    private var status = 200
    private var holds = false
    private var waiter: CheckedContinuation<Void, Never>?
    var isHeld: Bool { waiter != nil }
    func holdContext() { holds = true }
    func releaseContext() { holds = false; waiter?.resume(); waiter = nil }
    func setContext(_ body: String, status: Int = 200) { context = body; self.status = status }
    func setHistory(_ body: String) { history = body }
    func contextRequests() -> [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/context") == true } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let body: String
        var responseStatus = 200
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_1":
            body = #"{"_tag":"UnknownError","message":"Session temporarily offline"}"#
            responseStatus = 503
        case "/api/session/ses_1/context":
            body = context
            responseStatus = status
            if holds { await withCheckedContinuation { waiter = $0 } }
        case "/api/session/ses_2/context": body = #"{"data":[{"id":"msg_other","type":"user","text":"Another session."}]}"#
        case "/api/session/ses_1/message": body = history
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue,
                                     callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ActiveContextEventStream()
    }
}

nonisolated private final class ActiveContextEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
