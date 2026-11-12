import Foundation
import Testing
@testable import OpenLens

struct SessionsServiceTests {
    @Test func v1SessionStillDecodesItsTopLevelDirectory() throws {
        let session = try JSONDecoder().decode(
            OCSession.self,
            from: Data(#"{"id":"ses_legacy","projectID":"legacy","directory":"/workspace/Legacy","title":"Legacy","time":{"created":0,"updated":1}}"#.utf8)
        )

        #expect(session.directory == "/workspace/Legacy")
        #expect(session.projectID == "legacy")
    }

    @MainActor
    @Test func openingLocatedSessionsSwitchesContextInBothDirections() async throws {
        let sessions = try JSONDecoder().decode([OCSession].self, from: Data(#"[{"id":"ses_alpha","title":"Alpha","location":{"directory":"/workspace/Alpha"}},{"id":"ses_beta","title":"Beta","location":{"directory":"/workspace/Beta"}}]"#.utf8))
        let connection = ConnectionManager()
        let store = SavedConnectionsStore(initialConnections: [])
        let chat = ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection),
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: store,
            recordedReplayStore: RecordedReplayStore()
        )

        for session in [sessions[0], sessions[1], sessions[0]] {
            await chat.loadSession(session)
            #expect(connection.selectedProjectDirectory == session.directory)
            #expect(chat.currentSession?.id == session.id)
        }

        await connection.setProjectContext(directory: "/workspace/Beta")
        await chat.restoreProjectContext(for: sessions[0])
        #expect(connection.selectedProjectDirectory == "/workspace/Alpha")
        #expect(chat.currentSession?.id == "ses_alpha")
    }

    @Test func sessionsResolveTheirProjectDirectoryWhenV2ProvidesOnlyProjectID() {
        let sessions = [
            OCSession(
                id: "ses_123",
                projectID: "proj_openlens",
                title: "",
                time: OCSessionTime(created: 0, updated: 0)
            )
        ]
        let projects = [
            OCProject(id: "proj_openlens", worktree: "/workspace/OpenLens")
        ]

        let resolved = SessionsService.applyingProjectDirectories(sessions, projects: projects)

        #expect(resolved[0].directory == "/workspace/OpenLens")
        #expect(resolved[0].workspaceDisplayName == "OpenLens")
    }

    @Test func sessionsKeepTheirOwnDirectoryWhenItIsAlreadyProvided() {
        let sessions = [
            OCSession(
                id: "ses_123",
                projectID: "proj_openlens",
                directory: "/workspace/FeatureBranch",
                title: "",
                time: OCSessionTime(created: 0, updated: 0)
            )
        ]
        let projects = [
            OCProject(id: "proj_openlens", worktree: "/workspace/OpenLens")
        ]

        let resolved = SessionsService.applyingProjectDirectories(sessions, projects: projects)

        #expect(resolved[0].directory == "/workspace/FeatureBranch")
        #expect(resolved[0].workspaceDisplayName == "FeatureBranch")
    }

    @MainActor
    @Test func childSubagentsAreTrackedLinkedToParentsAndBatchCancelled() async throws {
        let sessionPage = Data(#"""
        {
          "data": [
            {"id":"ses_parent","title":"Parent work","location":{"directory":"/workspace/App"},"time":{"created":1000,"updated":3000,"idle":3000},"outcome":"succeeded"},
            {"id":"ses_child_1","parentID":"ses_parent","agent":"general","title":"Fix ledger","location":{"directory":"/workspace/App"},"time":{"created":2000,"updated":3100,"busy":2000}},
            {"id":"ses_child_2","parentID":"ses_parent","agent":"explore","title":"Audit routes","location":{"directory":"/workspace/App"},"time":{"created":2100,"updated":3200,"busy":2100}}
          ],
          "cursor": {"previous": null, "next": null}
        }
        """#.utf8)
        let activeJSON = Data(#"""
        {
          "data": {
            "ses_child_1": {"type": "running"},
            "ses_child_2": {"type": "running"}
          }
        }
        """#.utf8)
        let interruptJSON = Data(#"{"interrupted":true}"#.utf8)
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
            "/api/project": .init(statusCode: 200, body: Data(#"{"data":[{"id":"proj_1","directory":"/workspace/App"}]}"#.utf8)),
            "/api/session": .init(statusCode: 200, body: sessionPage),
            "/api/session/active": .init(statusCode: 200, body: activeJSON),
            "/api/session/ses_child_1/interrupt": .init(statusCode: 200, body: interruptJSON),
            "/api/session/ses_child_2/interrupt": .init(statusCode: 200, body: interruptJSON),
            "/api/session/ses_child_1": .init(statusCode: 200, body: Data(#"{"data":{"id":"ses_child_1","parentID":"ses_parent","title":"Fix ledger","location":{"directory":"/workspace/App"},"time":{"created":2000,"updated":4000,"idle":4000},"outcome":"interrupted"}}"#.utf8)),
            "/api/session/ses_child_2": .init(statusCode: 200, body: Data(#"{"data":{"id":"ses_child_2","parentID":"ses_parent","title":"Audit routes","location":{"directory":"/workspace/App"},"time":{"created":2100,"updated":4000,"idle":4000},"outcome":"interrupted"}}"#.utf8)),
        ])
        let client = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            contextDirectory: "/workspace/App",
            transport: transport
        )
        let capabilities = try await client.probeCapabilities()
        let connection = ConnectionManager(testClient: client, capabilities: capabilities)
        let service = SessionsService(connection: connection)

        let roots = try await service.listAllSessions()
        _ = try await service.getSessionStatuses()

        // Root catalog stays clean while child subagent sessions are indexed and linked to their parent.
        #expect(roots.map(\.id) == ["ses_parent"])
        #expect(service.cachedSessions.map(\.id) == ["ses_parent"])
        #expect(service.childSessions(forParentID: "ses_parent").map(\.id) == ["ses_child_2", "ses_child_1"])
        #expect(service.activeChildCountsByParentID()["ses_parent"] == 2)
        #expect(service.activeSubagentSessions().count == 2)

        let resolvedChild = try await service.resolveSessionForOpening(id: "ses_child_1")
        #expect(resolvedChild.title == "Fix ledger")
        #expect(resolvedChild.parentID == "ses_parent")

        let outcome = await service.abortAllActiveSessions(forParentID: "ses_parent")
        #expect(outcome.stopped == 2)
        #expect(outcome.failed == 0)
        #expect(service.activeChildCountsByParentID()["ses_parent"] == nil)

        let paths = Set(await transport.recordedPaths())
        #expect(paths.contains("/api/session/ses_child_1/interrupt"))
        #expect(paths.contains("/api/session/ses_child_2/interrupt"))
    }
}
