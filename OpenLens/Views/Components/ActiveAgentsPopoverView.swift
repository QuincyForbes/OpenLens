import SwiftUI

/// Live mission-control popover/sheet showing every running chat and subagent
/// across all repositories, what tool/step each agent is currently executing,
/// elapsed durations, 1-click thread navigation, and individual/batch stop controls.
struct ActiveAgentsPopoverView: View {
    let currentSession: OCSession?
    let isCurrentSessionGenerating: Bool
    let currentActivityLabel: String?
    let currentTurnStartDate: Date?
    let currentSubagents: [ChatClient.SubagentThreadItem]
    let currentShellWatchers: [ChatClient.BackgroundWatcherItem]
    let onSelectSession: (OCSession) -> Void
    let onSelectSessionID: (String) -> Void
    let onStopCurrentSession: () -> Void

    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false
    @State private var isStoppingAll = false
    @State private var stoppingIDs: Set<String> = []

    private var statuses: [String: OCSessionStatus] {
        sessionsService.effectiveStatuses
    }

    private var runningCurrentSubagents: [ChatClient.SubagentThreadItem] {
        currentSubagents.filter(\.isRunning)
    }

    private var hasCurrentActiveWork: Bool {
        isCurrentSessionGenerating || !runningCurrentSubagents.isEmpty || !currentShellWatchers.isEmpty
    }

    private var otherActiveRoots: [OCSession] {
        sessionsService.activeRootSessions(excluding: currentSession?.id)
    }

    private var orphanActiveSubagents: [OCSession] {
        let rootIDs = Set(otherActiveRoots.map(\.id)).union(currentSession.map { [$0.id] } ?? [])
        return sessionsService.activeSubagentSessions(statuses: statuses).filter { child in
            guard let parentID = child.parentID?.nilIfBlank else { return true }
            return !rootIDs.contains(parentID)
        }
    }

    private var totalRunningRootCount: Int {
        otherActiveRoots.count + (hasCurrentActiveWork ? 1 : 0)
    }

    private var totalRunningSubagentCount: Int {
        let otherSubagentCount = otherActiveRoots.reduce(0) { sum, root in
            sum + activeChildren(for: root.id).count
        } + orphanActiveSubagents.count
        return runningCurrentSubagents.count + otherSubagentCount
    }

    private var headerSubtitle: String {
        if totalRunningRootCount == 0 && totalRunningSubagentCount == 0 {
            return "All chats and subagents are currently idle"
        }
        var parts: [String] = []
        if totalRunningRootCount > 0 {
            parts.append("\(totalRunningRootCount) \(totalRunningRootCount == 1 ? "chat" : "chats")")
        }
        if totalRunningSubagentCount > 0 {
            parts.append("\(totalRunningSubagentCount) \(totalRunningSubagentCount == 1 ? "subagent" : "subagents")")
        }
        return parts.joined(separator: " · ") + " running"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .overlay(Color.appSeparator)

            if !hasCurrentActiveWork && otherActiveRoots.isEmpty && orphanActiveSubagents.isEmpty {
                idleEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if hasCurrentActiveWork, let current = currentSession {
                            sectionHeader("CURRENT CHAT")
                            currentSessionCard(current)
                        }

                        if !otherActiveRoots.isEmpty {
                            sectionHeader(hasCurrentActiveWork ? "OTHER REPOSITORIES & CHATS" : "WORKING NOW")
                            ForEach(otherActiveRoots) { session in
                                otherSessionCard(session)
                            }
                        }

                        if !orphanActiveSubagents.isEmpty {
                            sectionHeader("BACKGROUND SUBAGENTS")
                            ForEach(orphanActiveSubagents) { child in
                                orphanSubagentCard(child)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.appBackground)
        #if targetEnvironment(macCatalyst)
        .frame(width: 420)
        .frame(minHeight: 240, maxHeight: 540)
        #else
        .frame(minWidth: 360, idealWidth: 400, maxHeight: 540)
        #endif
        .presentationCompactAdaptation(.sheet)
        .task {
            await refreshStatuses()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill((totalRunningRootCount + totalRunningSubagentCount) > 0 ? Color.appAccent.opacity(0.16) : Color.appSuccess.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: (totalRunningRootCount + totalRunningSubagentCount) > 0 ? "bolt.horizontal.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle((totalRunningRootCount + totalRunningSubagentCount) > 0 ? Color.appAccent : Color.appSuccess)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Live Activity")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await refreshStatuses() }
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.appTertiary, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh live activity")

            if totalRunningRootCount > 0 || totalRunningSubagentCount > 0 {
                Button {
                    stopEverything()
                } label: {
                    HStack(spacing: 4) {
                        if isStoppingAll {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text("Stop all")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.appDanger)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.appDanger.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isStoppingAll)
                .accessibilityIdentifier("activePopover.stopAll")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
    }

    private var idleEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.appSuccess)
            Text("No agents running right now")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
            Text("When chats or background subagents are working across any repository, their live steps and tools appear here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.appSecondary)
            .tracking(0.6)
            .padding(.horizontal, 4)
    }

    private func currentSessionCard(_ session: OCSession) -> some View {
        let liveSnapshot = sessionsService.liveActivity(for: session.id)
        let statusLine = currentActivityLabel?.nilIfBlank
            ?? liveSnapshot?.statusLabel
            ?? (isCurrentSessionGenerating ? "Working…" : "Waiting on background tasks")
        let iconName = liveSnapshot?.iconName ?? "sparkles"
        let startDate = currentTurnStartDate ?? sessionsService.activeStartDate(for: session)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)

                        Text("Viewing")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent.opacity(0.14), in: Capsule())
                    }

                    if let repo = session.workspaceDisplayName {
                        repoLabel(repo)
                    }
                }

                Spacer(minLength: 6)

                if let startDate {
                    ElapsedDurationText(startDate: startDate)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appAccent)
                }

                Button {
                    onStopCurrentSession()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.appDanger)
                }
                .buttonStyle(.plain)
                .help("Stop current chat & subagents")
                .accessibilityLabel("Stop current chat")
            }

            liveActivityPill(
                icon: iconName,
                text: statusLine,
                stepCount: liveSnapshot?.stepCount ?? 0
            )

            if !runningCurrentSubagents.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(runningCurrentSubagents) { sub in
                        subagentInlineRow(
                            title: sub.title,
                            agentName: sub.agentName,
                            liveText: sub.childSessionID.flatMap { sessionsService.liveActivity(for: $0)?.statusLabel } ?? sub.detail,
                            startDate: sub.startedAt,
                            childSessionID: sub.childSessionID
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.appAccent.opacity(0.32), lineWidth: 1)
        }
    }

    private func otherSessionCard(_ session: OCSession) -> some View {
        let isDirectlyBusy = SessionListOrganization.isWorking(statuses[session.id])
        let children = activeChildren(for: session.id)
        let liveSnapshot = sessionsService.liveActivity(for: session.id)
        let statusLine: String = {
            if let liveSnapshot {
                return liveSnapshot.statusLabel
            }
            if statuses[session.id]?.type == .retry {
                return statuses[session.id]?.message?.nilIfBlank ?? "Retrying…"
            }
            if !isDirectlyBusy, !children.isEmpty {
                return children.count == 1 ? "1 subagent working" : "\(children.count) subagents working"
            }
            return "Working…"
        }()
        let iconName = liveSnapshot?.iconName ?? (!isDirectlyBusy && !children.isEmpty ? "person.2.wave.2" : "sparkles")
        let startDate = sessionsService.activeStartDate(for: session)
        let isStopping = stoppingIDs.contains(session.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    dismiss()
                    onSelectSession(session)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title.nilIfBlank ?? AppText.titleUntitled)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            if let repo = session.workspaceDisplayName {
                                repoLabel(repo)
                            }
                            Text("Open →")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let startDate {
                    ElapsedDurationText(startDate: startDate)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appAccent)
                }

                Button {
                    stopSessionAndChildren(session)
                } label: {
                    if isStopping {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.appDanger)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isStopping || isStoppingAll)
                .help("Stop session")
                .accessibilityLabel("Stop \(session.title.nilIfBlank ?? AppText.titleUntitled)")
            }

            Button {
                dismiss()
                onSelectSession(session)
            } label: {
                liveActivityPill(
                    icon: iconName,
                    text: statusLine,
                    stepCount: liveSnapshot?.stepCount ?? 0
                )
            }
            .buttonStyle(.plain)

            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(children) { child in
                        subagentInlineRow(
                            title: child.title.nilIfBlank ?? child.agent ?? "Subagent",
                            agentName: child.agent,
                            liveText: sessionsService.liveActivity(for: child.id)?.statusLabel,
                            startDate: sessionsService.activeStartDate(for: child),
                            childSessionID: child.id
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        }
    }

    private func orphanSubagentCard(_ child: OCSession) -> some View {
        let liveSnapshot = sessionsService.liveActivity(for: child.id)
        let isStopping = stoppingIDs.contains(child.id)

        return HStack(spacing: 10) {
            Button {
                dismiss()
                onSelectSession(child)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appAccent)
                        Text(child.title.nilIfBlank ?? child.agent ?? "Subagent")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)
                    }
                    liveActivityPill(
                        icon: liveSnapshot?.iconName ?? "sparkles",
                        text: liveSnapshot?.statusLabel ?? "Working…",
                        stepCount: liveSnapshot?.stepCount ?? 0
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let start = sessionsService.activeStartDate(for: child) {
                ElapsedDurationText(startDate: start)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appAccent)
            }

            Button {
                stopSingleID(child.id)
            } label: {
                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.appDanger)
                }
            }
            .buttonStyle(.plain)
            .disabled(isStopping || isStoppingAll)
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.appSeparator, lineWidth: 1)
        }
    }

    private func liveActivityPill(icon: String, text: String, stepCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .symbolEffect(.pulse)

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if stepCount > 0 {
                Text("Step \(stepCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.appAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func subagentInlineRow(
        title: String,
        agentName: String?,
        liveText: String?,
        startDate: Date?,
        childSessionID: String?
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                guard let childSessionID else { return }
                dismiss()
                onSelectSessionID(childSessionID)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appSecondary)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)
                    if let agentName = agentName?.nilIfBlank,
                       agentName.caseInsensitiveCompare(title) != .orderedSame {
                        Text(agentName)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.appTertiary, in: Capsule())
                    }
                    if let liveText = liveText?.nilIfBlank, liveText != title {
                        Text("· \(liveText)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(childSessionID == nil)

            if let startDate {
                ElapsedDurationText(startDate: startDate)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }

            if let childSessionID {
                let isStopping = stoppingIDs.contains(childSessionID)
                Button {
                    stopSingleID(childSessionID)
                } label: {
                    if isStopping {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appDanger)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isStopping || isStoppingAll)
            }
        }
        .padding(.leading, 6)
        .padding(.vertical, 3)
    }

    private func repoLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.appSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.appTertiary, in: Capsule())
    }

    private func activeChildren(for parentID: String) -> [OCSession] {
        sessionsService.childSessions(forParentID: parentID)
            .filter { SessionListOrganization.isWorking(statuses[$0.id]) }
    }

    private func refreshStatuses() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = try? await sessionsService.getSessionStatuses()
    }

    private func stopSessionAndChildren(_ session: OCSession) {
        var ids = [session.id]
        ids.append(contentsOf: activeChildren(for: session.id).map(\.id))
        stoppingIDs.formUnion(ids)
        Task {
            defer { stoppingIDs.subtract(ids) }
            _ = await sessionsService.abortSessions(ids: ids)
        }
    }

    private func stopSingleID(_ sessionID: String) {
        stoppingIDs.insert(sessionID)
        Task {
            defer { stoppingIDs.remove(sessionID) }
            _ = await sessionsService.abortSessions(ids: [sessionID])
        }
    }

    private func stopEverything() {
        guard !isStoppingAll else { return }
        isStoppingAll = true
        if hasCurrentActiveWork {
            onStopCurrentSession()
        }
        Task {
            defer { isStoppingAll = false }
            _ = await sessionsService.abortAllActiveSessions()
        }
    }
}
