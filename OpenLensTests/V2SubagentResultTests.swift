import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2SubagentResultTests {
    @Test(arguments: ["completed", "error", "cancelled"])
    func terminalResultsAreReadableInParentHistoryBeforeAnotherResponse(_ state: String) async throws {
        let transport = SubagentResultTransport()
        await transport.setHistory(Self.history(state: state))
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(chat.messages.map(\.id) == ["msg_launch"])
        let result = try #require(chat.contextEntries.first)
        #expect(result.id == "msg_result")
        #expect(result.title == "Subagent · \(state == "error" ? "Failed" : state.capitalized)")
        #expect(result.summary.contains("review"))
        #expect(result.details == "Useful child result.\nSecond line.")
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == ["message-msg_launch-part-call_child", "context-msg_result"])
    }

    @Test(arguments: ["completed", "error", "cancelled"], ["sessionID", "sessionId", "session_id"])
    func resultReconcilesOnlyTheMatchingChildAndSurvivesReopening(_ state: String, _ childKey: String) async throws {
        let transport = SubagentResultTransport()
        var page = try #require(JSONSerialization.jsonObject(with: Data(Self.history(state: state, childKey: childKey).utf8)) as? [String: Any])
        var records = try #require(page["data"] as? [[String: Any]])
        var launch = records[0]
        launch["id"] = "msg_unrelated"
        var tool = try #require((launch["content"] as? [[String: Any]])?.first)
        tool["id"] = "call_unrelated"
        var toolState = try #require(tool["state"] as? [String: Any])
        toolState["metadata"] = [childKey: "ses_other", "status": "running"]
        tool["state"] = toolState
        launch["content"] = [tool]
        records.insert(launch, at: 1)
        page["data"] = records
        await transport.setHistory(String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self))
        let chat = try await makeChat(transport)
        for _ in 0..<2 {
            #expect(await chat.loadMessages())
            let result = try #require(chat.contextEntries.first?.subagentResult)
            #expect(result.childID == "ses_child")
            #expect(result.agent == "review")
            #expect(result.state?.rawValue == state)
            let matched = try subagentStep(chat.messages[0])
            #expect(matched.resultState?.rawValue == state)
            #expect(matched.isCompleted)
            #expect(!matched.isActive)
            #expect(matched.isError == (state == "error"))
            #expect(try subagentStep(chat.messages[1]).isActive)
            #expect(chat.contextEntries.count == 1)
            chat.unloadSession(ifMatching: "ses_parent")
            chat.currentSession = OCSession(id: "ses_parent", title: "Reopened", time: .init(created: 0, updated: 0))
        }
    }

    @Test(arguments: ["completed", "error", "cancelled"])
    func nativeSyntheticDeliveryConvergesWithHistoryWithoutAnotherAssistant(_ state: String) async throws {
        let transport = SubagentResultTransport()
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(try subagentStep(chat.messages[0]).isActive)
        await transport.setHistory(Self.history(state: state))
        var adapter = V2EventAdapter()
        let native: [String: Any] = [
            "id": "evt_result", "type": "session.synthetic", "location": ["directory": "/work"],
            "data": ["sessionID": "ses_parent", "text": "Event text is not a second notification",
                     "metadata": ["source": "subagent", "childID": "ses_child", "agent": "review", "state": state]]
        ]
        let event = try #require(try adapter.event(native, directory: "/work"))
        let inbound = SSEInboundEvent.prepare(event, retainingRawEvent: false) ?? .raw(event)
        chat.receiveStreamEvent(inbound)
        chat.receiveStreamEvent(inbound)
        #expect(!chat.isStreamSynchronized)
        try await waitUntil { chat.isStreamSynchronized }
        #expect(chat.errorMessage == nil)
        #expect(chat.messages.map(\.id) == ["msg_launch"])
        #expect(chat.contextEntries.map(\.id) == ["msg_result"])
        #expect(chat.contextEntries.first?.details == "Useful child result.\nSecond line.")
        #expect(try subagentStep(chat.messages[0]).isCompleted)
        #expect(chat.timelineItems(showsThinking: false).filter { $0.id == "context-msg_result" }.count == 1)
        let requests = await transport.requestCount()
        var unrelated = native
        unrelated["data"] = ["sessionID": "ses_other"]
        let other = try #require(try adapter.event(unrelated, directory: "/work"))
        chat.receiveStreamEvent(SSEInboundEvent.prepare(other, retainingRawEvent: false) ?? .raw(other))
        #expect(chat.isStreamSynchronized)
        #expect(await transport.requestCount() == requests)
        #expect(await chat.loadMessages())
        #expect(chat.contextEntries.map(\.id) == ["msg_result"])
    }

    @Test func anOldResultDoesNotCompleteALaterLaunchOfTheSameChild() async throws {
        let transport = SubagentResultTransport()
        var page = try #require(JSONSerialization.jsonObject(with: Data(Self.history(state: "completed").utf8)) as? [String: Any])
        var records = try #require(page["data"] as? [[String: Any]])
        var later = records[0]
        later["id"] = "msg_later_launch"
        records.append(later)
        page["data"] = records
        await transport.setHistory(String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self))
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(try subagentStep(chat.messages[0]).isCompleted)
        #expect(try subagentStep(chat.messages[1]).isActive)
        #expect(chat.contextEntries.count == 1)
    }

    @Test func unknownSourcesAndStatesStayNeutralWithoutCompletingChildCards() async throws {
        let transport = SubagentResultTransport()
        let cases: [[String: Any]] = [
            ["source": "other", "childID": "ses_child", "agent": "review", "state": "completed"],
            ["childID": "ses_child", "agent": "review", "state": "completed"],
            ["source": ["subagent"], "childID": "ses_child", "state": "completed"],
            ["source": "subagent", "childID": "ses_child", "agent": "review", "state": "future"],
            ["source": "subagent", "childID": "ses_child", "state": true]
        ]
        for metadata in cases {
            await transport.setHistory(try replacingResultMetadata(metadata))
            let chat = try await makeChat(transport)
            #expect(await chat.loadMessages())
            #expect(chat.messages.count == 1)
            #expect(try subagentStep(chat.messages[0]).isActive)
            let entry = try #require(chat.contextEntries.first)
            #expect(entry.details == "Unfamiliar result text")
            let supportedSource = metadata["source"] as? String == "subagent"
            #expect(entry.title == (supportedSource ? "Subagent · Result" : "Session update"))
            #expect(entry.subagentResult?.state == nil)
        }
    }

    @Test func malformedMetadataAndUnsafeChildIDsDoNotInvalidateParentHistory() async throws {
        let transport = SubagentResultTransport()
        let malformed: [Any] = [NSNull(), ["subagent"], 42, "subagent",
            ["source": "subagent", "childID": "../child", "state": "completed"],
            ["source": "subagent", "childID": String(repeating: "x", count: 257), "state": "error"],
            ["source": "subagent", "childID": true, "agent": ["review"], "state": "cancelled"]]
        for metadata in malformed {
            await transport.setHistory(try replacingResultMetadata(metadata))
            let chat = try await makeChat(transport)
            #expect(await chat.loadMessages())
            #expect(chat.contextEntries.first?.details == "Unfamiliar result text")
            #expect(chat.contextEntries.first?.subagentResult?.childID == nil)
            #expect(try subagentStep(chat.messages[0]).isActive)
        }
    }

    @Test func overlappingHistoryUpdatesOneResultInPlaceAheadOfALaterReply() async throws {
        let transport = SubagentResultTransport()
        let first = Self.history(state: "completed").replacingOccurrences(of: #""next":null"#, with: #""next":"next""#)
        await transport.setPages(first: first, second: #"""
        {"data":[
          {"id":"msg_result","type":"synthetic","description":"Review changes","text":"Provider offline","metadata":{"source":"subagent","childID":"ses_child","agent":"review","state":"error"}},
          {"id":"msg_reply","type":"assistant","content":[{"type":"text","text":"The review failed."}]}
        ],"cursor":{"next":null}}
        """#)
        let chat = try await makeChat(transport)
        for _ in 0..<2 {
            #expect(await chat.loadMessages())
            #expect(chat.contextEntries.map(\.id) == ["msg_result"])
            #expect(chat.contextEntries.first?.details == "Provider offline")
            #expect(try subagentStep(chat.messages[0]).isError)
            #expect(chat.timelineItems(showsThinking: false).map(\.id) == ["message-msg_launch-part-call_child", "context-msg_result", "message-msg_reply-part-msg_reply-0"])
        }
    }

    @Test func revertingBeforeTheResultKeepsTheLaunchWorking() async throws {
        let transport = SubagentResultTransport()
        await transport.setHistory(Self.history(state: "completed"))
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        #expect(try subagentStep(chat.messages[0]).isCompleted)
        chat.currentSession = OCSession(id: "ses_parent", title: "Reverted", time: .init(created: 0, updated: 0), revert: .init(messageID: "msg_result"))
        #expect(await chat.loadMessages())
        #expect(chat.contextEntries.isEmpty)
        #expect(try subagentStep(chat.messages[0]).isActive)
    }

    @Test func resultPreviewsAreBoundedAndKeepReadableUnicode() async throws {
        let transport = SubagentResultTransport()
        var page = try #require(JSONSerialization.jsonObject(with: Data(Self.history(state: "completed").utf8)) as? [String: Any])
        var records = try #require(page["data"] as? [[String: Any]])
        records[1]["text"] = String(repeating: "🧪 check passed\n", count: 4_000)
        page["data"] = records
        await transport.setHistory(String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self))
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        let text = try #require(chat.contextEntries.first?.details)
        #expect(text.count <= 40_000)
        #expect(text.hasPrefix("🧪 check passed\n"))
        #expect(text.hasSuffix("Preview shortened."))
        #expect(!text.contains("�"))
    }

    private func replacingResultMetadata(_ metadata: Any) throws -> String {
        var page = try #require(JSONSerialization.jsonObject(with: Data(Self.history(state: "completed").utf8)) as? [String: Any])
        var records = try #require(page["data"] as? [[String: Any]])
        records[1]["metadata"] = metadata
        records[1]["text"] = "Unfamiliar result text"
        page["data"] = records
        return String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
    }

    @Test func aStreamingLaunchKeepsItsResultAfterLateRunningToolEvidence() async throws {
        let transport = SubagentResultTransport()
        await transport.setActive(true)
        let chat = try await makeChat(transport)
        #expect(await chat.loadMessages())
        chat.beginExternalResponse()
        let pending = ChatMessage(id: "msg_launch", role: .assistant, content: "", parts: chat.messages[0].parts, isStreaming: true)
        chat.pendingAssistantMessage = pending
        await transport.setHistory(Self.history(state: "cancelled"))
        #expect(await chat.loadMessages())
        #expect(chat.pendingAssistantMessage === pending)
        #expect(pending.isStreaming)
        #expect(try subagentStep(pending).resultState == .cancelled)
        let stale = OCEvent(type: "message.part.updated", properties: AnyCodable(["part": [
            "id": "call_child", "sessionID": "ses_parent", "messageID": "msg_launch", "type": "tool", "tool": "subagent",
            "state": ["status": "completed", "metadata": ["sessionID": "ses_child", "status": "running"],
                      "input": ["agent": "review", "description": "Review changes"]]
        ]]))
        let inbound = try #require(SSEInboundEvent.prepare(stale, retainingRawEvent: false))
        chat.receiveStreamEvent(inbound)
        #expect(try subagentStep(pending).resultState == .cancelled)
        #expect(!pending.assistantSegments.contains { segment in
            if case .subagent(let step) = segment.kind { return step.isActive }
            return false
        })
        #expect(chat.timelineItems(showsThinking: false).map(\.id) == ["message-msg_launch-part-call_child", "context-msg_result"])
        chat.unloadSession(ifMatching: "ses_parent")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for background result recovery")
    }

    private func subagentStep(_ message: ChatMessage) throws -> ChatMessage.PersistedSubagentStep {
        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            throw OpenCodeError.invalidPayload("Expected delegated work card")
        }
        return step
    }

    private func makeChat(_ transport: SubagentResultTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = OCSession(id: "ses_parent", title: "Delegated work", time: .init(created: 0, updated: 0))
        return chat
    }

    nonisolated static func history(state: String, withResult: Bool = true, childKey: String = "sessionID") -> String {
        let result = withResult ? #"""
        ,{"id":"msg_result","type":"synthetic","time":{"created":2},"description":"Review changes","text":"<subagent sessionID=\"ses_child\" state=\"\#(state)\" description=\"Review changes\">\nUseful child result.\nSecond line.\n</subagent>","metadata":{"source":"subagent","childID":"ses_child","agent":"review","state":"\#(state)"}}
        """# : ""
        return #"""
        {"data":[{"id":"msg_launch","type":"assistant","time":{"created":1},"content":[{"id":"call_child","type":"tool","name":"subagent","state":{"status":"completed","input":{"agent":"review","description":"Review changes"},"content":[{"type":"text","text":"Background job started"}],"metadata":{"\#(childKey)":"ses_child","status":"running"}}}]}\#(result)],"cursor":{"next":null}}
        """#
    }
}

private actor SubagentResultTransport: OpenCodeTransport {
    private var history = V2SubagentResultTests.history(state: "completed", withResult: false)
    private var continuationPage: String?
    func setPages(first: String, second: String) { history = first; continuationPage = second }
    private var active = false
    func setActive(_ value: Bool) { active = value }
    private var requests = 0
    func requestCount() -> Int { requests }
    func setHistory(_ value: String) { history = value }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let url = request.url!
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/session/ses_parent/message":
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            body = cursor == nil ? history : (continuationPage ?? history)
        case "/api/session/ses_parent": body = #"{"data":{"id":"ses_parent","title":"Delegated work","time":{"created":0,"updated":0}}}"#
        case "/api/session/active": body = active ? #"{"data":{"ses_parent":{"type":"busy"}}}"# : #"{"data":{}}"#
        case "/api/session/ses_parent/inbox", "/api/session/ses_parent/permission", "/api/session/ses_parent/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        SubagentResultEventStream()
    }
}

nonisolated private final class SubagentResultEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
