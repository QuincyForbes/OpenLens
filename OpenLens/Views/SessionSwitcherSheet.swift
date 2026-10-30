import SwiftUI

/// Reuses the same metadata-only catalog, filters and priority rules as Sessions.
struct SessionSwitcherSheet: View {
    let selectedSessionID: String?
    let onSelect: (OCSession) -> Void
    let onDelete: (OCSession) -> Void
    let newSessionModel: @MainActor () async -> OCV2ModelRef?

    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.dismiss) private var dismiss
    @State private var initialState: SessionsListView.InitialState?

    var body: some View {
        NavigationStack {
            Group {
                if let initialState {
                    SessionsListView(
                        initialState: initialState,
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
            guard initialState == nil else { return }
            do {
                let sessions = try await sessionsService.listAllSessions()
                try Task.checkCancellation()
                initialState = .loaded(sessions)
            } catch is CancellationError {
                return
            } catch {
                initialState = .error(error.localizedDescription)
            }
        }
    }
}
