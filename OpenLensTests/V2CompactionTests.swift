import Foundation
import SwiftUI
import Testing
@testable import OpenLens

@MainActor
struct V2CompactionTests {
    @Test func compactionButtonKeepsItsHeightWhilePendingAndRunning() async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        func controlHeight() -> CGFloat {
            let host = UIHostingController(rootView: SessionCompactionControls().environment(chat))
            return host.sizeThatFits(in: CGSize(width: 354, height: 1000)).height
        }
        let readyHeight = controlHeight()
        await chat.requestCompaction()
        #expect(chat.compactionState == .pending)
        #expect(abs(controlHeight() - readyHeight) < 0.5)
        let id = try #require(chat.queuedPrompts.first?.messageID)
        await server.finish(id: id, outcome: "running")
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .running)
        #expect(abs(controlHeight() - readyHeight) < 0.5)
    }

    @Test func admissionUsesStableIdentityAndSessionLocationWithoutCompletingSynchronously() async throws {
        let server = CompactionTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, authHeader: "Bearer fixture",
                                 contextDirectory: "/unrelated-picker", transport: server)
        _ = try await api.probeCapabilities()
        let entry = try await api.requestCompaction(sessionID: "ses_1", messageID: "msg_compact")
        #expect(entry?.id == "msg_compact")
        #expect(entry?.type == "compaction")
        #expect(entry?.delivery == .steer)
        let request = try #require(await server.compactRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/session/ses_1/compact")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        #expect(body == ["id": "msg_compact", "delivery": "steer"])
        #expect(await server.history == "[]")
    }
    @Test func admittedCompactionRemainsPendingInSharedInboxAndSurvivesReopening() async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        await chat.requestCompaction()
        #expect(chat.compactionState == .pending)
        #expect(!chat.canRequestCompaction)
        #expect(chat.queuedPrompts.map(\.kind) == [.compaction])
        let id = try #require(chat.queuedPrompts.first?.messageID)
        await chat.requestCompaction()
        let reopened = try await openChat(server)
        #expect(reopened.compactionState == .pending)
        #expect(reopened.queuedPrompts.first?.messageID == id)
        reopened.synchronizeCurrentSessionFromServer()
        try await waitUntil { reopened.isStreamSynchronized }
        #expect(reopened.compactionState == .pending)
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: ["running", "completed", "failed", "interrupted"])
    func timelineLifecycleRefreshesContextAndRestoresResults(_ outcome: String) async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let id = try #require(chat.queuedPrompts.first?.messageID)
        let scope = chat.activeContextScope
        await server.finish(id: id, outcome: outcome)
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event([
            "type": outcome == "running" ? "session.compaction.started" : outcome == "completed" ? "session.compaction.ended" : "session.compaction.failed",
            "data": ["sessionID": "ses_1", "id": id]
        ], directory: nil))
        chat.receiveStreamEvent(.raw(event))
        try await waitUntil { chat.isStreamSynchronized && chat.queuedPrompts.isEmpty }
        let expected: ChatClient.CompactionState = switch outcome {
        case "running": .running
        case "completed": .completed
        case "failed": .failed("Provider offline")
        default: .interrupted
        }
        #expect(chat.compactionState == expected)
        #expect(chat.activeContextScope != scope)
        #expect(chat.contextEntries.first?.id == id)
        #expect(chat.timelineItems(showsThinking: false).first?.id == "context-" + id)
        if outcome == "completed" {
            let active = try #require(try await chat.loadActiveContext())
            #expect(active.contextEntries.first?.details == "Keep the current branch.\n\nRecent context:\nTests pass.")
        }
        let reopened = try await openChat(server)
        #expect(reopened.compactionState == expected)
        #expect(await server.compactRequests.count == 1)
    }

    @Test func completedLocalRequestDoesNotOverrideLaterAutomaticCompaction() async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let id = try #require(chat.queuedPrompts.first?.messageID)
        await server.finish(id: id, outcome: "completed")
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .completed)
        try await server.appendCompaction(id: "msg_auto", reason: "auto")
        await chat.refreshCompactionState()
        #expect(chat.contextEntries.last?.id == "msg_auto")
        #expect(chat.compactionState == .completed)
        #expect(chat.canRequestCompaction)
        #expect(chat.queuedPrompts.isEmpty)
        #expect(await server.compactRequests.count == 1)
    }

    @Test func resolvedUncertainRequestUsesANewIdentityAfterLaterCompaction() async throws {
        let server = CompactionTransport()
        await server.setMode("uncertain")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let first = try #require(await server.compactRequests.first)
        let original = try #require(try JSONSerialization.jsonObject(with: first.httpBody!) as? [String: String])
        await server.finish(id: try #require(original["id"]), outcome: "completed")
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .completed)
        try await server.appendCompaction(id: "msg_other_client")
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .completed)
        #expect(chat.canRequestCompaction)
        #expect(await server.compactRequests.count == 1)
        await server.setMode("normal")
        await chat.requestCompaction()
        let requests = await server.compactRequests
        #expect(requests.count == 2)
        let lastBody = try #require(requests.last?.httpBody)
        let last = try #require(try JSONSerialization.jsonObject(with: lastBody) as? [String: String])
        #expect(last["id"] != original["id"])
        #expect(chat.queuedPrompts.first?.messageID == last["id"])
    }

    @Test(arguments: ["rejected", "uncertain"])
    func laterOtherClientCompactionReplacesUnresolvedLocalFailure(_ mode: String) async throws {
        let server = CompactionTransport()
        // An older successful result must not resolve a new local failure.
        await server.finish(id: "msg_prior", outcome: "completed")
        await server.setMode(mode)
        let chat = try await openChat(server)
        await chat.requestCompaction()
        if mode == "uncertain" { #expect(chat.compactionState == .uncertain) }
        else if case .failed = chat.compactionState {} else { Issue.record("Expected the local rejection") }
        try await server.appendCompaction(id: "msg_other_client")
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .completed)
        #expect(chat.canRequestCompaction)
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: ["cancelled", "reverted"])
    func synchronizedRemovalDoesNotLeaveLocalCompactionPending(_ removal: String) async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let id = try #require(chat.queuedPrompts.first?.messageID)
        if removal == "reverted" {
            await server.finish(id: id, outcome: "completed")
            await server.setRevert(id)
        } else { await server.cancelCompaction() }
        await chat.refreshCompactionState()
        #expect(chat.isStreamSynchronized)
        #expect(chat.compactionState == .ready)
        #expect(chat.canRequestCompaction)
        #expect(chat.queuedPrompts.isEmpty)
        #expect(chat.contextEntries.isEmpty)
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: [false, true])
    func retryPreflightFindsCompletedIdentityBeforeTheLatestCompaction(_ reverted: Bool) async throws {
        let server = CompactionTransport()
        await server.setMode("uncertain")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let request = try #require(await server.compactRequests.first)
        let input = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        await server.finish(id: try #require(input["id"]), outcome: "completed")
        try await server.appendCompaction(id: "msg_auto", reason: "auto")
        if reverted { await server.setRevert(try #require(input["id"])) }
        await chat.requestCompaction()
        #expect(chat.compactionState == (reverted ? .ready : .completed))
        #expect(chat.canRequestCompaction)
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: [404, 405, 501])
    func unsupportedEndpointDisablesTheControlWithoutRetrying(_ status: Int) async throws {
        let server = CompactionTransport()
        await server.setMode("unsupported", status: status)
        let chat = try await openChat(server)
        await chat.requestCompaction()
        #expect(chat.compactionState == .unavailable)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        #expect(await server.compactRequests.count == 1)
        #expect(chat.queuedPrompts.isEmpty)
    }

    @Test(arguments: ["lost", "unreadable", "immediate"])
    func admittedWorkNeverResubmitsAfterALostOrUnreadableAcknowledgment(_ mode: String) async throws {
        let server = CompactionTransport()
        await server.setMode(mode)
        let chat = try await openChat(server)
        await chat.requestCompaction()
        #expect(chat.compactionState == (mode == "immediate" ? .completed : .pending))
        #expect(await server.compactRequests.count == 1)
        if mode != "immediate" { #expect(chat.queuedPrompts.count == 1) }
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil { chat.isStreamSynchronized }
        #expect(await server.compactRequests.count == 1)
    }

    @Test func definiteRejectionShowsTheReasonAndAllowsAnExplicitRetry() async throws {
        let server = CompactionTransport()
        await server.setMode("rejected")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        if case .failed(let reason) = chat.compactionState { #expect(reason.contains("Access refused")) }
        else { Issue.record("Expected a definitive failure") }
        #expect(chat.canRequestCompaction)
        await server.setMode("normal")
        await chat.requestCompaction()
        #expect(chat.compactionState == .pending)
        #expect(await server.compactRequests.count == 2)
    }

    @Test func uncertainAdmissionRetriesTheSameIdentityAfterRecovery() async throws {
        let server = CompactionTransport()
        await server.setMode("uncertain")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        #expect(chat.compactionState == .uncertain)
        #expect(chat.canRequestCompaction)
        await server.setMode("normal")
        await chat.requestCompaction()
        #expect(chat.compactionState == .pending)
        let requests = await server.compactRequests
        #expect(requests.count == 2)
        let first = try JSONSerialization.jsonObject(with: try #require(requests.first?.httpBody)) as? [String: String]
        let last = try JSONSerialization.jsonObject(with: try #require(requests.last?.httpBody)) as? [String: String]
        #expect(first == last)
    }

    @Test func unknownResultHasNoActiveRetryAndLaterInterruptionDoesNotRewriteFailure() async throws {
        let server = CompactionTransport()
        await server.setHistory(#"[{"id":"msg_future","type":"compaction","status":"future","summary":"Unfamiliar result"}]"#)
        let chat = try await openChat(server)
        #expect(chat.compactionState == .uncertain)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        #expect(await server.compactRequests.isEmpty)
        await server.setHistory(#"[{"id":"msg_failed","type":"compaction","status":"failed","error":{"type":"unknown","message":"Provider offline"}},{"id":"msg_user","type":"user","text":"Another turn"},{"id":"msg_idle","type":"idle","outcome":"interrupted"}]"#)
        await chat.refreshCompactionState()
        #expect(chat.compactionState == .failed("Provider offline"))
    }

    @Test func unsupportedInstallationRemainsUnavailableWhenSwitchingSessions() async throws {
        let server = CompactionTransport()
        await server.setMode("unsupported")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        await chat.loadSession(OCSession(id: "ses_2", title: "Other", time: .init(created: 0, updated: 0)))
        #expect(chat.compactionState == .unavailable)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: ["normal", "rejected", "lost"])
    func heldAdmissionCannotSubmitTwiceOrChangeAnotherSession(_ mode: String) async throws {
        let server = CompactionTransport()
        await server.setMode(mode)
        await server.holdCompaction()
        let chat = try await openChat(server)
        let request = Task { await chat.requestCompaction() }
        try await waitUntil { await server.isHoldingCompaction }
        #expect(chat.compactionState == .submitting)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        await chat.loadSession(OCSession(id: "ses_2", title: "Other", time: .init(created: 0, updated: 0)))
        await server.releaseCompaction()
        await request.value
        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.compactionState == .ready)
        #expect(chat.queuedPrompts.isEmpty)
        #expect(chat.errorMessage == nil)
        await chat.loadSession(OCSession(id: "ses_1", title: "Original", time: .init(created: 0, updated: 0)))
        if mode == "rejected" {
            if case .failed = chat.compactionState {} else { Issue.record("Expected the original rejection") }
        } else { #expect(chat.compactionState == .pending) }
        #expect(await server.compactRequests.count == 1)
    }

    @Test(arguments: [false, true])
    func failedRecoveryKeepsAcceptedWorkUntilAnAuthoritativeRead(_ remainsQueued: Bool) async throws {
        let server = CompactionTransport()
        let chat = try await openChat(server)
        await server.setMode("unreadable")
        await server.setFailsInbox(true)
        await chat.requestCompaction()
        #expect(chat.compactionState == .pending)
        #expect(chat.queuedPrompts.first?.kind == .compaction)
        #expect(!chat.isStreamSynchronized)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        if !remainsQueued { await server.cancelCompaction() }
        await server.setFailsInbox(false)
        await chat.refreshCompactionState()
        #expect(chat.isStreamSynchronized)
        #expect(chat.queuedPrompts.count == (remainsQueued ? 1 : 0))
        #expect(chat.compactionState == (remainsQueued ? .pending : .ready))
        #expect(chat.canRequestCompaction == !remainsQueued)
        #expect(await server.compactRequests.count == 1)
    }

    @Test func lateResultWithdrawsUncertainRetryBeforeAnotherPost() async throws {
        let server = CompactionTransport()
        await server.setMode("uncertain")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        let request = try #require(await server.compactRequests.first)
        let input = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        await server.finish(id: try #require(input["id"]), outcome: "completed")
        await chat.requestCompaction()
        #expect(chat.compactionState == .completed)
        #expect(await server.compactRequests.count == 1)
    }

    @Test func v1AndStructuredSessionErrorsAreNotMissingV2Endpoints() async throws {
        let server = CompactionTransport()
        await server.setMode("v1")
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        _ = try await api.probeCapabilities()
        #expect(try await api.requestCompaction(sessionID: "ses_1", messageID: "msg_legacy") == nil)
        #expect(await server.compactRequests.isEmpty)
        let legacyChat = try await openChat(server)
        #expect(legacyChat.compactionState == .unavailable)
        #expect(!legacyChat.canRequestCompaction)
        await server.setMode("missing-session")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        if case .failed(let reason) = chat.compactionState { #expect(reason.contains("Session absent")) }
        else { Issue.record("A structured session error must remain a failure") }
        #expect(chat.canRequestCompaction)
    }

    @Test func uncertainRetryAndAReopenedSubmittingRequestAreCoalesced() async throws {
        let server = CompactionTransport()
        await server.setMode("uncertain")
        let chat = try await openChat(server)
        await chat.requestCompaction()
        await server.setMode("normal")
        await server.holdCompaction()
        let retry = Task { await chat.requestCompaction() }
        try await waitUntil { await server.isHoldingCompaction }
        #expect(chat.compactionState == .submitting)
        await chat.loadSession(OCSession(id: "ses_1", title: "Reopened", time: .init(created: 0, updated: 0)))
        #expect(chat.compactionState == .submitting)
        await chat.requestCompaction()
        await server.releaseCompaction()
        await retry.value
        #expect(chat.compactionState == .pending)
        #expect(chat.queuedPrompts.count == 1)
        #expect(await server.compactRequests.count == 2)
    }

    @Test func disconnectionDoesNotInstallAHeldAdmissionIntoTheVisibleInbox() async throws {
        let server = CompactionTransport()
        var connection: ConnectionManager?
        let chat = try await openChat(server, onConnection: { connection = $0 })
        await server.holdCompaction()
        let request = Task { await chat.requestCompaction() }
        try await waitUntil { await server.isHoldingCompaction }
        connection?.disconnect()
        await server.releaseCompaction()
        await request.value
        #expect(chat.compactionState == .ready)
        #expect(!chat.canRequestCompaction)
        #expect(chat.queuedPrompts.isEmpty)
        let reconnected = try await openChat(server)
        #expect(reconnected.compactionState == .pending)
        #expect(reconnected.queuedPrompts.count == 1)
        #expect(await server.compactRequests.count == 1)
    }

    @Test func unnegotiatedConnectionRequiresReconnectInsteadOfClaimingUnsupported() async {
        let chat = makeChat(connection: ConnectionManager())
        #expect(chat.compactionState == .ready)
        #expect(!chat.canRequestCompaction)
        await chat.requestCompaction()
        #expect(chat.queuedPrompts.isEmpty)
    }

    private func openChat(_ server: CompactionTransport, onConnection: ((ConnectionManager) -> Void)? = nil) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        onConnection?(connection)
        let chat = makeChat(connection: connection)
        await chat.loadSession(OCSession(id: "ses_1", title: "Context", time: .init(created: 0, updated: 0)))
        return chat
    }

    private func makeChat(connection: ConnectionManager) -> ChatClient {
        ChatClient(connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore())
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for compaction recovery")
    }
}

private actor CompactionTransport: OpenCodeTransport {
    var compactRequests: [URLRequest] = []
    var history = "[]"
    private var inbox = "[]"
    private var revertID: String?
    func setRevert(_ id: String) { revertID = id }
    func cancelCompaction() { inbox = "[]" }
    func appendCompaction(id: String, reason: String = "manual") throws {
        var records = try JSONSerialization.jsonObject(with: Data(history.utf8)) as! [[String: Any]]
        records.append(["id": id, "type": "compaction", "status": "completed", "reason": reason,
                        "summary": "A later summary", "recent": "More recent context"])
        history = String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)
    }
    private var holdsCompaction = false
    private var compactionWaiter: CheckedContinuation<Void, Never>?
    var isHoldingCompaction: Bool { compactionWaiter != nil }
    private var failsInbox = false
    func setFailsInbox(_ value: Bool) { failsInbox = value }
    func holdCompaction() { holdsCompaction = true }
    func releaseCompaction() { holdsCompaction = false; compactionWaiter?.resume(); compactionWaiter = nil }
    private var mode = "normal"
    private var unsupportedStatus = 404
    func setMode(_ mode: String, status: Int = 404) { self.mode = mode; unsupportedStatus = status }
    func setHistory(_ value: String) { history = value }
    func finish(id: String, outcome: String) {
        inbox = "[]"
        let status = outcome == "interrupted" ? "failed" : outcome
        let result = outcome == "completed" || outcome == "running"
            ? #","summary":"Keep the current branch.","recent":"Tests pass.""#
            : #","error":{"type":"unknown","message":"Provider offline"}"#
        let idle = outcome == "interrupted" ? #",{"id":"msg_idle","type":"idle","outcome":"interrupted"}"# : ""
        history = #"[{"id":"\#(id)","type":"compaction","status":"\#(status)","reason":"manual"\#(result)}\#(idle)]"#
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body: String
        var status = 200
        switch url.path {
        case "/api/info":
            if mode == "v1" { status = 404; body = "" }
            else { body = #"{"version":"2.0.23"}"# }
        case "/global/health": body = #"{"healthy":true,"version":"1.0.0"}"#
        case "/api/session/ses_1/compact":
            compactRequests.append(request)
            if holdsCompaction { await withCheckedContinuation { compactionWaiter = $0 } }
            if mode == "missing-session" {
                status = 404
                body = #"{"_tag":"SessionNotFoundError","message":"Session absent"}"#
                break
            }
            if mode == "unsupported" {
                return (Data(), HTTPURLResponse(url: url, statusCode: unsupportedStatus, httpVersion: nil, headerFields: nil)!)
            }
            if mode == "uncertain" { throw URLError(.timedOut) }
            if mode == "rejected" {
                status = 403
                body = #"{"_tag":"InvalidRequestError","message":"Access refused"}"#
                break
            }
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            let entry = #"{"id":"\#(input["id"]!)","sessionID":"ses_1","type":"compaction","delivery":"steer","payload":{}}"#
            inbox = "[\(entry)]"
            if mode == "lost" { throw URLError(.networkConnectionLost) }
            if mode == "immediate" { finish(id: input["id"]!, outcome: "completed") }
            body = mode == "unreadable" ? "unreadable" : #"{"data":\#(entry)}"#
        case "/api/session/active": body = #"{"data":{}}"#
        case "/api/session/ses_1", "/api/session/ses_2":
            let revert = url.lastPathComponent == "ses_1" ? revertID.map { #", "revert":{"messageID":"\#($0)"}"# } ?? "" : ""
            body = #"{"data":{"id":"\#(url.lastPathComponent)","title":"Context","time":{"created":0,"updated":0}\#(revert)}}"#
        case "/api/session/ses_1/inbox":
            if failsInbox { throw URLError(.networkConnectionLost) }
            body = #"{"data":\#(inbox)}"#
        case "/api/session/ses_1/message": body = #"{"data":\#(history),"cursor":{"next":null}}"#
        case "/api/session/ses_1/context": body = #"{"data":\#(history)}"#
        case "/api/session/ses_1/permission", "/api/session/ses_1/form",
             "/api/session/ses_2/inbox", "/api/session/ses_2/permission", "/api/session/ses_2/form":
            body = #"{"data":[]}"#
        case "/api/session/ses_2/message": body = #"{"data":[],"cursor":{"next":null}}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue,
                                     callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        CompactionUnusedStream()
    }
}

nonisolated private final class CompactionUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
