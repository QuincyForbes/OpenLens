import Foundation
import SwiftUI
import Testing
import UIKit
@testable import OpenLens

@MainActor
@Suite(.serialized)
struct V2SessionViewedTests {
    @Test func canonicalViewedMarkerSurvivesDecodingAndSessionCopies() throws {
        let session = try JSONDecoder().decode(OCSession.self, from: Data(#"{"id":"ses_1","outcome":"failed","time":{"created":1000,"updated":2100,"idle":2000,"viewed":1900}}"#.utf8))
        for copy in [session, session.withSelection(agent: "build", model: nil), session.withoutExecutionOutcome()] {
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
            #expect((json["time"] as? [String: Any])?["viewed"] as? Double == 1900)
        }
    }

    @Test func viewingAcknowledgesOnlyTheObservedCompletionThroughTheV2Transport() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        #expect(observed.hasUnreadResult)
        let recovered = try await service.viewResult(observed)
        #expect(!recovered.hasUnreadResult)
        #expect(recovered.time.viewed == 2000)
        let request = try #require(await server.viewRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/session/ses_1/view")
        #expect(request.url?.query == nil)
        let requestBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Double])
        #expect(payload == ["idle": 2000])
        #expect(try await service.listSessions().first?.hasUnreadResult == false)
    }

    @Test func aNewerCompletionDuringAcknowledgementRemainsUnread() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.completeDuringView()
        let recovered = try await service.viewResult(observed)
        #expect(recovered.time.idle == 3000)
        #expect(recovered.time.viewed == 2000)
        #expect(recovered.hasUnreadResult)
        #expect(try await service.listSessions().first?.hasUnreadResult == true)
    }

    @Test(arguments: [true, false])
    func aLostResponseUsesCanonicalEvidenceInsteadOfGuessing(committed: Bool) async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.loseResponse(committed: committed)
        if committed {
            let recovered = try await service.viewResult(observed)
            #expect(!recovered.hasUnreadResult)
            #expect(recovered.time.viewed == 2000)
        } else {
            await #expect(throws: (any Error).self) { try await service.viewResult(observed) }
            #expect(try await service.getSession(id: "ses_1").hasUnreadResult)
            await server.allowView()
            #expect(try await service.viewResult(observed).hasUnreadResult == false)
        }
    }

    @Test func aSuccessfulResponseWithoutTheCanonicalMarkerIsNotConfirmation() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        await server.ignoreView()
        await #expect(throws: (any Error).self) { try await service.viewResult(observed) }
        #expect(try await service.getSession(id: "ses_1").hasUnreadResult)
    }

    @Test func aDesktopViewAndLaterCompletionSurviveListAndForegroundRefresh() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let listed = try await service.listSessions()
        await server.desktopViewed(2000)
        let read = await service.refreshSessionOutcomes(in: listed, previousStatuses: [:], refreshInactive: true)
        #expect(read.sessions.first?.hasUnreadResult == false)
        await server.complete(3000)
        let unread = await service.refreshSessionOutcomes(in: read.sessions, previousStatuses: [:], refreshInactive: true)
        #expect(unread.sessions.first?.hasUnreadResult == true)
        #expect(unread.sessions.first?.time.viewed == 2000)
        #expect(await server.viewRequests.isEmpty)
    }

    @Test func confirmedViewingImmediatelyUpdatesMatchingSidebarRowsAndSurvivesAnOlderPoll() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let row = try await service.getSession(id: "ses_1")
        let other = OCSession(id: "ses_other", title: "Other", time: row.time, outcome: "succeeded")
        _ = try await service.viewResult(row)
        let updated = service.applyingConfirmedViewedMarkers(to: [row, other])
        #expect(updated[0].time.viewed == 2000)
        #expect(!updated[0].hasUnreadResult)
        #expect(updated[0].outcome == row.outcome)
        #expect(updated[1] == other)
        // A poll captured before confirmation cannot bring its badge back.
        #expect(service.applyingConfirmedViewedMarkers(to: [row])[0].hasUnreadResult == false)
        let newer = OCSession(id: "ses_1", title: "New", time: .init(created: 1000, updated: 3000, idle: 3000))
        #expect(service.applyingConfirmedViewedMarkers(to: [newer])[0].hasUnreadResult)
    }

    @Test func periodicAttentionRefreshReadsOnlyUnreadInactiveRowsAndPreservesOutcomesOnFailure() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let unread = try await service.getSession(id: "ses_1")
        let other = OCSession(id: "ses_unread", title: "Unread", time: unread.time, outcome: "succeeded")
        let active = OCSession(id: "ses_active", title: "Running", time: unread.time, outcome: "succeeded")
        let readRows = (1...200).map {
            OCSession(id: "ses_read_\($0)", title: "Read", time: .init(created: 1000, updated: 2000, idle: 2000, viewed: 2000))
        }
        let rows = [unread, other, active] + readRows
        await server.desktopViewed(2000)
        await server.resetSessionReads()
        let statuses = [active.id: OCSessionStatus(type: .busy, attempt: nil, message: nil, next: nil)]
        let refreshed = await service.refreshUnreadResults(in: rows, statuses: statuses)
        #expect(Set(await server.sessionReads) == ["ses_1", "ses_unread"])
        #expect(await server.sessionReads.count == 2)
        #expect(refreshed[0].hasUnreadResult == false)
        #expect(refreshed[1].hasUnreadResult == false)
        #expect(refreshed[1].outcome == "succeeded")
        #expect(refreshed[2] == active)
        await server.failAllReads()
        let failed = await service.refreshUnreadResults(in: [
            OCSession(id: "ses_1", title: "New result", time: .init(created: 1000, updated: 3000, idle: 3000), outcome: "succeeded")
        ], statuses: [:])
        #expect(failed[0].outcome == "succeeded")
        #expect(failed[0].hasUnreadResult)
    }

    @Test func markAllReadAcknowledgesOnlyUnreadInactiveSessionsInBulk() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let first = try await service.getSession(id: "ses_1")
        let second = OCSession(id: "ses_2", title: "Second", time: first.time, outcome: "succeeded")
        let busy = OCSession(id: "ses_busy", title: "Busy", time: first.time, outcome: "succeeded")
        let alreadyRead = OCSession(id: "ses_read", title: "Read", time: .init(created: 1000, updated: 2000, idle: 2000, viewed: 2000), outcome: "succeeded")

        let statuses = [busy.id: OCSessionStatus(type: .busy, attempt: nil, message: nil, next: nil)]
        let result = await service.markAllRead(in: [first, second, busy, alreadyRead], statuses: statuses)

        #expect(result.failedCount == 0)
        #expect(result.sessions[0].hasUnreadResult == false)
        #expect(result.sessions[1].hasUnreadResult == false)
        #expect(result.sessions[2].hasUnreadResult == true)
        #expect(result.sessions[3].hasUnreadResult == false)
        #expect(await server.viewRequests.count == 2)
    }

    @Test func aDesktopViewedEventRequestsOnlyReadMarkerRecovery() throws {
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event(["type": "session.viewed", "data": ["sessionID": "ses_1", "idle": 2000]], directory: nil))
        #expect(event.type == "session.viewed.changed")
        let data = try #require(event.properties?.value as? [String: Any])
        #expect(data["sessionID"] as? String == "ses_1")
    }

    @Test func attentionRefreshPreservesANewerUnreadCompletionAgainstAnOlderRow() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let stale = OCSession(id: "ses_1", title: "Old result", time: .init(created: 1000, updated: 1000, idle: 1000), outcome: "succeeded")
        await server.complete(3000)
        await server.desktopViewed(2000)
        let rows = await service.refreshUnreadResults(in: [stale], statuses: [:])
        let result = try #require(rows.first)
        #expect(result.hasUnreadResult)
        #expect(result.time.idle == 3000)
        #expect(result.time.viewed == 2000)
        #expect(service.applyingConfirmedViewedMarkers(to: rows)[0].hasUnreadResult)
    }

    @Test(arguments: ["ses_1", "ses_other"])
    func viewedEventsRefreshOnlyTheMatchingMarkerWithoutReloadingHistory(sessionID: String) async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let original = try #require(chat.currentSession)
        chat.currentSession = OCSession(id: original.id, title: "Displayed title", time: original.time, outcome: original.outcome)
        chat.messages = [ChatMessage(id: "displayed", role: .assistant, content: "Keep this history")]
        await server.desktopViewed(2000)
        await server.resetRequests()
        var adapter = V2EventAdapter()
        let event = try #require(try adapter.event(["type": "session.viewed", "data": ["sessionID": sessionID, "idle": 2000]], directory: nil))
        chat.receiveStreamEvent(.raw(event))
        if sessionID == "ses_1" {
            try await waitUntil { chat.currentSession?.time.viewed == 2000 }
            #expect(await server.requestPaths == ["/api/session/ses_1"])
        } else {
            #expect(await server.requestPaths.isEmpty)
            #expect(chat.currentSession?.hasUnreadResult == true)
        }
        #expect(chat.currentSession?.title == "Displayed title")
        #expect(chat.messages.map(\.id) == ["displayed"])
        #expect(chat.isStreamSynchronized)
    }

    @Test func chatDoesNotReplaceANewerVisibleCompletionWithAnOldViewResponse() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.holdView()
        let viewing = Task { await chat.viewCurrentResult(observed) }
        try await waitForView(server)
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        await server.releaseView()
        await viewing.value
        #expect(chat.currentSession?.time.idle == 3000)
        #expect(chat.currentSession?.time.viewed == 2000)
        #expect(chat.currentSession?.hasUnreadResult == true)
    }

    @Test(arguments: [false, true])
    func failedOrCancelledViewingKeepsChatUnreadAndDoesNotReportConfirmation(cancelled: Bool) async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        if cancelled {
            await server.holdView()
            let viewing = Task { await chat.viewCurrentResult(observed) }
            try await waitForView(server)
            viewing.cancel()
            await server.releaseView()
            await viewing.value
            #expect(chat.errorMessage == nil)
        } else {
            await server.loseResponse(committed: false)
            await chat.viewCurrentResult(observed)
            #expect(chat.resultViewingError != nil)
            #expect(chat.currentSession?.time.viewed == nil)
            await server.allowView()
            await chat.viewCurrentResult(observed)
            #expect(chat.currentSession?.hasUnreadResult == false)
            #expect(chat.resultViewingError == nil)
            return
        }
        #expect(chat.currentSession?.hasUnreadResult == true)
        #expect(chat.currentSession?.time.viewed == nil)
    }

    @Test func failedCanonicalReadAfterAcknowledgementCanRetryWithoutGuessing() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.failReadAfterView()
        await chat.viewCurrentResult(observed)
        #expect(chat.currentSession?.hasUnreadResult == true)
        #expect(chat.currentSession?.time.viewed == nil)
        #expect(chat.resultViewingError != nil)
        await server.allowReads()
        await chat.viewCurrentResult(observed)
        #expect(chat.currentSession?.time.viewed == 2000)
        #expect(chat.resultViewingError == nil)
    }

    @Test func aLaterCanonicalConfirmationClearsTheViewErrorWithoutAnotherMutation() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.failReadAfterView()
        await chat.viewCurrentResult(observed)
        #expect(chat.resultViewingError != nil)
        await server.allowReads()
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        await chat.viewCurrentResult(try #require(chat.currentSession))
        #expect(chat.currentSession?.hasUnreadResult == false)
        #expect(chat.resultViewingError == nil)
        #expect(await server.viewRequests.count == 1)
    }

    @Test func aDelayedViewResponseCannotChangeAnotherChat() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.holdView()
        let viewing = Task { await chat.viewCurrentResult(observed) }
        try await waitForView(server)
        chat.unloadSession(ifMatching: "ses_1")
        chat.currentSession = OCSession(id: "ses_2", title: "Other", time: .init(created: 1000, updated: 4000, idle: 4000))
        await server.releaseView()
        await viewing.value
        #expect(chat.currentSession?.id == "ses_2")
        #expect(chat.currentSession?.time.viewed == nil)
        #expect(chat.errorMessage == nil)
    }

    @Test func unreadUsesIdleRatherThanTitleUpdateTimeAndHandlesMalformedViewedFields() throws {
        let fields = [
            (#""idle":2000"#, true),
            (#""idle":2000,"viewed":1900"#, true),
            (#""idle":2000,"viewed":2000"#, false),
            (#""idle":2000,"viewed":3000"#, false),
            (#""viewed":1900"#, false),
            (#""idle":0"#, false),
            (#""idle":-1"#, false),
            (#""idle":2000,"viewed":"invalid""#, true)
        ]
        for (time, unread) in fields {
            let session = try JSONDecoder().decode(OCSession.self, from: Data(#"{"id":"ses_1","time":{"created":1000,"updated":9999,\#(time)}}"#.utf8))
            #expect(session.hasUnreadResult == unread)
        }
        let first = OCSession(id: "ses_1", title: "Result", time: .init(created: 1000, updated: 2100, idle: 2000))
        #expect(first != first.withViewedMarker(2000))
    }

    @Test func legacyViewingAndAlreadyViewedOrMissingIdleDoNotSendV2Mutations() async throws {
        let server = ViewedTransport()
        let service = try await makeService(server)
        let observed = try await service.getSession(id: "ses_1")
        let read = observed.withViewedMarker(2000)
        #expect(try await service.viewResult(read) == read)
        let empty = OCSession(id: "ses_1", title: "New", time: .init(created: 1000, updated: 1000))
        #expect(try await service.viewResult(empty) == empty)
        await server.useLegacy()
        let legacy = try await makeService(server)
        #expect(try await legacy.viewResult(observed) == observed)
        #expect(await server.viewRequests.isEmpty)
    }

    @Test func onlyTheVisibleForegroundChatAcknowledgesAPresentedResult() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewedChatHarness(chat: chat, visibility: visibility)
            .environment(\.connection, connection)
            .environment(\.workspaceService, WorkspaceService(connection: connection)))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { visibility.renderedActive == false }
        #expect(await server.viewRequests.isEmpty)
        visibility.isActive = true
        for _ in 0..<200 {
            if chat.currentSession?.time.viewed == 2000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.currentSession?.hasUnreadResult == false)
        #expect(await server.viewRequests.count == 1)
    }

    // Rapid transport completions can land within one SwiftUI render frame.
    // Repeated hosting exercises that timing without slowing acknowledgements.
    @Test(arguments: 0..<10)
    func visibleCompletionsAreAcknowledgedSeriallyWithTheirOwnObservedMarkers(_ iteration: Int) async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        visibility.isActive = true
        await server.holdView()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewedChatHarness(chat: chat, visibility: visibility)
            .environment(\.connection, connection)
            .environment(\.workspaceService, WorkspaceService(connection: connection)))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForView(server)
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        await server.releaseView()
        try await waitUntil { chat.currentSession?.time.viewed == 3000 || chat.resultViewingError != nil }
        #expect(chat.currentSession?.time.viewed == 3000)
        #expect(await server.observedMarkers == [2000, 3000])
        #expect(await server.maximumConcurrentViews == 1)
        #expect(chat.currentSession?.hasUnreadResult == false)
        // A third result watched after the previous request settles also gets read.
        await server.complete(4000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        try await waitUntil { chat.currentSession?.time.viewed == 4000 }
        #expect(await server.observedMarkers == [2000, 3000, 4000])
    }

    @Test func aRetainedChatOnAnotherTabDoesNotViewResultsAfterForegroundRecovery() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        visibility.isActive = true
        let window = try await showChat(chat, visibility: visibility, server: server, inTabs: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { chat.currentSession?.time.viewed == 2000 }
        visibility.selectedTab = 1
        try await waitUntil { visibility.renderedChat == false && visibility.renderedTab == 1 }
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        visibility.isActive = false
        try await waitUntil { visibility.renderedActive == false }
        let readsBeforeForegrounding = await server.statusReads
        visibility.isActive = true
        try await waitUntil { visibility.renderedActive == true }
        // Global foreground recovery can update a retained hidden chat even
        // when TabView defers the child's own scenePhase callbacks.
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil {
            let reads = await server.statusReads
            return visibility.renderedActive == true && chat.isStreamSynchronized && reads > readsBeforeForegrounding
        }
        #expect(await server.observedMarkers == [2000])
        #expect(chat.currentSession?.hasUnreadResult == true)
        visibility.selectedTab = 0
        try await waitUntil { chat.currentSession?.time.viewed == 3000 }
        #expect(await server.observedMarkers == [2000, 3000])
    }

    @Test func returningToARetainedChatRestartsItsCancelledAcknowledgementWithoutSessionChanges() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        visibility.isActive = true
        await server.holdView()
        let window = try await showChat(chat, visibility: visibility, server: server, inTabs: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForView(server)
        visibility.selectedTab = 1
        try await waitUntil { visibility.renderedChat == false && visibility.renderedTab == 1 }
        await server.releaseView()
        try await waitUntil { await server.concurrentViews == 0 }
        #expect(chat.currentSession?.time.viewed == nil)
        #expect(await server.viewed == nil)
        visibility.selectedTab = 0
        try await waitUntil { chat.currentSession?.time.viewed == 2000 }
        #expect(await server.observedMarkers == [2000, 2000])
        #expect(chat.currentSession?.hasUnreadResult == false)
    }

    @Test(arguments: ["post", "canonical-read"])
    func aResyncDoesNotDropAnInFlightVisibleAcknowledgement(phase: String) async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let visibility = ViewedChatVisibility()
        visibility.isActive = true
        if phase == "post" { await server.holdView() } else { await server.holdAcknowledgementRead() }
        let window = try await showChat(chat, visibility: visibility, server: server)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil {
            let waiting = await server.isWaiting
            let reading = await server.isWaitingForRead
            return waiting || reading
        }
        chat.synchronizeCurrentSessionFromServer()
        try await waitUntil {
            let reads = await server.statusReads
            return chat.isStreamSynchronized && reads > 0
        }
        await server.releaseView()
        await server.releaseRead()
        try await waitUntil { chat.currentSession?.time.viewed == 2000 || chat.resultViewingError != nil }
        #expect(chat.currentSession?.time.viewed == 2000)
        #expect(chat.resultViewingError == nil)
        #expect(await server.observedMarkers == [2000])
    }

    @Test func acknowledgementErrorsKeepTheirRetryRouteWhenOtherErrorsChange() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        let observed = try #require(chat.currentSession)
        await server.loseResponse(committed: false)
        await chat.viewCurrentResult(observed)
        chat.errorMessage = "Another operation failed"
        #expect(chat.resultViewingError != nil)
        await server.allowView()
        chat.updateDisplayedResult(observed, isForeground: true)
        chat.retryViewingDisplayedResult()
        try await waitUntil { chat.currentSession?.time.viewed == 2000 }
        #expect(chat.resultViewingError == nil)
        #expect(chat.errorMessage == "Another operation failed")
    }

    @Test func sendErrorsArePresentedAndDismissibleBeforeAPersistentViewingError() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        await server.loseResponse(committed: false)
        await chat.viewCurrentResult(try #require(chat.currentSession))
        let viewingError = try #require(chat.resultViewingError)
        chat.errorMessage = "Failed to send the prompt."
        chat.responseState = .failed
        let first = try #require(chat.presentedError)
        #expect(first == .operation("Failed to send the prompt."))
        #expect(!first.canRetry)
        chat.dismissError()
        #expect(chat.responseState == .idle)
        let remaining = try #require(chat.presentedError)
        #expect(remaining == .viewing(viewingError))
        #expect(remaining.canRetry)
        #expect(chat.resultViewingError == viewingError)
    }

    @Test func displayedMarkersCoalesceWhileOneAcknowledgementIsHeld() async throws {
        let server = ViewedTransport()
        let chat = try await makeChat(server)
        await server.holdView()
        chat.updateDisplayedResult(chat.currentSession, isForeground: true)
        try await waitForView(server)
        await server.complete(3000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        chat.updateDisplayedResult(chat.currentSession, isForeground: true)
        await server.complete(4000)
        chat.currentSession = try await makeService(server).getSession(id: "ses_1")
        chat.updateDisplayedResult(chat.currentSession, isForeground: true)
        await server.releaseView()
        try await waitUntil { chat.currentSession?.time.viewed == 4000 }
        #expect(await server.observedMarkers == [2000, 4000])
        #expect(await server.maximumConcurrentViews == 1)
        chat.stopViewingResults()
    }

    private func showChat(_ chat: ChatClient, visibility: ViewedChatVisibility, server: ViewedTransport, inTabs: Bool = false) async throws -> UIWindow {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewedChatHarness(chat: chat, visibility: visibility, inTabs: inTabs)
            .environment(\.connection, connection)
            .environment(\.workspaceService, WorkspaceService(connection: connection)))
        window.isHidden = false
        return window
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the hosted view or transport", sourceLocation: sourceLocation)
        throw ViewedTestTimeout()
    }

    private func makeChat(_ server: ViewedTransport) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = SessionsService(connection: connection)
        let chat = ChatClient(
            connection: connection, liveActivity: TestLiveActivityProvider(),
            sessionsService: service, messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection), questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []), recordedReplayStore: RecordedReplayStore()
        )
        chat.currentSession = try await service.getSession(id: "ses_1")
        return chat
    }

    private func waitForView(_ server: ViewedTransport) async throws {
        for _ in 0..<200 {
            if await server.isWaiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for view acknowledgement")
    }

    private func makeService(_ server: ViewedTransport) async throws -> SessionsService {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, contextDirectory: "/workspace", transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        return SessionsService(connection: connection)
    }
}

private actor ViewedTransport: OpenCodeTransport {
    var idle: Double = 2000
    var viewed: Double?
    var viewRequests: [URLRequest] = []
    var concurrentViews = 0
    var maximumConcurrentViews = 0
    var observedMarkers: [Double] {
        viewRequests.compactMap { request in
            guard let data = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return nil }
            return json["idle"]
        }
    }
    var completesDuringView = false
    var commitsView = true
    var losesResponse = false
    var holdsView = false
    var failsReadAfterView = false
    var failsReads = false
    var usesV2 = true
    var holdsAcknowledgementRead = false
    var readWaiter: CheckedContinuation<Void, Never>?
    var isWaitingForRead: Bool { readWaiter != nil }
    var statusReads = 0
    var sessionReads: [String] = []
    var requestPaths: [String] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }

    func completeDuringView() { completesDuringView = true }
    func complete(_ idle: Double) { self.idle = idle }
    func desktopViewed(_ viewed: Double) { self.viewed = viewed }
    func ignoreView() { commitsView = false }
    func loseResponse(committed: Bool) { losesResponse = true; commitsView = committed }
    func allowView() { losesResponse = false; commitsView = true }
    func holdView() { holdsView = true }
    func holdAcknowledgementRead() { holdsAcknowledgementRead = true }
    func releaseRead() { readWaiter?.resume(); readWaiter = nil }
    func releaseView() { holdsView = false; waiters.forEach { $0.resume() }; waiters = [] }
    func failReadAfterView() { failsReadAfterView = true }
    func resetRequests() { requestPaths = [] }
    func resetSessionReads() { sessionReads = [] }
    func failAllReads() { failsReads = true }
    func allowReads() { failsReads = false; failsReadAfterView = false }
    func useLegacy() { usesV2 = false }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        requestPaths.append(url.path)
        let body: String
        var status = 200
        switch url.path {
        case "/api/info":
            body = #"{"version":"2.0.23"}"#
            if !usesV2 { status = 404 }
        case "/global/health": body = #"{"healthy":true,"version":"1.2.0"}"#
        case let path where path.hasPrefix("/api/session/") && path.hasSuffix("/view"):
            viewRequests.append(request)
            concurrentViews += 1
            maximumConcurrentViews = max(maximumConcurrentViews, concurrentViews)
            defer { concurrentViews -= 1 }
            if holdsView { await withCheckedContinuation { waiters.append($0) } }
            try Task.checkCancellation()
            if completesDuringView { idle = 3000 }
            let requestBody = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Double])
            if commitsView { viewed = max(viewed ?? 0, min(idle, try #require(payload["idle"]))) }
            if failsReadAfterView { failsReads = true }
            if losesResponse { throw URLError(.networkConnectionLost) }
            body = ""
            status = 204
        case let path where path == "/api/session" || (path.hasPrefix("/api/session/") && request.httpMethod == "GET"
            && !["active", "message", "inbox", "permission", "form"].contains(url.lastPathComponent)):
            if path != "/api/session" { sessionReads.append(url.lastPathComponent) }
            if holdsAcknowledgementRead, !viewRequests.isEmpty {
                holdsAcknowledgementRead = false
                await withCheckedContinuation { readWaiter = $0 }
            }
            if failsReads { throw URLError(.networkConnectionLost) }
            var time: [String: Double] = ["created": 1000, "updated": 2100, "idle": idle]
            time["viewed"] = viewed
            let session: [String: Any] = ["id": url.path == "/api/session" ? "ses_1" : url.lastPathComponent, "title": "Result", "time": time, "outcome": "failed"]
            let response: [String: Any] = url.path == "/api/session" ? ["data": [session], "cursor": ["next": NSNull()]] : ["data": session]
            body = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        case "/api/session/active": statusReads += 1; body = #"{"data":{}}"#
        case "/api/session/ses_1/message": body = #"{"data":[],"cursor":{"next":null}}"#
        case "/api/session/ses_1/inbox", "/api/session/ses_1/permission", "/api/session/ses_1/form": body = #"{"data":[]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        ViewedUnusedStream()
    }
}

private final class ViewedUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}; func suspend() {}; func resume() {}; func cancel() {}
}

@MainActor @Observable
private final class ViewedChatVisibility {
    var isActive = false
    var renderedActive: Bool?
    var selectedTab = 0
    var renderedTab: Int?
    var renderedChat: Bool?
}

private struct ViewedChatHarness: View {
    let chat: ChatClient
    @Bindable var visibility: ViewedChatVisibility
    var inTabs = false
    var body: some View {
        Group {
            if inTabs {
                TabView(selection: $visibility.selectedTab) {
                    NavigationStack(path: .constant(["chat"])) {
                        Text("Sessions")
                            .navigationDestination(for: String.self) { _ in hostedChat }
                    }
                    .tabItem { Label("Chat", systemImage: "bubble.left") }
                    .tag(0)
                    Text("Workspace")
                        .onAppear { visibility.renderedTab = 1 }
                        .tabItem { Label("Workspace", systemImage: "folder") }
                        .tag(1)
                }
            } else {
                hostedChat
            }
        }
        .environment(\.scenePhase, visibility.isActive ? .active : .background)
            .onChange(of: visibility.isActive, initial: true) { _, active in visibility.renderedActive = active }
    }

    private var hostedChat: some View {
        ChatView(chatClient: chat, initialSession: chat.currentSession)
            .onAppear { visibility.renderedChat = true; visibility.renderedTab = 0 }
            .onDisappear { visibility.renderedChat = false }
    }
}

private struct ViewedTestTimeout: Error {}
