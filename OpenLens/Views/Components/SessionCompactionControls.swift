import SwiftUI

/// Admission belongs to the shared chat service so dismissing this sheet does
/// not reset a request or turn reopening into another submission.
struct SessionCompactionControls: View {
    @Environment(ChatClient.self) private var chatClient
    @Environment(\.chatEasterEgg) private var chatEasterEgg

    private var state: ChatClient.CompactionState {
        ScreenshotFixtures.compactionState ?? chatClient.compactionState
    }
    private var isRetro: Bool { chatEasterEgg.visualMode.isRetro }
    private var canRequest: Bool {
        if ScreenshotFixtures.showsCompaction {
            switch state {
            case .ready, .completed, .failed, .interrupted, .uncertain: return true
            default: return false
            }
        }
        return chatClient.canRequestCompaction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "archivebox")
                .font(isRetro ? RetroChatStyle.headerFont : .headline)
            Text(explanation)
                .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : .secondary)
                .lineLimit(4)
            if state == .submitting || state == .running {
                ProgressView()
                    .accessibilityLabel(title)
            }
            Button(state == .uncertain ? "Retry Request" : "Compact Conversation") {
                Task { await chatClient.requestCompaction() }
            }
            .buttonStyle(.bordered)
            .disabled(!canRequest)
            .accessibilityIdentifier("active-context-compact")
        }
        .foregroundStyle(isRetro ? RetroChatStyle.ink : .primary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isRetro ? RetroChatStyle.paper : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("active-context-compaction-status")
    }

    private var title: String {
        switch state {
        case .ready: "Compaction"
        case .submitting: "Requesting compaction…"
        case .pending: "Compaction pending"
        case .running: "Compacting context…"
        case .completed: "Compaction completed"
        case .failed: "Compaction failed"
        case .interrupted: "Execution interrupted"
        case .uncertain: "Compaction status unconfirmed"
        case .unavailable: "Compaction unavailable"
        }
    }

    private var explanation: String {
        switch state {
        case .ready:
            canRequest
                ? "Request a summary at the next step boundary. The result appears in Chat and active context."
                : "Reconnect and refresh Chat before requesting compaction."
        case .submitting: "Waiting for the server to admit the request. You can close this view."
        case .pending: "Accepted in the shared inbox. Waiting for the server’s result."
        case .running: "The server is creating a summary. You can close this view."
        case .completed: "Inspect the summary and retained context below. The full conversation remains in Chat."
        case .failed(let reason): reason
        case .interrupted: "No successful compaction result was recorded. Inspect the timeline for details."
        case .uncertain: "Refresh to check whether the request was admitted or finished. A retry keeps the same request identity."
        case .unavailable: "This connection cannot request supported V2 compaction. You can still inspect context and Chat."
        }
    }
}
