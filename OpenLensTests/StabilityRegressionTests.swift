import Foundation
import Testing
@testable import OpenLens

@MainActor
struct StabilityRegressionTests {
    @Test func deferredPermissionStaysDeferredButNewRequestCanOpen() {
        let chat = ChatClient(demoMode: true)
        chat.pendingPermission = OCPermissionRequest(id: "per_first", sessionID: "ses_1", action: "shell")
        chat.showPermissionAlert = true
        chat.showPermissionAlert = false
        #expect(!chat.shouldPresentPermission("per_first"))
        #expect(chat.shouldPresentPermission("per_second"))
    }

    @Test func samePartCountDoesNotHideToolCompletion() {
        let running = OCPart(id: "part", sessionID: "ses", messageID: "msg", type: .tool,
                             state: OCToolState(status: .running))
        let completed = OCPart(id: "part", sessionID: "ses", messageID: "msg", type: .tool,
                               state: OCToolState(status: .completed, output: "Finished"))
        #expect(!ChatClient.sameParts([running], [completed]))
        #expect(ChatClient.sameParts([completed], [completed]))
    }
}
