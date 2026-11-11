import SwiftUI

/// Reuses the same metadata-only catalog, filters and priority rules as Sessions.
struct SessionSwitcherSheet: View {
    let selectedSessionID: String?
    let onSelect: (OCSession) -> Void
    let onDelete: (OCSession) -> Void
    let newSessionModel: @MainActor () async -> OCV2ModelRef?

    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.dismiss) private var dismiss
    @State private var fetchedState: SessionsListView.InitialState?

    private var resolvedInitialState: SessionsListView.InitialState? {
        if let fetchedState {
            return fetchedState
        }
        let cached = sessionsService.cachedSessions
        return cached.isEmpty ? nil : .loaded(cached)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let resolvedInitialState {
                    SessionsListView(
                        initialState: resolvedInitialState,
                        selectedSessionID: selectedSessionID,
                        onSelect: onSelect, onDelete: onDelete,
                        newSessionModel: newSessionModel
                    )
                } else {
                    ProgressView("Loading sessions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard fetchedState == nil else { return }
            do {
                let sessions = try await sessionsService.listAllSessions()
                try Task.checkCancellation()
                fetchedState = .loaded(sessions)
            } catch is CancellationError {
                return
            } catch {
                if sessionsService.cachedSessions.isEmpty {
                    fetchedState = .error(error.localizedDescription)
                }
            }
        }
    }
}
