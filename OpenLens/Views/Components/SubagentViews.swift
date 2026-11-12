import SwiftUI

extension EnvironmentValues {
    @Entry var onOpenSubagentSession: ((String) -> Void)? = nil
    @Entry var onStopSubagentSession: ((String) -> Void)? = nil
}

nonisolated enum ElapsedDurationFormatter {
    static func string(from startDate: Date, to now: Date = Date()) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(startDate)))
        if totalSeconds < 60 {
            return String(format: "0:%02d", totalSeconds)
        }
        if totalSeconds < 3_600 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return String(format: "%dm %02ds", minutes, seconds)
        }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        return String(format: "%dh %02dm", hours, minutes)
    }

    static func activeStartDate(for session: OCSession) -> Date? {
        activeStartDate(for: session, observedStart: nil)
    }

    static func activeStartDate(for session: OCSession, observedStart: Date?) -> Date? {
        if let busyMs = session.time.busy,
           busyMs.isFinite,
           busyMs > 0,
           busyMs > (session.time.idle ?? 0) {
            return Date(timeIntervalSince1970: busyMs / 1_000)
        }
        if let observedStart {
            return observedStart
        }
        if session.parentID?.nilIfBlank != nil, session.time.created > 0 {
            return Date(timeIntervalSince1970: session.time.created / 1_000)
        }
        return nil
    }
}

struct ElapsedDurationText: View {
    let startDate: Date

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let referenceDate = scenePhase == .active ? context.date : Date()
            Text(ElapsedDurationFormatter.string(from: startDate, to: referenceDate))
                .monospacedDigit()
        }
    }
}

struct SubagentParentBanner: View {
    let parentTitle: String?
    let subagentName: String?
    let isSubagentRunning: Bool
    let isStopping: Bool
    let startDate: Date?
    let isRetroChat: Bool
    let onOpenParent: () -> Void
    let onStopSubagent: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenParent) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Subagent Thread")
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                        Text("Parent: \(resolvedParentTitle)")
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .medium))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.openParentSession")

            Spacer(minLength: 8)

            if isSubagentRunning {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isRetroChat ? RetroChatStyle.magentaAccent : Color.appAccent)
                        .frame(width: 6, height: 6)
                        .symbolEffect(.pulse)
                    if let startDate {
                        ElapsedDurationText(startDate: startDate)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    }
                }

                Button(action: onStopSubagent) {
                    HStack(spacing: 4) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(isStopping ? "Stopping" : "Stop")
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isRetroChat ? RetroChatStyle.danger : Color.appDanger)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        (isRetroChat ? RetroChatStyle.danger : Color.appDanger).opacity(0.12),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(isStopping)
                .accessibilityIdentifier("chat.stopCurrentSubagent")
            } else if let subagentName = subagentName?.nilIfBlank {
                Text(subagentName)
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.appTertiary.opacity(0.8), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isRetroChat ? RetroChatStyle.paperWarm : Color.appSurface)
        .overlay(alignment: .bottom) {
            (isRetroChat ? RetroChatStyle.ink : Color.appSeparator)
                .frame(height: isRetroChat ? 1.5 : 0.5)
        }
    }

    private var resolvedParentTitle: String {
        guard let title = parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Main conversation"
        }
        return title
    }
}

struct LiveAgentsControlBar: View {
    let runningSubagents: [ChatClient.SubagentThreadItem]
    let shellWatchers: [ChatClient.BackgroundWatcherItem]
    let isStoppingAll: Bool
    let isRemindArmed: Bool
    let isRetroChat: Bool
    let onOpenThreadsSheet: () -> Void
    let onStopAll: () -> Void
    let onToggleReminder: () -> Void

    private var totalRunningCount: Int {
        runningSubagents.count + shellWatchers.count
    }

    private var summaryLabel: String {
        if !runningSubagents.isEmpty && shellWatchers.isEmpty {
            if runningSubagents.count == 1 {
                return "Subagent · \(runningSubagents[0].title)"
            }
            return "\(runningSubagents.count) subagents running"
        }
        if runningSubagents.isEmpty && shellWatchers.count == 1 {
            return "Watching · \(shellWatchers[0].title)"
        }
        return "\(totalRunningCount) background tasks running"
    }

    private var earliestStartDate: Date? {
        runningSubagents.compactMap(\.startedAt).min()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenThreadsSheet) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRetroChat ? RetroChatStyle.magentaAccent : Color.appAccent)
                        .frame(width: 7, height: 7)
                        .symbolEffect(.pulse)

                    Text(summaryLabel)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isRetroChat ? RetroChatStyle.ink : Color.appPrimary)
                        .lineLimit(1)

                    if let start = earliestStartDate {
                        Text("·")
                            .foregroundStyle(isRetroChat ? RetroChatStyle.mutedInk : Color.appSecondary)
                        ElapsedDurationText(startDate: start)
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary)
                    }

                    HStack(spacing: 2) {
                        Text("Threads")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.openSubagentThreads")

            if !runningSubagents.isEmpty {
                Divider()
                    .frame(height: 14)

                Button(action: onStopAll) {
                    HStack(spacing: 4) {
                        if isStoppingAll {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(runningSubagents.count > 1 ? "Stop all" : "Stop")
                            .font(isRetroChat ? RetroChatStyle.smallFont : .system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isRetroChat ? RetroChatStyle.danger : Color.appDanger)
                }
                .buttonStyle(.plain)
                .disabled(isStoppingAll)
                .accessibilityIdentifier("chat.stopAllSubagents")
            }

            Divider()
                .frame(height: 14)

            Button(action: onToggleReminder) {
                Image(systemName: isRemindArmed ? "bell.fill" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isRemindArmed ? Color.appAccent : (isRetroChat ? RetroChatStyle.secondaryInk : Color.appSecondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRemindArmed ? "Disable completion reminder" : "Notify when background tasks finish")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isRetroChat ? RetroChatStyle.paperWarm : Color.appSurface,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke((isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent).opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isRetroChat ? 0 : 0.08), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
}

struct SubagentThreadsSheet: View {
    let subagents: [ChatClient.SubagentThreadItem]
    let shellWatchers: [ChatClient.BackgroundWatcherItem]
    let isParentRunning: Bool
    let isStopping: Bool
    let onOpenThread: (String) -> Void
    let onStopSubagent: (String) -> Void
    let onStopAll: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var runningSubagents: [ChatClient.SubagentThreadItem] {
        subagents.filter(\.isRunning)
    }

    private var completedSubagents: [ChatClient.SubagentThreadItem] {
        subagents.filter { !$0.isRunning }
    }

    var body: some View {
        NavigationStack {
            List {
                if !runningSubagents.isEmpty || isParentRunning {
                    Section {
                        Button(role: .destructive, action: onStopAll) {
                            HStack {
                                Label(
                                    stopAllButtonTitle,
                                    systemImage: "stop.circle.fill"
                                )
                                .font(.subheadline.weight(.semibold))
                                Spacer()
                                if isStopping {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isStopping)
                        .listRowBackground(Color.appDanger.opacity(0.08))
                        .accessibilityIdentifier("subagentsSheet.stopAll")
                    }
                }

                if !runningSubagents.isEmpty {
                    Section("Running Subagents (\(runningSubagents.count))") {
                        ForEach(runningSubagents) { item in
                            subagentRow(item)
                        }
                    }
                }

                if !shellWatchers.isEmpty {
                    Section("Background Shells (\(shellWatchers.count))") {
                        ForEach(shellWatchers) { shell in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "terminal.fill")
                                    .foregroundStyle(Color.appAccent)
                                    .font(.subheadline)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shell.title)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.appPrimary)
                                    if let detail = shell.detail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(Color.appSecondary)
                                    }
                                }
                            }
                            .listRowBackground(Color.appSurface)
                        }
                    }
                }

                if !completedSubagents.isEmpty {
                    Section("Finished Subagents (\(completedSubagents.count))") {
                        ForEach(completedSubagents) { item in
                            subagentRow(item)
                        }
                    }
                }

                if subagents.isEmpty && shellWatchers.isEmpty {
                    ContentUnavailableView(
                        "No Subagent Threads",
                        systemImage: "person.2.slash",
                        description: Text("Subagents spawned by this conversation will appear here so you can inspect their threads or stop them.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Agents & Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppText.done) { dismiss() }
                }
            }
        }
    }

    private var stopAllButtonTitle: String {
        let count = runningSubagents.count + (isParentRunning ? 1 : 0)
        return count <= 1 ? "Stop Running Agent" : "Stop All \(count) Running Agents"
    }

    @ViewBuilder
    private func subagentRow(_ item: ChatClient.SubagentThreadItem) -> some View {
        HStack(spacing: 12) {
            Button {
                guard let childID = item.childSessionID else { return }
                dismiss()
                onOpenThread(childID)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: statusIcon(for: item))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor(for: item))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appPrimary)
                                .lineLimit(2)

                            if let agent = item.agentName?.nilIfBlank,
                               agent.caseInsensitiveCompare(item.title) != .orderedSame {
                                Text(agent)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.appSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.appTertiary, in: Capsule())
                            }
                        }

                        if let detail = item.detail?.nilIfBlank, detail != item.title {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(2)
                        }

                        HStack(spacing: 6) {
                            Text(item.stateLabel)
                                .fontWeight(.semibold)
                                .foregroundStyle(statusColor(for: item))

                            if item.isRunning, let startDate = item.startedAt {
                                Text("·")
                                    .foregroundStyle(Color.appSecondary)
                                ElapsedDurationText(startDate: startDate)
                                    .foregroundStyle(Color.appSecondary)
                            }

                            if item.childSessionID != nil {
                                Text("· View thread")
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                        .font(.caption2)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.childSessionID == nil)

            if item.isRunning, let childID = item.childSessionID {
                Button {
                    onStopSubagent(childID)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.appDanger)
                }
                .buttonStyle(.plain)
                .disabled(isStopping)
                .accessibilityLabel("Stop \(item.title)")
                .accessibilityIdentifier("subagentsSheet.stop.\(childID)")
            } else if item.childSessionID != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appSecondary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.appSurface)
    }

    private func statusIcon(for item: ChatClient.SubagentThreadItem) -> String {
        if item.isRunning { return "person.crop.circle.badge.clock" }
        if item.stateLabel == "Cancelled" { return "xmark.circle" }
        if item.isError { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private func statusColor(for item: ChatClient.SubagentThreadItem) -> Color {
        if item.isRunning { return Color.appAccent }
        if item.isError { return Color.appWarning }
        return Color.appSecondary
    }
}
