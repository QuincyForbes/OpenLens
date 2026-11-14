import Foundation
import Network
import os.log

/// Central connection manager that owns the API client and SSE client.
@MainActor @Observable
final class ConnectionManager: ConnectionProviding {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case error(String)
    }

    private(set) var state: State = .disconnected
    private(set) var serverVersion: String?
    private(set) var serverCapabilities: OpenCodeServerCapabilities?
    private(set) var currentProject: OCProject?
    private(set) var projectName: String?
    private(set) var branch: String?
    private(set) var selectedProjectDirectory: String?

    var windowsSystemDrive: String? {
        serverCapabilities?.windowsSystemDrive
            ?? WorkspaceSelectionBuilder.windowsDrivePrefix(in: selectedProjectDirectory)
            ?? WorkspaceSelectionBuilder.windowsDrivePrefix(in: currentProject?.worktree)
    }

    var defaultServerRootDirectory: String {
        windowsSystemDrive.map { "\($0)\\" } ?? "/"
    }
    private(set) var projectContextRevision: UInt = 0
    private var projectContextGeneration: UInt = 0
    @ObservationIgnored private var globalFormRecoveryDirectories: Set<String> = []
    @ObservationIgnored private var cachedProjectMetadataByDirectory: [String: (pathInfo: OCPathInfo?, project: OCProject?, branch: String?)] = [:]
    private(set) var connectionMethod: ConnectionMethod?
    private(set) var serverURL: URL?
    private(set) var localNetworkAccessRequired: Bool = false

    /// Set to `true` when the user explicitly disconnects via Settings.
    /// Prevents auto-reconnect from firing until the user manually connects again.
    private(set) var didManuallyDisconnect: Bool = false

    /// Set on the first connection attempt of this app run, so opening the app reconnects only once.
    private(set) var hasAttemptedConnection: Bool = false

    /// Reference to the shared saved connections store, set from the composition root.
    @ObservationIgnored var savedConnectionsStore: SavedConnectionsStore?

    private(set) var client: OpenCodeClient?
    private(set) var sseClient: SSEClient?

    /// Continuation used to bridge the SSE callback-based connection into async/await.
    /// Resumed once when SSE reports `.connected` or fails to connect.
    private var sseConnectionContinuation: CheckedContinuation<Void, Never>?
    private var connectionGeneration: UInt = 0
    @ObservationIgnored private var sseConnectionDeadline: Task<Void, Never>?
    @ObservationIgnored private var transport: (any OpenCodeTransport)?
    private var sseConnectionTimeout: Duration = .seconds(30)

    /// Timestamp of the last liveness signal: stream bytes or a heartbeat event.
    /// Used by the heartbeat watchdog to detect silently dead connections.
    @ObservationIgnored private var lastHeartbeat: Date = .distantPast
    @ObservationIgnored private var heartbeatWatchdog: Timer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastNetworkInterfaceSignature: String?
    @ObservationIgnored private var pathReconnectTask: Task<Void, Never>?
    private static let pathChangeDebounce: Duration = .seconds(1)

    @ObservationIgnored private let localNetworkAccessProbe: any LocalNetworkAccessProbing
    @ObservationIgnored private let lanServerDiscoverer: (any LANServerDiscovering)?
    @ObservationIgnored private var endpointRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var activeAuthHeader: String?
    @ObservationIgnored private var activeCredentials: (username: String, password: String)?
    private var reconnectingRecoveryInitialDelay: Duration = .milliseconds(2500)
    @ObservationIgnored var onGlobalSessionActivity: ((GlobalSessionActivityEvent) -> Void)?

    /// If no heartbeat arrives within this interval, the connection is considered stale.
    /// OpenCode server typically sends heartbeats every ~15-30s; 60s catches zombie sockets quickly.
    private static let heartbeatTimeout: TimeInterval = 60

    init() {
        self.localNetworkAccessProbe = LocalNetworkAccessProbe()
        self.lanServerDiscoverer = BonjourLANServerDiscoverer()
    }

    init(localNetworkAccessProbe: any LocalNetworkAccessProbing,
         transport: (any OpenCodeTransport)? = nil,
         sseConnectionTimeout: Duration = .seconds(30),
         lanServerDiscoverer: (any LANServerDiscovering)? = nil,
         reconnectingRecoveryInitialDelay: Duration = .milliseconds(2500)) {
        self.localNetworkAccessProbe = localNetworkAccessProbe
        self.transport = transport
        self.sseConnectionTimeout = sseConnectionTimeout
        self.lanServerDiscoverer = lanServerDiscoverer
        self.reconnectingRecoveryInitialDelay = reconnectingRecoveryInitialDelay
    }

#if DEBUG
    /// Installs a negotiated client without opening a live network connection.
    init(testClient: OpenCodeClient, capabilities: OpenCodeServerCapabilities, testSSEClient: SSEClient? = nil) {
        self.localNetworkAccessProbe = LocalNetworkAccessProbe()
        self.lanServerDiscoverer = nil
        self.client = testClient
        self.serverCapabilities = capabilities
        self.sseClient = testSSEClient
        self.state = .connected
    }
#endif

    /// Host (with a non-default port) of the connected server, for compact display.
    var serverHostDisplay: String? {
        guard let host = serverURL?.host(percentEncoded: false)?.nilIfBlank else { return nil }
        if let port = serverURL?.port { return "\(host):\(port)" }
        return host
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// True when SSE is reconnecting after a drop. UI can show "Reconnecting..." state.
    var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    // MARK: - Connect

    func connect(url: String, username: String, password: String) async {
        await connect(url: url, username: username, password: password, method: .manual)
    }

    func connect(
        url: String,
        username: String = "opencode",
        password: String = "",
        method: ConnectionMethod = .manual,
        alternateServerURLs: [String] = [],
        replacingConnectionID: String? = nil,
        probeTimeout: TimeInterval? = nil
    ) async {
        // Replacing an attempt must not forget the saved connection: a failed
        // retry would otherwise leave nothing to reconnect to.
        tearDownConnection()
        let generation = connectionGeneration
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await performConnect(
                url: url,
                username: username,
                password: password,
                method: method,
                alternateServerURLs: alternateServerURLs,
                replacingConnectionID: replacingConnectionID,
                probeTimeout: probeTimeout,
                generation: generation
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.tearDownConnection()
            }
        }
    }

    private func performConnect(
        url: String,
        username: String,
        password: String,
        method: ConnectionMethod,
        alternateServerURLs: [String],
        replacingConnectionID: String?,
        probeTimeout: TimeInterval?,
        generation: UInt
    ) async {
        didManuallyDisconnect = false
        hasAttemptedConnection = true
        connectionMethod = method
        localNetworkAccessRequired = false
        serverCapabilities = nil
        currentProject = nil

        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Server URL is empty.")
            return
        }

        let normalizedInput = normalizeScopedIPv4Address(in: trimmed)
        let urlString = normalizedInput.contains("://") ? normalizedInput : "http://\(normalizedInput)"
        guard let baseURL = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        state = .connecting

        let localNetworkProbeResult = await localNetworkAccessProbe.probe(baseURL)
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        guard localNetworkProbeResult == .continueConnection else {
            localNetworkAccessRequired = true
            state = .error(AppText.localNetworkAccessRequiredBody)
            return
        }

        let authHeader = Self.makeBasicAuthHeader(username: username, password: password)

        let restoredProjectDirectory = WorkspaceSelectionBuilder.normalizedDirectory(
            savedConnectionsStore?
                .matchingConnection(
                    serverURL: urlString,
                    username: username,
                    connectionID: replacingConnectionID
                )?
                .selectedProjectDirectory
        )

        Logger.connection.debug("Connecting to \(urlString, privacy: .public) with restored project directory \(restoredProjectDirectory ?? "nil", privacy: .public)")

        let apiClient = OpenCodeClient(
            baseURL: baseURL,
            authHeader: authHeader,
            contextDirectory: restoredProjectDirectory,
            transport: transport
        )
        do {
            let capabilities = try await apiClient.probeCapabilities(timeout: probeTimeout)
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            guard capabilities.isHealthy else {
                state = .error("Server is not healthy.")
                return
            }
            serverCapabilities = capabilities
            serverVersion = capabilities.serverVersion

            self.client = apiClient
            self.activeAuthHeader = authHeader
            self.activeCredentials = (username: username, password: password)
            globalFormRecoveryDirectories = []
            cachedProjectMetadataByDirectory = [:]
            self.serverURL = baseURL
            let healedRestoredDirectory = WorkspaceSelectionBuilder.healServerDirectory(
                restoredProjectDirectory,
                windowsDrive: capabilities.windowsSystemDrive
            )
            if healedRestoredDirectory != restoredProjectDirectory {
                await apiClient.updateContextDirectory(healedRestoredDirectory)
            }
            self.selectedProjectDirectory = healedRestoredDirectory?.nilIfBlank

            SharedConnectionStore.save(
                baseURL: baseURL.absoluteString, authHeader: authHeader,
                protocolVersion: capabilities.protocolVersion.rawValue
            )

            savedConnectionsStore?.saveConnection(
                serverURL: urlString,
                username: username,
                password: password,
                alternateServerURLs: alternateServerURLs,
                replacingConnectionID: replacingConnectionID
            )
            if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
                savedConnectionsStore?.updateProjectSelection(
                    connectionID: activeConnectionID,
                    directory: self.selectedProjectDirectory
                )
            }

            let sse = SSEClient(
                baseURL: baseURL,
                authHeader: authHeader,
                protocolVersion: capabilities.protocolVersion,
                contextDirectory: selectedProjectDirectory,
                transport: transport
            )
            self.sseClient = sse
            configureSSECallbacks(sse)

            async let metadataRefresh: Void = refreshProjectMetadata()
            async let sseConnect: Void = connectSSEAndWait(sse)
            _ = await (metadataRefresh, sseConnect)
        } catch {
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            state = .error(error.localizedDescription)
        }
    }

    /// Reconnect using saved config, falling back to sibling pairing origins,
    /// Bonjour-advertised LAN ports, or default port 4096 when a computer restarts.
    func reconnect() async {
        guard let saved = savedConnectionsStore?.mostRecent, saved.isConfigured else { return }
        await connectSaved(saved, method: .autoReconnect)
    }

    func connectSaved(_ saved: SavedConnection, method: ConnectionMethod = .autoReconnect) async {
        guard saved.isConfigured else { return }
        let primaryIsLocal = saved.baseURL.map(LocalNetworkAccessProbe.requiresLocalNetworkProbe) ?? false

        await connect(
            url: saved.serverURL,
            username: saved.username,
            password: saved.password,
            method: method,
            alternateServerURLs: saved.alternateServerURLs ?? [],
            replacingConnectionID: saved.id,
            probeTimeout: primaryIsLocal ? 6 : 10
        )

        guard !isConnected,
              !Task.isCancelled,
              !didManuallyDisconnect,
              !localNetworkAccessRequired else {
            return
        }

        let primaryErrorState = state
        let fallbackGeneration = connectionGeneration
        state = .connecting

        await withTaskCancellationHandler {
            let alternates = saved.alternateServerURLs ?? []
            let knownLocalHosts = Self.localHosts(from: [saved.serverURL] + alternates)
            let discovered: [BonjourDiscovery.DiscoveredServer]
            if !knownLocalHosts.isEmpty, let lanServerDiscoverer {
                discovered = await lanServerDiscoverer.discoverServers(
                    timeout: .milliseconds(2200),
                    preferredHosts: knownLocalHosts
                )
            } else {
                discovered = []
            }

            guard !Task.isCancelled, !didManuallyDisconnect, connectionGeneration == fallbackGeneration else {
                return
            }

            let candidates = Self.fallbackCandidateURLs(
                primaryURL: saved.serverURL,
                alternateURLs: alternates,
                discoveredServers: discovered
            )
            guard !candidates.isEmpty else {
                state = primaryErrorState
                return
            }

            let authHeader = Self.makeBasicAuthHeader(username: saved.username, password: saved.password)
            let preservedAlternates = [saved.serverURL] + alternates

            for candidate in candidates {
                guard !Task.isCancelled, !didManuallyDisconnect, connectionGeneration == fallbackGeneration else {
                    return
                }
                let normalizedCandidate = normalizeScopedIPv4Address(in: candidate)
                let candidateURLString = normalizedCandidate.contains("://")
                    ? normalizedCandidate
                    : "http://\(normalizedCandidate)"
                guard let candidateURL = URL(string: candidateURLString) else { continue }

                let probeResult = await localNetworkAccessProbe.probe(candidateURL)
                guard !Task.isCancelled, !didManuallyDisconnect, connectionGeneration == fallbackGeneration else {
                    return
                }
                guard probeResult == .continueConnection else {
                    localNetworkAccessRequired = true
                    state = .error(AppText.localNetworkAccessRequiredBody)
                    return
                }

                let probeClient = OpenCodeClient(
                    baseURL: candidateURL,
                    authHeader: authHeader,
                    transport: transport
                )
                guard let capabilities = try? await probeClient.probeCapabilities(timeout: 4),
                      capabilities.isHealthy else {
                    continue
                }

                guard !Task.isCancelled, !didManuallyDisconnect, connectionGeneration == fallbackGeneration else {
                    return
                }
                Logger.connection.info("Recovered saved connection via fallback endpoint \(candidateURLString, privacy: .public)")
                await connect(
                    url: candidateURLString,
                    username: saved.username,
                    password: saved.password,
                    method: method,
                    alternateServerURLs: preservedAlternates,
                    replacingConnectionID: saved.id,
                    probeTimeout: 6
                )
                if isConnected || Task.isCancelled || didManuallyDisconnect || localNetworkAccessRequired {
                    return
                }
                break
            }

            if !Task.isCancelled && !didManuallyDisconnect && !isConnected {
                state = primaryErrorState
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionGeneration == fallbackGeneration,
                      self.state == .connecting else { return }
                self.tearDownConnection()
            }
        }
    }

    /// Quietly checks whether the most recent saved server (or one of its LAN/Bonjour fallbacks)
    /// has finished booting and is ready to accept connections, without mutating `state`.
    func probeSavedServerAvailability() async -> Bool {
        guard !isConnected,
              !didManuallyDisconnect,
              let saved = savedConnectionsStore?.mostRecent,
              saved.isConfigured else {
            return false
        }

        let alternates = saved.alternateServerURLs ?? []
        let knownLocalHosts = Self.localHosts(from: [saved.serverURL] + alternates)
        let discovered: [BonjourDiscovery.DiscoveredServer]
        if !knownLocalHosts.isEmpty, let lanServerDiscoverer {
            discovered = await lanServerDiscoverer.discoverServers(
                timeout: .milliseconds(1500),
                preferredHosts: knownLocalHosts
            )
        } else {
            discovered = []
        }
        guard !Task.isCancelled else { return false }

        let allCandidates = [saved.serverURL] + Self.fallbackCandidateURLs(
            primaryURL: saved.serverURL,
            alternateURLs: alternates,
            discoveredServers: discovered
        )
        let authHeader = Self.makeBasicAuthHeader(username: saved.username, password: saved.password)

        for candidate in allCandidates {
            guard !Task.isCancelled else { return false }
            let normalized = normalizeScopedIPv4Address(in: candidate)
            let urlString = normalized.contains("://") ? normalized : "http://\(normalized)"
            guard let url = URL(string: urlString) else { continue }
            guard await localNetworkAccessProbe.probe(url) == .continueConnection else {
                return false
            }
            let probeClient = OpenCodeClient(baseURL: url, authHeader: authHeader, transport: transport)
            if let capabilities = try? await probeClient.probeCapabilities(timeout: 3),
               capabilities.isHealthy {
                return true
            }
        }

        return false
    }

    // MARK: - Disconnect

    func disconnect() {
        tearDownConnection()
        savedConnectionsStore?.clearActiveConnection()
        SharedConnectionStore.clear()
    }

    /// Stops the live connection without changing the saved active connection.
    private func tearDownConnection() {
        connectionGeneration &+= 1
        projectContextGeneration &+= 1
        projectContextRevision &+= 1
        stopEndpointRecovery()
        finishSSEConnectionWait()
        stopHeartbeatWatchdog()
        stopNetworkPathMonitor()
        sseClient?.disconnect()
        sseClient = nil
        client = nil
        activeAuthHeader = nil
        activeCredentials = nil
        globalFormRecoveryDirectories = []
        cachedProjectMetadataByDirectory = [:]
        serverURL = nil
        state = .disconnected
        serverVersion = nil
        serverCapabilities = nil
        currentProject = nil
        projectName = nil
        branch = nil
        selectedProjectDirectory = nil
        connectionMethod = nil
        localNetworkAccessRequired = false
    }

    private func configureSSECallbacks(_ sse: SSEClient) {
        sse.onGlobalSessionActivity = { [weak self, weak sse] event in
            guard let self, let sse, self.sseClient === sse else { return }
            self.onGlobalSessionActivity?(event)
        }
        sse.onStateChange = { [weak self, weak sse] sseState in
            guard let self, let sse, self.sseClient === sse else { return }
            switch sseState {
            case .connected:
                self.stopEndpointRecovery()
                self.state = .connected
                self.startHeartbeatWatchdog()
                self.startNetworkPathMonitor()
                self.finishSSEConnectionWait()
            case .connecting:
                if self.state == .connected {
                    self.enterReconnectingState(trackDisconnection: false)
                }
            case .disconnected:
                if self.state == .connected || self.state == .reconnecting {
                    self.enterReconnectingState(trackDisconnection: true)
                }
            }
        }

        // Any bytes on the stream (including v2 comment keep-alives) prove
        // liveness, independently of whether a chat has attached its handler.
        sse.onLiveness = { [weak self, weak sse] in
            guard let self, let sse, self.sseClient === sse else { return }
            self.receivedHeartbeat()
        }

        sse.onTerminalHTTPError = { [weak self, weak sse] statusCode in
            guard let self, let sse, self.sseClient === sse else { return }
            self.stopEndpointRecovery()
            self.stopHeartbeatWatchdog()
            self.stopNetworkPathMonitor()
            self.state = .error(
                "Authentication failed for the live event stream (HTTP \(statusCode)). Check the OpenCode username and password."
            )
            self.finishSSEConnectionWait()
        }
    }

    private func connectSSEAndWait(_ sse: SSEClient) async {
        guard !Task.isCancelled, sseClient === sse else { return }
        await withCheckedContinuation { continuation in
            sseConnectionContinuation = continuation
            let generation = connectionGeneration
            let timeout = sseConnectionTimeout
            sseConnectionDeadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.connectionGeneration == generation,
                      self.sseClient === sse, self.sseConnectionContinuation != nil else { return }
                self.tearDownConnection()
                self.state = .error("Timed out connecting to the live event stream. Please retry.")
            }
            sse.connect()
        }
    }

    private func finishSSEConnectionWait() {
        sseConnectionDeadline?.cancel()
        sseConnectionDeadline = nil
        let continuation = sseConnectionContinuation
        sseConnectionContinuation = nil
        continuation?.resume()
    }

    func setProjectContext(directory: String?) async {
        projectContextGeneration &+= 1
        let generation = projectContextGeneration
        let normalizedDirectory = WorkspaceSelectionBuilder.healServerDirectory(
            directory,
            windowsDrive: windowsSystemDrive
        )
        Logger.connection.debug("OpenLens changing active project directory from \(self.selectedProjectDirectory ?? "nil", privacy: .public) to \(normalizedDirectory ?? "nil", privacy: .public)")
        guard let client else {
            selectedProjectDirectory = normalizedDirectory
            projectContextRevision &+= 1
            return
        }

        let previousDirectory = await client.updateContextDirectory(normalizedDirectory)
        guard self.client === client else { return }
        // Chat can leave a workspace before any Inbox load has discovered its
        // global forms. Queue that actual routing directory for recovery once.
        if serverCapabilities?.protocolVersion == .v2,
           let previousDirectory, previousDirectory != normalizedDirectory,
           InteractiveFormSafety.fitsGlobalDirectory(previousDirectory) {
            globalFormRecoveryDirectories.insert(previousDirectory)
        }
        // The actor has already changed request routing. Commit the matching
        // published/SSE context even if the caller was cancelled at this await.
        guard generation == projectContextGeneration else { return }
        selectedProjectDirectory = normalizedDirectory
        sseClient?.updateContextDirectory(normalizedDirectory)
        projectContextRevision &+= 1
        if let normalizedDirectory, let cached = cachedProjectMetadataByDirectory[normalizedDirectory] {
            currentProject = cached.project
            projectName = cached.project?.displayName ?? cached.project?.worktree
            branch = cached.branch
        } else {
            currentProject = nil
            projectName = nil
            branch = nil
        }

        if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
            savedConnectionsStore?.updateProjectSelection(
                connectionID: activeConnectionID,
                directory: normalizedDirectory
            )
        }

        await refreshProjectMetadata()
    }

    func takeGlobalFormRecoveryDirectories(using client: OpenCodeClient) -> Set<String> {
        guard self.client === client else { return [] }
        let directories = globalFormRecoveryDirectories
        globalFormRecoveryDirectories = []
        return directories
    }

    func clearProjectContext() async {
        await setProjectContext(directory: nil)
    }

    /// An externally moved session must resolve successfully before its
    /// destination becomes the active workspace. A refusal leaves it untouched.
    func rebindProjectContext(directory: String, isCurrent: () -> Bool = { true }) async throws {
        guard let client else { throw OpenCodeError.notConnected }
        let generation = projectContextGeneration
        guard WorkspaceSelectionBuilder.isAbsoluteServerDirectory(directory),
              let normalized = WorkspaceSelectionBuilder.healServerDirectory(directory, windowsDrive: windowsSystemDrive) else {
            throw OpenCodeError.invalidPayload("The session's new location is not an absolute directory.")
        }
        let location = try await client.resolveLocation(directory: normalized)
        try Task.checkCancellation()
        guard generation == projectContextGeneration, isCurrent() else { throw CancellationError() }
        let drive = location.resolvedWindowsDrive ?? windowsSystemDrive
        let resolvedNormalized = WorkspaceSelectionBuilder.healServerDirectory(location.directory, windowsDrive: drive)
        let expectedNormalized = WorkspaceSelectionBuilder.healServerDirectory(normalized, windowsDrive: drive)
        guard WorkspaceSelectionBuilder.sameServerDirectory(resolvedNormalized, expectedNormalized) else {
            throw OpenCodeError.invalidPayload("The server resolved a different session location.")
        }
        await setProjectContext(directory: resolvedNormalized ?? normalized)
    }

    /// Recovery can retry a cancelled metadata load. For an already committed
    /// directory this preserves the context revision and SSE binding.
    func refreshProjectMetadata() async {
        guard let client else {
            currentProject = nil
            projectName = nil
            branch = nil
            return
        }

        let generation = projectContextGeneration
        let hadSelectedDirectory = selectedProjectDirectory != nil
        async let parallelVCS: OCVCSInfo? = hadSelectedDirectory ? (try? await client.getVCS()) : nil
        let (pathInfo, project) = await client.getLocationMetadata()
        guard !Task.isCancelled, generation == projectContextGeneration else { return }

        Logger.connection.debug("OpenCode reported directory \(pathInfo?.directory ?? "nil", privacy: .public), worktree \(pathInfo?.worktree ?? "nil", privacy: .public), and project worktree \(project?.worktree ?? "nil", privacy: .public)")

        if let project {
            currentProject = project
            projectName = project.displayName ?? project.worktree
        } else {
            currentProject = nil
            projectName = nil
            Logger.connection.warning("Failed to fetch project info")
        }

        if selectedProjectDirectory == nil {
            let serverDirectory = WorkspaceSelectionBuilder.normalizedDirectory(pathInfo?.directory)
            let projectWorktree = WorkspaceSelectionBuilder.normalizedDirectory(project?.worktree)
            let inferredDirectory = serverDirectory ?? projectWorktree
            let source = serverDirectory == nil ? "project worktree fallback" : "server directory"
            Logger.connection.debug("OpenLens initialized active project directory to \(inferredDirectory ?? "nil", privacy: .public) from \(source, privacy: .public)")
            selectedProjectDirectory = inferredDirectory

            if let inferredDirectory {
                await client.updateContextDirectory(inferredDirectory)
                guard generation == projectContextGeneration else { return }
                sseClient?.updateContextDirectory(inferredDirectory)

                if let activeConnectionID = savedConnectionsStore?.activeConnectionID {
                    savedConnectionsStore?.updateProjectSelection(
                        connectionID: activeConnectionID,
                        directory: inferredDirectory
                    )
                }
            }
        } else {
            Logger.connection.debug("OpenLens kept restored/selected project directory \(self.selectedProjectDirectory ?? "nil", privacy: .public)")
        }

        if hadSelectedDirectory {
            let vcs = await parallelVCS
            guard !Task.isCancelled, generation == projectContextGeneration else { return }
            branch = vcs?.branch
        } else {
            do {
                let vcs = try await client.getVCS()
                guard !Task.isCancelled, generation == projectContextGeneration else { return }
                branch = vcs.branch
            } catch {
                guard !Task.isCancelled, generation == projectContextGeneration else { return }
                branch = nil
                Logger.connection.warning("Failed to fetch VCS info: \(error, privacy: .public)")
            }
        }

        if let activeDirectory = selectedProjectDirectory {
            cachedProjectMetadataByDirectory[activeDirectory] = (pathInfo: pathInfo, project: currentProject, branch: branch)
        }
    }

    /// Disconnect triggered explicitly by the user (e.g. from Settings).
    /// Suppresses auto-reconnect until the next manual connect.
    func manualDisconnect() {
        disconnect()
        didManuallyDisconnect = true
    }

    // MARK: - Heartbeat

    /// Called by SSEEventHandler when `server.connected` or `server.heartbeat` arrives.
    /// Resets the heartbeat watchdog timer.
    func receivedHeartbeat() {
        lastHeartbeat = Date()

        // If we were in .reconnecting due to a stale heartbeat, recover to .connected.
        if state == .reconnecting {
            stopEndpointRecovery()
            state = .connected
        }
    }

    /// Start the heartbeat watchdog that checks for stale connections.
    private func startHeartbeatWatchdog() {
        stopHeartbeatWatchdog()
        lastHeartbeat = Date()

        let timer = Timer(timeInterval: Self.heartbeatTimeout / 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.lastHeartbeat)
                if elapsed > Self.heartbeatTimeout, self.state == .connected {
                    Logger.connection.warning("Heartbeat timeout (\(elapsed, format: .fixed(precision: 0))s since last heartbeat) — forcing SSE reconnect")
                    self.enterReconnectingState(trackDisconnection: true)
                    self.sseClient?.reconnectNow()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatWatchdog = timer
    }

    /// Immediately forces a fresh SSE connection if currently reconnecting or if the heartbeat is stale.
    func reconnectIfNeeded() {
        guard !didManuallyDisconnect, sseClient != nil else { return }
        let elapsed = Date().timeIntervalSince(lastHeartbeat)
        if state == .reconnecting || (state == .connected && elapsed > Self.heartbeatTimeout) {
            enterReconnectingState(trackDisconnection: false, immediateEndpointRecovery: true)
            sseClient?.reconnectNow()
        }
    }

    private func startNetworkPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let generation = connectionGeneration
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            let signature = Self.primaryInterfaceSignature(path.availableInterfaces.map { "\($0.type):\($0.name)" })
            Task { @MainActor [weak self] in
                guard let self, !self.didManuallyDisconnect,
                      self.connectionGeneration == generation else { return }
                let previous = self.lastNetworkInterfaceSignature
                self.lastNetworkInterfaceSignature = signature
                let interfaceChanged = previous != nil && previous != signature
                guard self.state == .reconnecting || interfaceChanged else { return }
                // A handoff usually arrives as a burst of path updates; reconnect once it settles.
                self.pathReconnectTask?.cancel()
                self.pathReconnectTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: Self.pathChangeDebounce) } catch { return }
                    guard let self, !self.didManuallyDisconnect,
                          self.connectionGeneration == generation else { return }
                    self.pathReconnectTask = nil
                    Logger.connection.debug("Network path settled (changed=\(interfaceChanged)) — triggering SSE reconnect")
                    self.sseClient?.reconnectNow()
                    if self.state == .reconnecting {
                        self.startEndpointRecoveryIfNeeded(immediate: true)
                    }
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.openlens.network-path-monitor", qos: .utility))
    }

    /// Only the preferred interface carries the stream. A secondary interface
    /// appearing (cellular under weak Wi-Fi, a VPN tunnel) must not reconnect.
    nonisolated static func primaryInterfaceSignature(_ interfaces: [String]) -> String {
        interfaces.first ?? "none"
    }

    private func stopNetworkPathMonitor() {
        pathReconnectTask?.cancel()
        pathReconnectTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkInterfaceSignature = nil
    }

    private func enterReconnectingState(trackDisconnection: Bool, immediateEndpointRecovery: Bool = false) {
        state = .reconnecting
        startEndpointRecoveryIfNeeded(immediate: immediateEndpointRecovery)
    }

    private func stopEndpointRecovery() {
        endpointRecoveryTask?.cancel()
        endpointRecoveryTask = nil
    }

    /// While `.reconnecting` persists (e.g. the host computer restarted), periodically probes
    /// the current URL, sibling pairing URLs, Bonjour-advertised LAN ports, and port 4096 so
    /// OpenLens recovers automatically even when OpenCode restarts on a new port or LAN IP.
    private func startEndpointRecoveryIfNeeded(immediate: Bool = false) {
        guard !didManuallyDisconnect, sseClient != nil else { return }
        if immediate {
            endpointRecoveryTask?.cancel()
            endpointRecoveryTask = nil
        }
        guard endpointRecoveryTask == nil else { return }

        let generation = connectionGeneration
        let initialDelay = reconnectingRecoveryInitialDelay
        endpointRecoveryTask = Task { @MainActor [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: initialDelay)
                } catch {
                    return
                }
            }

            let retryDelays: [Duration] = [.seconds(3), .seconds(5), .seconds(8), .seconds(12)]
            var attempt = 0

            while !Task.isCancelled {
                guard let self,
                      !self.didManuallyDisconnect,
                      self.connectionGeneration == generation,
                      self.state == .reconnecting else {
                    return
                }

                var recoveredOrTriggered = false

                if let currentURL = self.serverURL {
                    let currentProbe = OpenCodeClient(
                        baseURL: currentURL,
                        authHeader: self.activeAuthHeader,
                        transport: self.transport
                    )
                    if let capabilities = try? await currentProbe.probeCapabilities(timeout: 3),
                       capabilities.isHealthy {
                        guard !Task.isCancelled,
                              self.connectionGeneration == generation,
                              self.state == .reconnecting else {
                            return
                        }
                        self.serverCapabilities = capabilities
                        self.serverVersion = capabilities.serverVersion
                        self.sseClient?.updateConnection(
                            baseURL: currentURL,
                            authHeader: self.activeAuthHeader,
                            protocolVersion: capabilities.protocolVersion
                        )
                        self.sseClient?.reconnectNow()
                        recoveredOrTriggered = true
                    }
                }

                if !recoveredOrTriggered {
                    let saved = self.savedConnectionsStore?.activeConnection ?? self.savedConnectionsStore?.mostRecent
                    let primaryString = self.serverURL?.absoluteString ?? saved?.serverURL ?? ""
                    let alternates = saved?.alternateServerURLs ?? []
                    let knownLocalHosts = Self.localHosts(from: [primaryString] + alternates)
                    let discovered: [BonjourDiscovery.DiscoveredServer]
                    if !knownLocalHosts.isEmpty, let lanServerDiscoverer = self.lanServerDiscoverer {
                        discovered = await lanServerDiscoverer.discoverServers(
                            timeout: .milliseconds(2000),
                            preferredHosts: knownLocalHosts
                        )
                    } else {
                        discovered = []
                    }

                    guard !Task.isCancelled,
                          self.connectionGeneration == generation,
                          self.state == .reconnecting else {
                        return
                    }

                    let candidates = Self.fallbackCandidateURLs(
                        primaryURL: primaryString,
                        alternateURLs: alternates,
                        discoveredServers: discovered
                    )

                    for candidate in candidates {
                        guard !Task.isCancelled,
                              self.connectionGeneration == generation,
                              self.state == .reconnecting else {
                            return
                        }
                        let normalizedCandidate = self.normalizeScopedIPv4Address(in: candidate)
                        let candidateURLString = normalizedCandidate.contains("://")
                            ? normalizedCandidate
                            : "http://\(normalizedCandidate)"
                        guard let candidateURL = URL(string: candidateURLString),
                              await self.localNetworkAccessProbe.probe(candidateURL) == .continueConnection else {
                            continue
                        }

                        let candidateClient = OpenCodeClient(
                            baseURL: candidateURL,
                            authHeader: self.activeAuthHeader,
                            transport: self.transport
                        )
                        guard let capabilities = try? await candidateClient.probeCapabilities(timeout: 3),
                              capabilities.isHealthy else {
                            continue
                        }

                        guard !Task.isCancelled,
                              self.connectionGeneration == generation,
                              self.state == .reconnecting else {
                            return
                        }

                        await self.rebindLiveEndpoint(
                            to: candidateURL,
                            urlString: candidateURLString,
                            capabilities: capabilities,
                            savedConnection: saved
                        )
                        break
                    }
                }

                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                attempt += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func rebindLiveEndpoint(
        to candidateURL: URL,
        urlString: String,
        capabilities: OpenCodeServerCapabilities,
        savedConnection: SavedConnection?
    ) async {
        Logger.connection.info("Rebinding live connection to recovered endpoint \(urlString, privacy: .public)")
        self.serverURL = candidateURL
        self.serverCapabilities = capabilities
        self.serverVersion = capabilities.serverVersion

        if let client {
            await client.updateConnection(
                baseURL: candidateURL,
                authHeader: activeAuthHeader,
                contextDirectory: selectedProjectDirectory
            )
            _ = try? await client.probeCapabilities(timeout: 4)
        }

        SharedConnectionStore.save(
            baseURL: candidateURL.absoluteString,
            authHeader: activeAuthHeader,
            protocolVersion: capabilities.protocolVersion.rawValue
        )

        if let creds = activeCredentials {
            let preservedAlternates = [savedConnection?.serverURL].compactMap { $0 }
                + (savedConnection?.alternateServerURLs ?? [])
            savedConnectionsStore?.saveConnection(
                serverURL: urlString,
                username: creds.username,
                password: creds.password,
                alternateServerURLs: preservedAlternates,
                replacingConnectionID: savedConnection?.id ?? savedConnectionsStore?.activeConnectionID
            )
        }

        sseClient?.updateConnection(
            baseURL: candidateURL,
            authHeader: activeAuthHeader,
            protocolVersion: capabilities.protocolVersion
        )
        sseClient?.reconnectNow()

        Task { @MainActor [weak self] in
            await self?.refreshProjectMetadata()
        }
    }

    // MARK: - Fallback Endpoint Ordering

    nonisolated static func makeBasicAuthHeader(username: String, password: String) -> String? {
        guard !password.isEmpty else { return nil }
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    nonisolated static func localHosts(from rawURLs: [String]) -> Set<String> {
        var hosts = Set<String>()
        for raw in rawURLs {
            guard let parsed = parsedHostAndPort(raw),
                  LocalNetworkAccessProbe.requiresLocalNetworkProbe(for: parsed.url) else {
                continue
            }
            hosts.insert(parsed.host)
        }
        return hosts
    }

    /// Produces deduplicated fallback server URLs ordered from highest-confidence same-host
    /// LAN candidates to general LAN Bonjour discoveries and remote tunnel alternates.
    nonisolated static func fallbackCandidateURLs(
        primaryURL: String,
        alternateURLs: [String],
        discoveredServers: [BonjourDiscovery.DiscoveredServer]
    ) -> [String] {
        let primaryKey = normalizedEndpointKey(primaryURL)
        let primaryHost = parsedHostAndPort(primaryURL)?.host
        let knownLocalHosts = localHosts(from: [primaryURL] + alternateURLs)

        var seen: Set<String> = primaryKey.isEmpty ? [] : [primaryKey]
        var ordered: [String] = []

        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedEndpointKey(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, seen.insert(key).inserted else { return }
            ordered.append(trimmed)
        }

        // 1. Live Bonjour server advertised on the exact same primary host (new port after restart).
        if let primaryHost {
            for server in discoveredServers where server.host.lowercased() == primaryHost {
                append(server.url)
            }
        }

        // 2. Local / VPN / Tailscale sibling URLs from pairing or connection history, plus any
        //    live Bonjour server matching one of those local hosts.
        var remoteAlternates: [String] = []
        for alt in alternateURLs {
            if let parsed = parsedHostAndPort(alt),
               LocalNetworkAccessProbe.requiresLocalNetworkProbe(for: parsed.url) {
                append(alt)
                for server in discoveredServers where server.host.lowercased() == parsed.host {
                    append(server.url)
                }
            } else {
                remoteAlternates.append(alt)
            }
        }

        // 3. Standard OpenCode port 4096 on known local hosts (when previously paired on an ephemeral port).
        if let primaryParsed = parsedHostAndPort(primaryURL),
           LocalNetworkAccessProbe.requiresLocalNetworkProbe(for: primaryParsed.url),
           primaryParsed.port != 4096 {
            let hostLiteral = primaryParsed.host.contains(":") ? "[\(primaryParsed.host)]" : primaryParsed.host
            append("http://\(hostLiteral):4096")
        }
        for host in knownLocalHosts.sorted() where host != primaryHost {
            let hostLiteral = host.contains(":") ? "[\(host)]" : host
            append("http://\(hostLiteral):4096")
        }

        // 4. Other live OpenCode Bonjour servers on the LAN (router assigned a new DHCP IP after reboot).
        for server in discoveredServers {
            append(server.url)
        }

        // 5. Remote tunnel alternates (e.g. `--remote` URLs).
        for alt in remoteAlternates {
            append(alt)
        }

        return ordered
    }

    nonisolated private static func normalizedEndpointKey(_ rawURL: String) -> String {
        rawURL.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated private static func parsedHostAndPort(_ rawURL: String) -> (host: String, port: Int?, url: URL)? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host(percentEncoded: false)?
                  .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                  .lowercased()
                  .nilIfBlank
        else {
            return nil
        }
        return (host: host, port: url.port, url: url)
    }

    private func stopHeartbeatWatchdog() {
        heartbeatWatchdog?.invalidate()
        heartbeatWatchdog = nil
    }

    private func normalizeScopedIPv4Address(in rawURL: String) -> String {
        guard let schemeRange = rawURL.range(of: "://") else {
            return normalizeScopedIPv4Address(inHostPort: rawURL)
        }

        let prefix = String(rawURL[..<schemeRange.upperBound])
        let rest = String(rawURL[schemeRange.upperBound...])
        return prefix + normalizeScopedIPv4Address(inHostPort: rest)
    }

    private func normalizeScopedIPv4Address(inHostPort hostPortAndPath: String) -> String {
        let separators = ["/", "?", "#"]
        let splitIndex = separators
            .compactMap { hostPortAndPath.firstIndex(of: Character($0)) }
            .min() ?? hostPortAndPath.endIndex

        let authority = String(hostPortAndPath[..<splitIndex])
        let suffix = String(hostPortAndPath[splitIndex...])

        guard let portSeparator = authority.lastIndex(of: ":") else {
            return sanitizeIPv4Scope(in: authority) + suffix
        }

        let host = String(authority[..<portSeparator])
        let port = String(authority[portSeparator...])
        return sanitizeIPv4Scope(in: host) + port + suffix
    }

    private func sanitizeIPv4Scope(in host: String) -> String {
        guard let percentIndex = host.firstIndex(of: "%") else {
            return host
        }

        let candidate = String(host[..<percentIndex])
        let parts = candidate.split(separator: ".")
        guard parts.count == 4 else { return host }

        let isIPv4 = parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }

        return isIPv4 ? candidate : host
    }

    // MARK: - Demo Mode

    /// Configures the connection manager with fake state for demo mode.
    /// The header toolbar reads projectName/branch/state from the connection.
    func configureDemoState(projectName: String = "my-project", branch: String = "main") {
        self.state = .connected
        self.projectName = projectName
        self.branch = branch
        self.serverVersion = "demo"
        self.serverURL = URL(string: "http://macbook-pro.local:4096")
        self.serverCapabilities = nil
    }
}
