import Foundation

enum RouterDestination: Hashable {
    case chatSession(session: OCSession)
    case sessionInsights(sessionID: String?)
}
