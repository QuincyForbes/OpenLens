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

    @Test func staleGetRequestsAreRetriedOnceAndWritesAreNot() async throws {
        var getRequest = URLRequest(url: URL(string: "https://example.com/api/info")!)
        getRequest.httpMethod = "GET"
        var attempts = 0
        let (data, _) = try await DirectOpenCodeTransport.retryingStaleConnection(getRequest) {
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return (Data("ok".utf8), HTTPURLResponse(url: getRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(attempts == 2)
        #expect(String(decoding: data, as: UTF8.self) == "ok")

        attempts = 0
        await #expect(throws: URLError.self) {
            _ = try await DirectOpenCodeTransport.retryingStaleConnection(getRequest) {
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(attempts == 2)

        var postRequest = getRequest
        postRequest.httpMethod = "POST"
        attempts = 0
        await #expect(throws: URLError.self) {
            _ = try await DirectOpenCodeTransport.retryingStaleConnection(postRequest) {
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(attempts == 1)

        attempts = 0
        await #expect(throws: URLError.self) {
            _ = try await DirectOpenCodeTransport.retryingStaleConnection(getRequest) {
                attempts += 1
                throw URLError(.timedOut)
            }
        }
        #expect(attempts == 1)
    }

    @Test func onlyThePreferredInterfaceDecidesAPathChange() {
        let wifiOnly = ConnectionManager.primaryInterfaceSignature(["wifi:en0"])
        let wifiWithCellularBackup = ConnectionManager.primaryInterfaceSignature(["wifi:en0", "cellular:pdp_ip0"])
        let cellularFirst = ConnectionManager.primaryInterfaceSignature(["cellular:pdp_ip0", "wifi:en0"])
        #expect(wifiOnly == wifiWithCellularBackup)
        #expect(wifiOnly != cellularFirst)
        #expect(ConnectionManager.primaryInterfaceSignature([]) == "none")
    }

    @Test func recoveryRetryDelayIsCappedButNeverStops() {
        #expect(ChatClient.streamSynchronizationRetryDelay(attempt: 0) == 1)
        #expect(ChatClient.streamSynchronizationRetryDelay(attempt: 3) == 8)
        #expect(ChatClient.streamSynchronizationRetryDelay(attempt: 5) == 30)
        #expect(ChatClient.streamSynchronizationRetryDelay(attempt: 40) == 30)
        #expect(ChatClient.streamSynchronizationRetryDelay(attempt: Int.max) == 30)
    }

    @Test func aBriefTripToAnotherAppDoesNotReloadAHealthyChat() {
        #expect(!ChatClient.shouldReconcileOnForeground(awayInterval: 3, isConnected: true, isStreamSynchronized: true))
        #expect(ChatClient.shouldReconcileOnForeground(awayInterval: 60, isConnected: true, isStreamSynchronized: true))
        #expect(ChatClient.shouldReconcileOnForeground(awayInterval: .infinity, isConnected: true, isStreamSynchronized: true))
        #expect(ChatClient.shouldReconcileOnForeground(awayInterval: 3, isConnected: false, isStreamSynchronized: true))
        #expect(ChatClient.shouldReconcileOnForeground(awayInterval: 3, isConnected: true, isStreamSynchronized: false))
    }

    @Test func aFailedRetryKeepsTheSavedActiveConnection() async throws {
        let transport = RecoveryTransport()
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = makeConnection(transport)
        connection.savedConnectionsStore = store
        defer { connection.disconnect() }
        let first = Task { await connection.connect(url: "https://new.example") }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await first.value
        #expect(connection.isConnected)
        let activeID = try #require(store.activeConnectionID)

        await transport.server.failProbe(host: "broken.example")
        await connection.connect(url: "https://broken.example")
        guard case .error = connection.state else {
            Issue.record("Connecting to an unreachable server did not fail")
            return
        }
        #expect(store.activeConnectionID == activeID)
    }

    @Test func fallbackCandidateOrderingPrioritizesSameHostBonjourThenLocalAlternatesThenPort4096() {
        let discovered = [
            BonjourDiscovery.DiscoveredServer(
                id: "opencode-4096-other",
                name: "opencode-4096",
                host: "192.168.3.88",
                port: 4096
            ),
            BonjourDiscovery.DiscoveredServer(
                id: "opencode-28894-same",
                name: "opencode-28894",
                host: "192.168.3.3",
                port: 28894
            ),
        ]

        let candidates = ConnectionManager.fallbackCandidateURLs(
            primaryURL: "http://192.168.3.3:54321",
            alternateURLs: ["https://dead.opentunnel.xyz", "http://100.114.113.63:54321"],
            discoveredServers: discovered
        )

        #expect(candidates == [
            "http://192.168.3.3:28894",
            "http://100.114.113.63:54321",
            "http://192.168.3.3:4096",
            "http://100.114.113.63:4096",
            "http://192.168.3.88:4096",
            "https://dead.opentunnel.xyz",
        ])
    }

    @Test func autoReconnectFallsBackToRestartedBonjourPortAndPreservesSavedPreferences() async throws {
        let transport = RecoveryTransport()
        await transport.server.failProbe(port: 54321)
        let discoverer = RecoveryLANDiscoverer(servers: [
            .init(id: "opencode-28894", name: "opencode-28894", host: "192.168.3.3", port: 28894),
        ])
        let store = SavedConnectionsStore(initialConnections: [])
        let saved = store.saveConnection(
            serverURL: "http://192.168.3.3:54321",
            username: "opencode",
            password: "persistent-token"
        )
        store.updateProjectSelection(connectionID: saved.id, directory: "/Users/me/OpenLens")

        let connection = ConnectionManager(
            localNetworkAccessProbe: RecoveryAccessProbe(),
            transport: transport,
            lanServerDiscoverer: discoverer
        )
        connection.savedConnectionsStore = store
        defer { connection.disconnect() }

        let reconnectTask = Task { await connection.reconnect() }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await reconnectTask.value

        #expect(connection.isConnected)
        #expect(connection.serverURL?.absoluteString == "http://192.168.3.3:28894")
        #expect(connection.selectedProjectDirectory == "/Users/me/OpenLens")
        #expect(store.connections.count == 1)
        #expect(store.mostRecent?.id == saved.id)
        #expect(store.mostRecent?.serverURL == "http://192.168.3.3:28894")
        #expect(store.mostRecent?.password == "persistent-token")
        let expectedAuth = "Basic " + Data("opencode:persistent-token".utf8).base64EncodedString()
        let lastAuth = await transport.server.lastAuthHeader
        #expect(lastAuth == expectedAuth)
    }

    @Test func autoReconnectFallsBackToSavedLANAlternateWhenRemoteTunnelDiesOnRestart() async throws {
        let transport = RecoveryTransport()
        await transport.server.failProbe(host: "dead-route.opentunnel.xyz")
        let store = SavedConnectionsStore(initialConnections: [])
        let saved = store.saveConnection(
            serverURL: "https://dead-route.opentunnel.xyz",
            username: "opencode",
            password: "persistent-token",
            alternateServerURLs: ["http://192.168.3.3:4096"]
        )

        let connection = makeConnection(transport)
        connection.savedConnectionsStore = store
        defer { connection.disconnect() }

        let reconnectTask = Task { await connection.reconnect() }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await reconnectTask.value

        #expect(connection.isConnected)
        #expect(connection.serverURL?.absoluteString == "http://192.168.3.3:4096")
        #expect(store.mostRecent?.id == saved.id)
        #expect(store.mostRecent?.serverURL == "http://192.168.3.3:4096")
    }

    @Test func liveReconnectingSessionAutomaticallyRebindsWhenServerRestartsOnNewBonjourPort() async throws {
        let transport = RecoveryTransport()
        let discoverer = RecoveryLANDiscoverer(servers: [])
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = ConnectionManager(
            localNetworkAccessProbe: RecoveryAccessProbe(),
            transport: transport,
            lanServerDiscoverer: discoverer,
            reconnectingRecoveryInitialDelay: .milliseconds(30)
        )
        connection.savedConnectionsStore = store
        defer { connection.disconnect() }

        let initialTask = Task {
            await connection.connect(
                url: "http://192.168.3.3:54321",
                username: "opencode",
                password: "persistent-token"
            )
        }
        try await waitUntil { transport.streamCount == 1 }
        transport.respond(status: 200)
        await initialTask.value
        #expect(connection.isConnected)

        // Simulate host computer restart: old port 54321 refuses connections, new port 28894
        // appears on Bonjour, and the active SSE stream drops into `.reconnecting`.
        await transport.server.failProbe(port: 54321)
        discoverer.servers = [
            .init(id: "opencode-28894", name: "opencode-28894", host: "192.168.3.3", port: 28894),
        ]
        connection.sseClient?.onStateChange?(.disconnected)
        #expect(connection.isReconnecting)

        try await waitUntil { transport.streamCount >= 2 && transport.lastStreamURL?.port == 28894 }
        transport.respond(status: 200)
        try await waitUntil { connection.isConnected }

        #expect(connection.serverURL?.absoluteString == "http://192.168.3.3:28894")
        #expect(store.mostRecent?.serverURL == "http://192.168.3.3:28894")
        #expect(store.mostRecent?.password == "persistent-token")
    }

    private func makeConnection(_ transport: RecoveryTransport, timeout: Duration = .seconds(30)) -> ConnectionManager {
        ConnectionManager(localNetworkAccessProbe: RecoveryAccessProbe(), transport: transport,
                          sseConnectionTimeout: timeout)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
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

@MainActor
private final class RecoveryLANDiscoverer: LANServerDiscovering {
    var servers: [BonjourDiscovery.DiscoveredServer]
    init(servers: [BonjourDiscovery.DiscoveredServer]) {
        self.servers = servers
    }
    func discoverServers(timeout: Duration, preferredHosts: Set<String>) async -> [BonjourDiscovery.DiscoveredServer] {
        servers
    }
}

private actor RecoveryServer {
    private var heldHost: String?
    private var failingHost: String?
    private var failingPort: Int?
    private(set) var lastAuthHeader: String?
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func holdProbe(host: String) { heldHost = host }
    func failProbe(host: String) { failingHost = host }
    func failProbe(port: Int) { failingPort = port }
    func release() { waiter?.resume(); waiter = nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        lastAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        if url.path.hasSuffix("/prompt_async") {
            await withCheckedContinuation { waiter = $0 }
            throw URLError(.networkConnectionLost)
        }
        if url.path == "/api/info", let failingPort, url.port == failingPort {
            throw URLError(.cannotConnectToHost)
        }
        if url.path == "/api/info", url.host() == failingHost {
            throw URLError(.cannotConnectToHost)
        }
        if url.path == "/api/info", url.host() == heldHost {
            heldHost = nil
            await withCheckedContinuation { waiter = $0 }
        }
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/location":
            // These tests isolate connection ownership from workspace discovery.
            // A discovered directory deliberately reconnects SSE and is covered
            // separately by V2SessionLocationTests.
            return (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
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
    var lastStreamURL: URL? { lock.withLock { streams.last?.request.url } }
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
