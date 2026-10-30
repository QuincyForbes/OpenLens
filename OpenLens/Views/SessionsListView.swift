import SwiftUI
import UIKit

/// Session list view with create, delete, and select.
/// Uses SessionsService directly with view-local state.
struct SessionsListView: View {
    enum PresentationStyle: Equatable {
        case navigation
        case sidebar
    }

    enum SessionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case unread = "Unread"
        case attention = "Needs You"

        var id: String { rawValue }
    }

    private struct NewSessionRequest: Identifiable {
        let id = UUID()
    }

    private typealias SessionProjectGroup = SessionListOrganization.RepositoryGroup
    private typealias SessionTimelineSection = SessionListOrganization.TimelineSection

    private static let sessionExpansionAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.9)

    // MARK: - View State

    enum InitialState {
        case loaded([OCSession])
        case error(String)
    }

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @State private var viewState: ViewState
    @State private var sessions: [OCSession]
    @State private var repositoryIndex = SessionRepositoryIndex()
    @State private var lastCatalogRefresh: Date?
    @State private var refreshWarning: String?
    @State private var sessionStatuses: [String: OCSessionStatus]
    @State private var openedSessionIDs: Set<String> = []
    @State private var failedOutcomeSessionIDs: Set<String> = []
    @State private var outcomeRefreshGeneration = 0

    @State private var newSessionRequest: NewSessionRequest?
    @State private var sessionToDelete: OCSession?
    @State private var showDeleteConfirmation = false
    @State private var sessionToRename: OCSession?
    @State private var renameTitleText = ""
    @State private var showRenameAlert = false
    @State private var searchQuery = ""
    @State private var sessionFilter: SessionFilter = .all
    @State private var selectedRepositoryID: String?
    @AppStorage("sessions.layout") private var layout: SessionListOrganization.Layout = .focus
    @AppStorage("sessions.sortOrder") private var sortOrder: SessionListOrganization.SortOrder = .working
    /// Sessions with a permission, question or form waiting on the person.
    @State private var attentionSessionIDs: Set<String> = []
    @State private var attentionLabels: [String: String] = [:]
    @State private var isOnScreen = true
    @State private var hasRefreshedInitialInactiveOutcomes = false
    @State private var expandedProjectIDs = Set<String>()

    let presentationStyle: PresentationStyle
    let selectedSessionID: String?
    var onSelect: (OCSession) -> Void
    var onDelete: (OCSession) -> Void
    /// Resolves the model a new session starts with; nil uses the server default.
    var newSessionModel: @MainActor () async -> OCV2ModelRef?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.inboxService) private var inboxService
    @Environment(\.connection) private var connection

    init(
        initialState: InitialState,
        presentationStyle: PresentationStyle = .navigation,
        selectedSessionID: String? = nil,
        onSelect: @escaping (OCSession) -> Void,
        onDelete: @escaping (OCSession) -> Void = { _ in },
        newSessionModel: @escaping @MainActor () async -> OCV2ModelRef? = { nil }
    ) {
        self.presentationStyle = presentationStyle
        self.selectedSessionID = selectedSessionID
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.newSessionModel = newSessionModel

        switch initialState {
        case .loaded(let sessions):
            self._viewState = State(initialValue: .loaded)
            self._sessions = State(initialValue: SessionListOrganization.uniqueSessions(sessions))
            self._repositoryIndex = State(initialValue: SessionRepositoryIndex(sessions: sessions))
        case .error(let message):
            self._viewState = State(initialValue: .error(message))
            self._sessions = State(initialValue: [])
        }

        self._sessionStatuses = State(initialValue: [:])
    }

    // MARK: - Convenience

    private var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    private var errorMessage: String? {
        if case .error(let msg) = viewState { return msg }
        return nil
    }

    private var isSidebar: Bool {
        presentationStyle == .sidebar
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sessionFilter != .all || selectedRepositoryID != nil
    }

    private var repositorySessions: [OCSession] {
        guard let selectedRepositoryID else { return sessions }
        return sessions.filter { projectGroupID(for: $0) == selectedRepositoryID }
    }

    private var runningSessionCount: Int {
        repositorySessions.filter { SessionListOrganization.isWorking(sessionStatuses[$0.id]) }.count
    }

    private var attentionSessionCount: Int {
        repositorySessions.filter { attentionSessionIDs.contains($0.id) }.count
    }

    private var unreadSessionCount: Int {
        repositorySessions.filter { session in
            let isBusy = sessionStatuses[session.id]?.type == .busy || sessionStatuses[session.id]?.type == .retry
            return !isBusy && session.hasUnreadResult
        }.count
    }

    private struct PollTaskKey: Equatable {
        let scenePhase: ScenePhase
        let isPollingActive: Bool
    }

    private var pollTaskKey: PollTaskKey {
        PollTaskKey(scenePhase: scenePhase, isPollingActive: isSidebar || isOnScreen)
    }

    /// Chats that pass the repository, status and search filters, in catalog order.
    private var filteredSessions: [OCSession] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositorySessions.filter { session in
            let isBusy = sessionStatuses[session.id]?.type == .busy || sessionStatuses[session.id]?.type == .retry
            switch sessionFilter {
            case .all:
                break
            case .running:
                guard isBusy else { return false }
            case .unread:
                guard !isBusy && session.hasUnreadResult else { return false }
            case .attention:
                guard attentionSessionIDs.contains(session.id) else { return false }
            }
            if !trimmedQuery.isEmpty {
                let matchesTitle = session.title.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesProject = repositoryIndex.repository(for: session).title
                    .localizedCaseInsensitiveContains(trimmedQuery)
                let matchesID = session.id.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesPath = session.directory?.localizedCaseInsensitiveContains(trimmedQuery) == true
                guard matchesTitle || matchesProject || matchesID || matchesPath else { return false }
            }
            return true
        }
    }

    private var groupedSessions: [SessionProjectGroup] {
        SessionListOrganization.groups(from: filteredSessions, statuses: sessionStatuses, sortOrder: sortOrder, repositoryIndex: repositoryIndex)
    }

    private var timelineSections: [SessionTimelineSection] {
        if layout == .focus {
            return SessionListOrganization.focus(
                from: filteredSessions, statuses: sessionStatuses,
                attentionIDs: attentionSessionIDs, pinnedIDs: sessionsService.pinnedSessionIDs
            )
        }
        return SessionListOrganization.timeline(from: filteredSessions, statuses: sessionStatuses)
    }

    private var repositories: [SessionProjectGroup] {
        SessionListOrganization.groups(from: sessions, statuses: [:], sortOrder: .repository, repositoryIndex: repositoryIndex)
    }

    /// Repository names shared by several folders, so the filter menu shows their full paths instead.
    private func ambiguousRepositoryTitles(in repositories: [SessionProjectGroup]) -> Set<String> {
        var seen = Set<String>()
        var ambiguous = Set<String>()
        for repository in repositories where !seen.insert(repository.title).inserted {
            ambiguous.insert(repository.title)
        }
        return ambiguous
    }

    private var sectionHeaderInset: CGFloat {
        isSidebar ? 10 : 4
    }

    private var alwaysVisibleSessionIDs: Set<String> {
        Set(sessionStatuses.filter { SessionListOrganization.isWorking($0.value) }.map(\.key))
            .union(attentionSessionIDs)
            .union(sessionsService.pinnedSessionIDs)
    }

    // MARK: - Body

    var body: some View {
        presentationContent
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        .background(isSidebar ? Color.clear : Color.appBackground)
        .sheet(item: $newSessionRequest) { _ in
            NewSessionSheet(newSessionModel: newSessionModel) { session in
                handleCreatedSession(session)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        .confirmationDialog(
            AppText.deleteSession,
            isPresented: $showDeleteConfirmation,
            presenting: sessionToDelete
        ) { session in
            Button("\(AppText.delete) \"\(session.title)\"", role: .destructive) {
                deleteSession(session)
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: { _ in
            Text(AppText.deleteSessionMessage)
        }
        .alert(
            "Rename Session",
            isPresented: $showRenameAlert,
            presenting: sessionToRename
        ) { session in
            TextField("Session title", text: $renameTitleText)
            Button("Save") {
                renameSession(session, newTitle: renameTitleText)
            }
            Button(AppText.cancel, role: .cancel) {}
        }
        .onAppear {
            isOnScreen = true
        }
        .onDisappear {
            isOnScreen = false
        }
        .onChange(of: selectedSessionID, initial: true) { previousID, currentID in
            // Queue affected rows for the existing poll without restarting catalog recovery.
            openedSessionIDs.formUnion([previousID, currentID].compactMap { $0 })
        }
        .onChange(of: sessionsService.confirmedViewedMarkers, initial: true) { _, _ in
            sessions = sessionsService.applyingConfirmedViewedMarkers(to: sessions)
        }
        .onChange(of: sessions, initial: true) { _, _ in
            rebuildRepositoryIndex()
        }
        .onChange(of: sessionsService.repositoryProjects.map { "\($0.id):\($0.worktree ?? "")" }) { _, _ in
            rebuildRepositoryIndex()
        }
        .task(id: pollTaskKey) {
            guard pollTaskKey.scenePhase == .active, pollTaskKey.isPollingActive else { return }
            let shouldRefreshAllInactive = !hasRefreshedInitialInactiveOutcomes
            hasRefreshedInitialInactiveOutcomes = true
            if shouldRefreshAllInactive {
                await loadSessionStatuses(refreshInactive: true)
                await refreshAttentionSessions()
            } else {
                await loadSessions()
            }
            guard connection.serverCapabilities?.protocolVersion == .v2
                    || (ScreenshotFixtures.isEnabled && ScreenshotFixtures.showsExecutionOutcomes) else { return }
            var lastAttentionRefresh = Date()
            var iteration = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                iteration += 1
                // Desktop viewing can change idle rows without an active-entry
                // transition. Reconcile attention periodically while visible.
                let refreshAttention = Date().timeIntervalSince(lastAttentionRefresh) >= 30
                await loadSessionStatuses(refreshAttention: refreshAttention)
                if refreshAttention { lastAttentionRefresh = Date() }
                // Pending permissions, questions and forms change rarely; three
                // small inbox reads every ~6s keep the "Needs You" pill honest.
                if iteration % 3 == 0 {
                    await refreshAttentionSessions()
                }
            }
        }
    }

    @ViewBuilder
    private var presentationContent: some View {
        if isSidebar {
            VStack(spacing: 0) {
                SessionsSidebarHeader(onCreate: presentNewSessionSheet, onRefresh: retryLoadingSessions, isRefreshing: isLoading)
                sessionStateContent
            }
        } else {
            sessionStateContent
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    newSessionButton
                        .padding(.trailing, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(AppText.sessions)
                .searchable(text: $searchQuery, prompt: "Search sessions or projects")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: retryLoadingSessions) {
                            if isLoading { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .disabled(isLoading)
                        .accessibilityLabel("Refresh sessions")
                        .accessibilityHint("Fetches sessions and updates their activity order")
                        .accessibilityIdentifier("sessions.refresh")
                    }
                    if let host = connection.serverHostDisplay {
                        ToolbarItem(placement: .principal) {
                            ConnectedHostCapsule(host: host, isReconnecting: connection.isReconnecting)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
        }
    }

    private var newSessionButton: some View {
        Button(action: presentNewSessionSheet) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.appOnNeutralAction)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(Color.appNeutralAction)
        .accessibilityLabel(AppText.newSession)
    }

    @ViewBuilder
    private var sessionStateContent: some View {
        if isLoading && sessions.isEmpty {
            ProgressView()
                .tint(Color.appSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, sessions.isEmpty {
            SessionsLoadErrorView(
                message: errorMessage,
                retry: retryLoadingSessions
            )
        } else if sessions.isEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        let repositories = self.repositories
        // Rows only name their repository when the timeline mixes several of them.
        let showsRepositoryOnRows = layout != .repository && selectedRepositoryID == nil && repositories.count > 1
        return ScrollView {
            LazyVStack(spacing: isSidebar ? 12 : 18) {
                listControls(repositories: repositories)

                switch layout {
                case .focus, .recent:
                    let sections = timelineSections
                    if sections.isEmpty {
                        noMatchingSessionsView
                    }
                    ForEach(sections) { section in
                        timelineSection(section, showsRepository: showsRepositoryOnRows)
                    }
                case .repository:
                    let groups = groupedSessions
                    if groups.isEmpty {
                        noMatchingSessionsView
                    }
                    ForEach(groups) { group in
                        projectSection(group)
                    }
                }
            }
            .padding(.horizontal, isSidebar ? 12 : 20)
            .padding(.top, isSidebar ? 10 : 12)
            .padding(.bottom, 16)
        }
        .refreshable {
            await loadSessions()
        }
    }

    private var noMatchingSessionsView: some View {
        ContentUnavailableView {
            Label("No matching chats", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Try another repository, status, or search.")
        } actions: {
            Button("Clear filters") {
                selectedRepositoryID = nil
                sessionFilter = .all
                searchQuery = ""
            }
        }
    }

    private func listControls(repositories: [SessionProjectGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isSidebar {
                TextField("Search sessions or repositories", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sessions.search")
            }
            Picker(AppText.sessionsLayout, selection: $layout) {
                ForEach(SessionListOrganization.Layout.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sessions.layout")

            organizationBar(repositories: repositories)
            sessionFilterBar

            if let nextWaiting = repositorySessions.first(where: { attentionSessionIDs.contains($0.id) }) {
                Button {
                    openedSessionIDs.insert(nextWaiting.id)
                    onSelect(nextWaiting)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .foregroundStyle(Color.appWarning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attentionLabels[nextWaiting.id] ?? "Waiting for your response")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appPrimary)
                            Text(nextWaiting.title.isEmpty ? AppText.titleUntitled : nextWaiting.title)
                                .font(.caption2)
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("Open")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appWarning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.appWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sessions.openNextWaiting")
            }

            if let message = errorMessage ?? refreshWarning {
                HStack(alignment: .top) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("Retry", action: retryLoadingSessions)
                        .disabled(isLoading)
                }
                .foregroundStyle(Color.appWarning)
            } else if let lastCatalogRefresh {
                Text("Updated \(lastCatalogRefresh.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
            }
        }
    }

    private func organizationBar(repositories: [SessionProjectGroup]) -> some View {
        let ambiguousTitles = ambiguousRepositoryTitles(in: repositories)
        let selectedRepository = repositories.first { $0.id == selectedRepositoryID }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Repository", selection: $selectedRepositoryID) {
                        Text(AppText.sessionsAllRepositories).tag(String?.none)
                        ForEach(repositories) { repository in
                            let showsPath = ambiguousTitles.contains(repository.title)
                            Text(showsPath ? (repository.subtitle ?? repository.title) : repository.title)
                                .tag(Optional(repository.id))
                        }
                    }
                } label: {
                    controlChip(
                        title: selectedRepository?.title ?? AppText.sessionsAllRepositories,
                        systemImage: "folder",
                        isActive: selectedRepository != nil
                    )
                }
                .accessibilityIdentifier("sessions.repositoryFilter")

                if layout == .repository {
                    Menu {
                        Picker(AppText.sessionsSortChats, selection: $sortOrder) {
                            ForEach(SessionListOrganization.SortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        controlChip(title: sortOrder.rawValue, systemImage: "arrow.up.arrow.down", isActive: false)
                    }
                    .accessibilityLabel("\(AppText.sessionsSortChats): \(sortOrder.rawValue)")
                    .accessibilityIdentifier("sessions.sortOrder")
                }
            }
        }
    }

    private func controlChip(title: String, systemImage: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(isActive ? Color.appOnAccent : Color.appPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color.appAccent : Color.appTertiary, in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var sessionFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionFilter.allCases) { filter in
                    let isSelected = sessionFilter == filter
                    let count: Int? = switch filter {
                    case .all: nil
                    case .running: runningSessionCount > 0 ? runningSessionCount : nil
                    case .unread: unreadSessionCount > 0 ? unreadSessionCount : nil
                    case .attention: attentionSessionCount > 0 ? attentionSessionCount : nil
                    }
                    // Hide the attention pill until something actually needs a reply.
                    if filter != .attention || attentionSessionCount > 0 || sessionFilter == .attention {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                sessionFilter = filter
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(filter.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                if let count {
                                    Text("\(count)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            isSelected ? Color.white.opacity(0.22) : Color.appAccent.opacity(0.16),
                                            in: Capsule()
                                        )
                                }
                            }
                            .foregroundStyle(isSelected ? Color.appOnAccent : Color.appSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.appAccent : Color.appTertiary,
                                in: Capsule()
                            )
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    private func projectSection(_ group: SessionProjectGroup) -> some View {
        let isExpanded = isSearching || expandedProjectIDs.contains(group.id)
        let collapsedSessions = group.visibleSessions(keeping: alwaysVisibleSessionIDs)
        let hiddenSessionCount = group.sessions.count - collapsedSessions.count
        let displayedSessions = isExpanded ? group.sessions : collapsedSessions
        let workingCount = group.sessions.filter { SessionListOrganization.isWorking(sessionStatuses[$0.id]) }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)

                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(AppText.groupedProjectCount(group.sessions.count))
                            .font(.caption)
                            .foregroundStyle(Color.appSecondary)
                    }
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if workingCount > 0 {
                        Label(AppText.sessionsWorkingCount(workingCount), systemImage: "circle.dotted")
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                    }
                }
            }
            .padding(.horizontal, sectionHeaderInset)

            sessionCard(displayedSessions, showsRepository: false)
            if hiddenSessionCount > 0, !isSearching {
                Button {
                    toggleProjectExpansion(group.id)
                } label: {
                    Label(isExpanded ? AppText.showFewerSessions : AppText.showMoreSessions(hiddenSessionCount),
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
            }
        }
    }

    private func timelineSection(_ section: SessionTimelineSection, showsRepository: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if section.isWorking {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }

                Text(section.title)
                    .font(.system(size: isSidebar ? 13 : 15, weight: .semibold, design: .rounded))

                Text("\u{00B7}")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.appSecondary)

                Text(AppText.groupedProjectCount(section.sessions.count))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }
            .foregroundStyle(section.isWorking ? Color.appAccent : Color.appPrimary)
            .padding(.horizontal, sectionHeaderInset)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            sessionCard(section.sessions, showsRepository: showsRepository)
        }
    }

    /// Rows of one section. Pushed lists get a bordered surface with separators; the sidebar stays flat.
    private func sessionCard(_ sessions: [OCSession], showsRepository: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                sessionButton(session, showsRepository: showsRepository)

                if !isSidebar, index < sessions.count - 1 {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(height: 1)
                        .padding(.leading, 14)
                        .transition(.opacity)
                }
            }
        }
        .background(
            isSidebar ? Color.clear : Color.appSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if !isSidebar {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.appSeparator, lineWidth: 1)
            }
        }
    }

    private func sessionButton(_ session: OCSession, showsRepository: Bool) -> some View {
        Button {
            openedSessionIDs.insert(session.id)
            onSelect(session)
        } label: {
            sessionRow(session, showsRepository: showsRepository)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                sessionsService.togglePin(session.id)
            } label: {
                Label(sessionsService.pinnedSessionIDs.contains(session.id) ? "Unpin" : "Pin for follow-up", systemImage: "pin")
            }
            Button {
                renameTitleText = session.title
                sessionToRename = session
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = session.id
            } label: {
                Label("Copy Session ID", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                sessionToDelete = session
                showDeleteConfirmation = true
            } label: {
                Label(AppText.delete, systemImage: "trash")
            }
        }
        .transition(.asymmetric(
            insertion: .opacity
                .combined(with: .move(edge: .top))
                .combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
        ))
    }

    private func sessionRow(_ session: OCSession, showsRepository: Bool) -> some View {
        let statusType = sessionStatuses[session.id]?.type
        let isBusy = statusType == .busy || statusType == .retry
        let isSelected = selectedSessionID == session.id
        let showsListExecutionOutcomes = connection.serverCapabilities?.protocolVersion == .v2
            || ScreenshotFixtures.showsExecutionOutcomes

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SessionWorkingTitle(
                    title: session.title.isEmpty ? AppText.titleUntitled : session.title,
                    isWorking: isBusy,
                    lineLimit: 2
                )

                if let attention = attentionLabels[session.id] {
                    Text(attention)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appWarning)
                }

                if layout == .repository, let directory = session.directory,
                   SessionRepositoryIndex.pathKey(directory) != SessionRepositoryIndex.pathKey(repositoryIndex.repository(for: session).directory) {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !isBusy, showsListExecutionOutcomes,
                   let outcome = session.executionOutcomeVisibleOnSessionList() {
                    ExecutionStatusView(state: outcome, idleTime: session.time.idle)
                }

                HStack(spacing: 6) {
                    if showsRepository {
                        repositoryChip(for: session)
                    }
                    if isBusy {
                        Label(statusType == .retry ? "Retrying" : "Working", systemImage: "circle.dotted")
                            .foregroundStyle(Color.appAccent)
                    }
                    Text(formattedDate(session.updatedAt))
                        .foregroundStyle(Color.appSecondary)
                }
                .font(.caption)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if sessionsService.pinnedSessionIDs.contains(session.id) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityLabel("Pinned for follow-up")
            }

            if attentionSessionIDs.contains(session.id) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appWarning)
                    .accessibilityLabel("Waiting for your response")
                    .accessibilityIdentifier("session.needsAttention.\(session.id)")
            }

            if !isBusy, session.hasUnreadResult, showsListExecutionOutcomes {
                Text(AppText.unreadResult)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appAccent.opacity(0.12), in: Capsule())
                    .accessibilityLabel(AppText.unreadResultAccessibility)
                    .accessibilityIdentifier("session.unreadResult.\(session.id)")
            }

            if !isSidebar {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.appSecondary.opacity(0.7))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, isSidebar ? 10 : 14)
        .background(
            isSelected ? Color.appTertiary : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func repositoryChip(for session: OCSession) -> some View {
        let title = repositoryIndex.repository(for: session).title
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.appSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.appTertiary, in: Capsule())
        .accessibilityLabel("\(AppText.project), \(title)")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.appTertiary)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.appSecondary)
                }

            VStack(spacing: 6) {
                Text(AppText.emptySessionsTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(AppText.emptySessionsSubtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                presentNewSessionSheet()
            } label: {
                Text(AppText.newSession)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appOnAccent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.appAccent)
                    )
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Side Effects (Service calls)

    private func loadSessions() async {
        guard !Task.isCancelled, !isLoading else { return }
        let client = connection.client
        outcomeRefreshGeneration &+= 1
        let generation = outcomeRefreshGeneration
        viewState = .loading
        refreshWarning = nil
        defer {
            if generation == outcomeRefreshGeneration, case .loading = viewState {
                viewState = .loaded
            }
        }
        do {
            let result = try await sessionsService.listAllSessions()
            guard !Task.isCancelled, generation == outcomeRefreshGeneration, connection.client === client else { return }
            let requestedIDs = openedSessionIDs.union(failedOutcomeSessionIDs)
            let snapshot = await sessionsService.refreshSessionOutcomes(
                in: result, previousStatuses: sessionStatuses, openedSessionIDs: requestedIDs
            )
            guard !Task.isCancelled, generation == outcomeRefreshGeneration, connection.client === client else { return }
            applyExecutionSnapshot(snapshot, requestedIDs: requestedIDs)
            await refreshAttentionSessions(force: true)
            guard !Task.isCancelled, generation == outcomeRefreshGeneration, connection.client === client else { return }
            lastCatalogRefresh = .now
            viewState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
            viewState = .error(error.localizedDescription)
        }
    }

    private func loadSessionStatuses(refreshInactive: Bool = false, refreshAttention: Bool = false) async {
        guard !sessions.isEmpty, !Task.isCancelled, !isLoading else { return }
        outcomeRefreshGeneration &+= 1
        let generation = outcomeRefreshGeneration
        let requestedIDs = openedSessionIDs.union(failedOutcomeSessionIDs)
        let snapshot = await sessionsService.refreshSessionOutcomes(
            in: sessions, previousStatuses: sessionStatuses, openedSessionIDs: requestedIDs, refreshInactive: refreshInactive
        )
        guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
        applyExecutionSnapshot(snapshot, requestedIDs: requestedIDs)
        if refreshAttention {
            let refreshed = await sessionsService.refreshUnreadResults(in: sessions, statuses: sessionStatuses)
            guard !Task.isCancelled, generation == outcomeRefreshGeneration else { return }
            sessions = sessionsService.applyingConfirmedViewedMarkers(to: refreshed)
        }
    }

    private func refreshAttentionSessions(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let generation = outcomeRefreshGeneration
        let client = connection.client
        guard let snapshot = try? await inboxService.loadInbox(maxAge: force ? 0 : 5), !Task.isCancelled else {
            if force, !Task.isCancelled, generation == outcomeRefreshGeneration, connection.client === client {
                refreshWarning = "Sessions updated, but pending requests could not be refreshed."
            }
            return
        }
        guard generation == outcomeRefreshGeneration, connection.client === client else { return }
        var ids = Set<String>()
        ids.formUnion(snapshot.permissions.compactMap(\.sessionID))
        ids.formUnion(snapshot.questions.map(\.sessionID))
        ids.formUnion(snapshot.sessionForms.map(\.sessionID))
        if ids != attentionSessionIDs {
            attentionSessionIDs = ids
        }
        var labels: [String: String] = [:]
        for permission in snapshot.permissions {
            if let id = permission.sessionID { labels[id] = "Permission needed" }
        }
        for question in snapshot.questions { labels[question.sessionID] = "Answer needed" }
        for form in snapshot.sessionForms {
            labels[form.sessionID] = "Form waiting for your response"
        }
        attentionLabels = labels
        if let warning = snapshot.warning { refreshWarning = warning }
    }

    private func applyExecutionSnapshot(_ snapshot: SessionExecutionSnapshot, requestedIDs: Set<String>) {
        sessions = SessionListOrganization.uniqueSessions(sessionsService.applyingConfirmedViewedMarkers(to: snapshot.sessions))
        sessionStatuses = snapshot.statuses
        failedOutcomeSessionIDs = snapshot.failedOutcomeSessionIDs
        if snapshot.statusRefreshFailed {
            refreshWarning = "Activity status could not be refreshed. Showing the last known status."
        }
        openedSessionIDs.subtract(requestedIDs)
        pruneExpandedProjects(using: snapshot.sessions)
    }

    private func retryLoadingSessions() {
        Task {
            await loadSessions()
        }
    }

    private func presentNewSessionSheet() {
        newSessionRequest = NewSessionRequest()
    }

    private func handleCreatedSession(_ session: OCSession) {
        outcomeRefreshGeneration &+= 1
        openedSessionIDs.insert(session.id)
        viewState = .loaded
        sessions.insert(session, at: 0)
        pruneExpandedProjects(using: sessions)
        onSelect(session)
    }

    private func deleteSession(_ session: OCSession) {
        Task {
            do {
                try await sessionsService.deleteSession(session)
                outcomeRefreshGeneration &+= 1
                if case .loading = viewState { viewState = .loaded }
                sessions.removeAll { $0.id == session.id }
                pruneExpandedProjects(using: sessions)
                onDelete(session)
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    private func renameSession(_ session: OCSession, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        Task {
            do {
                let updated = try await sessionsService.updateTitle(session: session, newTitle: trimmed)
                if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index] = updated
                }
            } catch {
                viewState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func formattedDate(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestamp)
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func toggleProjectExpansion(_ groupID: String) {
        withAnimation(Self.sessionExpansionAnimation) {
            if expandedProjectIDs.contains(groupID) {
                expandedProjectIDs.remove(groupID)
            } else {
                expandedProjectIDs.insert(groupID)
            }
        }
    }

    private func pruneExpandedProjects(using sessions: [OCSession]) {
        let index = SessionRepositoryIndex(sessions: sessions, projects: sessionsService.repositoryProjects)
        let validGroupIDs = Set(sessions.map { index.repository(for: $0).id })
        expandedProjectIDs = expandedProjectIDs.intersection(validGroupIDs)
    }

    private func projectGroupID(for session: OCSession) -> String {
        repositoryIndex.repository(for: session).id
    }

    private func rebuildRepositoryIndex() {
        repositoryIndex = SessionRepositoryIndex(sessions: sessions, projects: sessionsService.repositoryProjects)
        let validIDs = Set(sessions.map { repositoryIndex.repository(for: $0).id })
        if let selectedRepositoryID, !validIDs.contains(selectedRepositoryID) {
            self.selectedRepositoryID = nil
        }
        expandedProjectIDs.formIntersection(validIDs)
    }
}

private struct SessionsSidebarHeader: View {
    let onCreate: () -> Void
    let onRefresh: () -> Void
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(AppText.sessions)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)

            Spacer()

            Button(action: onRefresh) {
                if isRefreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh sessions")

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppText.newSession)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct SessionsLoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(AppText.sessionsLoadErrorTitle, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(AppText.tryAgain, action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct NewSessionSheet: View {
    private struct FolderBrowserRequest: Identifiable {
        let id = UUID()
        let directory: String
    }

    enum WorkspaceLoadState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    let newSessionModel: @MainActor () async -> OCV2ModelRef?
    let onCreated: (OCSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.messagesService) private var messagesService
    @Environment(\.workspaceService) private var workspaceService

    @State private var title = ""
    @State private var workspaceState: WorkspaceLoadState = .idle
    @State private var workspaceOptions: [WorkspaceSelectionOption] = []
    @State private var selectedWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var defaultWorkspaceID: WorkspaceSelectionOption.ID?
    @State private var unavailablePreferredDirectory: String?
    @State private var createErrorMessage: String?
    @State private var isCreating = false
    @State private var folderBrowserRequest: FolderBrowserRequest?
    @State private var showGitHubCloneSheet = false
    @State private var pendingCloneSelections: [String: ClonedRepositorySelection] = [:]

    private var selectedWorkspace: WorkspaceSelectionOption? {
        workspaceOptions.first { $0.id == selectedWorkspaceID }
    }

    private var canCreate: Bool {
        selectedWorkspace?.canCreateSession == true && !isCreating && !isLoadingWorkspaces
    }

    private var isLoadingWorkspaces: Bool {
        if case .loading = workspaceState { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleSection
                    workspaceSection

                    if let createErrorMessage {
                        noticeRow(
                            icon: "exclamationmark.triangle.fill",
                            message: createErrorMessage,
                            tint: Color.appDanger
                        )
                    }

                    workspaceSourceNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .background(Color.appBackground)
            .navigationTitle(AppText.newSession)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel(AppText.dismiss)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createSession() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .tint(Color.appAccent)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .accessibilityLabel(AppText.create)
                    .disabled(!canCreate)
                }
            }
            .task {
                await loadWorkspaceOptions()
            }
            .sheet(item: $folderBrowserRequest) { request in
                WorkspaceFolderBrowser(initialDirectory: request.directory, onSelect: selectBrowsedDirectory)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.appBackground)
            }
            .sheet(isPresented: $showGitHubCloneSheet) {
                GitHubCloneSheet(
                    defaultParentDirectory: defaultCloneParentDirectory,
                    onSelectRepository: selectClonedRepository
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.appBackground)
            }
        }
    }

    private var defaultCloneParentDirectory: String {
        let candidates = workspaceOptions.compactMap(\.directory)
            + [connection.selectedProjectDirectory].compactMap { $0 }
        return GitHubRepositoryService.defaultParentDirectory(from: candidates)
    }

    private var workspaceSourceNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appSecondary)
                .padding(.top, 2)

            Text(AppText.newSessionWorkspaceSourceNote)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppText.newSessionPlaceholder)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            TextField(AppText.newSessionPlaceholder, text: $title)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .submitLabel(.done)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appSeparator, lineWidth: 1)
                }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppText.workspace)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)

                Spacer()

                if isLoadingWorkspaces {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.appAccent)
                }
            }

            if let unavailablePreferredDirectory {
                noticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: "\(AppText.newSessionWorkspaceUnavailable) \(unavailablePreferredDirectory)",
                    tint: Color.appWarning
                )
            }

            switch workspaceState {
            case .idle, .loading:
                loadingRow
            case .loaded:
                workspaceOptionsList
            case .error(let message):
                VStack(alignment: .leading, spacing: 10) {
                    noticeRow(icon: "exclamationmark.triangle.fill", message: message, tint: Color.appDanger)

                    Button {
                        Task { await loadWorkspaceOptions() }
                    } label: {
                        Label(AppText.tryAgain, systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                }
            }

            Button {
                folderBrowserRequest = FolderBrowserRequest(
                    directory: selectedWorkspace?.directory ?? connection.selectedProjectDirectory ?? "/"
                )
            } label: {
                Label(AppText.browseFolders, systemImage: "folder.badge.plus")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
            .disabled(isCreating || isLoadingWorkspaces)
            .accessibilityIdentifier("newSession.browseFolders")

            Button {
                showGitHubCloneSheet = true
            } label: {
                Label("Clone from GitHub", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
            .disabled(isCreating || isLoadingWorkspaces)
            .accessibilityIdentifier("newSession.cloneGitHub")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appAccent)
            Text("Loading workspaces...")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var workspaceOptionsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(workspaceOptions.enumerated()), id: \.element.id) { index, option in
                workspaceOptionRow(option)

                if index < workspaceOptions.count - 1 {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        }
    }

    private func workspaceOptionRow(_ option: WorkspaceSelectionOption) -> some View {
        Button {
            guard option.canCreateSession else { return }
            selectedWorkspaceID = option.id
            createErrorMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: option))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconTint(for: option))
                    .frame(width: 28, height: 28)
                    .background(iconTint(for: option).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(option.canCreateSession ? Color.appPrimary : Color.appSecondary)
                            .lineLimit(1)

                        badges(for: option)
                    }

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                Image(systemName: selectedWorkspaceID == option.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selectedWorkspaceID == option.id ? Color.appAccent : Color.appSecondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(option.canCreateSession ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!option.canCreateSession)
    }

    @ViewBuilder
    private func badges(for option: WorkspaceSelectionOption) -> some View {
        if option.id == defaultWorkspaceID, option.canCreateSession {
            badge(AppText.workspaceSuggested, tint: Color.appAccent)
        }

        if option.isCurrent {
            badge(AppText.workspaceCurrent, tint: Color.appSuccess)
        } else if option.isRecent {
            badge(AppText.workspaceRecent, tint: Color.appSecondary)
        }

        if option.availability == .unavailable {
            badge(AppText.workspaceUnavailable, tint: Color.appWarning)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func noticeRow(icon: String, message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func iconName(for option: WorkspaceSelectionOption) -> String {
        switch option.availability {
        case .available:
            "folder"
        case .unavailable:
            "folder.badge.questionmark"
        case .serverDefault:
            "server.rack"
        }
    }

    private func iconTint(for option: WorkspaceSelectionOption) -> Color {
        switch option.availability {
        case .available:
            option.isCurrent ? Color.appSuccess : Color.appAccent
        case .unavailable:
            Color.appWarning
        case .serverDefault:
            Color.appSecondary
        }
    }

    private func selectBrowsedDirectory(_ directory: String) {
        let option = WorkspaceSelectionOption(
            id: "directory:\(directory)",
            directory: directory,
            projectID: nil,
            title: WorkspaceSelectionBuilder.displayName(for: directory),
            subtitle: directory,
            availability: .available,
            isCurrent: directory == connection.selectedProjectDirectory,
            isRecent: false
        )
        workspaceOptions.removeAll { $0.id == option.id }
        workspaceOptions.insert(option, at: 0)
        selectedWorkspaceID = option.id
        unavailablePreferredDirectory = nil
        createErrorMessage = nil
        workspaceState = .loaded
    }

    private func selectClonedRepository(_ selection: ClonedRepositorySelection) {
        let optionID = "clone:\(selection.repository.fullName.lowercased())"
        let option = WorkspaceSelectionOption(
            id: optionID,
            directory: selection.parentDirectory,
            projectID: nil,
            title: selection.repository.name,
            subtitle: "\(selection.repository.fullName) → \(selection.targetDirectory)",
            availability: .available,
            isCurrent: false,
            isRecent: false
        )
        pendingCloneSelections[optionID] = selection
        workspaceOptions.removeAll { $0.id == option.id }
        workspaceOptions.insert(option, at: 0)
        selectedWorkspaceID = option.id
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = "Clone \(selection.repository.name)"
        }
        unavailablePreferredDirectory = nil
        createErrorMessage = nil
        workspaceState = .loaded
    }

    private func loadWorkspaceOptions() async {
        workspaceState = .loading
        createErrorMessage = nil

        let activeConnectionID = savedConnections.activeConnectionID
        let recentDirectories = activeConnectionID
            .map { savedConnections.recentProjectSelections(connectionID: $0) }
            ?? []
        let preferredDirectory = activeConnectionID
            .flatMap { savedConnections.savedProjectSelection(connectionID: $0) }
            ?? connection.selectedProjectDirectory

        do {
            let snapshot = try await workspaceService.loadWorkspaceSelection(
                verifying: recentDirectories + [preferredDirectory].compactMap { $0 }
            )

            let result = WorkspaceSelectionBuilder.makeOptions(
                snapshot: snapshot,
                recentDirectories: recentDirectories,
                preferredDirectory: preferredDirectory
            )

            workspaceOptions = result.options
            defaultWorkspaceID = result.defaultOptionID
            selectedWorkspaceID = result.defaultOptionID
            unavailablePreferredDirectory = result.unavailablePreferredDirectory
            workspaceState = .loaded
        } catch {
            workspaceOptions = []
            defaultWorkspaceID = nil
            selectedWorkspaceID = nil
            unavailablePreferredDirectory = nil
            workspaceState = .error(error.localizedDescription)
        }
    }

    private func createSession() async {
        guard let selectedWorkspace, selectedWorkspace.canCreateSession else { return }

        isCreating = true
        createErrorMessage = nil
        defer { isCreating = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let modelRef = await newSessionModel()
            let session = try await sessionsService.createSession(
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                workspaceDirectory: selectedWorkspace.directory,
                clearsWorkspaceContext: selectedWorkspace.clearsWorkspaceContext,
                model: modelRef
            )
            if let cloneSelection = pendingCloneSelections[selectedWorkspace.id] {
                _ = try? await messagesService.sendPromptAsync(
                    sessionID: session.id,
                    text: cloneSelection.initialPrompt,
                    model: modelRef.map { OCPromptInput.OCModelRef(providerID: $0.providerID, modelID: $0.id) },
                    variant: modelRef?.variant
                )
            }
            onCreated(session)
            dismiss()
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Connected Host Capsule

private struct ConnectedHostCapsule: View {
    let host: String
    let isReconnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReconnecting ? Color.appWarning : Color.appSuccess)
                .frame(width: 7, height: 7)
            Text(host)
                .font(.subheadline.weight(.medium).monospaced())
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppText.sessions), \(host)")
    }
}
