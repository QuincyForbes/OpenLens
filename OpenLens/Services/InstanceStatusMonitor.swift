import Foundation
import Observation

/// On-demand reachability and active-session probe across all saved OpenCode instances.
/// Runs bounded concurrent probes only when the user opens the instance switcher/settings,
/// so background battery and network cost stays zero.
@MainActor @Observable
final class InstanceStatusMonitor {

    enum Status: Equatable, Sendable {
        case unknown
        case checking
        case online(protocolVersion: OpenCodeProtocolVersion, serverVersion: String?, activeSessionCount: Int?)
        case offline(String)

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    private(set) var statuses: [String: Status] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let transport: (any OpenCodeTransport)?

    init(transport: (any OpenCodeTransport)? = nil) {
        self.transport = transport
    }

    func status(for connectionID: String) -> Status {
        statuses[connectionID] ?? .unknown
    }

    /// Concurrently checks every saved OpenCode instance with a short bounded timeout.
    func refreshStatuses(
        for connections: [SavedConnection],
        activeConnectionID: String?,
        activeConnection: ConnectionManager?,
        activeSessionCount: Int? = nil
    ) {
        refreshTask?.cancel()
        guard !connections.isEmpty else {
            statuses = [:]
            isRefreshing = false
            return
        }

        let validIDs = Set(connections.map(\.id))
        statuses = statuses.filter { validIDs.contains($0.key) }

        var toProbe: [(id: String, baseURL: URL?, authHeader: String?)] = []
        for saved in connections {
            if saved.id == activeConnectionID,
               let activeConnection,
               activeConnection.isConnected,
               let capabilities = activeConnection.serverCapabilities {
                statuses[saved.id] = .online(
                    protocolVersion: capabilities.protocolVersion,
                    serverVersion: activeConnection.serverVersion,
                    activeSessionCount: activeSessionCount
                )
            } else {
                statuses[saved.id] = .checking
                let authHeader = ConnectionManager.makeBasicAuthHeader(
                    username: saved.username,
                    password: saved.password
                )
                toProbe.append((id: saved.id, baseURL: saved.baseURL, authHeader: authHeader))
            }
        }

        guard !toProbe.isEmpty else {
            isRefreshing = false
            return
        }

        isRefreshing = true
        let transport = self.transport
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (String, Status).self) { group in
                for target in toProbe {
                    group.addTask {
                        let status = await Self.probe(
                            baseURL: target.baseURL,
                            authHeader: target.authHeader,
                            transport: transport
                        )
                        return (target.id, status)
                    }
                }

                for await (id, status) in group {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.statuses[id] = status
                    }
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isRefreshing = false
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private nonisolated static func probe(
        baseURL: URL?,
        authHeader: String?,
        transport: (any OpenCodeTransport)?
    ) async -> Status {
        guard let baseURL else {
            return .offline("Invalid address")
        }
        let client = OpenCodeClient(
            baseURL: baseURL,
            authHeader: authHeader,
            transport: transport
        )
        do {
            let capabilities = try await client.probeCapabilities(timeout: 3)
            guard capabilities.isHealthy else {
                return .offline("Unhealthy")
            }
            let activeCount: Int?
            if let sessionStatuses = try? await client.getSessionStatus() {
                activeCount = sessionStatuses.values.filter { $0.type == .busy || $0.type == .retry }.count
            } else {
                activeCount = nil
            }
            return .online(
                protocolVersion: capabilities.protocolVersion,
                serverVersion: capabilities.serverVersion,
                activeSessionCount: activeCount
            )
        } catch is CancellationError {
            return .unknown
        } catch {
            return .offline(error.localizedDescription)
        }
    }
}
