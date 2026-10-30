import Foundation
import Testing
@testable import OpenLens

struct SessionListOrganizationTests {
    private func session(_ id: String, directory: String? = "/repos/Alpha", updated: Double) -> OCSession {
        OCSession(
            id: id,
            directory: directory,
            title: id,
            time: OCSessionTime(created: 0, updated: updated)
        )
    }

    private func status(_ type: OCSessionStatusType) -> OCSessionStatus {
        OCSessionStatus(type: type, attempt: nil, message: nil, next: nil)
    }

    @Test func workingSortPromotesBusyAndRetryingRepositoriesAndChats() {
        let sessions = [
            session("new-idle", directory: "/repos/Beta", updated: 500),
            session("old-idle", updated: 400),
            session("busy", updated: 200),
            session("retry", updated: 300),
        ]
        let groups = SessionListOrganization.groups(
            from: sessions,
            statuses: ["busy": status(.busy), "retry": status(.retry)],
            sortOrder: .working
        )

        #expect(groups.map(\.title) == ["Alpha", "Beta"])
        #expect(groups[0].sessions.map(\.id) == ["retry", "busy", "old-idle"])
    }

    @Test func recentSortUsesLatestCanonicalTimestampRatherThanInputOrderOrStatus() {
        let sessions = [
            session("old", updated: 100),
            session("new", directory: "/repos/Beta", updated: 500),
            session("middle", updated: 300),
        ]
        let groups = SessionListOrganization.groups(
            from: sessions, statuses: ["old": status(.busy)], sortOrder: .updated
        )

        #expect(groups.map(\.title) == ["Beta", "Alpha"])
        #expect(groups[1].sessions.map(\.id) == ["middle", "old"])
    }

    @Test func alphabeticalSortKeepsChatsNewestFirstWithinEachRepository() {
        let groups = SessionListOrganization.groups(
            from: [
                session("beta", directory: "/repos/Beta", updated: 900),
                session("alpha-old", updated: 100),
                session("alpha-new", updated: 200),
            ],
            statuses: [:], sortOrder: .repository
        )

        #expect(groups.map(\.title) == ["Alpha", "Beta"])
        #expect(groups[0].sessions.map(\.id) == ["alpha-new", "alpha-old"])
    }

    @Test func collapsedGroupsNeverHideWorkingOrAttentionChats() {
        let sessions = (1...8).map { session("chat-\($0)", updated: Double(10 - $0)) }
        let groups = SessionListOrganization.groups(from: sessions, statuses: [:], sortOrder: .updated)
        let visible = groups[0].visibleSessions(keeping: ["chat-6", "chat-8"])

        #expect(visible.map(\.id) == ["chat-1", "chat-2", "chat-3", "chat-4", "chat-6", "chat-8"])
    }

    @Test func equalTimestampsHaveDeterministicOrder() {
        let groups = SessionListOrganization.groups(
            from: [session("b", updated: 100), session("a", updated: 100)],
            statuses: [:], sortOrder: .updated
        )
        #expect(groups[0].sessions.map(\.id) == ["a", "b"])
    }

    @Test func directoryNormalizationAndFullPathsKeepRepositoryGroupsUnambiguous() {
        let groups = SessionListOrganization.groups(
            from: [
                session("a", directory: "/repos/Alpha/", updated: 100),
                session("b", directory: " /repos/Alpha ", updated: 200),
                session("c", directory: "/other/Alpha", updated: 300),
                session("unknown", directory: nil, updated: 0),
            ],
            statuses: [:], sortOrder: .repository
        )

        #expect(groups.count == 3)
        #expect(groups.first { $0.id == "directory:/repos/Alpha" }?.sessions.count == 2)
        #expect(groups.first { $0.id == "directory:/other/Alpha" }?.subtitle == "/other/Alpha")
        #expect(groups.contains { $0.id == "unknown" })
    }

    @Test func completionReturnsChatToTimestampOrderWhenItBecomesIdle() {
        let before = SessionListOrganization.groups(
            from: [session("working", updated: 100), session("other", updated: 200)],
            statuses: ["working": status(.busy)], sortOrder: .working
        )
        let after = SessionListOrganization.groups(
            from: [session("working", updated: 150), session("other", updated: 200)],
            statuses: ["working": status(.idle)], sortOrder: .working
        )

        #expect(before[0].sessions.first?.id == "working")
        #expect(after[0].sessions.first?.id == "other")
    }

    @Test func windowsDirectoriesUseTheirRepositoryNameAndNormalizeSeparators() {
        let groups = SessionListOrganization.groups(
            from: [
                session("a", directory: "C:/repos/Alpha/", updated: 100),
                session("b", directory: #"C:\repos\Alpha"#, updated: 200),
            ],
            statuses: [:], sortOrder: .repository
        )

        #expect(groups.count == 1)
        #expect(groups[0].title == "Alpha")
        #expect(groups[0].sessions.map(\.id) == ["b", "a"])
    }

    @Test func projectOnlySessionsRemainDistinctFromUnknownRepositories() {
        let projectSession = OCSession(
            id: "project", projectID: " alpha ", title: "Project",
            time: OCSessionTime(created: 0, updated: 100)
        )
        let groups = SessionListOrganization.groups(
            from: [projectSession, session("unknown", directory: nil, updated: 0)],
            statuses: [:], sortOrder: .repository
        )

        #expect(groups.contains { $0.id == "projectID:alpha" && $0.title == "alpha" })
        #expect(groups.contains { $0.id == "unknown" })
    }

    // MARK: - Timeline

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-31 15:00 UTC, so bucket boundaries never straddle a real midnight.
    private let referenceNow = Date(timeIntervalSince1970: 1_793_458_800)

    private func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000
    }

    @Test func recentTimelineUsesChronologyEvenWhenOlderChatsAreWorking() {
        let calendar = utcCalendar
        let startOfToday = calendar.startOfDay(for: referenceNow)
        let sessions = [
            session("today", updated: milliseconds(startOfToday.addingTimeInterval(3_600))),
            session("stale-busy", updated: milliseconds(startOfToday.addingTimeInterval(-40 * 86_400))),
            session("retry", updated: milliseconds(startOfToday.addingTimeInterval(-3 * 86_400))),
        ]
        let sections = SessionListOrganization.timeline(
            from: sessions,
            statuses: ["stale-busy": status(.busy), "retry": status(.retry)],
            now: referenceNow,
            calendar: calendar
        )

        #expect(sections.map(\.title) == [AppText.sessionsToday, AppText.sessionsPreviousWeek, AppText.sessionsOlder])
        #expect(sections.allSatisfy { !$0.isWorking })
        #expect(sections.flatMap(\.sessions).map(\.id) == ["today", "retry", "stale-busy"])
    }

    @Test func timelineBucketsIdleChatsByCalendarDayRelativeToNow() {
        let calendar = utcCalendar
        let startOfToday = calendar.startOfDay(for: referenceNow)
        let sessions = [
            session("unknown", updated: 0),
            session("older", updated: milliseconds(startOfToday.addingTimeInterval(-31 * 86_400))),
            session("month", updated: milliseconds(startOfToday.addingTimeInterval(-10 * 86_400))),
            session("week", updated: milliseconds(startOfToday.addingTimeInterval(-2 * 86_400))),
            session("yesterday", updated: milliseconds(startOfToday.addingTimeInterval(-60))),
            session("today", updated: milliseconds(startOfToday.addingTimeInterval(60))),
            session("future", updated: milliseconds(referenceNow.addingTimeInterval(3_600))),
        ]
        let sections = SessionListOrganization.timeline(
            from: sessions, statuses: [:], now: referenceNow, calendar: calendar
        )

        #expect(sections.map(\.title) == [
            AppText.sessionsToday, AppText.sessionsYesterday, AppText.sessionsPreviousWeek,
            AppText.sessionsPreviousMonth, AppText.sessionsOlder,
        ])
        #expect(sections.map { $0.sessions.map(\.id) } == [
            ["future", "today"], ["yesterday"], ["week"], ["month"], ["older", "unknown"],
        ])
        #expect(sections.allSatisfy { !$0.isWorking })
    }

    @Test func timelineOrdersChatsNewestFirstWithDeterministicTies() {
        let calendar = utcCalendar
        let startOfToday = calendar.startOfDay(for: referenceNow)
        let sections = SessionListOrganization.timeline(
            from: [
                session("b", updated: milliseconds(startOfToday.addingTimeInterval(120))),
                session("a", updated: milliseconds(startOfToday.addingTimeInterval(120))),
                session("newest", updated: milliseconds(startOfToday.addingTimeInterval(600))),
            ],
            statuses: [:], now: referenceNow, calendar: calendar
        )

        #expect(sections.count == 1)
        #expect(sections[0].sessions.map(\.id) == ["newest", "a", "b"])
    }

    @Test func timelineHasNoSectionsWithoutChats() {
        #expect(SessionListOrganization.timeline(from: [], statuses: [:]).isEmpty)
    }

    @Test func repositoryTitlePrefersFolderNameThenProjectThenFallback() {
        let projectOnly = OCSession(
            id: "project", projectID: " beta ", title: "Project",
            time: OCSessionTime(created: 0, updated: 100)
        )

        #expect(SessionListOrganization.repositoryTitle(for: session("a", directory: "/repos/Alpha/", updated: 100)) == "Alpha")
        #expect(SessionListOrganization.repositoryTitle(for: projectOnly) == "beta")
        #expect(SessionListOrganization.repositoryTitle(for: session("unknown", directory: nil, updated: 100)) == AppText.projectFallback)
    }
}
