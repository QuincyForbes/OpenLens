import Foundation

/// A link or JSON QR payload issued by `opencode pair`, including `--remote`.
struct OpenCodePairingLink: Equatable, Sendable {
    /// Each URL redeems the same single-use code on a reachable server address.
    let urls: [URL]
    let serverURLs: [URL]
    let credentials: OpenCodePairingCredentials?

    var url: URL { urls[0] }
    var serverURL: URL { serverURLs[0] }

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("{") else {
            guard let url = URL(string: value) else { return nil }
            self.init(url: url)
            return
        }

        guard let payload = try? JSONDecoder().decode(PairingPayload.self, from: Data(value.utf8)),
              Self.isValidCode(payload.code), !payload.urls.isEmpty
        else { return nil }

        var links: [URL] = []
        var servers: [URL] = []
        for address in payload.urls {
            guard var components = URLComponents(string: address),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  components.port.map({ (1...65535).contains($0) }) ?? true
            else { return nil }

            components.path = ""
            guard let server = components.url else { return nil }
            if servers.contains(server) { continue }
            components.path = "/auth/connect/\(payload.code)"
            guard let link = components.url else { return nil }
            servers.append(server)
            links.append(link)
        }
        self.init(urls: links, serverURLs: servers, credentials: nil)
    }

    private init(urls: [URL], serverURLs: [URL], credentials: OpenCodePairingCredentials?) {
        self.urls = urls
        self.serverURLs = serverURLs
        self.credentials = credentials
    }

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil
        else { return nil }

        let path = components.percentEncodedPath
        let credentials: OpenCodePairingCredentials?

        if path == "/connect" {
            guard let fragment = components.fragment,
                  let decodedCredentials = Self.decodeCredentials(from: fragment) else {
                return nil
            }
            credentials = decodedCredentials
        } else {
            guard components.fragment == nil else { return nil }

            let prefix = "/auth/connect/"
            guard path.hasPrefix(prefix) else { return nil }
            let code = path.dropFirst(prefix.count)
            guard Self.isValidCode(String(code)) else { return nil }
            credentials = nil
        }

        self.urls = [url]
        self.credentials = credentials
        components.fragment = nil
        components.path = ""
        guard let serverURL = components.url else { return nil }
        self.serverURLs = [serverURL]
    }

    private static func isValidCode(_ code: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return !code.isEmpty && code.allSatisfy { allowed.contains($0) }
    }

    private static func decodeCredentials(from fragment: String) -> OpenCodePairingCredentials? {
        let base64 = fragment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64 + padding),
              let credentials = try? JSONDecoder().decode(OpenCodePairingCredentials.self, from: data),
              !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.password.isEmpty
        else {
            return nil
        }

        return credentials
    }
}

private struct PairingPayload: Decodable {
    let code: String
    let urls: [String]
}

struct OpenCodePairingCredentials: Decodable, Equatable, Sendable {
    let username: String
    let password: String
}
