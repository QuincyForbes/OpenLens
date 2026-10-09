import SwiftUI

/// A read-only inspection of the server projection. Loading and disclosure
/// state belong to this sheet; the shared chat service owns scoped IO.
struct SessionActiveContextView: View {
    @Bindable var chatClient: ChatClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @Environment(\.colorScheme) private var colorScheme

    private enum LoadState {
        case loading
        case loaded(SessionTranscript)
        case failed(String)
        case unavailable
    }

    private struct ReadID: Hashable {
        let scope: ChatClient.ActiveContextScope
        let refresh: UInt
    }

    @State private var state: LoadState = .loading
    @State private var loadedScope: ChatClient.ActiveContextScope?
    @State private var refresh: UInt = 0
    @State private var requestToken = UUID()

    private var isRetro: Bool { chatEasterEgg.visualMode.isRetro }
    private var ink: Color { isRetro ? RetroChatStyle.ink : .primary }
    private var secondaryInk: Color { isRetro ? RetroChatStyle.secondaryInk : .secondary }
    private var readID: ReadID { .init(scope: chatClient.activeContextScope, refresh: refresh) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = chatClient.currentSession?.title, !title.isEmpty {
                            Text(title)
                                .font(isRetro ? RetroChatStyle.headerFont : .headline)
                                .foregroundStyle(ink)
                        }
                        Text("Current server context, separate from the full conversation in Chat. Older entries may be replaced by a compaction summary.")
                            .foregroundStyle(secondaryInk)
                        Label("Occupancy unknown", systemImage: "questionmark.circle")
                            .font(isRetro ? RetroChatStyle.bodyFont : .subheadline.weight(.medium))
                            .foregroundStyle(ink)
                        Text("The server does not report current context occupancy.")
                            .font(isRetro ? RetroChatStyle.smallFont : .caption)
                            .foregroundStyle(secondaryInk)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isRetro ? RetroChatStyle.paper : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    content
                }
                .font(isRetro ? RetroChatStyle.bodyFont : .subheadline)
                .padding(16)
            }
            .background(isRetro ? RetroChatStyle.screenBottom : Color(.systemGroupedBackground))
            .refreshable { await load(scope: chatClient.activeContextScope) }
            .navigationTitle("Active Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh &+= 1 }
                        .accessibilityIdentifier("active-context-refresh")
                }
            }
            .task(id: readID) { await load(scope: readID.scope) }
        }
        .tint(isRetro ? RetroChatStyle.ink : Color.accentColor)
        .environment(\.colorScheme, isRetro ? .light : colorScheme)
    }

    @ViewBuilder
    private var content: some View {
        // Do not display the previous session's snapshot while its replacement
        // task is waiting to start. The service also rejects delayed completions.
        if loadedScope != chatClient.activeContextScope {
            loading
        } else {
            switch state {
            case .loading:
                loading
            case .loaded(let transcript):
                if transcript.entryOrder.isEmpty {
                    ContentUnavailableView("No active entries", systemImage: "text.bubble",
                        description: Text("The server returned an empty active context."))
                } else {
                    ActiveContextEntries(transcript: transcript)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t load context", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { refresh &+= 1 }
                        .accessibilityIdentifier("active-context-retry")
                }
            case .unavailable:
                ContentUnavailableView("Context unavailable", systemImage: "text.bubble",
                    description: Text(chatClient.activeContextScope.isReady
                        ? "This server cannot provide active context. You can still read the full conversation in Chat."
                        : "Wait for the session and its location to finish refreshing, then try again."))
            }
        }
    }

    private var loading: some View {
        ProgressView("Loading active context…")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .accessibilityIdentifier("active-context-loading")
    }

    private func load(scope: ChatClient.ActiveContextScope) async {
        let token = UUID()
        requestToken = token
        loadedScope = scope
        state = .loading
        do {
            let transcript: SessionTranscript?
            if ScreenshotFixtures.showsActiveContextButton {
                switch ScreenshotFixtures.activeContextState {
                case "loading": return
                case "failed": throw OpenCodeError.invalidPayload("The connection was interrupted. Try again to read current context.")
                case "unavailable": transcript = nil
                default: transcript = try ScreenshotFixtures.activeContextProjection()
                }
            } else {
                transcript = try await chatClient.loadActiveContext()
            }
            guard !Task.isCancelled, token == requestToken, scope == chatClient.activeContextScope else { return }
            state = transcript.map(LoadState.loaded) ?? .unavailable
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, token == requestToken, scope == chatClient.activeContextScope else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct ActiveContextEntries: View {
    let transcript: SessionTranscript
    private let messagesByID: [String: ChatMessage]
    private let contextByID: [String: SessionContextEntry]
    @Environment(\.chatEasterEgg) private var chatEasterEgg

    init(transcript: SessionTranscript) {
        self.transcript = transcript
        messagesByID = Dictionary(transcript.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        contextByID = Dictionary(transcript.contextEntries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Active entries")
                .font(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.headerFont : .headline)
            ForEach(transcript.entryOrder, id: \.self) { id in
                if let context = contextByID[id] {
                    SessionContextTimelineRow(entry: context, initiallyExpanded: ScreenshotFixtures.opensActiveContext)
                } else if let message = messagesByID[id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.role == .user ? "You" : "Assistant")
                            .font(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.smallFont : .caption.weight(.semibold))
                            .foregroundStyle(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.secondaryInk : Color.secondary)
                        MessageBubbleView(message: message)
                    }
                    .accessibilityIdentifier("active-context-\(id)")
                }
            }
        }
        .foregroundStyle(chatEasterEgg.visualMode.isRetro ? RetroChatStyle.ink : Color.primary)
    }
}
