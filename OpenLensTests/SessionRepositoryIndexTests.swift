import Foundation
import Testing
@testable import OpenLens

@MainActor
struct SessionRepositoryIndexTests {
    private func session(_ id: String, project: String? = nil, directory: String? = nil, updated: Double = 100) -> OCSession {
        OCSession(id: id, projectID: project, directory: directory, title: id, time: .init(created: 0, updated: updated))
    }

    @Test func worktreesAndSubfoldersJoinTheirCanonicalRepository() {
        let sessions = [
            session("main", project: "repo", directory: "/work/App"),
            session("feature", project: "repo", directory: "/work/App-feature", updated: 300),
            session("nested", directory: "/work/App/Sources", updated: 200),
            session("unlocated", project: "repo"),
        ]
        let index = SessionRepositoryIndex(sessions: sessions, projects: [.init(id: "repo", worktree: "/work/App")])
        let groups = SessionListOrganization.groups(from: sessions, statuses: [:], sortOrder: .updated, repositoryIndex: index)
        #expect(groups.count == 1)
        #expect(groups[0].title == "App")
        #expect(groups[0].subtitle == "/work/App")
        #expect(groups[0].sessions.map(\.id) == ["feature", "nested", "main", "unlocated"])
    }

    @Test func unrelatedSameNamedFoldersAndNestedRepositoriesStaySeparate() {
        let sessions = [
            session("a", directory: "/work/App/Sources"),
            session("b", directory: "/other/App"),
            session("nested", directory: "/work/App/vendor/Nested/src"),
            session("prefix", directory: "/work/Application"),
        ]
        let index = SessionRepositoryIndex(sessions: sessions, projects: [
            .init(id: "a", worktree: "/work/App"),
            .init(id: "b", worktree: "/other/App"),
            .init(id: "nested", worktree: "/work/App/vendor/Nested"),
        ])
        #expect(index.repository(for: sessions[0]).id == "projectID:a")
        #expect(index.repository(for: sessions[1]).id == "projectID:b")
        #expect(index.repository(for: sessions[2]).id == "projectID:nested")
        #expect(index.repository(for: sessions[3]).id == "directory:/work/Application")
    }

    @Test func windowsAliasesCollapseButPOSIXCaseIsPreserved() {
        let sessions = [
            session("a", directory: #"C:\Work\App\src\..\"#),
            session("b", directory: " /c:/work/app/./ "),
            session("unc1", directory: #"\\Server\Share\App"#),
            session("unc2", directory: "//server/share/app/"),
            session("upper", directory: "/work/App"),
            session("lower", directory: "/work/app"),
        ]
        let index = SessionRepositoryIndex(sessions: sessions)
        #expect(index.repository(for: sessions[0]).id == index.repository(for: sessions[1]).id)
        #expect(index.repository(for: sessions[2]).id == index.repository(for: sessions[3]).id)
        #expect(index.repository(for: sessions[4]).id != index.repository(for: sessions[5]).id)
        #expect(SessionListOrganization.groups(from: sessions, statuses: [:], sortOrder: .updated, repositoryIndex: index).count == 4)
    }

    @Test func globalProjectDoesNotCombineUnrelatedNonGitFolders() {
        let sessions = [session("a", project: "global", directory: "/work/Notes"), session("b", project: "global", directory: "/work/Scripts")]
        let index = SessionRepositoryIndex(sessions: sessions, projects: [.init(id: "global", worktree: "/")])
        #expect(index.repository(for: sessions[0]).id != index.repository(for: sessions[1]).id)
    }

    @Test func missingProjectIDJoinsOnlyUnambiguousKnownPaths() {
        let sessions = [
            session("known", project: "repo", directory: "/work/App"),
            session("legacy", directory: "/work/App/"),
            session("conflict-a", project: "one", directory: "/ambiguous"),
            session("conflict-b", project: "two", directory: "/ambiguous"),
            session("unidentified", directory: "/ambiguous"),
        ]
        let index = SessionRepositoryIndex(sessions: sessions)
        #expect(index.repository(for: sessions[1]).id == "projectID:repo")
        #expect(index.repository(for: sessions[4]).id == "directory:/ambiguous")
    }

    @Test func serverProjectAliasesForTheSameRootDoNotDuplicateRepositorySections() {
        let sessions = [session("a", project: "old", directory: "C:/Work/App"), session("b", project: "new", directory: "C:/Work/App-feature")]
        let index = SessionRepositoryIndex(sessions: sessions, projects: [
            .init(id: "old", worktree: "C:/Work/App"), .init(id: "new", worktree: #"c:\work\app\"#),
        ])
        #expect(index.repository(for: sessions[0]).id == index.repository(for: sessions[1]).id)
    }

    @Test func duplicateSessionIDsKeepNewestSnapshotAndCanMoveRepositories() {
        let sessions = [
            session("same", project: "old", directory: "/old", updated: 10),
            session("other", directory: "/other", updated: 20),
            session("same", project: "new", directory: "/new", updated: 30),
        ]
        let groups = SessionListOrganization.groups(from: sessions, statuses: [:], sortOrder: .updated)
        #expect(groups.count == 2)
        #expect(groups[0].id == "projectID:new")
        #expect(groups.flatMap(\.sessions).map(\.id) == ["same", "other"])
        #expect(SessionListOrganization.timeline(from: sessions, statuses: [:]).flatMap(\.sessions).count == 2)
    }

    @Test func focusOrdersAttentionFailuresPinsUnreadAndRunningWithoutDuplicates() {
        func completed(_ id: String, outcome: String) -> OCSession {
            OCSession(id: id, title: id, time: .init(created: 0, updated: 20, idle: 20), outcome: outcome)
        }
        let sessions = [session("recent", updated: 1000), session("running"), completed("done", outcome: "succeeded"),
                        session("pinned"), completed("failed", outcome: "failed"), session("waiting", updated: 1)]
        let sections = SessionListOrganization.focus(
            from: sessions, statuses: ["running": .init(type: .busy, attempt: nil, message: nil, next: nil)],
            attentionIDs: ["waiting"], pinnedIDs: ["pinned", "waiting"]
        )
        #expect(sections.flatMap(\.sessions).map(\.id) == ["waiting", "failed", "pinned", "done", "running", "recent"])
        #expect(sections.map(\.title) == ["Needs You", "Unseen failures", "Pinned", "Unread results", "Working now", "Recent"])
    }
}
