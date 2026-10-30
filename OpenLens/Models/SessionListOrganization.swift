import Foundation

/// Presentation-only ordering; always use canonical timestamps and live statuses.
enum SessionListOrganization {
    /// How the Sessions screen arranges chats: one newest-first timeline, or one group per repository.
    enum Layout: String, CaseIterable, Identifiable {
        case focus = "Focus"
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
        case today
        case yesterday
        case previousWeek
        case previousMonth
        case older

        var id: String {
            switch self {
            case .today: "today"
            case .yesterday: "yesterday"
            case .previousWeek: "previous-week"
            case .previousMonth: "previous-month"
            case .older: "older"
            }
        }

        var title: String {
            switch self {
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
        if let projectID = SessionRepositoryIndex.projectID(session.projectID) {
            return "projectID:\(projectID)"
        }
        if let directory = SessionRepositoryIndex.pathKey(session.directory) {
            return "directory:\(directory)"
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
        sortOrder: SortOrder,
        repositoryIndex: SessionRepositoryIndex? = nil
    ) -> [RepositoryGroup] {
        let sessions = uniqueSessions(sessions)
        let index = repositoryIndex ?? SessionRepositoryIndex(sessions: sessions)
        let ordered = sorted(sessions, statuses: statuses, workingFirst: sortOrder == .working)
        var groupOrder: [String] = []
        var grouped: [String: [OCSession]] = [:]
        for session in ordered {
            let id = index.repository(for: session).id
            if grouped[id] == nil { groupOrder.append(id) }
            grouped[id, default: []].append(session)
        }
        let groups = groupOrder.compactMap { id -> RepositoryGroup? in
            guard let members = grouped[id], let first = members.first else { return nil }
            return RepositoryGroup(
                id: id,
                title: index.repository(for: first).title,
                subtitle: index.repository(for: first).directory,
                sessions: members
            )
        }
        guard sortOrder == .repository else { return groups }
        return groups.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Strict chronological order; activity priority lives in Focus instead.
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
        for session in sorted(uniqueSessions(sessions), statuses: statuses, workingFirst: false) {
            let bucket: TimelineBucket
            if session.updatedAt <= 0 {
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
            return TimelineSection(id: bucket.id, title: bucket.title, isWorking: false, sessions: members)
        }
    }

    /// Catalog pagination and v1 cross-directory reads can overlap. Keep one
    /// canonical row per ID, preferring the freshest server snapshot.
    static func uniqueSessions(_ sessions: [OCSession]) -> [OCSession] {
        var byID: [String: OCSession] = [:]
        var order: [String] = []
        for session in sessions {
            if let existing = byID[session.id] {
                if session.updatedAt > existing.updatedAt { byID[session.id] = session }
            } else {
                order.append(session.id)
                byID[session.id] = session
            }
        }
        return order.compactMap { byID[$0] }
    }

    static func focus(
        from sessions: [OCSession], statuses: [String: OCSessionStatus],
        attentionIDs: Set<String>, pinnedIDs: Set<String>
    ) -> [TimelineSection] {
        let titles = ["Needs You", "Unseen failures", "Pinned", "Unread results", "Working now", "Recent"]
        var buckets = Array(repeating: [OCSession](), count: titles.count)
        for session in sorted(uniqueSessions(sessions), statuses: statuses, workingFirst: false) {
            let working = isWorking(statuses[session.id])
            let bucket: Int
            if attentionIDs.contains(session.id) { bucket = 0 }
            else if !working && session.hasUnreadResult && session.executionOutcome == .failed { bucket = 1 }
            else if pinnedIDs.contains(session.id) { bucket = 2 }
            else if !working && session.hasUnreadResult { bucket = 3 }
            else if working { bucket = 4 }
            else { bucket = 5 }
            buckets[bucket].append(session)
        }
        return titles.indices.compactMap { index in
            guard !buckets[index].isEmpty else { return nil }
            return TimelineSection(id: "focus-\(index)", title: titles[index], isWorking: index == 4, sessions: buckets[index])
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
