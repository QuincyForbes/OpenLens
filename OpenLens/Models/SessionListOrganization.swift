import Foundation

/// Presentation-only ordering; always use canonical timestamps and live statuses.
enum SessionListOrganization {
    /// How the Sessions screen arranges chats: one newest-first timeline, or one group per repository.
    enum Layout: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case repository = "By repo"

        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case working = "Working first"
        case updated = "Recently updated"
        case repository = "Repository A–Z"

        var id: String { rawValue }
    }

    struct RepositoryGroup: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let sessions: [OCSession]

        func visibleSessions(keeping sessionIDs: Set<String>) -> [OCSession] {
            let visibleIDs = Set(sessions.prefix(4).map(\.id)).union(sessionIDs)
            return sessions.filter { visibleIDs.contains($0.id) }
        }
    }

    /// One stretch of the activity timeline: chats working right now, then calendar buckets.
    struct TimelineSection: Identifiable {
        let id: String
        let title: String
        let isWorking: Bool
        let sessions: [OCSession]
    }

    private enum TimelineBucket: CaseIterable {
        case working
        case today
        case yesterday
        case previousWeek
        case previousMonth
        case older

        var id: String {
            switch self {
            case .working: "working"
            case .today: "today"
            case .yesterday: "yesterday"
            case .previousWeek: "previous-week"
            case .previousMonth: "previous-month"
            case .older: "older"
            }
        }

        var title: String {
            switch self {
            case .working: AppText.sessionsWorkingNow
            case .today: AppText.sessionsToday
            case .yesterday: AppText.sessionsYesterday
            case .previousWeek: AppText.sessionsPreviousWeek
            case .previousMonth: AppText.sessionsPreviousMonth
            case .older: AppText.sessionsOlder
            }
        }
    }

    static func isWorking(_ status: OCSessionStatus?) -> Bool {
        status?.type == .busy || status?.type == .retry
    }

    static func repositoryID(for session: OCSession) -> String {
        if let directory = WorkspaceSelectionBuilder.normalizedDirectory(session.directory) {
            return "directory:\(directory)"
        }
        if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return "projectID:\(projectID)"
        }
        return "unknown"
    }

    /// The repository name a chat belongs to, as shown on rows and group headers.
    static func repositoryTitle(for session: OCSession) -> String {
        session.workspaceDisplayName
            ?? session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? AppText.projectFallback
    }

    static func groups(
        from sessions: [OCSession],
        statuses: [String: OCSessionStatus],
        sortOrder: SortOrder
    ) -> [RepositoryGroup] {
        let ordered = sorted(sessions, statuses: statuses, workingFirst: sortOrder == .working)
        var groupOrder: [String] = []
        var grouped: [String: [OCSession]] = [:]
        for session in ordered {
            let id = repositoryID(for: session)
            if grouped[id] == nil { groupOrder.append(id) }
            grouped[id, default: []].append(session)
        }
        let groups = groupOrder.compactMap { id -> RepositoryGroup? in
            guard let members = grouped[id], let first = members.first else { return nil }
            return RepositoryGroup(
                id: id,
                title: repositoryTitle(for: first),
                subtitle: WorkspaceSelectionBuilder.normalizedDirectory(first.directory),
                sessions: members
            )
        }
        guard sortOrder == .repository else { return groups }
        return groups.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Newest-first timeline. Working chats lead regardless of timestamp; the rest
    /// fall into calendar buckets measured from the start of `now`'s day.
    static func timeline(
        from sessions: [OCSession],
        statuses: [String: OCSessionStatus],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TimelineSection] {
        let startOfToday = calendar.startOfDay(for: now)
        func start(daysAgo days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: startOfToday)
                ?? startOfToday.addingTimeInterval(-Double(days) * 86_400)
        }
        let startOfYesterday = start(daysAgo: 1)
        let startOfPreviousWeek = start(daysAgo: 7)
        let startOfPreviousMonth = start(daysAgo: 30)

        var bucketed: [TimelineBucket: [OCSession]] = [:]
        for session in sorted(sessions, statuses: statuses, workingFirst: true) {
            let bucket: TimelineBucket
            if isWorking(statuses[session.id]) {
                bucket = .working
            } else if session.updatedAt <= 0 {
                bucket = .older
            } else {
                let updated = Date(timeIntervalSince1970: session.updatedAt)
                if updated >= startOfToday {
                    bucket = .today
                } else if updated >= startOfYesterday {
                    bucket = .yesterday
                } else if updated >= startOfPreviousWeek {
                    bucket = .previousWeek
                } else if updated >= startOfPreviousMonth {
                    bucket = .previousMonth
                } else {
                    bucket = .older
                }
            }
            bucketed[bucket, default: []].append(session)
        }
        return TimelineBucket.allCases.compactMap { bucket in
            guard let members = bucketed[bucket], !members.isEmpty else { return nil }
            return TimelineSection(id: bucket.id, title: bucket.title, isWorking: bucket == .working, sessions: members)
        }
    }

    private static func sorted(
        _ sessions: [OCSession],
        statuses: [String: OCSessionStatus],
        workingFirst: Bool
    ) -> [OCSession] {
        sessions.sorted { lhs, rhs in
            if workingFirst {
                let leftWorking = isWorking(statuses[lhs.id])
                let rightWorking = isWorking(statuses[rhs.id])
                if leftWorking != rightWorking { return leftWorking }
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }
}
