import Foundation
import Testing
import SwiftUI
import UIKit
@testable import OpenLens

@Suite(.serialized)
struct OpenCodeV2FormTests {
    @MainActor @Test func canonicalLocationRefreshReplacesOldFormsEvenIfTheRememberedReadFails() async throws {
        func body(_ id: String) -> Data {
            Data("""
            {"location":{"directory":"/canonical"},"data":[
              {"id":"\(id)","sessionID":"global","title":"MCP","fields":[{"key":"ok","type":"boolean"}]}
            ]}
            """.utf8)
        }
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)],
            "GET /api/permission/request /alias": Array(repeating: .init(statusCode: 200,
                body: Data(#"{"location":{"directory":"/canonical"},"data":[]}"#.utf8)), count: 2),
            "GET /api/form /alias": [.init(statusCode: 200, body: body("frm_old")), .init(statusCode: 200, body: body("frm_new"))],
            "GET /api/form /canonical": [.init(statusCode: 503, body: Data())],
        ], matchesLocation: true)
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/alias", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        let initial = try await inbox.loadInbox()
        #expect(initial.globalForms.map(\.id) == ["frm_old"])
        let refreshed = try await inbox.loadInbox()
        #expect(refreshed.warning != nil)
        #expect(refreshed.globalForms.map(\.id) == ["frm_new"])
        #expect(refreshed.globalForms.first?.globalDirectory == "/canonical")
    }

    @MainActor @Test func overlappingInboxLoadsUseTheNewWorkspaceAfterAHeldOldWorkspaceRead() async throws {
        let gate = FormReadGate()
        let a = Data(#"""
        {"location":{"directory":"/a"},"data":[
          {"id":"frm_global","sessionID":"global","title":"MCP A","fields":[{"key":"ok","type":"boolean"}]},
          {"id":"frm_a","sessionID":"ses_a","title":"Session A","fields":[{"key":"ok","type":"boolean"}]}
        ]}
        """#.utf8)
        let b = Data(#"""
        {"location":{"directory":"/b"},"data":[
          {"id":"frm_b","sessionID":"ses_b","title":"Session B","fields":[{"key":"ok","type":"boolean"}]}
        ]}
        """#.utf8)
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)],
            "GET /api/permission/request /a": [.init(statusCode: 200, body: Data(#"{"location":{"directory":"/a"},"data":[]}"#.utf8))],
            "GET /api/permission/request /b": [.init(statusCode: 200, body: Data(#"{"location":{"directory":"/b"},"data":[]}"#.utf8))],
            "GET /api/form /a": Array(repeating: .init(statusCode: 200, body: a), count: 2),
            "GET /api/form /b": [.init(statusCode: 200, body: b)],
        ], matchesLocation: true, gate: gate)
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/a", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        async let oldRead = inbox.loadInbox()
        for _ in 0..<500 {
            if await gate.isHeld { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isHeld)
        await connection.setProjectContext(directory: "/b")
        async let newRead = inbox.loadInbox()
        await gate.release()
        for snapshot in try await [oldRead, newRead] {
            #expect(snapshot.warning == nil)
            #expect(snapshot.globalForms.first?.globalDirectory == "/a")
            #expect(snapshot.sessionForms.map(\.id) == ["frm_b"])
        }
    }

    @MainActor @Test func inboxDeduplicatesGlobalFormsByLocationAndIDAndRetainsThemOnFailedReads() async throws {
        func body(_ directory: String, includeGlobal: Bool = true) -> Data {
            Data("""
            {"location":{"directory":"\(directory)"},"data":[
              {"id":"frm_session","sessionID":"ses\(directory.dropFirst())","title":"Session","fields":[{"key":"ok","type":"boolean"}]}
              \(includeGlobal ? #",{"id":"frm_shared","sessionID":"global","title":"MCP","fields":[{"key":"ok","type":"boolean"}]},{"id":"frm_shared","sessionID":"global","title":"MCP","fields":[{"key":"ok","type":"boolean"}]}"# : "")
            ]}
            """.utf8)
        }
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)],
            "GET /api/permission/request /a": [.init(statusCode: 200, body: Data(#"{"location":{"directory":"/a"},"data":[]}"#.utf8))],
            "GET /api/permission/request /b": Array(repeating: .init(statusCode: 200,
                body: Data(#"{"location":{"directory":"/b"},"data":[]}"#.utf8)), count: 3),
            "GET /api/form /a": [.init(statusCode: 200, body: body("/a")), .init(statusCode: 503, body: Data()),
                .init(statusCode: 200, body: body("/a", includeGlobal: false))],
            "GET /api/form /b": Array(repeating: .init(statusCode: 200, body: body("/b")), count: 3),
        ], matchesLocation: true)
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/a", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        let initial = try await inbox.loadInbox()
        #expect(initial.globalForms.count == 1)
        await connection.setProjectContext(directory: "/b")
        let failed = try await inbox.loadInbox()
        #expect(failed.warning != nil)
        #expect(failed.globalForms.count == 2)
        #expect(Set(failed.globalForms.compactMap(\.globalDirectory)) == ["/a", "/b"])
        #expect(failed.sessionForms.map(\.sessionID) == ["sesb"])
        let settled = try await inbox.loadInbox()
        #expect(settled.warning == nil)
        #expect(settled.globalForms.count == 1)
        #expect(settled.globalForms.first?.globalDirectory == "/b")
        _ = try await inbox.loadInbox()
        #expect(transport.recordedRequests().filter { $0.path == "/api/form" && $0.queryItems["location[directory]"] == "/a" }.count == 3)
    }

    @MainActor @Test func inboxRecoversRememberedGlobalFormsAfterChatSwitchesWorkspaceAndForgetsSettledLocations() async throws {
        func located(_ directory: String, _ ids: [(String, String)]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["location": ["directory": directory], "data": ids.map { id, owner in
                ["id": id, "sessionID": owner, "title": id, "fields": [["key": "ok", "type": "boolean"]]] as [String: Any]
            }])
        }
        let pendingA = try located("/a", [("frm_reply", "global"), ("frm_cancel", "global"), ("frm_a_session", "ses_a")])
        let cancelA = try located("/a", [("frm_cancel", "global"), ("frm_a_session", "ses_a")])
        let settledA = try located("/a", [("frm_a_session", "ses_a")])
        let pendingB = try located("/b", [("frm_b_session", "ses_b")])
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)],
            "GET /api/permission/request /a": [.init(statusCode: 200, body: try located("/a", []))],
            "GET /api/permission/request /b": Array(repeating: .init(statusCode: 200, body: try located("/b", [])), count: 4),
            "GET /api/form /a": [.init(statusCode: 200, body: pendingA), .init(statusCode: 200, body: pendingA),
                .init(statusCode: 200, body: cancelA), .init(statusCode: 200, body: settledA)],
            "GET /api/form /b": Array(repeating: .init(statusCode: 200, body: pendingB), count: 4),
            "POST /api/session/global/form/frm_reply/reply": [.init(statusCode: 204, body: Data())],
            "DELETE /api/session/global/form/frm_cancel": [.init(statusCode: 204, body: Data())],
        ], matchesLocation: true)
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/a", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        let initial = try await inbox.loadInbox()
        #expect(initial.globalForms.map(\.id) == ["frm_reply", "frm_cancel"])
        let chat = ChatClient(connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore())
        // Exercise the production workspace-restoration path called when opening a chat.
        await chat.restoreProjectContext(for: OCSession(id: "ses_b", directory: "/b", title: "Chat in B", time: .init(created: 0, updated: 0)))
        #expect(await client.currentContextDirectory() == "/b")
        let switched = try await inbox.loadInbox()
        #expect(switched.warning == nil)
        #expect(switched.globalForms.map(\.id) == ["frm_reply", "frm_cancel"])
        #expect(switched.sessionForms.map(\.id) == ["frm_b_session"])
        #expect(switched.pendingRequestCount == 3)
        let reply = try #require(switched.globalForms.first { $0.id == "frm_reply" })
        try await inbox.respondToForm(reply, answer: ["ok": .boolean(false)])
        let afterReply = try await inbox.loadInbox()
        #expect(afterReply.globalForms.map(\.id) == ["frm_cancel"])
        try await inbox.cancelForm(try #require(afterReply.globalForms.first))
        let afterCancel = try await inbox.loadInbox()
        #expect(afterCancel.globalForms.isEmpty)
        #expect(afterCancel.sessionForms.map(\.id) == ["frm_b_session"])
        let requestsBeforeFinalLoad = transport.recordedRequests().count
        _ = try await inbox.loadInbox()
        let finalRequests = transport.recordedRequests().dropFirst(requestsBeforeFinalLoad)
        #expect(!finalRequests.contains { $0.path == "/api/form" && $0.queryItems["location[directory]"] == "/a" })
        let operations = transport.recordedRequests().filter { $0.method != "GET" }
        #expect(operations.map(\.path) == ["/api/session/global/form/frm_reply/reply", "/api/session/global/form/frm_cancel"])
        #expect(operations.allSatisfy { $0.queryItems == ["location[directory]": "/a"] })
    }

    @MainActor @Test(arguments: [
        #"{"key":"future","type":"server-control","title":"Future control"}"#,
        #"{"key":"future","type":"string","when":[{"key":"ok","op":"future","value":true}]}"#,
    ])
    func unsupportedGlobalFormsKeepTheFallbackAndCanStillBeCancelled(field: String) async throws {
        let wire = Data("""
        {"location":{"directory":"/workspace/mcp"},"data":[
          {"id":"frm_global","sessionID":"global","title":"MCP","fields":[
            {"key":"ok","type":"boolean"},\(field)
          ]}
        ]}
        """.utf8)
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: wire), .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        let form = try #require(try await client.listPendingForms().first)
        #expect(form.hasUnsupportedFields)
        #expect(form.owner == .global(directory: "/workspace/mcp"))
        await #expect(throws: OpenCodeError.self) { try await inbox.respondToForm(form, answer: ["ok": .boolean(true)]) }
        #expect(transport.recordedRequests().count == 2)
        try await inbox.cancelForm(form)
        let cancellation = try #require(transport.recordedRequests().last)
        #expect(cancellation.method == "DELETE")
        #expect(cancellation.path == "/api/session/global/form/frm_global")
        #expect(cancellation.queryItems == ["location[directory]": "/workspace/mcp"])
    }

    @MainActor @Test func unboundGlobalOwnersAndUnsafeRouteTokensNeverReachTransport() async throws {
        let transport = V2FormTransport(responses: [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)])
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        // A location embedded in an untrusted event/form cannot override recovery.
        let unbound = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {"id":"frm_global","sessionID":"global","globalDirectory":"/forged",
         "title":"MCP","fields":[{"key":"ok","type":"boolean"}]}
        """#.utf8))
        #expect(unbound.owner == .global(directory: nil))
        let inbox = InboxService(connection: connection)
        await #expect(throws: OpenCodeError.self) { try await inbox.respondToForm(unbound, answer: ["ok": .boolean(true)]) }
        await #expect(throws: OpenCodeError.self) { try await inbox.cancelForm(unbound) }
        for directory in ["", "relative/path", "/bad\0path", "/" + String(repeating: "x", count: 4_096)] {
            await #expect(throws: OpenCodeError.self) { _ = try await client.listPendingForms(directory: directory) }
            await #expect(throws: OpenCodeError.self) {
                try await client.replyToForm(owner: .global(directory: directory), formID: "frm_global", answer: [:])
            }
            await #expect(throws: OpenCodeError.self) {
                try await client.cancelForm(owner: .global(directory: directory), formID: "frm_global")
            }
        }
        for id in ["../escape", "frm/other", "frm?owner=global"] {
            await #expect(throws: OpenCodeError.self) {
                try await client.cancelForm(owner: .global(directory: "/workspace/mcp"), formID: id)
            }
        }
        await #expect(throws: OpenCodeError.self) { try await client.replyToForm(sessionID: "global", formID: "frm_global", answer: [:]) }
        await #expect(throws: OpenCodeError.self) { try await client.cancelForm(sessionID: "global", formID: "frm_global") }
        await #expect(throws: OpenCodeError.self) {
            _ = try await client.listPendingForms(sessionID: "ses_owner", directory: "/workspace/mcp")
        }
        #expect(transport.recordedRequests().map(\.path) == ["/api/info"])
    }

    @MainActor @Test func v1InboxStillRecoversLegacyInteractionsWithoutAnyGlobalFormRoutes() async throws {
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 404, body: Data())],
            "GET /global/health": [.init(statusCode: 200, body: OpenCodeContractFixtures.v1HealthResponse)],
            "GET /permission": [.init(statusCode: 200, body: Data("[]".utf8))],
            "GET /question": [.init(statusCode: 200, body: Data("[]".utf8))],
        ])
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let snapshot = try await InboxService(connection: connection).loadInbox()
        #expect(snapshot.warning == nil)
        #expect(snapshot.forms.isEmpty)
        #expect(snapshot.pendingRequestCount == 0)
        await #expect(throws: OpenCodeError.self) {
            try await client.replyToForm(owner: .global(directory: "/workspace/mcp"), formID: "frm_global", answer: [:])
        }
        await #expect(throws: OpenCodeError.self) {
            try await client.cancelForm(owner: .global(directory: "/workspace/mcp"), formID: "frm_global")
        }
        #expect(Set(transport.recordedRequests().map(\.path)) == ["/api/info", "/global/health", "/permission", "/question"])
    }

    @MainActor @Test func inboxSeparatesGlobalFormsAndRecoversAfterLoadReplyAndCancelFailures() async throws {
        let located = Data(#"""
        {"location":{"directory":"/canonical/mcp"},"data":[
          {"id":"frm_global","sessionID":"global","title":"MCP","fields":[{"key":"ok","type":"boolean"}]},
          {"id":"frm_cancel","sessionID":"global","title":"Cancel MCP","fields":[{"key":"ok","type":"boolean"}]},
          {"id":"frm_session","sessionID":"ses_owner","title":"Session","fields":[{"key":"ok","type":"boolean"}]}
        ]}
        """#.utf8)
        let transport = V2FormTransport(pathResponses: [
            "GET /api/info": [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)],
            "GET /api/permission/request /canonical/mcp": Array(repeating: .init(statusCode: 200,
                body: Data(#"{"location":{"directory":"/canonical/mcp"},"data":[]}"#.utf8)), count: 2),
            "GET /api/permission/request /another/chat": [.init(statusCode: 200,
                body: Data(#"{"location":{"directory":"/another/chat"},"data":[]}"#.utf8))],
            "GET /api/form /canonical/mcp": [.init(statusCode: 503, body: Data()),
                .init(statusCode: 200, body: located), .init(statusCode: 200, body: Data(#"""
                {"location":{"directory":"/canonical/mcp"},"data":[
                  {"id":"frm_cancel","sessionID":"global","title":"Cancel MCP","fields":[{"key":"ok","type":"boolean"}]}
                ]}
                """#.utf8))],
            "GET /api/form /another/chat": [.init(statusCode: 200,
                body: Data(#"{"location":{"directory":"/another/chat"},"data":[]}"#.utf8))],
            "POST /api/session/global/form/frm_global/reply": [
                .init(statusCode: 503, body: Data()), .init(statusCode: 204, body: Data())],
            "DELETE /api/session/global/form/frm_cancel": [
                .init(statusCode: 503, body: Data()), .init(statusCode: 204, body: Data())],
        ], matchesLocation: true)
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!,
            contextDirectory: "/canonical/mcp", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let inbox = InboxService(connection: connection)
        let failed = try await inbox.loadInbox()
        #expect(failed.forms.isEmpty)
        #expect(failed.warning != nil)
        let recovered = try await inbox.loadInbox()
        #expect(recovered.warning == nil)
        #expect(recovered.globalForms.map(\.id) == ["frm_global", "frm_cancel"])
        #expect(recovered.sessionForms.map(\.id) == ["frm_session"])
        #expect(recovered.pendingRequestCount == 3)
        let global = try #require(recovered.globalForms.first)
        #expect(global.owner == .global(directory: "/canonical/mcp"))
        await client.updateContextDirectory("/another/chat")
        await #expect(throws: OpenCodeError.self) { try await inbox.respondToForm(global, answer: ["ok": .boolean(true)]) }
        try await inbox.respondToForm(global, answer: ["ok": .boolean(false)])
        let reopened = try await inbox.loadInbox()
        #expect(reopened.warning == nil)
        #expect(reopened.globalForms.map(\.id) == ["frm_cancel"])
        #expect(reopened.sessionForms.isEmpty)
        let cancel = try #require(reopened.globalForms.first)
        await #expect(throws: OpenCodeError.self) { try await inbox.cancelForm(cancel) }
        try await inbox.cancelForm(cancel)
        let operations = transport.recordedRequests().filter { $0.method != "GET" }
        #expect(operations.count == 4)
        #expect(operations.allSatisfy { $0.queryItems == ["location[directory]": "/canonical/mcp"] })
        #expect(operations.map(\.method) == ["POST", "POST", "DELETE", "DELETE"])
        #expect(!transport.recordedRequests().contains { $0.path.hasPrefix("/api/question") })
    }

    @MainActor @Test func chatRecoveryNeverTreatsGlobalAsASessionOwner() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(#"""
            {"data":[
              {"id":"frm_global","sessionID":"global","title":"MCP","fields":[{"key":"ok","type":"boolean"}]},
              {"id":"frm_foreign","sessionID":"ses_foreign","title":"Foreign","fields":[{"key":"ok","type":"boolean"}]},
              {"id":"frm_owner","title":"Owner","fields":[{"key":"ok","type":"boolean"}]}
            ]}
            """#.utf8)),
        ])
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let questions = QuestionService(connection: connection)
        let ordinary = try #require(try await questions.recoverPendingForm(sessionID: "ses_owner"))
        #expect(ordinary.id == "frm_owner")
        #expect(ordinary.owner == .session("ses_owner"))
        let global = OCFormRequest(id: "frm_global", sessionID: "global", title: "MCP", fields: ordinary.fields)
        #expect(global.owner == .global(directory: nil))
        let chat = ChatClient(demoMode: true)
        let didPresent = chat.presentForm(global)
        #expect(!didPresent)
        #expect(try await questions.recoverPendingForm(sessionID: "global") == nil)
        await #expect(throws: OpenCodeError.self) { _ = try await client.listPendingForms(sessionID: "global") }
        await #expect(throws: OpenCodeError.self) { try await questions.respondToForm(global, answer: ["ok": .boolean(true)]) }
        await #expect(throws: OpenCodeError.self) { try await questions.cancelForm(global) }
        #expect(transport.recordedRequests().map(\.path) == ["/api/info", "/api/session/ses_owner/form"])
    }

    @MainActor @Test(arguments: ["", "ses_a", "ses_b"])
    func globalEventsNeverPresentOrResolveAChatForm(selectedSession: String) throws {
        let chat = ChatClient(demoMode: true)
        if !selectedSession.isEmpty {
            chat.currentSession = OCSession(id: selectedSession, title: "Another chat", time: .init(created: 0, updated: 0))
        }
        let handler = SSEEventHandler(haptics: HapticController(),
            liveActivityTracker: LiveActivityTracker(liveActivity: TestLiveActivityProvider()))
        handler.delegate = chat
        let global = OCEvent(type: "form.created", properties: AnyCodable([
            "form": ["id": "frm_shared", "sessionID": "global", "title": "MCP confirmation",
                "fields": [["key": "approved", "type": "boolean"]]]
        ]))
        handler.handleInboundEvent(try #require(SSEInboundEvent.prepare(global)))
        #expect(chat.pendingForm == nil)
        #expect(!chat.showFormSheet)
        // A global resolution cannot clear an ordinary form with the same ID,
        // including before the user selects a chat.
        let ordinary = try JSONDecoder().decode(OCFormRequest.self, from: Data("""
        {"id":"frm_shared","sessionID":"\(selectedSession.isEmpty ? "ses_a" : selectedSession)",
         "title":"Session confirmation","fields":[{"key":"approved","type":"boolean"}]}
        """.utf8))
        chat.pendingForm = ordinary
        chat.showFormSheet = true
        for type in ["form.replied", "form.cancelled"] {
            handler.handleInboundEvent(try #require(SSEInboundEvent.prepare(OCEvent(type: type,
                properties: AnyCodable(["id": "frm_shared", "sessionID": "global"])))))
            #expect(chat.pendingForm?.sessionID == ordinary.sessionID)
            #expect(chat.showFormSheet)
        }
    }

    @MainActor @Test func inboxGlobalFormKeepsItsRecoveredLocationWhenAnotherChatChangesContext() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(#"""
            {"location":{"directory":"/canonical/mcp"},"data":[
              {"id":"frm_global","sessionID":"global","title":"MCP confirmation","fields":[
                {"key":"approved","type":"boolean","required":true}
              ]}
            ]}
            """#.utf8)),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(baseURL: URL(string: "https://example.com")!,
            contextDirectory: "/requested/mcp", transport: transport)
        let connection = ConnectionManager(testClient: client, capabilities: try await client.probeCapabilities())
        let form = try #require(try await client.listPendingForms().first)
        // Opening a chat may change the client's selected location. The recovered
        // global interaction still belongs to the server-resolved MCP location.
        await client.updateContextDirectory("/another/chat")
        let inbox = InboxService(connection: connection)
        try await inbox.respondToForm(form, answer: ["approved": .boolean(false)])
        try await inbox.cancelForm(form)
        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == ["/api/info", "/api/form",
            "/api/session/global/form/frm_global/reply", "/api/session/global/form/frm_global"])
        #expect(requests[1].queryItems["location[directory]"] == "/requested/mcp")
        #expect(requests[2].queryItems == ["location[directory]": "/canonical/mcp"])
        #expect(requests[3].queryItems == ["location[directory]": "/canonical/mcp"])
        #expect(requests[2].method == "POST")
        #expect(requests[3].method == "DELETE")
        let payload = try #require(try bodyObject(requests[2])["answer"] as? [String: Any])
        #expect(payload["approved"] as? Bool == false)
    }

    @Test func v2FormsUseTheOwningSessionForRecoveryRepliesAndCancellation() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: sessionFormListEnvelope()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let forms = try await client.listPendingForms(sessionID: "ses_1")
        try await client.replyToForm(
            sessionID: "ses_1",
            formID: "frm_1",
            answer: [
                "summary": .string("Ship it"),
                "retries": .number(3),
                "approved": .boolean(true),
                "targets": .strings(["ios", "macos"]),
            ]
        )
        try await client.cancelForm(sessionID: "ses_1", formID: "frm_1")

        #expect(forms.map(\.id) == ["frm_1"])
        #expect(forms.first?.sessionID == "ses_1")
        #expect(forms.first?.fields.count == 6)

        let requests = transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "/api/info",
            "/api/session/ses_1/form",
            "/api/session/ses_1/form/frm_1/reply",
            "/api/session/ses_1/form/frm_1",
        ])
        #expect(requests[1...].allSatisfy { $0.queryItems["location[directory]"] == nil })
        #expect(requests[2].method == "POST")
        #expect(requests[3].method == "DELETE")

        let reply = try bodyObject(requests[2])
        let answer = try #require(reply["answer"] as? [String: Any])
        #expect(answer["summary"] as? String == "Ship it")
        #expect(answer["retries"] as? Double == 3)
        #expect(answer["approved"] as? Bool == true)
        #expect(answer["targets"] as? [String] == ["ios", "macos"])
    }

    @Test func v2InboxFormsRecoverSupportedFieldsAndKeepUnknownFieldsExplicitlyUnsupported() async throws {
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: locatedFormListEnvelope()),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "https://opencode.example.com")),
            contextDirectory: "/workspace/OpenLens",
            transport: transport
        )
        _ = try await client.probeCapabilities()

        let forms = try await client.listPendingForms()
        let form = try #require(forms.first)

        #expect(form.id == "frm_inbox")
        #expect(form.sessionID == "ses_inbox")
        #expect(form.fields.map(\.kind) == [.string, .number, .integer, .boolean, .multiselect, .external, .unsupported])
        #expect(form.hasUnsupportedFields)
        #expect(form.fields[5].externalURL?.absoluteString == "https://opencode.ai/docs/forms")
        #expect(form.fields[6].displayTitle == "New server control")

        let request = try #require(transport.recordedRequests().last)
        #expect(request.path == "/api/form")
        #expect(request.queryItems["location[directory]"] == "/workspace/OpenLens")
    }

    @Test func formSafetyRejectsUnsafeReplyTokensButAllowsAnUnknownFieldFallback() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_safe",
          "sessionID": "ses_safe",
          "title": "Safe form",
          "fields": [
            {"key": "known", "type": "string", "title": "Known"},
            {"key": "future", "type": "future", "title": "Future"}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(form)?.hasUnsupportedFields == true)

        let unsafe = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_unsafe",
          "sessionID": "ses_safe",
          "title": "Unsafe form",
          "fields": [
            {
              "key": "target",
              "type": "multiselect",
              "options": [{"value": "\#(String(repeating: "x", count: 601))", "label": "Too long"}]
            }
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(unsafe) == nil)
    }

    @Test func formReplySafetyValidatesBoundsAndSupportsConditionalFields() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_constraints",
          "sessionID": "ses_safe",
          "title": "Constrained form",
          "fields": [
            {"key": "name", "type": "string", "required": true, "minLength": 3, "maxLength": 8},
            {"key": "targets", "type": "multiselect", "minItems": 1, "maxItems": 2, "options": [
              {"value": "ios", "label": "iOS"},
              {"value": "macos", "label": "macOS"}
            ]}
          ]
        }
        """#.utf8))

        #expect(InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens"), "targets": .strings(["ios"])],
            for: form
        ))
        #expect(!InteractiveFormSafety.accepts(
            answer: ["name": .string("No"), "targets": .strings(["ios", "macos", "watchos"])],
            for: form
        ))

        let externalLink = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_external",
          "sessionID": "ses_safe",
          "title": "Linked form",
          "fields": [
            {"key": "name", "type": "string", "required": true},
            {"key": "docs", "type": "external", "required": true, "url": "https://opencode.ai/docs/forms"}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens"), "docs": .boolean(true)],
            for: externalLink
        ))
        #expect(!InteractiveFormSafety.accepts(
            answer: ["name": .string("OpenLens")],
            for: externalLink
        ))

        let conditional = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_conditional",
          "sessionID": "ses_safe",
          "title": "Conditional form",
          "fields": [
            {"key": "enabled", "type": "boolean"},
            {"key": "details", "type": "string", "when": [{"key": "enabled", "op": "eq", "value": true}]}
          ]
        }
        """#.utf8))
        #expect(InteractiveFormSafety.sanitize(conditional)?.hasUnsupportedFields == false)
    }

    @Test func formIdentifiersCannotEscapeSessionScopedRoutes() {
        #expect(InteractiveFormSafety.fitsIdentifier("ses_safe-1._~"))
        #expect(!InteractiveFormSafety.fitsIdentifier("../form"))
        #expect(!InteractiveFormSafety.fitsIdentifier("ses/other"))
        #expect(!InteractiveFormSafety.fitsIdentifier("ses?form=other"))
    }

    @Test func requiredFieldsMayStartWithoutDefaultsAndAcceptFalseBooleanValues() throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {
          "id": "frm_required",
          "sessionID": "ses_required",
          "title": "Required inputs",
          "fields": [
            {"key": "confirmed", "type": "boolean", "required": true},
            {"key": "targets", "type": "multiselect", "required": true, "options": [
              {"value": "ios", "label": "iOS"}
            ]}
          ]
        }
        """#.utf8))

        #expect(InteractiveFormSafety.sanitize(form) != nil)
        #expect(InteractiveFormSafety.accepts(
            answer: ["confirmed": .boolean(false), "targets": .strings(["ios"])],
            for: form
        ))
    }

    @MainActor @Test func conditionalReplyDropsInactiveRequiredAnswersThroughBothServices() async throws {
        let wire = Data(#"""
        {"data":[{"id":"frm_branch","title":"Release","fields":[
          {"key":"enabled","type":"boolean","required":true,"default":false},
          {"key":"details","type":"string","required":true,"minLength":3,
           "when":[{"key":"enabled","op":"eq","value":true}]},
          {"key":"followup","type":"integer","required":true,"minimum":1,"maximum":5,
           "when":[{"key":"details","op":"neq","value":"skip"}]}
        ]}]}
        """#.utf8)
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: wire),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!,
            contextDirectory: "/different/location", transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let questions = QuestionService(connection: connection)
        let form = try #require(try await questions.recoverPendingForm(sessionID: "ses_owner"))
        #expect(!form.hasUnsupportedFields)
        // A previous branch's invalid/stale answers cannot travel in either reply.
        let answer: [String: OCFormValue] = ["enabled": .boolean(false),
            "details": .string("x"), "followup": .number(99)]
        try await questions.respondToForm(form, answer: answer)
        try await InboxService(connection: connection).respondToForm(form, answer: answer)
        let requests = transport.recordedRequests()
        for request in requests.suffix(2) {
            #expect(request.path == "/api/session/ses_owner/form/frm_branch/reply")
            #expect(request.queryItems.isEmpty)
            let payload = try #require(try bodyObject(request)["answer"] as? [String: Any])
            #expect(Set(payload.keys) == ["enabled"])
            #expect(payload["enabled"] as? Bool == false)
        }
        await #expect(throws: OpenCodeError.self) {
            try await questions.respondToForm(form, answer: ["enabled": .boolean(true)])
        }
        #expect(transport.recordedRequests().count == 4)
    }

    @MainActor @Test func conditionalBranchesUpdateWithTypedPredicatesAndPreserveValidation() async throws {
        let wire = #"""
        {"data":[{"id":"frm_matrix","sessionID":"ses_owner","title":"Branches","fields":[
          {"key":"mode","type":"string","default":"ship","options":[{"value":"ship","label":"Ship"},{"value":"hold","label":"Hold"}]},
          {"key":"amount","type":"number","default":2.5,"minimum":0,"maximum":5},
          {"key":"targets","type":"multiselect","default":["ios"],"minItems":1,"maxItems":2,"options":[{"value":"ios","label":"iOS"},{"value":"macos","label":"macOS"}]},
          {"key":"ready","type":"boolean","default":false,"required":true},
          {"key":"label","type":"string","required":true,"default":"go","minLength":2,"maxLength":4,"pattern":"^[a-z]+$",
           "when":[{"key":"mode","op":"eq","value":"ship"},{"key":"amount","op":"eq","value":2.5},{"key":"targets","op":"eq","value":"ios"},{"key":"ready","op":"eq","value":false}]},
          {"key":"other","type":"integer","required":true,"minimum":1,"maximum":3,
           "when":[{"key":"targets","op":"neq","value":"ios"}]},
          {"key":"docs","type":"external","url":"https://example.com/checklist"}
        ]}]}
        """#
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(wire.utf8)),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let service = QuestionService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))
        let form = try #require(try await service.recoverPendingForm(sessionID: "ses_owner"))
        #expect(!form.hasUnsupportedFields)
        var answer: [String: OCFormValue] = ["mode": .string("ship"), "amount": .number(2.5),
            "targets": .strings(["ios"]), "ready": .boolean(false), "label": .string("go"), "docs": .boolean(true)]
        #expect(InteractiveFormSafety.activeFields(for: form, answer: answer).map(\.key) == ["mode", "amount", "targets", "ready", "label", "docs"])
        try await service.respondToForm(form, answer: answer)
        // AND and unanswered neq: deleting a target hides both selection branches.
        answer.removeValue(forKey: "targets")
        #expect(InteractiveFormSafety.activeFields(for: form, answer: answer).map(\.key) == ["mode", "amount", "targets", "ready", "docs"])
        try await service.respondToForm(form, answer: answer)
        answer["targets"] = .strings(["macos"])
        await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: answer) }
        answer["other"] = .number(3)
        try await service.respondToForm(form, answer: answer)
        let replies = transport.recordedRequests().suffix(3)
        let payloads = try replies.map { try #require(try bodyObject($0)["answer"] as? [String: Any]) }
        #expect(payloads[0]["label"] as? String == "go")
        #expect(payloads[1]["label"] == nil && payloads[1]["other"] == nil)
        #expect(payloads[2]["label"] == nil && payloads[2]["other"] as? Double == 3)
        // Retain active scalar, option, number/integer, multiselect and external constraints.
        let invalidAnswers: [[String: OCFormValue]] = [
            ["label": .string("")], ["label": .string("x")], ["label": .string("ABCDE")],
            ["mode": .string("guess")], ["amount": .number(6)], ["amount": .number(.infinity)],
            ["ready": .string("false")], ["targets": .strings(["macos", "macos"])],
            ["targets": .strings(["watchos"])], ["docs": .boolean(false)],
        ]
        let original: [String: OCFormValue] = ["mode": .string("ship"), "amount": .number(2.5),
            "targets": .strings(["ios"]), "ready": .boolean(false), "label": .string("go"), "docs": .boolean(true)]
        for change in invalidAnswers {
            let candidate = original.merging(change) { _, new in new }
            await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: candidate) }
        }
        answer["other"] = .number(1.5)
        await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: answer) }
        #expect(transport.recordedRequests().count == 5)
    }

    @MainActor @Test(arguments: [
        #"[{"key":"enabled","op":"future","value":true}]"#,
        #"[{"key":"enabled","op":"eq","value":"true"}]"#,
        #"[{"key":"missing","op":"eq","value":true}]"#,
        #"[{"key":"secret","op":"eq","value":false}]"#,
        #"[{"key":"details","op":"eq","value":"self"}]"#,
        #"[{"key":"later","op":"eq","value":true}]"#,
        #"[{"key":"enabled","op":"eq","value":[true]}]"#,
        #"[{"key":"enabled","op":"eq","value":null}]"#,
        #"[{"key":"enabled","op":"eq"}]"#,
        #"{"key":"enabled","op":"eq","value":true}"#,
        "null",
    ]) func unsupportedPredicatesRecoverExplicitlyAndCannotReachTransport(predicate: String) async throws {
        let wire = """
        {"data":[{"id":"frm_unsupported","title":"Future rules","fields":[
          {"key":"enabled","type":"boolean","default":false},
          {"key":"secret","type":"boolean","hidden":true,"default":false},
          {"key":"details","type":"string","when":\(predicate)},
          {"key":"later","type":"boolean"}
        ]}]}
        """
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(wire.utf8)),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let questions = QuestionService(connection: connection)
        let form = try #require(try await questions.recoverPendingForm(sessionID: "ses_owner"))
        #expect(form.hasUnsupportedFields)
        await #expect(throws: OpenCodeError.self) {
            try await questions.respondToForm(form, answer: ["enabled": .boolean(false)])
        }
        await #expect(throws: OpenCodeError.self) {
            try await InboxService(connection: connection).respondToForm(form, answer: ["enabled": .boolean(false)])
        }
        #expect(transport.recordedRequests().count == 2)
    }

    @MainActor @Test func nativeFormUpdatesVisibleInputsWhenBooleanAnswerChanges() async throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {"id":"frm_native","sessionID":"ses_owner","title":"Native branches","fields":[
          {"key":"enabled","type":"boolean","required":true,"default":false},
          {"key":"details","type":"string","required":true,"default":"Ready to ship",
           "when":[{"key":"enabled","op":"eq","value":true}]}
        ]}
        """#.utf8))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: FormView(form: form,
            onSubmit: { _ in }, onCancel: {}, isSubmitting: false))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { descendants(window).contains { $0 is UISwitch } }
        let toggle = try #require(descendants(window).compactMap { $0 as? UISwitch }.first)
        #expect(descendants(window).compactMap { $0 as? UITextField }.isEmpty)
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await waitUntil { descendants(window).compactMap { $0 as? UITextField }.first?.text == "Ready to ship" }
        let input = try #require(descendants(window).compactMap { $0 as? UITextField }.first)
        #expect(input.text == "Ready to ship")
        input.text = "Edited release"
        input.sendActions(for: .editingChanged)
        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await waitUntil { descendants(window).compactMap { $0 as? UITextField }.isEmpty }
        #expect(descendants(window).compactMap { $0 as? UITextField }.isEmpty)
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await waitUntil { descendants(window).compactMap { $0 as? UITextField }.first?.text == "Edited release" }
        #expect(descendants(window).compactMap { $0 as? UITextField }.first?.text == "Edited release")
    }

    @MainActor @Test(arguments: ["eq", "neq"])
    func optionalBooleanStartsUnansweredAndSubmitsOnlyTheChosenBranch(op: String) async throws {
        let value = op == "eq" ? "false" : "true"
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data("""
        {"id":"frm_optional","sessionID":"ses_owner","title":"Optional answer","fields":[
          {"key":"enabled","type":"boolean","title":"Release now"},
          {"key":"reason","type":"string","title":"Reason to wait","required":true,
           "when":[{"key":"enabled","op":"\(op)","value":\(value)}]}
        ]}
        """.utf8))
        var submissions: [[String: OCFormValue]] = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Color.clear
            .sheet(isPresented: .constant(true)) {
                FormView(form: form, onSubmit: { submissions.append($0) }, onCancel: {}, isSubmitting: false)
                    .presentationDetents([.large])
            })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        try await waitUntil { descendants(window).contains { $0 is UISegmentedControl } }
        let choice = try #require(descendants(window).compactMap { $0 as? UISegmentedControl }.first)
        #expect(choice.numberOfSegments == 3)
        #expect(choice.titleForSegment(at: 0) == "Not answered")
        #expect(choice.selectedSegmentIndex == 0)
        #expect(descendants(window).compactMap { $0 as? UISwitch }.isEmpty)
        #expect(descendants(window).compactMap { $0 as? UITextField }.isEmpty)
        try await waitUntil {
            descendants(window).compactMap { $0 as? UINavigationBar }
                .contains { $0.topItem?.trailingItemGroups.contains { !$0.barButtonItems.isEmpty } == true }
        }
        let submitItems = descendants(window).compactMap { $0 as? UINavigationBar }
            .flatMap { $0.topItem?.trailingItemGroups.flatMap(\.barButtonItems) ?? [] }
        let submit = try #require(submitItems.first)
        let action = try #require(submit.action)
        try await waitUntil { submit.isEnabled }
        #expect(UIApplication.shared.sendAction(action, to: submit.target, from: submit, for: nil))
        try await waitUntil { submissions.count == 1 }
        #expect(submissions[0].isEmpty)

        choice.selectedSegmentIndex = 1
        choice.sendActions(for: .valueChanged)
        try await waitUntil { !descendants(window).compactMap { $0 as? UITextField }.isEmpty && !submit.isEnabled }
        let reason = try #require(descendants(window).compactMap { $0 as? UITextField }.first)
        reason.text = "Finish verification"
        reason.sendActions(for: .editingChanged)
        try await waitUntil { submit.isEnabled }
        #expect(UIApplication.shared.sendAction(action, to: submit.target, from: submit, for: nil))
        try await waitUntil { submissions.count == 2 }
        #expect(submissions[1] == ["enabled": .boolean(false), "reason": .string("Finish verification")])

        choice.selectedSegmentIndex = 0
        choice.sendActions(for: .valueChanged)
        try await waitUntil { descendants(window).compactMap { $0 as? UITextField }.isEmpty && submit.isEnabled }
        #expect(UIApplication.shared.sendAction(action, to: submit.target, from: submit, for: nil))
        try await waitUntil { submissions.count == 3 }
        #expect(submissions[2].isEmpty)

        choice.selectedSegmentIndex = 2
        choice.sendActions(for: .valueChanged)
        try await waitUntil { choice.selectedSegmentIndex == 2 && submit.isEnabled }
        #expect(UIApplication.shared.sendAction(action, to: submit.target, from: submit, for: nil))
        try await waitUntil { submissions.count == 4 }
        #expect(submissions[3] == ["enabled": .boolean(true)])

        // Carry the actual UI submissions through the production reply boundary.
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ] + Array(repeating: .init(statusCode: 204, body: Data()), count: 4))
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let service = QuestionService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))
        for answer in submissions { try await service.respondToForm(form, answer: answer) }
        let replies = transport.recordedRequests().dropFirst()
        #expect(replies.allSatisfy { $0.path == "/api/session/ses_owner/form/frm_optional/reply" })
        let answers = try replies.map { try #require(try bodyObject($0)["answer"] as? [String: Any]) }
        #expect(answers[0].isEmpty && answers[2].isEmpty)
        #expect(Set(answers[1].keys) == ["enabled", "reason"])
        #expect(answers[1]["enabled"] as? Bool == false)
        #expect(answers[1]["reason"] as? String == "Finish verification")
        #expect(Set(answers[3].keys) == ["enabled"])
        #expect(answers[3]["enabled"] as? Bool == true)
    }

    @MainActor @Test(arguments: [false, true])
    func conditionalExternalFieldsCannotGuessServerAcknowledgementSemantics(enabled: Bool) async throws {
        let wire = Data(#"""
        {"data":[{"id":"frm_external_when","sessionID":"ses_owner","title":"External rules","fields":[
          {"key":"enabled","type":"boolean"},
          {"key":"docs","type":"external","url":"https://example.com/checklist",
           "when":[{"key":"enabled","op":"eq","value":true}]}
        ]}]}
        """#.utf8)
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: wire),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let questions = QuestionService(connection: connection)
        let form = try #require(try await questions.recoverPendingForm(sessionID: "ses_owner"))
        #expect(form.hasUnsupportedFields)
        #expect(!form.fields[1].isSupported)
        for answer: [String: OCFormValue] in [
            ["enabled": .boolean(enabled)], ["enabled": .boolean(enabled), "docs": .boolean(true)],
        ] {
            await #expect(throws: OpenCodeError.self) { try await questions.respondToForm(form, answer: answer) }
            await #expect(throws: OpenCodeError.self) { try await InboxService(connection: connection).respondToForm(form, answer: answer) }
        }
        #expect(transport.recordedRequests().count == 2)
    }

    @MainActor private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the native form update", sourceLocation: sourceLocation)
        throw FormUIWaitTimeout()
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor @Test func requiredEmptyValuesAndUnknownAnswersCannotSubmit() async throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data(#"""
        {"id":"frm_empty","sessionID":"ses_owner","title":"Required values","fields":[
          {"key":"name","type":"string","required":true},
          {"key":"targets","type":"multiselect","required":true,"options":[{"value":"ios","label":"iOS"}]}
        ]}
        """#.utf8))
        let transport = V2FormTransport(responses: [.init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse)])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let service = QuestionService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))
        for answer: [String: OCFormValue] in [
            ["name": .string(""), "targets": .strings(["ios"])],
            ["name": .string("Release"), "targets": .strings([])],
            ["name": .string("Release"), "targets": .strings(["ios"]), "unknown": .boolean(true)],
        ] {
            await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: answer) }
        }
        #expect(transport.recordedRequests().count == 1)
    }

    @MainActor @Test func failedRecoveryAndReplyCanRetryWithoutChangingFormOwnership() async throws {
        let wire = Data(#"""
        {"data":[{"id":"frm_retry","title":"Retry","fields":[
          {"key":"enabled","type":"boolean","default":true,"required":true,"when":[]},
          {"key":"count","type":"integer","default":1,"minimum":1,"maximum":3,"required":true,
           "when":[{"key":"enabled","op":"eq","value":true}]}
        ]}]}
        """#.utf8)
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 500, body: Data()),
            .init(statusCode: 200, body: wire),
            .init(statusCode: 500, body: Data()),
            .init(statusCode: 204, body: Data()),
            .init(statusCode: 204, body: Data()),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/new/location", transport: transport)
        let service = QuestionService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))
        await #expect(throws: OpenCodeError.self) { try await service.recoverPendingForm(sessionID: "ses_owner") }
        let form = try #require(try await service.recoverPendingForm(sessionID: "ses_owner"))
        #expect(form.fields[0].booleanDefault == true)
        #expect(form.fields[1].numberDefault == 1)
        // A default is initial UI input, never a substitute for a missing caller answer.
        await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: ["enabled": .boolean(true)]) }
        let answer: [String: OCFormValue] = ["enabled": .boolean(true), "count": .number(1)]
        await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: answer) }
        try await service.respondToForm(form, answer: answer)
        try await service.cancelForm(form)
        #expect(transport.recordedRequests().map(\.path) == ["/api/info",
            "/api/session/ses_owner/form", "/api/session/ses_owner/form",
            "/api/session/ses_owner/form/frm_retry/reply", "/api/session/ses_owner/form/frm_retry/reply",
            "/api/session/ses_owner/form/frm_retry"])
        #expect(transport.recordedRequests().dropFirst().allSatisfy { $0.queryItems.isEmpty })
    }

    @Test(arguments: [12, 13]) func conditionalBudgetsApplyToRecoveryAndNativeEvents(count: Int) async throws {
        let predicates = Array(repeating: ["key": "name", "op": "eq", "value": "release"], count: count)
        let raw: [String: Any] = ["id": "frm_budget", "sessionID": "ses_owner", "title": "Budget", "fields": [
            ["key": "name", "type": "string"], ["key": "details", "type": "string", "when": predicates],
        ]]
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ["data": [raw]])),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        _ = try await api.probeCapabilities()
        let forms = try await api.listPendingForms(sessionID: "ses_owner")
        let prepared = try #require(SSEFormCreated(event: OCEvent(type: "form.created", properties: AnyCodable(["form": raw]))))
        #expect(forms.count == (count == 12 ? 1 : 0))
        #expect((prepared.form != nil) == (count == 12))
        #expect(prepared.rejectedFormID == (count == 12 ? nil : "frm_budget"))
    }

    @Test(arguments: [2400, 2401]) func conditionalScalarBudgetDoesNotTruncatePredicateValues(bytes: Int) async throws {
        let raw: [String: Any] = ["id": "frm_scalar", "sessionID": "ses_owner", "title": "Budget", "fields": [
            ["key": "name", "type": "string"], ["key": "details", "type": "string", "when": [
                ["key": "name", "op": "eq", "value": String(repeating: "x", count: bytes)]
            ]],
        ]]
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ["data": [raw]])),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        _ = try await api.probeCapabilities()
        let forms = try await api.listPendingForms(sessionID: "ses_owner")
        #expect(forms.count == (bytes == 2400 ? 1 : 0))
        if let form = forms.first {
            #expect(form.fields[1].conditions?.first?.value == .string(String(repeating: "x", count: 2400)))
        }
    }

    @Test(arguments: [
        #"{"key":"details","type":"external","url":"https://example.com","when":[{"key":"enabled","op":"eq","value":true}]}"#,
        #"{"key":"details","type":"future","when":[{"key":"enabled","op":"eq","value":true}]}"#,
        #"{"key":"details","type":"string","format":"future","when":[{"key":"enabled","op":"eq","value":true}]}"#,
    ]) func unsupportedConditionalFieldTypesStayUnsupportedEvenOnAnInactiveBranch(field: String) throws {
        let form = try JSONDecoder().decode(OCFormRequest.self, from: Data("""
        {"id":"frm_future","sessionID":"ses_owner","title":"Future field","fields":[
          {"key":"enabled","type":"boolean"}, \(field)
        ]}
        """.utf8))
        #expect(InteractiveFormSafety.sanitize(form) != nil)
        #expect(form.hasUnsupportedFields)
        #expect(InteractiveFormSafety.submissionAnswer(["enabled": .boolean(false)], for: form) == nil)
    }

    @MainActor @Test(arguments: [
        #"{"key":"target","type":"string","options":[]}"#,
        #"{"key":"target","type":"string","options":[{"value":"ios","label":"iOS"}]}"#,
        #"{"key":"target","type":"multiselect","options":[{"value":"ios","label":"iOS"}]}"#,
        #"{"key":"target","type":"external","url":"https://example.com"}"#,
    ]) func predicatesCannotReferenceClosedInvalidOptionsOrExternalAnswers(target: String) async throws {
        let wire = """
        {"data":[{"id":"frm_options","sessionID":"ses_owner","title":"Option rules","fields":[
          \(target), {"key":"details","type":"string","when":[{"key":"target","op":"eq","value":"guess"}]}
        ]}]}
        """
        let transport = V2FormTransport(responses: [
            .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            .init(statusCode: 200, body: Data(wire.utf8)),
        ])
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let service = QuestionService(connection: ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities()))
        let form = try #require(try await service.recoverPendingForm(sessionID: "ses_owner"))
        #expect(form.hasUnsupportedFields)
        await #expect(throws: OpenCodeError.self) { try await service.respondToForm(form, answer: [:]) }
        #expect(transport.recordedRequests().count == 2)
    }

    private func sessionFormListEnvelope() -> Data {
        Data(#"""
        {"data":[
          {"id":"frm_1","title":"Release plan","fields":[
            {"key":"summary","type":"string","title":"Summary"},
            {"key":"retries","type":"number","title":"Retries","default":2.5},
            {"key":"build","type":"integer","title":"Build","default":42},
            {"key":"approved","type":"boolean","title":"Approved","default":false},
            {"key":"targets","type":"multiselect","title":"Targets","options":[{"value":"ios","label":"iOS"}]},
            {"key":"docs","type":"external","title":"Read docs","url":"https://opencode.ai/docs/forms"}
          ]}
        ]}
        """#.utf8)
    }

    private func locatedFormListEnvelope() -> Data {
        Data(#"""
        {"location":{"directory":"/workspace/OpenLens"},"data":[
          {"id":"frm_inbox","sessionID":"ses_inbox","title":"Server form","fields":[
            {"key":"name","type":"string","title":"Name"},
            {"key":"ratio","type":"number","title":"Ratio"},
            {"key":"count","type":"integer","title":"Count"},
            {"key":"enabled","type":"boolean","title":"Enabled"},
            {"key":"targets","type":"multiselect","title":"Targets","options":[{"value":"ios","label":"iOS"}]},
            {"key":"docs","type":"external","title":"Docs","url":"https://opencode.ai/docs/forms"},
            {"key":"future","type":"server-control","title":"New server control"}
          ]}
        ]}
        """#.utf8)
    }

    private func bodyObject(_ request: V2FormTransport.RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

nonisolated private final class V2FormTransport: OpenCodeTransport, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var pathResponses: [String: [Response]]?
    private let matchesLocation: Bool
    private let gate: FormReadGate?
    private var requests: [RecordedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
        self.matchesLocation = false
        self.gate = nil
    }

    init(pathResponses: [String: [Response]], matchesLocation: Bool = false, gate: FormReadGate? = nil) {
        self.responses = []
        self.pathResponses = pathResponses
        self.matchesLocation = matchesLocation
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let queryItems = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value {
                    result[item.name] = value
                }
            }
        if url.path == "/api/form", queryItems["location[directory]"] == "/a" {
            await gate?.holdFirstRead()
        }
        let response = try lock.withLock { () throws -> Response in
            requests.append(.init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                queryItems: queryItems,
                body: request.httpBody
            ))
            if pathResponses != nil {
                let locationSuffix = matchesLocation && ["/api/form", "/api/permission/request"].contains(url.path)
                    ? " \(queryItems["location[directory]"] ?? "<missing location>")" : ""
                let key = "\(request.httpMethod ?? "GET") \(url.path)\(locationSuffix)"
                guard var queued = pathResponses?[key], !queued.isEmpty else { throw MissingV2FormResponse() }
                let response = queued.removeFirst()
                pathResponses?[key] = queued
                return response
            }
            guard !responses.isEmpty else {
                throw MissingV2FormResponse()
            }
            return responses.removeFirst()
        }

        return (
            response.body,
            HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        UnusedV2FormEventStream()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.withLock { requests }
    }
}

nonisolated private struct MissingV2FormResponse: Error {}

nonisolated private final class UnusedV2FormEventStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}

nonisolated private struct FormUIWaitTimeout: Error {}

private actor FormReadGate {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }

    func holdFirstRead() async {
        guard !held else { return }
        held = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
