import Foundation
import Testing
@testable import OpenLens

@MainActor
struct V2SubagentToolTests {
    @Test(arguments: ["sessionID", "sessionId", "session_id"])
    func validChildIdentifiersAndReleasedStatusesSurvivePreparation(_ key: String) throws {
        for status in ["running", "completed"] {
            let message = try preparedMessage(partEvent(metadata: [key: "ses_child", "status": status, "unrelated": ["large": String(repeating: "x", count: 10_000)]]))
            let part = try #require(message.parts.first)
            #expect(part.state?.metadata?[key]?.value as? String == "ses_child")
            #expect(part.state?.metadata?["status"]?.value as? String == status)
            #expect(part.state?.metadata?["unrelated"] == nil)
            guard case .subagent(let step) = message.assistantSegments.first?.kind else {
                Issue.record("Expected delegated work")
                return
            }
            if status == "running" {
                #expect(step.isActive)
                #expect(!step.isCompleted)
            } else {
                #expect(step.isCompleted)
                #expect(!step.isActive)
            }
        }
    }

    @Test func malformedAndUnknownMetadataKeepHistoryAndStreamReadable() async throws {
        let malformed: [Any] = [
            NSNull(), ["future"], "unexpected", 42,
            ["sessionID": 42, "status": ["running": true]],
            ["sessionID": "../child", "status": "future"],
            ["sessionID": String(repeating: "x", count: 257), "status": false]
        ]
        for metadata in malformed {
            let history = try await loadHistory(name: "subagent", metadata: metadata)
            let streamed = try preparedMessage(partEvent(metadata: metadata))
            for message in [history, streamed] {
                guard case .subagent(let step) = message.assistantSegments.first?.kind else {
                    Issue.record("Malformed advisory metadata must not hide delegated work")
                    return
                }
                #expect(step.isCompleted)
                #expect(!step.isError)
                #expect(step.detail == "Inspect the workspace")
            }
            #expect(streamed.parts.first?.state?.metadata == nil)
        }
    }

    @Test(arguments: ["", " ", ".", "..", "../child", "ses/child", "child?x=1", "child\n", "é", String(repeating: "x", count: 257)])
    func invalidChildIdentifierIsDroppedWithoutChangingRunningEvidence(_ identifier: String) throws {
        let message = try preparedMessage(partEvent(metadata: ["sessionID": identifier, "status": "running"]))
        #expect(message.parts.first?.state?.metadata?["sessionID"] == nil)
        #expect(message.parts.first?.state?.metadata?["status"]?.value as? String == "running")
        try expectWorking(message)
    }

    @Test func completedAndFailedV2CallsKeepTheirTerminalPresentation() throws {
        for outcome in ["success", "failed"] {
            var adapter = V2EventAdapter()
            _ = try adapter.event(event("session.tool.input.started", ["name": "subagent"]), directory: "/work")
            _ = try adapter.event(event("session.tool.called", ["input": ["agent": "explore", "description": "Inspect the workspace"]]), directory: "/work")
            let result = try #require(try adapter.event(event("session.tool.\(outcome)", [
                "metadata": ["sessionID": "ses_child", "status": outcome == "success" ? "completed" : "running"],
                "error": outcome == "failed" ? ["type": "unknown", "message": "Subagent failed"] : NSNull(),
                "content": [["type": "text", "text": "Result"]]
            ]), directory: "/work"))
            let message = try preparedMessage(result)
            guard case .subagent(let step) = message.assistantSegments.first?.kind else {
                Issue.record("Expected delegated work")
                return
            }
            #expect(step.isCompleted)
            #expect(!step.isActive)
            if outcome == "failed" { #expect(step.isError) } else { #expect(!step.isError) }
        }
    }

    @Test(arguments: ["task", "subagent"], ["sessionID", "sessionId", "session_id"])
    func launchedChildKeepsPermissionAndFormOwnership(_ name: String, _ key: String) throws {
        let chat = ChatClient(demoMode: true)
        chat.currentSession = OCSession(id: "ses_parent", title: "Parent", time: OCSessionTime(created: 1, updated: 1))
        chat.messages = [ChatMessage(id: "msg_parent", role: .assistant, content: "")]
        let handler = SSEEventHandler(haptics: HapticController(), liveActivityTracker: LiveActivityTracker(liveActivity: TestLiveActivityProvider()))
        handler.delegate = chat
        var adapter = V2EventAdapter()
        for (type, extra) in [
            ("session.tool.input.started", ["name": name] as [String: Any]),
            ("session.tool.called", ["input": ["agent": "explore", "description": "Inspect the workspace"]]),
            ("session.tool.progress", ["metadata": [key: "ses_child", "status": "running"]]),
            ("session.tool.success", ["metadata": [key: "ses_child", "status": "running"]])
        ] {
            if let event = try adapter.event(event(type, extra), directory: "/work") { handler.handleEvent(event) }
        }
        try expectWorking(try #require(chat.messages.first))
        handler.handleEvent(permissionEvent(sessionID: "ses_unrelated"))
        #expect(chat.pendingPermission == nil)
        handler.handleEvent(permissionEvent(sessionID: "ses_child"))
        #expect(chat.pendingPermission?.sessionID == "ses_child")
        #expect(chat.pendingPermission?.id == "per_child")
        chat.pendingPermission = nil
        handler.handleEvent(formEvent(sessionID: "ses_unrelated"))
        #expect(chat.pendingForm == nil)
        handler.handleEvent(formEvent(sessionID: "ses_child"))
        #expect(chat.pendingForm?.sessionID == "ses_child")
        #expect(chat.pendingForm?.id == "frm_child")
        handler.handleEvent(OCEvent(type: "form.replied", properties: AnyCodable(["sessionID": "ses_child", "id": "frm_child"])))
        #expect(chat.pendingForm == nil)
        // Links from the previous parent must not authorize requests in a new chat.
        chat.currentSession = OCSession(id: "ses_other_parent", title: "Other", time: OCSessionTime(created: 1, updated: 1))
        handler.handleEvent(permissionEvent(sessionID: "ses_child"))
        handler.handleEvent(formEvent(sessionID: "ses_child"))
        #expect(chat.pendingPermission == nil)
        #expect(chat.pendingForm == nil)
    }

    private func partEvent(metadata: Any) -> OCEvent {
        OCEvent(type: "message.part.updated", properties: AnyCodable(["part": [
            "id": "call_child", "sessionID": "ses_parent", "messageID": "msg_parent", "type": "tool",
            "tool": "subagent", "state": ["status": "completed", "metadata": metadata,
                "input": ["agent": "explore", "description": "Inspect the workspace"]]
        ]]))
    }

    private func permissionEvent(sessionID: String) -> OCEvent {
        OCEvent(type: "permission.asked", properties: AnyCodable([
            "id": "per_child", "sessionID": sessionID, "action": "shell", "resources": ["pwd"]
        ]))
    }

    private func formEvent(sessionID: String) -> OCEvent {
        OCEvent(type: "form.created", properties: AnyCodable(["form": [
            "id": "frm_child", "sessionID": sessionID, "title": "Continue?",
            "fields": [["key": "approved", "type": "boolean"]]
        ]]))
    }

    @Test(arguments: ["task", "subagent"])
    func pendingLaunchWithoutInputStillShowsDelegatedWork(_ name: String) throws {
        let raw = OCEvent(type: "message.part.updated", properties: AnyCodable(["part": [
            "id": "call_child", "sessionID": "ses_parent", "messageID": "msg_parent", "type": "tool",
            "tool": name, "state": ["status": "pending", "metadata": ["status": ["future": true]]]
        ]]))
        let message = try preparedMessage(raw)
        try expectWorking(message)
        #expect(message.assistantSegments.count == 1)
    }

    @Test(arguments: ["task", "subagent"])
    func successfulBackgroundLaunchStaysWorkingInHistoryAndStream(_ name: String) async throws {
        let message = try await loadHistory(name: name, metadata: ["sessionID": "ses_child", "status": "running"])
        try expectWorking(message)

        var adapter = V2EventAdapter()
        _ = try adapter.event(event("session.tool.input.started", ["name": name]), directory: "/work")
        _ = try adapter.event(event("session.tool.called", ["input": ["agent": "explore", "description": "Inspect the workspace"]]), directory: "/work")
        let success = try #require(try adapter.event(event("session.tool.success", [
            "metadata": ["sessionID": "ses_child", "status": "running"],
            "content": [["type": "text", "text": "Working in the background"]]
        ]), directory: "/work"))
        guard case .partUpdated(let part, _, _, _) = SSEInboundEvent.prepare(success, retainingRawEvent: false) else {
            Issue.record("Expected prepared subagent launch")
            return
        }
        #expect(part.state?.status == .completed)
        #expect(part.state?.metadata?["sessionID"]?.value as? String == "ses_child")
        #expect(part.state?.metadata?["status"]?.value as? String == "running")
        try expectWorking(ChatMessage(id: "msg_parent", role: .assistant, content: "", parts: [part]))
    }

    private func expectWorking(_ message: ChatMessage) throws {
        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected delegated-work presentation")
            return
        }
        #expect(step.isActive)
        #expect(!step.isCompleted)
        #expect(!step.isError)
    }

    private func event(_ type: String, _ extra: [String: Any]) -> [String: Any] {
        let identity: [String: Any] = ["sessionID": "ses_parent", "assistantMessageID": "msg_parent", "id": "call_child"]
        return ["type": type, "data": identity.merging(extra) { $1 }, "location": ["directory": "/work"]]
    }

    private func preparedMessage(_ event: OCEvent) throws -> ChatMessage {
        guard case .partUpdated(let part, _, _, _) = SSEInboundEvent.prepare(event, retainingRawEvent: false) else {
            throw OpenCodeError.invalidPayload("Expected prepared activity part")
        }
        return ChatMessage(id: "msg_parent", role: .assistant, content: "", parts: [part])
    }

    @Test(arguments: ["task", "subagent"])
    func historyShowsDelegatedWorkForBothToolNames(_ name: String) async throws {
        let message = try await loadHistory(name: name)
        guard case .subagent(let step) = message.assistantSegments.first?.kind else {
            Issue.record("Expected delegated-work presentation for \(name)")
            return
        }
        #expect(step.title == "explore")
        #expect(step.detail == "Inspect the workspace")
        #expect(step.isCompleted)
        #expect(!step.isActive)
        #expect(!step.isError)
    }

    private func loadHistory(name: String, metadata: Any = ["sessionID": "ses_child", "status": "completed"]) async throws -> ChatMessage {
        let page = try JSONSerialization.data(withJSONObject: ["data": [[
            "id": "msg_parent", "type": "assistant", "time": ["created": 1],
            "agent": "build", "model": ["id": "test", "providerID": "test"], "finish": "stop",
            "content": [["id": "call_child", "type": "tool", "name": name, "state": [
                "status": "completed", "input": ["agent": "explore", "description": "Inspect the workspace"],
                "metadata": metadata
            ]]]
        ]], "cursor": ["next": NSNull()]])
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/session/ses_parent/message": .init(statusCode: 200, body: page)
        ])
        let client = OpenCodeClient(baseURL: URL(string: "http://opencode.example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let messages = try await MessagesService(connection: connection).loadMessages(sessionID: "ses_parent")
        return try #require(messages.first)
    }
}
