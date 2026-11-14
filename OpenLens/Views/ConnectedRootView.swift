import SwiftUI

func shouldHideConnectedRootTabBar(selectedTab: AppTab, chatPath: [RouterDestination]) -> Bool {
    selectedTab == .chat && !chatPath.isEmpty
}

func shouldUseConnectedRootSidebarLayout(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
    horizontalSizeClass == .regular
}

struct ConnectedRootView: View {
    @Bindable var chatClient: ChatClient
    let initialSessions: SessionsListView.InitialState

    @Environment(AppRouter.self) private var router
    @Environment(\.connection) private var connection
    @Environment(\.inboxService) private var inboxService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var permissionSheetDetent = PermissionRequestSheet.defaultPresentationDetent
    @State private var inboxPendingCount = 0

    private struct InboxRefreshKey: Equatable {
        let isActive: Bool
        let permissionID: String?
        let isLoading: Bool
        let sessionID: String?
    }

    private var inboxRefreshKey: InboxRefreshKey {
        InboxRefreshKey(
            isActive: scenePhase == .active,
            permissionID: chatClient.pendingPermission?.id,
            isLoading: chatClient.isLoading,
            sessionID: chatClient.currentSession?.id
        )
    }

    var body: some View {
        @Bindable var router = router

        Group {
            if shouldUseConnectedRootSidebarLayout(horizontalSizeClass: horizontalSizeClass) {
                ConnectedSidebarLayout(
                    chatClient: chatClient,
                    initialSessions: initialSessions,
                    inboxPendingCount: inboxPendingCount
                )
            } else {
                TabView(selection: $router.selectedTab) {
                    Tab(value: AppTab.chat) {
                        tabNavigationView(for: .chat)
                    } label: {
                        tabLabel(for: .chat, selectedTab: router.selectedTab)
                    }
                    Tab(value: AppTab.review) {
                        tabNavigationView(for: .review)
                            .badge(inboxPendingCount)
                    } label: {
                        tabLabel(for: .review, selectedTab: router.selectedTab)
                    }
                    Tab(value: AppTab.workspace) {
                        tabNavigationView(for: .workspace)
                    } label: {
                        tabLabel(for: .workspace, selectedTab: router.selectedTab)
                    }
                    Tab(value: AppTab.settings, role: .search) {
                        tabNavigationView(for: .settings)
                    } label: {
                        tabLabel(for: .settings, selectedTab: router.selectedTab)
                    }
                }
            }
        }
        .tint(Color.appPrimary)
        .background {
            DesktopKeyboardShortcutsResponder(chatClient: chatClient)
        }
        .sheet(item: permissionSheetBinding) { permission in
            PermissionRequestSheet(
                permission: permission,
                selectedDetent: $permissionSheetDetent,
                initiallyConfirmsAllowAll: ScreenshotFixtures.opensPermissionAllowAllConfirmation,
                onDefer: {
                    // Keep the request pending on the server; just stop blocking the app.
                    chatClient.showPermissionAlert = false
                }
            ) { reply in
                await chatClient.respondToPermission(requestID: permission.id, reply: reply)
            }
            .id(permission.id)
            .presentationDetents(
                PermissionRequestSheet.presentationDetents(for: permission),
                selection: $permissionSheetDetent
            )
            .presentationBackground(Color.appBackground)
            .presentationContentInteraction(.resizes)
            .adaptiveSheetDragIndicator()
            .interactiveDismissDisabled()
        }
        .onChange(of: chatClient.pendingPermission?.id) { _, _ in
            permissionSheetDetent = PermissionRequestSheet.defaultPresentationDetent
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                connection.reconnectIfNeeded()
            }
        }
        .task {
            await chatClient.recoverPendingPermission()
        }
        .task(id: chatClient.isLoading) {
            await recoverSessionStateWhileLoading()
        }
        .task(id: chatClient.hasActiveBackgroundWork && !chatClient.isLoading) {
            await recoverBackgroundWatchersWhileIdle()
        }
        .task(id: inboxRefreshKey) {
            // Permissions, questions and forms for sessions that are not open
            // never reach the chat. Surface their count on the Review tab,
            // where the Inbox lives, so nothing waits unnoticed.
            guard inboxRefreshKey.isActive else { return }
            while !Task.isCancelled {
                if let snapshot = try? await inboxService.loadInbox(maxAge: 5) {
                    inboxPendingCount = snapshot.pendingRequestCount
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func tabLabel(for tab: AppTab, selectedTab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.icon)
            .environment(\.symbolVariants, selectedTab == tab ? .fill : .none)
    }

    private var tabBarVisibility: Visibility {
        shouldHideConnectedRootTabBar(
            selectedTab: router.selectedTab,
            chatPath: router.chatPath
        ) ? .hidden : .visible
    }

    private var permissionSheetBinding: Binding<OCPermissionRequest?> {
        Binding(
            get: {
                chatClient.showPermissionAlert ? chatClient.pendingPermission : nil
            },
            set: { permission in
                chatClient.pendingPermission = permission
                chatClient.showPermissionAlert = permission != nil
            }
        )
    }

    private func recoverSessionStateWhileLoading() async {
        guard chatClient.isLoading else { return }

        while !Task.isCancelled, chatClient.isLoading {
            // Yield first so sending a prompt (`POST .../prompt`) does not immediately
            // contend with status/transcript recovery GETs at t = 0ms. When SSE is
            // healthy and synchronized, poll gently as a safety net; when SSE is
            // reconnecting or unsynchronized, recover quickly.
            let sseHealthy = connection.sseClient?.state == .connected && chatClient.isStreamSynchronized
            let interval: UInt64 = sseHealthy ? 12_000_000_000 : 1_500_000_000
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled, chatClient.isLoading else { return }

            let needsExternalTranscriptSync = chatClient.pendingAssistantMessage == nil
                || connection.sseClient?.state != .connected
            if needsExternalTranscriptSync {
                async let messagesRefresh = chatClient.loadMessages(syncModelSelection: false)
                async let permissionRefresh = chatClient.recoverPendingPermission()
                async let questionRefresh = chatClient.recoverPendingQuestions()
                async let formRefresh = chatClient.recoverPendingForms()
                _ = await (messagesRefresh, permissionRefresh, questionRefresh, formRefresh)
            } else {
                async let statusRefresh = chatClient.refreshCurrentSessionStatus()
                async let permissionRefresh = chatClient.recoverPendingPermission()
                async let questionRefresh = chatClient.recoverPendingQuestions()
                async let formRefresh = chatClient.recoverPendingForms()
                _ = await (statusRefresh, permissionRefresh, questionRefresh, formRefresh)
            }
        }
    }

    private func recoverBackgroundWatchersWhileIdle() async {
        guard !chatClient.isLoading, chatClient.hasActiveBackgroundWork else { return }

        while !Task.isCancelled, !chatClient.isLoading, chatClient.hasActiveBackgroundWork {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !chatClient.isLoading, chatClient.hasActiveBackgroundWork else { return }

            async let messagesRefresh = chatClient.loadMessages(syncModelSelection: false)
            async let permissionRefresh = chatClient.recoverPendingPermission()
            async let questionRefresh = chatClient.recoverPendingQuestions()
            async let formRefresh = chatClient.recoverPendingForms()
            _ = await (messagesRefresh, permissionRefresh, questionRefresh, formRefresh)
        }
    }

    private func tabNavigationView(for tab: AppTab) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            tabRootView(for: tab)
                .navigationDestination(for: RouterDestination.self) { destination in
                    ConnectedDestinationView(chatClient: chatClient, destination: destination)
                }
        }
        // Keep this on the tab NavigationStack so TabView reliably hides the bar when Chat pushes a session.
        .toolbar(tabBarVisibility, for: .tabBar)
    }

    private func pathBinding(for tab: AppTab) -> Binding<[RouterDestination]> {
        Binding(
            get: { router.path(for: tab) },
            set: { router.setPath($0, for: tab) }
        )
    }

    @ViewBuilder
    private func tabRootView(for tab: AppTab) -> some View {
        switch tab {
        case .chat:
            SessionsListView(
                initialState: initialSessions,
                selectedSessionID: router.selectedChatSessionID,
                onSelect: selectChatSession,
                onDelete: handleDeletedSession,
                newSessionModel: { await chatClient.newSessionModelPreference() }
            )
        case .review:
            ReviewRootView(chatClient: chatClient)
        case .workspace:
            WorkspaceRootView(chatClient: chatClient)
        case .settings:
            SettingsView()
        }
    }

    private func selectChatSession(_ session: OCSession) {
        chatClient.prepareForOpeningSession(session)
        router.selectChatSession(session)
    }

    private func handleDeletedSession(_ session: OCSession) {
        router.clearChatSession(ifMatching: session.id)
        chatClient.unloadSession(ifMatching: session.id)
    }
}

private struct ConnectedSidebarLayout: View {
    private static let minimumSidebarWidth: CGFloat = 272
    private static let maximumSidebarWidth: CGFloat = 440

    @Bindable var chatClient: ChatClient
    let initialSessions: SessionsListView.InitialState
    var inboxPendingCount: Int = 0

    @Environment(AppRouter.self) private var router
    @AppStorage("sidebar.isCollapsed") private var isSidebarCollapsed = false
    @AppStorage("sidebar.width") private var persistedSidebarWidth: Double = 320
    @State private var dragStartSidebarWidth: CGFloat?

    private var effectiveSidebarWidth: CGFloat {
        min(max(CGFloat(persistedSidebarWidth), Self.minimumSidebarWidth), Self.maximumSidebarWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarCollapsed {
                sidebar
                    .frame(width: effectiveSidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                sidebarDivider
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Color.appBackground
                .ignoresSafeArea()
        }
        .onChange(of: router.toggleSidebarCommandCount) { _, _ in
            toggleSidebar()
        }
    }

    private var sidebarDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let initial = dragStartSidebarWidth ?? effectiveSidebarWidth
                    dragStartSidebarWidth = initial
                    let clamped = min(
                        max(initial + value.translation.width, Self.minimumSidebarWidth),
                        Self.maximumSidebarWidth
                    )
                    persistedSidebarWidth = Double(clamped)
                }
                .onEnded { _ in
                    dragStartSidebarWidth = nil
                }
        )
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.22)) {
            isSidebarCollapsed.toggle()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ConnectedSidebarNavigation(
                selectedTab: router.selectedTab,
                badgeCounts: [.review: inboxPendingCount],
                onNewSession: { router.requestNewSession() },
                onToggleSidebar: toggleSidebar,
                onSelect: { tab in
                    withAnimation(.snappy(duration: 0.2)) {
                        router.selectedTab = tab
                    }
                }
            )

            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
                .padding(.horizontal, 12)

            SessionsListView(
                initialState: initialSessions,
                presentationStyle: .sidebar,
                selectedSessionID: router.selectedChatSessionID,
                onSelect: selectChatSession,
                onDelete: handleDeletedSession,
                newSessionModel: { await chatClient.newSessionModelPreference() }
            )
        }
        .background {
            Color.appSurface
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedTab {
        case .chat:
            sidebarNavigationStack(for: .chat) {
                ChatDetailPlaceholderView(
                    showsExpandSidebarButton: isSidebarCollapsed,
                    onExpandSidebar: toggleSidebar
                )
            }
        case .review:
            sidebarNavigationStack(for: .review) {
                ReviewRootView(chatClient: chatClient)
                    .modifier(CollapsedSidebarToolbarButton(isVisible: isSidebarCollapsed, action: toggleSidebar))
            }
        case .workspace:
            sidebarNavigationStack(for: .workspace) {
                WorkspaceRootView(chatClient: chatClient)
                    .modifier(CollapsedSidebarToolbarButton(isVisible: isSidebarCollapsed, action: toggleSidebar))
            }
        case .settings:
            sidebarNavigationStack(for: .settings) {
                SettingsView()
                    .modifier(CollapsedSidebarToolbarButton(isVisible: isSidebarCollapsed, action: toggleSidebar))
            }
        }
    }

    private func sidebarNavigationStack<Root: View>(
        for tab: AppTab,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            root()
                .navigationDestination(for: RouterDestination.self) { destination in
                    ConnectedDestinationView(
                        chatClient: chatClient,
                        destination: destination,
                        isSidebarDetail: true,
                        isSidebarCollapsed: isSidebarCollapsed,
                        onToggleSidebar: toggleSidebar
                    )
                }
        }
    }

    private func pathBinding(for tab: AppTab) -> Binding<[RouterDestination]> {
        Binding(
            get: { router.path(for: tab) },
            set: { router.setPath($0, for: tab) }
        )
    }

    private func selectChatSession(_ session: OCSession) {
        chatClient.prepareForOpeningSession(session)
        router.selectChatSession(session)
    }

    private func handleDeletedSession(_ session: OCSession) {
        router.clearChatSession(ifMatching: session.id)
        chatClient.unloadSession(ifMatching: session.id)
    }
}

private struct CollapsedSidebarToolbarButton: ViewModifier {
    let isVisible: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isVisible {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: action) {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Show Sidebar (⌥⌘S)")
                        .accessibilityLabel("Show Sidebar")
                    }
                }
            }
    }
}

private struct ConnectedSidebarNavigation: View {
    let selectedTab: AppTab
    var badgeCounts: [AppTab: Int] = [:]
    var onNewSession: (() -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil
    let onSelect: (AppTab) -> Void

    @Environment(\.connection) private var connection

    private var connectionStatusColor: Color {
        switch connection.state {
        case .connected: Color.appSuccess
        case .reconnecting, .connecting: Color.appWarning
        case .disconnected, .error: Color.appDanger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                    Text("OpenLens")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 6, height: 6)
                        .help(connection.serverHostDisplay.map { "Connected to \($0)" } ?? "Server status")
                }

                Spacer(minLength: 4)

                if let onNewSession {
                    Button(action: onNewSession) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                            Text("New")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.appAccent.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .macHoverHighlight(cornerRadius: 12)
                    .help("\(AppText.newSession) (⌘N)")
                    .accessibilityLabel(AppText.newSession)
                }

                if let onToggleSidebar {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .macHoverHighlight(cornerRadius: 8)
                    .help("Hide Sidebar (⌥⌘S)")
                    .accessibilityLabel("Hide Sidebar")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 2)

            HStack(spacing: 4) {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    let isSelected = selectedTab == tab
                    let badge = badgeCounts[tab] ?? 0

                    Button {
                        onSelect(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .symbolVariant(isSelected ? .fill : .none)
                            Text(compactTabTitle(for: tab))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                                .lineLimit(1)
                            if badge > 0 {
                                Text("\(badge)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.appOnAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.appWarning, in: Capsule())
                                    .accessibilityLabel("\(badge) pending")
                            }
                        }
                        .foregroundStyle(isSelected ? Color.appPrimary : Color.appSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            isSelected ? Color.appBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.appSeparator, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .macHoverHighlight(cornerRadius: 8)
                    .help("\(sidebarTitle(for: tab)) (⌘\(index + 1))")
                    .accessibilityLabel(sidebarTitle(for: tab))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Color.appTertiary.opacity(0.82), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sidebarTitle(for tab: AppTab) -> String {
        tab == .chat ? "Chat" : tab.title
    }

    private func compactTabTitle(for tab: AppTab) -> String {
        switch tab {
        case .chat: "Chat"
        case .review: "Review"
        case .workspace: "Files"
        case .settings: "Settings"
        }
    }
}

private struct ConnectedDestinationView: View {
    @Bindable var chatClient: ChatClient
    let destination: RouterDestination
    var isSidebarDetail: Bool = false
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        switch destination {
        case .chatSession(let session):
            SessionChatDestinationView(
                chatClient: chatClient,
                session: session,
                isSidebarDetail: isSidebarDetail,
                isSidebarCollapsed: isSidebarCollapsed,
                onToggleSidebar: onToggleSidebar
            )
        case .sessionInsights(let sessionID):
            InsightsRootView(chatClient: chatClient, sessionID: sessionID)
        }
    }
}

private struct SessionChatDestinationView: View {
    @Bindable var chatClient: ChatClient
    let session: OCSession
    var isSidebarDetail: Bool = false
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil

    @Environment(AppRouter.self) private var router: AppRouter?

    private var hidesRootBackButton: Bool {
        isSidebarDetail && (router?.chatPath.count ?? 0) <= 1
    }

    var body: some View {
        ChatView(chatClient: chatClient, initialSession: session)
            .id(session.id)
            .background(Color.appBackground)
            .navigationBarBackButtonHidden(hidesRootBackButton)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if isSidebarDetail, isSidebarCollapsed, let onToggleSidebar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onToggleSidebar) {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Show Sidebar (⌥⌘S)")
                        .accessibilityLabel("Show Sidebar")
                    }
                }
            }
            .task(id: session.id) {
                if chatClient.needsSessionLoad(session) {
                    await chatClient.loadSession(session)
                } else {
                    await chatClient.restoreProjectContext(for: session)
                }
            }
    }
}

private struct ChatDetailPlaceholderView: View {
    var showsExpandSidebarButton: Bool = false
    var onExpandSidebar: (() -> Void)? = nil

    @Environment(AppRouter.self) private var router: AppRouter?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 72, height: 72)
                .background(Color.appTertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 6) {
                Text(AppText.selectSessionTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)

                Text(AppText.selectSessionSubtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .multilineTextAlignment(.center)
            }

            if let router {
                Button {
                    router.requestNewSession()
                } label: {
                    Label(AppText.newSession, systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.appAccent.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .macHoverHighlight(cornerRadius: 18)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsExpandSidebarButton ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if showsExpandSidebarButton, let onExpandSidebar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onExpandSidebar) {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show Sidebar (⌥⌘S)")
                    .accessibilityLabel("Show Sidebar")
                }
            }
        }
    }
}

/// Registers hardware keyboard shortcuts via the responder chain (`UIViewController.keyCommands`)
/// rather than `Scene.commands` (`UIMenuBuilder`), avoiding UIKit menu-identifier crashes on
/// Mac Catalyst when no `Settings.bundle` is present.
private struct DesktopKeyboardShortcutsResponder: View {
    let chatClient: ChatClient

    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            Button("") { router.requestNewSession() }
                .keyboardShortcut("n", modifiers: .command)

            Button("") { router.requestSessionSwitcher() }
                .keyboardShortcut("k", modifiers: .command)

            Button("") { router.requestFocusSessionSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])

            Button("") { router.selectedTab = .settings }
                .keyboardShortcut(",", modifiers: .command)

            Button("") { router.selectedTab = .chat }
                .keyboardShortcut("1", modifiers: .command)

            Button("") { router.selectedTab = .review }
                .keyboardShortcut("2", modifiers: .command)

            Button("") { router.selectedTab = .workspace }
                .keyboardShortcut("3", modifiers: .command)

            Button("") { router.selectedTab = .settings }
                .keyboardShortcut("4", modifiers: .command)

            Button("") { router.requestToggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])

            if chatClient.currentSession != nil {
                Button("") { router.requestChooseModel() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("") { router.requestPasteClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .option])

                Button("") { Task { await chatClient.refreshCurrentSessionFromServer() } }
                    .keyboardShortcut("r", modifiers: .command)
            }

            if chatClient.canAttachFiles {
                Button("") { router.requestAttachFile() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            if chatClient.hasDisplayedMessages {
                Button("") { router.requestJumpToLatest() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            }

            if chatClient.isLoading {
                Button("") { chatClient.abort() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
