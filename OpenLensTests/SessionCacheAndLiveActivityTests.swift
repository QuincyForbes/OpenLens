import Foundation
import Testing
@testable import OpenLens

@MainActor
struct SessionCacheAndLiveActivityTests {

    @Test func diskCachePersistsAndReloadsCatalogAndTranscriptsAcrossColdLaunches() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLensCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scope = "http://opencode.local:4096"
        let rootSession = OCSession(
            id: "ses_root_1",
            projectID: "proj_1",
            directory: "/workspace/OpenLens",
            title: "Cache architecture review",
            time: OCSessionTime(created: 1_000, updated: 5_000, idle: 4_800, viewed: 4_800),
            outcome: "succeeded"
        )
        let childSession = OCSession(
            id: "ses_child_1",
            projectID: "proj_1",
            directory: "/workspace/OpenLens",
            parentID: "ses_root_1",
            title: "Explore views",
            time: OCSessionTime(created: 2_000, updated: 4_500),
            agent: "explore"
        )
        let project = OCProject(id: "proj_1", worktree: "/workspace/OpenLens")

        do {
            let writer = SessionCacheStore(storageDirectory: tempDir, maximumInMemorySessions: 4)
            writer.saveCatalog(
                serverScope: scope,
                rootSessions: [rootSession],
                childSessions: [childSession],
                projects: [project],
                viewedMarkers: ["ses_root_1": 4_800]
            )
            let userMsg = ChatMessage(id: "msg_u1", role: .user, content: "Make chat switching instant")
            let assistantMsg = ChatMessage(
                id: "msg_a1",
                role: .assistant,
                content: "Added two-tier LRU and disk caching.",
                finish: "stop",
                parentUserMessageID: "msg_u1"
            )
            writer.saveTranscript(
                serverScope: scope,
                session: rootSession,
                messages: [userMsg, assistantMsg],
                contextEntries: [],
                entryOrder: ["msg_u1", "msg_a1"],
                olderCursor: "cursor_prev_1",
                todos: [OCTodo(id: "t1", content: "Verify tests", status: "completed", priority: "high")],
                hiddenTodoCount: 0
            )
            await writer.flushPendingWrites()
        }

        // Fresh cold-start store reads persisted catalog and transcript from disk.
        let reader = SessionCacheStore(storageDirectory: tempDir, maximumInMemorySessions: 4)
        let loadedCatalog = try #require(reader.loadCatalog(serverScope: scope))
        #expect(loadedCatalog.rootSessions.map(\.id) == ["ses_root_1"])
        #expect(loadedCatalog.childSessions.map(\.id) == ["ses_child_1"])
        #expect(loadedCatalog.projects.map(\.id) == ["proj_1"])
        #expect(loadedCatalog.viewedMarkers["ses_root_1"] == 4_800)

        let loadedTranscript = try #require(reader.transcript(serverScope: scope, sessionID: "ses_root_1"))
        #expect(loadedTranscript.messages.map(\.id) == ["msg_u1", "msg_a1"])
        #expect(loadedTranscript.messages.last?.content == "Added two-tier LRU and disk caching.")
        #expect(loadedTranscript.olderCursor == "cursor_prev_1")
        #expect(loadedTranscript.todos.map(\.content) == ["Verify tests"])
    }

    @Test func crossSessionLiveActivityTracksToolsStepsElapsedDatesAndExcludesCurrentSubagentsFromOtherCount() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let api = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let service = SessionsService(connection: connection)

        let parent = OCSession(
            id: "ses_parent",
            directory: "/workspace/OpenLens",
            title: "Main feature",
            time: OCSessionTime(created: 1_700_000_000_000, updated: 1_700_086_400_000)
        )
        let child = OCSession(
            id: "ses_child",
            directory: "/workspace/OpenLens",
            parentID: "ses_parent",
            title: "Audit sidebar",
            time: OCSessionTime(created: 1_700_086_400_000, updated: 1_700_086_405_000, busy: 1_700_086_401_000),
            agent: "explore"
        )
        let otherRepoSession = OCSession(
            id: "ses_other",
            directory: "/workspace/dayzero-monolith",
            title: "Sign-in page loading performance",
            time: OCSessionTime(created: 1_690_000_000_000, updated: 1_700_086_410_000)
        )

        // Root session created long ago without `time.busy` must NOT report its creation date as active start.
        #expect(ElapsedDurationFormatter.activeStartDate(for: otherRepoSession) == nil)
        // Subagent with `time.busy` reports exact busy timestamp.
        #expect(ElapsedDurationFormatter.activeStartDate(for: child) == Date(timeIntervalSince1970: 1_700_086_401))

        service.setClientObservedActive(true, for: parent.id, sessionSnapshot: parent)
        service.promoteToBackgroundRunning(sessionID: child.id, sessionSnapshot: child)
        service.handleGlobalSessionActivity(.busy(sessionID: otherRepoSession.id, isRetry: false))
        service.handleGlobalSessionActivity(
            .progress(
                sessionID: otherRepoSession.id,
                phase: .tool(name: "shell", label: "Shell pnpm test"),
                incrementsStep: true
            )
        )

        let live = try #require(service.liveActivity(for: otherRepoSession.id))
        #expect(live.statusLabel == "Shell pnpm test")
        #expect(live.stepCount == 1)
        #expect(live.iconName == "terminal")
        #expect(service.activeStartDate(for: otherRepoSession) != nil)

        // Viewing `ses_parent` excludes both `ses_parent` AND its own child subagent `ses_child`
        // from `activeSessionCount(excluding: "ses_parent")`, leaving only `ses_other` (1).
        #expect(service.activeSessionCount(excluding: parent.id) == 1)

        // Ending `ses_other` clears both its status and its live activity entry.
        service.handleGlobalSessionActivity(.ended(sessionID: otherRepoSession.id))
        #expect(service.liveActivity(for: otherRepoSession.id) == nil)
        #expect(service.effectiveStatuses[otherRepoSession.id] == nil)
    }

    @Test func openingARunningSessionRestoresWorkingStateAndLiveToolLabelImmediately() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let api = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let cache = SessionCacheStore()
        let sessions = SessionsService(connection: connection, cacheStore: cache)
        let chat = ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: sessions,
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
            recordedReplayStore: RecordedReplayStore(),
            sessionCacheStore: cache
        )

        let runningSession = OCSession(
            id: "ses_running",
            directory: "/workspace/OpenLens",
            title: "Refactor sidebar",
            time: OCSessionTime(created: 1_000, updated: 2_000)
        )
        sessions.handleGlobalSessionActivity(.busy(sessionID: runningSession.id, isRetry: false))
        sessions.handleGlobalSessionActivity(
            .progress(
                sessionID: runningSession.id,
                phase: .tool(name: "edit", label: "Edit ConnectedRootView.swift"),
                incrementsStep: true
            )
        )

        chat.prepareForOpeningSession(runningSession)

        #expect(chat.isLoading)
        #expect(chat.responseState == .generating)
        #expect(chat.currentActivity?.currentLabel == "Edit ConnectedRootView.swift")
    }

    @Test func incrementalV2CatalogRefreshStopsAtFirstUnchangedPage() async throws {
        let page1 = Data(#"""
        {
          "data": [
            {"id":"ses_new","title":"Brand new chat","location":{"directory":"/workspace/App"},"time":{"created":5000,"updated":6000}},
            {"id":"ses_existing_top","title":"Existing top","location":{"directory":"/workspace/App"},"time":{"created":3000,"updated":4000}}
          ],
          "cursor": {"previous": null, "next": "page_2_cursor"}
        }
        """#.utf8)
        let page2 = Data(#"""
        {
          "data": [
            {"id":"ses_ancient","title":"Ancient chat","location":{"directory":"/workspace/App"},"time":{"created":1000,"updated":2000}}
          ],
          "cursor": {"previous": null, "next": null}
        }
        """#.utf8)

        let transport = IncrementalCatalogTestTransport(page1: page1, page2: page2)
        let api = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let service = SessionsService(connection: connection)

        // Initial cold load reads all pages (2 requests).
        let initial = try await service.listAllSessions(incremental: false)
        #expect(initial.map(\.id) == ["ses_new", "ses_existing_top", "ses_ancient"])
        #expect(await transport.sessionPageRequests == 2)

        await transport.resetCounter()

        // Subsequent incremental sync sees `ses_existing_top` unchanged on page 1 and stops after 1 request!
        let refreshed = try await service.listAllSessions(incremental: true)
        #expect(refreshed.map(\.id) == ["ses_new", "ses_existing_top", "ses_ancient"])
        let pageCountAfterIncremental = await transport.sessionPageRequests
        #expect(pageCountAfterIncremental == 1)
    }

    @Test func diskCachePersistsContextEntriesTurnDiffsDisplayLimitAndWatermark() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLensLosslessCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scope = "conn:saved-mac-id"
        let session = OCSession(
            id: "ses_ctx",
            directory: "/workspace/OpenLens",
            title: "Delta architecture",
            time: OCSessionTime(created: 1_000, updated: 9_500)
        )
        let contextEntry = SessionContextEntry(
            id: "ctx_model_1",
            kind: .model,
            created: 4_000,
            title: "Model changed",
            summary: "anthropic/claude-sonnet-4",
            details: "Previously: openai/gpt-5",
            resultPreview: "",
            subagentResult: nil,
            compactionStatus: nil,
            idleOutcome: nil
        )
        let diffs = [
            TurnFileChangeSummary(path: "OpenLens/Services/ChatClient.swift", status: "modified", additions: 42, deletions: 11),
        ]

        do {
            let writer = SessionCacheStore(storageDirectory: tempDir, maximumInMemorySessions: 4)
            let userMsg = ChatMessage(id: "m1", role: .user, content: "Update cache", hasAuthoritativeServerID: true)
            let assistantMsg = ChatMessage(
                id: "m2",
                role: .assistant,
                content: "Done.",
                finish: "stop",
                parentUserMessageID: "m1",
                turnFileChanges: diffs,
                hasAuthoritativeServerID: true
            )
            writer.saveTranscript(
                serverScope: scope,
                session: session,
                messages: [userMsg, assistantMsg],
                contextEntries: [contextEntry],
                entryOrder: ["m1", "ctx_model_1", "m2"],
                olderCursor: nil,
                todos: [],
                hiddenTodoCount: 0,
                turnDiffSummaries: ["m2": diffs],
                displayLimit: 30,
                syncedUpdatedAt: 9_500,
                isAuthoritative: true
            )
            await writer.flushPendingWrites()
        }

        let reader = SessionCacheStore(storageDirectory: tempDir, maximumInMemorySessions: 4)
        let restored = try #require(reader.transcript(serverScope: scope, sessionID: "ses_ctx"))
        #expect(restored.contextEntries.map(\.id) == ["ctx_model_1"])
        #expect(restored.contextEntries.first?.summary == "anthropic/claude-sonnet-4")
        #expect(restored.turnDiffSummariesByMessageID["m2"] == diffs)
        #expect(restored.messages.last?.turnFileChanges == diffs)
        #expect(restored.displayLimit == 30)
        #expect(restored.syncedUpdatedAt == 9_500)
        #expect(restored.isAuthoritative)
    }

    @Test func authoritativeWatermarkSkipsMessageStackAndDeltaSyncFetchesOnlyNewTail() async throws {
        let transport = DeltaTranscriptTestTransport()
        let api = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let cache = SessionCacheStore()
        let sessions = SessionsService(connection: connection, cacheStore: cache)
        let chat = ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: sessions,
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
            recordedReplayStore: RecordedReplayStore(),
            sessionCacheStore: cache
        )

        let sessionV1 = OCSession(
            id: "ses_delta",
            directory: "/workspace/App",
            title: "Delta test",
            time: OCSessionTime(created: 1_000, updated: 5_000)
        )
        let sessionB = OCSession(
            id: "ses_other",
            directory: "/workspace/App",
            title: "Other chat",
            time: OCSessionTime(created: 1_000, updated: 2_000)
        )

        // 1. Cold open loads initial 8 messages and records watermark updated=5000.
        chat.prepareForOpeningSession(sessionV1)
        await chat.loadSession(sessionV1)
        #expect(chat.messages.count == 8)
        let initialFirstMessage = try #require(chat.messages.first)
        let initialRequests = await transport.messageRequestLimits
        #expect(initialRequests == [16])

        // 2. Switch to another chat, then re-enter `ses_delta` while `updated` is still 5000:
        //    0 message requests should be made!
        await transport.resetMessageRequests()
        chat.prepareForOpeningSession(sessionB)
        chat.prepareForOpeningSession(sessionV1)
        #expect(chat.isStreamSynchronized)
        await chat.loadSession(sessionV1)
        let unchangedRequests = await transport.messageRequestLimits
        #expect(unchangedRequests.isEmpty)
        #expect(chat.messages.count == 8)

        // 3. Now 1 new message arrives on the server (`updated` advances to 6000):
        //    re-entering fetches ONLY the small delta tail (`limit=6`) and preserves earlier objects!
        await transport.appendNewTurn()
        let sessionV2 = OCSession(
            id: "ses_delta",
            directory: "/workspace/App",
            title: "Delta test",
            time: OCSessionTime(created: 1_000, updated: 6_000)
        )
        chat.prepareForOpeningSession(sessionB)
        chat.prepareForOpeningSession(sessionV2)
        await chat.loadSession(sessionV2)

        let deltaRequests = await transport.messageRequestLimits
        #expect(deltaRequests == [6])
        #expect(chat.messages.count == 9)
        #expect(chat.messages.last?.id == "msg_09")
        #expect(chat.messages.first === initialFirstMessage)
        #expect(!chat.hasEarlierMessages)
    }

    @Test func runningSubagentWithoutMetadataAndMultiStepTurnsNeverDuplicateAgents() async throws {
        let transport = OpenCodeContractTransport(routes: [
            "/api/info": .init(statusCode: 200, body: OpenCodeContractFixtures.v2InfoResponse),
        ])
        let api = OpenCodeClient(
            baseURL: try #require(URL(string: "http://opencode.example.com")),
            transport: transport
        )
        let capabilities = try await api.probeCapabilities()
        let connection = ConnectionManager(testClient: api, capabilities: capabilities)
        let sessions = SessionsService(connection: connection)
        let chat = ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: sessions,
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
            recordedReplayStore: RecordedReplayStore()
        )

        let nowMs = Date().timeIntervalSince1970 * 1_000
        let parent = OCSession(
            id: "ses_parent_dedup",
            directory: "/workspace/App",
            title: "Parent",
            time: OCSessionTime(created: nowMs - 5_000, updated: nowMs)
        )
        let child = OCSession(
            id: "ses_child_dedup",
            directory: "/workspace/App",
            parentID: parent.id,
            title: "Explore codebase",
            time: OCSessionTime(created: nowMs - 1_000, updated: nowMs, busy: nowMs - 1_000),
            agent: "explore"
        )
        sessions.promoteToBackgroundRunning(sessionID: child.id, sessionSnapshot: child)

        chat.currentSession = parent
        chat.isLoading = true
        chat.responseState = .generating

        let runningSubagentPart = OCPart(
            id: "call_sub_1",
            sessionID: parent.id,
            messageID: "msg_step_1",
            type: .tool,
            callID: "call_sub_1",
            tool: "subagent",
            state: OCToolState(
                status: .running,
                input: ["agent": AnyCodable("explore"), "description": AnyCodable("Explore codebase")]
            )
        )
        let step1 = ChatMessage(
            id: "msg_step_1",
            role: .assistant,
            content: "",
            parts: [runningSubagentPart],
            isStreaming: true,
            createdAt: Date(),
            hasAuthoritativeServerID: true
        )
        chat.messages = [step1]
        chat.pendingAssistantMessage = step1

        // Running subagent tool call (without metadata.sessionId yet) correlates with `ses_child_dedup`
        // instead of producing duplicate `call_sub_1` + `ses_child_dedup` items!
        let subagents = chat.currentSessionSubagents()
        #expect(subagents.count == 1)
        #expect(subagents.first?.childSessionID == child.id)

        // When Step 2 arrives on SSE with a new authoritative assistant message ID (`msg_step_2`),
        // `msg_step_1` stays intact as Step 1 and `msg_step_2` opens cleanly without duplicating `msg_step_1`.
        let handler = SSEEventHandler(
            haptics: HapticController(),
            liveActivityTracker: LiveActivityTracker(liveActivity: TestLiveActivityProvider())
        )
        handler.delegate = chat
        handler.handleEvent(
            OCEvent(
                type: "message.updated",
                properties: AnyCodable([
                    "info": [
                        "id": "msg_step_2",
                        "sessionID": parent.id,
                        "role": "assistant",
                    ]
                ])
            )
        )

        #expect(chat.messages.map(\.id) == ["msg_step_1"])
        #expect(chat.pendingAssistantMessage?.id == "msg_step_2")
        #expect(chat.displayedMessages.map(\.id) == ["msg_step_1", "msg_step_2"])
    }
}

private actor IncrementalCatalogTestTransport: OpenCodeTransport {
    let page1: Data
    let page2: Data
    var sessionPageRequests = 0

    init(page1: Data, page2: Data) {
        self.page1 = page1
        self.page2 = page2
    }

    func resetCounter() {
        sessionPageRequests = 0
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let cursor = components?.queryItems?.first(where: { $0.name == "cursor" })?.value
        let body: Data
        switch url.path {
        case "/api/info":
            body = OpenCodeContractFixtures.v2InfoResponse
        case "/api/project":
            body = Data(#"{"data":[{"id":"proj_1","directory":"/workspace/App"}]}"#.utf8)
        case "/api/session":
            sessionPageRequests += 1
            body = (cursor == "page_2_cursor") ? page2 : page1
        default:
            throw URLError(.unsupportedURL)
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        NoopIncrementalStream()
    }
}

private final class NoopIncrementalStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}

private actor DeltaTranscriptTestTransport: OpenCodeTransport {
    private var updatedAt: Int = 5_000
    private var messageIDs: [String] = (1...8).map { String(format: "msg_%02d", $0) }
    private(set) var messageRequestLimits: [Int] = []

    func resetMessageRequests() {
        messageRequestLimits.removeAll()
    }

    func appendNewTurn() {
        updatedAt = 6_000
        messageIDs.append("msg_09")
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let limit = components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 16
        let body: Data

        let loc = #"{"directory":"/workspace/App","project":{"id":"proj_1","directory":"/workspace/App"}}"#
        switch url.path {
        case "/api/info":
            body = OpenCodeContractFixtures.v2InfoResponse
        case "/api/location":
            body = Data(loc.utf8)
        case "/api/vcs":
            body = Data(#"{"location":\#(loc),"data":{"branch":"main"}}"#.utf8)
        case "/api/model":
            body = Data(#"{"location":\#(loc),"data":[{"id":"claude-sonnet-4","providerID":"anthropic","modelID":"claude-sonnet-4","name":"Claude Sonnet 4"}]}"#.utf8)
        case "/api/model/default":
            body = Data(#"{"location":\#(loc),"data":{"id":"claude-sonnet-4","providerID":"anthropic","modelID":"claude-sonnet-4","name":"Claude Sonnet 4"}}"#.utf8)
        case "/api/provider":
            body = Data(#"{"location":\#(loc),"data":[]}"#.utf8)
        case "/api/session/ses_delta":
            body = Data(#"{"data":{"id":"ses_delta","title":"Delta test","location":{"directory":"/workspace/App"},"time":{"created":1000,"updated":\#(updatedAt)}}}"#.utf8)
        case "/api/session/active":
            body = Data(#"{"data":{}}"#.utf8)
        case "/api/session/ses_delta/inbox",
             "/api/session/ses_delta/permission",
             "/api/session/ses_delta/form":
            body = Data(#"{"data":[]}"#.utf8)
        case "/api/session/ses_delta/message":
            messageRequestLimits.append(limit)
            let descending = Array(messageIDs.reversed())
            let slice = Array(descending.prefix(limit))
            let hasOlder = descending.count > slice.count
            let items = slice.enumerated().map { idx, id -> String in
                let created = (descending.count - idx) * 100
                return #"{"id":"\#(id)","type":"user","time":{"created":\#(created)},"text":"Message \#(id)"}"#
            }.joined(separator: ",")
            let nextJSON = hasOlder ? #""older_cursor""# : "null"
            body = Data("{\"data\":[\(items)],\"cursor\":{\"next\":\(nextJSON)}}".utf8)
        default:
            throw URLError(.unsupportedURL)
        }

        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        NoopIncrementalStream()
    }
}
