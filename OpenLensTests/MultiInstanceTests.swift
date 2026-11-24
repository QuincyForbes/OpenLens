import Foundation
import Testing
@testable import OpenLens

@MainActor
@Suite(.serialized)
struct MultiInstanceTests {

    @Test func supportsFriendlyNamesEditingAndSearchWithoutChangingActiveInstance() {
        let store = SavedConnectionsStore(initialConnections: [])
        let first = store.saveConnection(
            serverURL: "http://192.168.1.10:4096",
            username: "opencode",
            password: "pw1",
            name: "MacBook Pro"
        )

        #expect(first.hasCustomName)
        #expect(first.displayName == "MacBook Pro")
        #expect(first.hostDisplay == "192.168.1.10:4096")
        #expect(store.activeConnectionID == first.id)

        // Adding a second instance without switching preserves the active instance.
        let second = store.addOrUpdateInstance(
            name: "Work Linux",
            serverURL: "http://100.64.0.22:4096",
            username: "dev",
            password: "pw2"
        )

        #expect(store.connections.count == 2)
        #expect(store.activeConnectionID == first.id)
        #expect(second.displayName == "Work Linux")
        #expect(second.hostDisplay == "100.64.0.22:4096")

        // Suggestions match by friendly name as well as host.
        #expect(store.suggestions(for: "linux").map(\.id) == [second.id])
        #expect(store.suggestions(for: "192.168").map(\.id) == [first.id])

        // Renaming updates displayName cleanly, and blank clears back to hostDisplay.
        store.renameConnection(id: second.id, name: "Lab Box")
        #expect(store.connections.first(where: { $0.id == second.id })?.displayName == "Lab Box")

        store.renameConnection(id: second.id, name: "   ")
        let cleared = store.connections.first(where: { $0.id == second.id })
        #expect(cleared?.hasCustomName == false)
        #expect(cleared?.displayName == "100.64.0.22:4096")
    }

    @Test func publicSnapshotPreservesCustomInstanceName() {
        let original = SavedConnection(
            id: "inst-named",
            name: "Studio Desktop",
            serverURL: "http://10.0.0.5:4096",
            username: "opencode",
            password: "secret",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [],
            withPublicSnapshots: [SavedConnectionPublicSnapshot(connection: original)]
        )

        #expect(restored.first?.name == "Studio Desktop")
        #expect(restored.first?.displayName == "Studio Desktop")
        #expect(restored.first?.hostDisplay == "10.0.0.5:4096")
    }

    @Test func lanFallbackExcludesOtherSavedInstances() {
        let store = SavedConnectionsStore(initialConnections: [])
        let instanceA = store.saveConnection(
            serverURL: "http://192.168.1.10:4096",
            username: "opencode",
            password: "",
            name: "Machine A"
        )
        let instanceB = store.addOrUpdateInstance(
            name: "Machine B",
            serverURL: "http://192.168.1.20:4096",
            username: "opencode",
            password: ""
        )

        let excludedForA = store.otherSavedEndpointKeys(excludingConnectionID: instanceA.id)
        #expect(excludedForA.contains("192.168.1.20:4096"))
        #expect(!excludedForA.contains("192.168.1.10:4096"))

        let discovered = [
            BonjourDiscovery.DiscoveredServer(
                id: "b",
                name: "opencode-4096",
                host: "192.168.1.20",
                port: 4096
            ),
            BonjourDiscovery.DiscoveredServer(
                id: "a-new-port",
                name: "opencode-4097",
                host: "192.168.1.10",
                port: 4097
            ),
        ]

        let candidates = ConnectionManager.fallbackCandidateURLs(
            primaryURL: instanceA.serverURL,
            alternateURLs: [],
            discoveredServers: discovered,
            excludingEndpoints: excludedForA
        )

        #expect(candidates.contains("http://192.168.1.10:4097"))
        #expect(!candidates.contains("http://192.168.1.20:4096"))
        #expect(instanceB.serverURL == "http://192.168.1.20:4096")
    }

    @Test func liveInstanceSwitchSwapsHealthyServerAndPreservesCurrentWhenTargetIsOffline() async {
        let transport = MultiInstanceTransport(
            healthyHosts: ["alpha.example.com", "beta.example.com"],
            offlineHosts: ["offline.example.com"]
        )
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = ConnectionManager(
            localNetworkAccessProbe: MultiInstanceAccessProbe(),
            transport: transport
        )
        connection.savedConnectionsStore = store

        let alpha = store.saveConnection(
            serverURL: "https://alpha.example.com",
            username: "opencode",
            password: "pw-a",
            name: "Alpha"
        )
        let beta = store.addOrUpdateInstance(
            name: "Beta",
            serverURL: "https://beta.example.com",
            username: "opencode",
            password: "pw-b"
        )
        let offline = store.addOrUpdateInstance(
            name: "Offline Box",
            serverURL: "https://offline.example.com",
            username: "opencode",
            password: ""
        )

        // Connect initially to Alpha.
        await connection.connectSaved(alpha, method: .manual)
        #expect(connection.isConnected)
        #expect(connection.serverURL?.host() == "alpha.example.com")
        #expect(connection.activeInstanceDisplayName == "Alpha")
        #expect(connection.cacheScopeKey == "conn:\(alpha.id)")
        let alphaClient = connection.client
        let initialRevision = connection.instanceSwitchRevision

        // Attempting to switch to an offline instance must fail and keep Alpha alive & untouched.
        let offlineResult = await connection.switchToInstance(offline)
        if case .success = offlineResult {
            Issue.record("Expected switching to an offline instance to fail")
        }
        #expect(connection.isConnected)
        #expect(connection.client === alphaClient)
        #expect(connection.serverURL?.host() == "alpha.example.com")
        #expect(store.activeConnectionID == alpha.id)
        #expect(connection.instanceSwitchRevision == initialRevision)

        // Switching to healthy Beta swaps live without dropping state.
        let betaResult = await connection.switchToInstance(beta)
        if case .failure(let error) = betaResult {
            Issue.record("Expected switching to Beta to succeed, got \(error)")
        }
        #expect(connection.isConnected)
        #expect(connection.client !== alphaClient)
        #expect(connection.serverURL?.host() == "beta.example.com")
        #expect(connection.activeInstanceDisplayName == "Beta")
        #expect(store.activeConnectionID == beta.id)
        #expect(connection.cacheScopeKey == "conn:\(beta.id)")
        #expect(connection.instanceSwitchRevision == initialRevision + 1)

        // Updating the active instance's URL and calling switchToInstance with forceReconnect
        // reconnects to the updated endpoint while keeping the same connection ID.
        let editedBeta = store.addOrUpdateInstance(
            id: beta.id,
            name: "Beta Updated",
            serverURL: "https://alpha.example.com",
            username: "opencode",
            password: "pw-b2"
        )
        let reconnectResult = await connection.switchToInstance(editedBeta, forceReconnect: true)
        if case .failure(let error) = reconnectResult {
            Issue.record("Expected forceReconnect on edited active instance to succeed, got \(error)")
        }
        #expect(connection.isConnected)
        #expect(connection.serverURL?.host() == "alpha.example.com")
        #expect(connection.activeInstanceDisplayName == "Beta Updated")
        #expect(store.activeConnectionID == beta.id)
        #expect(connection.instanceSwitchRevision == initialRevision + 2)
    }

    @Test func statusMonitorProbesMultipleInstancesConcurrently() async {
        let transport = MultiInstanceTransport(
            healthyHosts: ["alpha.example.com", "beta.example.com"],
            offlineHosts: ["gamma.example.com"],
            busyCountByHost: ["beta.example.com": 2]
        )
        let monitor = InstanceStatusMonitor(transport: transport)
        let store = SavedConnectionsStore(initialConnections: [])
        let alpha = store.saveConnection(
            serverURL: "https://alpha.example.com",
            username: "opencode",
            password: "",
            name: "Alpha"
        )
        let beta = store.addOrUpdateInstance(
            name: "Beta",
            serverURL: "https://beta.example.com",
            username: "opencode",
            password: ""
        )
        let gamma = store.addOrUpdateInstance(
            name: "Gamma",
            serverURL: "https://gamma.example.com",
            username: "opencode",
            password: ""
        )

        monitor.refreshStatuses(
            for: [alpha, beta, gamma],
            activeConnectionID: nil,
            activeConnection: nil
        )

        for _ in 0..<40 where monitor.isRefreshing {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(!monitor.isRefreshing)
        #expect(monitor.status(for: alpha.id).isOnline)
        if case .online(_, _, let running) = monitor.status(for: beta.id) {
            #expect(running == 2)
        } else {
            Issue.record("Expected Beta to report online with 2 running sessions")
        }
        if case .offline = monitor.status(for: gamma.id) {
            // expected
        } else {
            Issue.record("Expected Gamma to report offline")
        }
    }

    @Test func routerResetForInstanceSwitchClearsAllStacks() {
        let router = AppRouter()
        router.selectedTab = .workspace
        router.chatPath = [.sessionInsights(sessionID: "ses_1")]
        router.reviewPath = [.sessionInsights(sessionID: "ses_2")]
        router.workspacePath = [.sessionInsights(sessionID: "ses_3")]
        router.settingsPath = [.sessionInsights(sessionID: "ses_4")]

        router.resetForInstanceSwitch()

        #expect(router.selectedTab == .chat)
        #expect(router.chatPath.isEmpty)
        #expect(router.reviewPath.isEmpty)
        #expect(router.workspacePath.isEmpty)
        #expect(router.settingsPath.isEmpty)
    }
}

// MARK: - Test Transport

@MainActor
private final class MultiInstanceAccessProbe: LocalNetworkAccessProbing {
    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult { .continueConnection }
}

nonisolated private final class MultiInstanceTransport: OpenCodeTransport, @unchecked Sendable {
    let healthyHosts: Set<String>
    let offlineHosts: Set<String>
    let busyCountByHost: [String: Int]

    init(
        healthyHosts: Set<String>,
        offlineHosts: Set<String>,
        busyCountByHost: [String: Int] = [:]
    ) {
        self.healthyHosts = healthyHosts
        self.offlineHosts = offlineHosts
        self.busyCountByHost = busyCountByHost
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host() else {
            throw URLError(.badURL)
        }
        if offlineHosts.contains(host) || !healthyHosts.contains(host) {
            throw URLError(.cannotConnectToHost)
        }

        let body: String
        switch url.path {
        case "/api/info":
            body = #"{"version":"2.1.0"}"#
        case "/api/location":
            return (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        case "/api/vcs":
            body = #"{"location":{"directory":"/workspace"},"data":{"branch":"main"}}"#
        case "/api/session/active":
            let busyCount = busyCountByHost[host] ?? 0
            if busyCount == 0 {
                body = #"{"data":{}}"#
            } else {
                let entries = (0..<busyCount)
                    .map { #""ses_\#($0)":{"type":"busy"}"# }
                    .joined(separator: ",")
                body = #"{"data":{\#(entries)}}"#
            }
        case "/session/status":
            let busyCount = busyCountByHost[host] ?? 0
            if busyCount == 0 {
                body = "{}"
            } else {
                let entries = (0..<busyCount)
                    .map { #""ses_\#($0)":{"type":"busy"}"# }
                    .joined(separator: ",")
                body = "{\(entries)}"
            }
        default:
            body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        ImmediateEventStream(request: request, queue: deliveryQueue, callbacks: callbacks)
    }
}

nonisolated private final class ImmediateEventStream: OpenCodeEventStream, @unchecked Sendable {
    let request: URLRequest
    private let queue: DispatchQueue
    private let callbacks: OpenCodeEventStreamCallbacks

    init(
        request: URLRequest,
        queue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) {
        self.request = request
        self.queue = queue
        self.callbacks = callbacks
    }

    func start() {
        queue.async { [self] in
            if let url = request.url,
               let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
               ) {
                _ = callbacks.onResponse(response)
            }
        }
    }

    func suspend() {}
    func resume() {}
    func cancel() {}
}
