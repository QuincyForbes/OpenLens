import Foundation
import Network

/// Performs the narrow, connection-specific local-network check supported by
/// Network.framework. iOS does not provide a general API for reading this
/// permission without attempting a local network operation.
@MainActor
protocol LocalNetworkAccessProbing: AnyObject {
    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult
}

enum LocalNetworkAccessProbeResult: Equatable, Sendable {
    case continueConnection
    case accessRequired
}

/// Starts a lightweight TCP connection before the HTTP health request.
///
/// When iOS presents the Local Network alert, Network.framework can initially
/// report `.localNetworkDenied` before the person answers. The connection is
/// retried automatically after Allow, so this probe waits briefly for that
/// decision instead of treating the first waiting state as a permanent denial.
@MainActor
final class LocalNetworkAccessProbe: LocalNetworkAccessProbing {
    private static let permissionDecisionTimeout: Duration = .seconds(12)

    private let queue = DispatchQueue(label: "app.openlens.local-network-probe")

    func probe(_ url: URL) async -> LocalNetworkAccessProbeResult {
        guard Self.requiresLocalNetworkProbe(for: url),
              let endpoint = endpoint(for: url) else {
            return .continueConnection
        }

        let coordinator = LocalNetworkProbeCoordinator(
            endpoint: endpoint,
            queue: queue,
            timeout: Self.permissionDecisionTimeout
        )

        return await withTaskCancellationHandler {
            await coordinator.waitForResult()
        } onCancel: {
            Task { @MainActor in
                coordinator.cancel()
            }
        }
    }

    /// Public internet hosts (such as `opencode pair --remote` tunnels) never trigger
    /// the iOS Local Network permission prompt and should not pay an extra TCP handshake.
    nonisolated static func requiresLocalNetworkProbe(for url: URL) -> Bool {
        guard let rawHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".local.") {
            return true
        }
        if host.contains(":") {
            // IPv6 loopback, link-local (fe80::/10), or unique local (fc00::/7)
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _),
                 (127, _),
                 (169, 254),
                 (192, 168):
                return true
            case (172, 16...31),
                 (100, 64...127):
                return true
            default:
                return false
            }
        }
        // Single-label local hostnames (no dots) use local resolution.
        return !host.contains(".")
    }

    private func endpoint(for url: URL) -> NWEndpoint? {
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }

        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        let portValue = url.port ?? defaultPort
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            return nil
        }

        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

@MainActor
private final class LocalNetworkProbeCoordinator {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: Duration

    private var continuation: CheckedContinuation<LocalNetworkAccessProbeResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var wasCancelled = false

    init(endpoint: NWEndpoint, queue: DispatchQueue, timeout: Duration) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.queue = queue
        self.timeout = timeout
    }

    func waitForResult() async -> LocalNetworkAccessProbeResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            guard !wasCancelled else {
                finish(.continueConnection)
                return
            }

            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handle(state)
                }
            }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        wasCancelled = true
        finish(.continueConnection)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready, .failed, .cancelled:
            finish(.continueConnection)

        case .waiting:
            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                waitForPermissionDecision()
            } else {
                finish(.continueConnection)
            }

        default:
            break
        }
    }

    private func waitForPermissionDecision() {
        guard timeoutTask == nil else { return }

        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.timeout)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self.finish(.accessRequired)
        }
    }

    private func finish(_ result: LocalNetworkAccessProbeResult) {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()

        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
