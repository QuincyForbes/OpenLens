import Foundation
import Testing
@testable import OpenLens

@MainActor
@Suite(.serialized)
struct ConnectionRecoveryTests {
    @Test(arguments: [false, true])
    func lateV1SendFailureCannotFailAnotherViewingGeneration(returnToOriginal: Bool) async throws {
        let transport = RecoveryTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: .v1(.init(healthy: true, version: "1")))
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection), messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        let original = OCSession(id: "ses_a", title: "Original", time: .init(created: 0, updated: 0))
        chat.currentSession = original
        chat.inputText = "An old request"
        chat.send()
        try await waitUntil { await transport.server.isWaiting }
        chat.prepareForOpeningSession(OCSession(id: "ses_b", title: "Other", time: .init(created: 0, updated: 0)))
        if returnToOriginal { chat.prepareForOpeningSession(original) }
        chat.beginExternalResponse()
        await transport.server.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.responseState == .generating)
        #expect(chat.errorMessage == nil)
    }

    @Test func supersededCapabilityProbeCannotReplaceTheNewConnection() async throws {
        let transport = RecoveryTransport()
        await transport.server.holdProbe(host: "old.example")
        let connection = makeConnection(transport)
        defer { connection.disconnect() }
        let oldAttempt = Task { await connection.connect(url: "https://old.example") }
        try await waitUntil { await transport.server.isWaiting }
        let newAttempt = Task { await connection.connect(url: "https://new.example") }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await newAttempt.value
        await transport.server.release()
        await oldAttempt.value
        #expect(connection.isConnected)
        #expect(connection.serverURL?.host() == "new.example")
        #expect(transport.streamCount == 1)
    }

    @Test func disconnectInvalidatesAProbeThatIgnoresCancellation() async throws {
        let transport = RecoveryTransport()
        await transport.server.holdProbe(host: "old.example")
        let connection = makeConnection(transport)
        let attempt = Task { await connection.connect(url: "https://old.example") }
        try await waitUntil { await transport.server.isWaiting }
        connection.manualDisconnect()
        await transport.server.release()
        await attempt.value
        #expect(connection.state == .disconnected)
        #expect(connection.client == nil)
        #expect(connection.didManuallyDisconnect)
        #expect(transport.streamCount == 0)
    }

    @Test func cancelledHandshakeReturnsAndClosesItsStream() async throws {
        let transport = RecoveryTransport()
        let connection = makeConnection(transport)
        let attempt = Task { await connection.connect(url: "https://example.com") }
        try await waitUntil { transport.streamCount == 1 }
        attempt.cancel()
        await attempt.value
        try await waitUntil { connection.state == .disconnected && transport.cancelledCount == 1 }
        #expect(connection.sseClient == nil)
    }

    @Test func silentHandshakeTimesOutAndUsesFiniteRequestTimeout() async throws {
        let transport = RecoveryTransport()
        let connection = makeConnection(transport, timeout: .milliseconds(150))
        await connection.connect(url: "https://example.com")
        guard case .error(let message) = connection.state else {
            Issue.record("Silent SSE handshake did not fail")
            return
        }
        #expect(message.contains("Timed out"))
        #expect(connection.sseClient == nil)
        #expect(transport.requestTimeouts == [75])
        try await waitUntil { transport.cancelledCount == 1 }
    }

    @Test func replacementRejectsAlreadyQueuedCallbacksFromTheOldStream() async throws {
        let transport = RecoveryTransport()
        let connection = makeConnection(transport)
        defer { connection.disconnect() }
        let first = Task { await connection.connect(url: "https://old.example") }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await first.value
        let oldStream = try #require(connection.sseClient)
        let oldState = oldStream.onStateChange
        let oldError = oldStream.onTerminalHTTPError
        let oldLiveness = oldStream.onLiveness

        let second = Task { await connection.connect(url: "https://new.example") }
        try await waitUntil { transport.streamCount == 2 }
        oldState?(.connected)
        oldError?(401)
        oldLiveness?()
        #expect(connection.state == .connecting)
        transport.respond(status: 200)
        await second.value
        #expect(connection.isConnected)
        #expect(connection.serverURL?.host() == "new.example")
        try await waitUntil { transport.cancelledCount == 1 }
    }

    private func makeConnection(_ transport: RecoveryTransport, timeout: Duration = .seconds(30)) -> ConnectionManager {
        ConnectionManager(localNetworkAccessProbe: RecoveryAccessProbe(), transport: transport,
                          sseConnectionTimeout: timeout)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RecoveryTestError.timedOut
    }
}

private enum RecoveryTestError: Error { case timedOut }

@MainActor
private final class RecoveryAccessProbe: LocalNetworkAccessProbing {
    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult { .continueConnection }
}

private actor RecoveryServer {
    private var heldHost: String?
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func holdProbe(host: String) { heldHost = host }
    func release() { waiter?.resume(); waiter = nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/prompt_async") {
            await withCheckedContinuation { waiter = $0 }
            throw URLError(.networkConnectionLost)
        }
        if url.path == "/api/info", url.host() == heldHost {
            heldHost = nil
            await withCheckedContinuation { waiter = $0 }
        }
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/location": body = #"{"directory":"/workspace","project":{"id":"project","directory":"/workspace"}}"#
        case "/api/vcs": body = #"{"location":{"directory":"/workspace"},"data":{"branch":"main"}}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

nonisolated private final class RecoveryTransport: OpenCodeTransport, @unchecked Sendable {
    let server = RecoveryServer()
    private let lock = NSLock()
    private var streams: [RecoveryStream] = []
    var streamCount: Int { lock.withLock { streams.count } }
    var cancelledCount: Int { lock.withLock { streams.filter(\.isCancelled).count } }
    var requestTimeouts: [TimeInterval] { lock.withLock { streams.map { $0.request.timeoutInterval } } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await server.data(for: request) }
    func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue,
                         callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        let stream = RecoveryStream(request: request, queue: deliveryQueue, callbacks: callbacks)
        lock.withLock { streams.append(stream) }
        return stream
    }
    func respond(status: Int) { lock.withLock { streams.last }?.respond(status: status) }
}

nonisolated private final class RecoveryStream: OpenCodeEventStream, @unchecked Sendable {
    let request: URLRequest
    private let queue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    init(request: URLRequest, queue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) {
        self.request = request
        self.queue = queue
        self.callbacks = callbacks
    }
    func respond(status: Int) {
        queue.async { [self] in
            _ = callbacks.onResponse(HTTPURLResponse(url: request.url!, statusCode: status,
                                                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
        }
    }
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() { lock.withLock { cancelled = true } }
}
