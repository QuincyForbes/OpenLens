import Foundation

/// Parses direct, native link, and multi-address JSON OpenCode pairing codes.
enum ScannedOpenLensCode {
    case direct(DeepLinkConnection)
    case openCodePairing(OpenCodePairingLink)

    init?(rawValue: String) {
        if let link = OpenCodePairingLink(rawValue: rawValue) {
            self = .openCodePairing(link)
        } else if let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let connection = DeepLinkConnection(from: url) {
            self = .direct(connection)
        } else {
            return nil
        }
    }

    init?(url: URL) {
        self.init(rawValue: url.absoluteString)
    }
}
