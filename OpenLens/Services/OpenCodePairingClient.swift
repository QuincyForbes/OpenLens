import Foundation

/// Resolves OpenCode pairing links into reusable connection credentials.
struct OpenCodePairingClient {
    nonisolated private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    nonisolated private static let redirectDelegate = PairingRedirectDelegate()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func pair(using link: OpenCodePairingLink) async throws -> DeepLinkConnection {
        if let credentials = link.credentials {
            return DeepLinkConnection(
                serverURL: link.serverURL.absoluteString,
                username: credentials.username,
                password: credentials.password
            )
        }

        if link.urls.count == 1 {
            return try await redeem(url: link.url, serverURL: link.serverURL, timeout: 30)
        }

        // All addresses share one code. A slow or unreachable LAN address must not
        // hold up a working tunnel, and another address's 401 must not hide a success.
        return try await withThrowingTaskGroup(of: PairingAttempt.self) { group in
            for (url, serverURL) in zip(link.urls, link.serverURLs) {
                group.addTask {
                    do {
                        return .paired(try await redeem(url: url, serverURL: serverURL, timeout: 10))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed(error as? OpenCodePairingError ?? .unreachable)
                    }
                }
            }

            var failure = OpenCodePairingError.unreachable
            var wasCancelled = false
            for try await attempt in group {
                switch attempt {
                case .paired(let credential):
                    group.cancelAll()
                    return credential
                case .failed(let error):
                    if error == .expiredOrUsed || failure == .unreachable {
                        failure = error
                    }
                case .cancelled:
                    wasCancelled = true
                }
            }
            try Task.checkCancellation()
            if wasCancelled && failure == .unreachable { throw CancellationError() }
            throw failure
        }
    }

    private func redeem(url: URL, serverURL: URL, timeout: TimeInterval) async throws -> DeepLinkConnection {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: Self.redirectDelegate)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Do not surface an error containing the secret-bearing request URL.
            throw OpenCodePairingError.unreachable
        }
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodePairingError.invalidResponse
        }
        switch response.statusCode {
        case 200: break
        case 401, 403, 404, 410: throw OpenCodePairingError.expiredOrUsed
        default: throw OpenCodePairingError.rejected(response.statusCode)
        }
        guard let credential = try? JSONDecoder().decode(PairingSession.self, from: data),
              !credential.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw OpenCodePairingError.invalidResponse }

        return DeepLinkConnection(
            serverURL: serverURL.absoluteString,
            username: "opencode",
            password: credential.token
        )
    }
}

private enum PairingAttempt: Sendable {
    case paired(DeepLinkConnection)
    case failed(OpenCodePairingError)
    case cancelled
}

private struct PairingSession: Decodable {
    let token: String
}

// A pairing code must only be sent to the origin the user scanned or pasted.
nonisolated private final class PairingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum OpenCodePairingError: LocalizedError, Equatable, Sendable {
    case expiredOrUsed
    case invalidResponse
    case unreachable
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .expiredOrUsed:
            "This pairing link expired or was already used. Run opencode pair on your computer and scan or paste the new link."
        case .invalidResponse:
            "The server did not return a pairing token. Run opencode pair to get a new link."
        case .unreachable:
            "Could not reach the pairing server. Check that OpenCode is running and the server or remote tunnel is reachable. Run opencode pair or opencode pair --remote for a new link."
        case .rejected(let status):
            "The server rejected pairing (HTTP \(status)). Run opencode pair to get a new link."
        }
    }
}
