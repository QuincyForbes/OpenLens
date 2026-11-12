import SwiftUI

/// Navigation bar toolbar content for the chat view.
struct ChatHeaderToolbar: ToolbarContent {
    let projectName: String?
    let branch: String?
    let connectionState: ConnectionManager.State
    let sessionTitle: String?
    let showsRecordingControls: Bool
    let isRecordingStream: Bool
    let visualMode: ChatVisualMode
    let onToggleRecording: (() -> Void)?
    var onShowInsights: (() -> Void)? = nil
    var onShowSessionReview: (() -> Void)? = nil
    var onShowMeridianUsage: (() -> Void)? = nil
    var onShowContext: (() -> Void)? = nil
    var onRenameSession: (() -> Void)? = nil
    var onSyncSession: (() -> Void)? = nil
    var onScrollToBottom: (() -> Void)? = nil
    var onSwitchSession: (() -> Void)? = nil
    var onShowSubagents: (() -> Void)? = nil
    var onShowActiveAgents: (() -> Void)? = nil
    var onStopAllInChat: (() -> Void)? = nil
    var onCopyLastReply: (() -> Void)? = nil
    var otherActiveSessionCount: Int = 0
    var subagentCount: Int = 0
    var runningSubagentCount: Int = 0
    var activeAgentsPopover: AnyView? = nil
    @Binding var isShowingActiveAgentsPopover: Bool

    init(
        projectName: String?,
        branch: String?,
        connectionState: ConnectionManager.State,
        sessionTitle: String?,
        showsRecordingControls: Bool,
        isRecordingStream: Bool,
        visualMode: ChatVisualMode,
        onToggleRecording: (() -> Void)?,
        onShowInsights: (() -> Void)? = nil,
        onShowSessionReview: (() -> Void)? = nil,
        onShowMeridianUsage: (() -> Void)? = nil,
        onShowContext: (() -> Void)? = nil,
        onRenameSession: (() -> Void)? = nil,
        onSyncSession: (() -> Void)? = nil,
        onScrollToBottom: (() -> Void)? = nil,
        onSwitchSession: (() -> Void)? = nil,
        onShowSubagents: (() -> Void)? = nil,
        onShowActiveAgents: (() -> Void)? = nil,
        onStopAllInChat: (() -> Void)? = nil,
        onCopyLastReply: (() -> Void)? = nil,
        otherActiveSessionCount: Int = 0,
        subagentCount: Int = 0,
        runningSubagentCount: Int = 0,
        activeAgentsPopover: AnyView? = nil,
        isShowingActiveAgentsPopover: Binding<Bool> = .constant(false)
    ) {
        self.projectName = projectName
        self.branch = branch
        self.connectionState = connectionState
        self.sessionTitle = sessionTitle
        self.showsRecordingControls = showsRecordingControls
        self.isRecordingStream = isRecordingStream
        self.visualMode = visualMode
        self.onToggleRecording = onToggleRecording
        self.onShowInsights = onShowInsights
        self.onShowSessionReview = onShowSessionReview
        self.onShowMeridianUsage = onShowMeridianUsage
        self.onShowContext = onShowContext
        self.onRenameSession = onRenameSession
        self.onSyncSession = onSyncSession
        self.onScrollToBottom = onScrollToBottom
        self.onSwitchSession = onSwitchSession
        self.onShowSubagents = onShowSubagents
        self.onShowActiveAgents = onShowActiveAgents
        self.onStopAllInChat = onStopAllInChat
        self.onCopyLastReply = onCopyLastReply
        self.otherActiveSessionCount = otherActiveSessionCount
        self.subagentCount = subagentCount
        self.runningSubagentCount = runningSubagentCount
        self.activeAgentsPopover = activeAgentsPopover
        self._isShowingActiveAgentsPopover = isShowingActiveAgentsPopover
    }

    private var statusColor: Color {
        if visualMode.isRetro {
            switch connectionState {
            case .connected: return RetroChatStyle.blueAccent
            case .reconnecting, .connecting: return RetroChatStyle.magentaAccent
            case .disconnected: return RetroChatStyle.mutedInk.opacity(0.7)
            case .error: return RetroChatStyle.danger
            }
        }

        switch connectionState {
        case .connected: return .green
        case .reconnecting, .connecting: return .orange
        case .disconnected, .error: return Color.gray.opacity(0.5)
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected: AppText.statusConnected
        case .reconnecting: AppText.statusReconnecting
        case .connecting: AppText.statusConnecting
        case .disconnected: AppText.statusOffline
        case .error: AppText.statusError
        }
    }

    private var recordingLabel: String {
        isRecordingStream ? AppText.recordingStop : AppText.recordingStart
    }

    private var recordingIcon: String {
        isRecordingStream ? "stop.circle.fill" : "record.circle"
    }

    private var recordingTint: Color {
        if visualMode.isRetro {
            return isRecordingStream ? RetroChatStyle.danger : RetroChatStyle.secondaryInk
        }
        return isRecordingStream ? .red : Color.appSecondary
    }

    private var isRetroChat: Bool {
        visualMode.isRetro
    }

    private var activeBadgeText: String? {
        if otherActiveSessionCount > 0 {
            return "\(otherActiveSessionCount) active"
        }
        if runningSubagentCount > 0 {
            return runningSubagentCount == 1 ? "1 subagent" : "\(runningSubagentCount) subagents"
        }
        return nil
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .center, spacing: 2) {
                HStack(spacing: 8) {
                    if let onSwitchSession {
                        Button(action: onSwitchSession) {
                            HStack(spacing: 4) {
                                sessionTitleLabel
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                            }
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Switch session, \(resolvedSessionTitle)")
                        .accessibilityIdentifier("chat.switchSession")
                    } else {
                        sessionTitleLabel
                    }

                    if let badgeText = activeBadgeText {
                        Button {
                            if let onShowActiveAgents {
                                onShowActiveAgents()
                            } else {
                                onSwitchSession?()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                                    .frame(width: 6, height: 6)
                                    .symbolEffect(.pulse)
                                Text(badgeText)
                                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent).opacity(0.14),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke((isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent).opacity(0.28), lineWidth: 1)
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Inspect running chats and live agent activity")
                        .accessibilityLabel("View live agent activity, \(badgeText)")
                        .accessibilityIdentifier("chat.activeAgentsPill")
                        .popover(isPresented: $isShowingActiveAgentsPopover, arrowEdge: .top) {
                            if let activeAgentsPopover {
                                activeAgentsPopover
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .symbolEffect(.pulse, isActive: connectionState == .connecting || connectionState == .reconnecting)
                        .padding(.trailing, 4)

                    if let projectName {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        Text(projectName)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                            .lineLimit(1)
                    }

                    if let branch {
                        if projectName != nil {
                            Text("\u{00B7}")
                                .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13))
                                .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        }
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : .gray)
                        Text(branch)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : .secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal)
                .chatHeaderStatusChrome(visualMode)
            }
            .safeAreaPadding(.vertical)
        }

        if showsRecordingControls, let onToggleRecording {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onToggleRecording) {
                    HStack(spacing: 6) {
                        Image(systemName: recordingIcon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(recordingLabel)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(recordingTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .chatRecordingButtonChrome(visualMode)
                }
                .accessibilityLabel(recordingLabel)
                .accessibilityHint(statusText)
            }
        }
        if onShowInsights != nil || onShowContext != nil || onRenameSession != nil || onSyncSession != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let onSwitchSession {
                        Button(action: onSwitchSession) {
                            Label("Switch Session", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    if let onShowActiveAgents, (otherActiveSessionCount > 0 || runningSubagentCount > 0) {
                        Button(action: onShowActiveAgents) {
                            Label("Live Agent Activity", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    if let onShowSubagents, subagentCount > 0 {
                        Button(action: onShowSubagents) {
                            let badge = runningSubagentCount > 0
                                ? "Subagent Threads (\(runningSubagentCount) running)"
                                : "Subagent Threads (\(subagentCount))"
                            Label(badge, systemImage: "person.2.wave.2")
                        }
                    }
                    if let onCopyLastReply {
                        Button(action: onCopyLastReply) {
                            Label("Copy Last Reply", systemImage: "doc.on.doc")
                        }
                    }
                    if let onShowInsights {
                        Button(action: onShowInsights) {
                            Label("Session Insights", systemImage: "chart.bar.xaxis")
                        }
                    }
                    if let onShowSessionReview {
                        Button(action: onShowSessionReview) {
                            Label("Session Changes & Revert", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    if let onShowMeridianUsage {
                        Button(action: onShowMeridianUsage) {
                            Label("Meridian Usage", systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                    if let onShowContext {
                        Button(action: onShowContext) {
                            Label("Inspect Context", systemImage: "text.bubble")
                        }
                    }
                    if let onRenameSession {
                        Button(action: onRenameSession) {
                            Label("Rename Session", systemImage: "pencil")
                        }
                    }
                    Divider()
                    if let onSyncSession {
                        Button(action: onSyncSession) {
                            Label("Sync Session", systemImage: "arrow.clockwise")
                        }
                    }
                    if let onScrollToBottom {
                        Button(action: onScrollToBottom) {
                            Label("Jump to Latest", systemImage: "arrow.down.to.line")
                        }
                    }
                    if let onStopAllInChat {
                        Divider()
                        Button(role: .destructive, action: onStopAllInChat) {
                            Label(
                                runningSubagentCount > 0 ? "Stop Chat & Subagents" : "Stop Running Turn",
                                systemImage: "stop.circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
                }
                .accessibilityLabel("Session actions")
            }
        }
    }

    private var resolvedSessionTitle: String {
        guard let sessionTitle else { return "OpenCode" }
        return sessionTitle.nilIfBlank ?? AppText.titleUntitled
    }

    private var sessionTitleLabel: some View {
        Text(resolvedSessionTitle)
            .font(isRetroChat ? RetroChatStyle.headerFont : .headline)
            .foregroundStyle(isRetroChat ? RetroChatStyle.ink : .primary)
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
    }
}
