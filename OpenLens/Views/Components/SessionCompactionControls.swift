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
        ScreenshotFixtures.canRequestCompaction ?? chatClient.canRequestCompaction
    }
    private var isWorking: Bool { state == .submitting || state == .pending || state == .running }

    var body: some View {
        VStack(spacing: 10) {
            if let status {
                Text(status)
                    .font(isRetro ? RetroChatStyle.smallFont : .footnote)
                    .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await chatClient.requestCompaction() }
            } label: {
                HStack(spacing: 8) {
                    if isWorking { ProgressView() }
                    Text(buttonTitle)
                        .font(isRetro ? RetroChatStyle.bodyFont : .body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRequest)
            .accessibilityIdentifier("active-context-compact")
        }
        .accessibilityIdentifier("active-context-compaction-status")
    }

    private var buttonTitle: String {
        switch state {
        case .submitting: "Requesting…"
        case .pending: "Compaction pending"
        case .running: "Compacting…"
        case .uncertain: "Retry compaction"
        default: "Compact"
        }
    }

    private var status: String? {
        switch state {
        case .ready:
            canRequest
                ? nil
                : "Reconnect and refresh Chat to compact this conversation."
        case .submitting, .pending, .running, .completed, .failed, .interrupted: nil
        case .uncertain: "The request may still be pending. Retrying won't create another compaction."
        case .unavailable: "This connection doesn't support compaction."
        }
    }
}
