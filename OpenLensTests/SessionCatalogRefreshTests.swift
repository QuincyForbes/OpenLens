import Foundation
import Testing
@testable import OpenLens

@MainActor
struct SessionCatalogRefreshTests {
    @Test func refreshReordersChangedSessionsDiscoversNewOnesAndRemovesDeletedRows() async throws {
        let transport = CatalogRefreshTransport()
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = SessionsService(connection: connection)

        let first = try await service.listAllSessions()
        #expect(first.map(\.id) == ["a", "b", "deleted"])
        await transport.advance()
        let second = try await service.listAllSessions()
        #expect(second.map(\.id) == ["b", "new", "a"])
        #expect(second.first?.updatedAt == 0.9)
        #expect(second.first { $0.id == "a" }?.directory == "/work/App")
        #expect(await transport.catalogReads == 2)
        #expect(service.repositoryProjects.contains { $0.id == "repo" && $0.worktree == "/work/App" })
    }

    @Test func projectLookupFailureStillReturnsFreshSessionCatalog() async throws {
        let transport = CatalogRefreshTransport(failsProjects: true)
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: transport)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let service = SessionsService(connection: connection)
        #expect(try await service.listAllSessions().map(\.id) == ["a", "b", "deleted"])
    }
}

private actor CatalogRefreshTransport: OpenCodeTransport {
    private var advanced = false
    private let failsProjects: Bool
    private(set) var catalogReads = 0

    init(failsProjects: Bool = false) { self.failsProjects = failsProjects }
    func advance() { advanced = true }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let body: String
        switch url.path {
        case "/api/info": body = #"{"version":"2.0.23"}"#
        case "/api/project":
            if failsProjects { throw URLError(.networkConnectionLost) }
            body = #"[{"id":"repo","worktree":"/work/App"}]"#
        case "/api/session":
            catalogReads += 1
            body = advanced ? #"{"data":[{"id":"a","projectID":"repo","title":"A","time":{"updated":100}},{"id":"b","title":"B","time":{"updated":200}},{"id":"new","title":"New on desktop","time":{"updated":500}},{"id":"b","title":"B updated","time":{"updated":900}}],"cursor":{"next":null}}"#
                : #"{"data":[{"id":"deleted","title":"Deleted later","time":{"updated":10}},{"id":"b","title":"B","time":{"updated":20}},{"id":"a","projectID":"repo","title":"A","time":{"updated":100}}],"cursor":{"next":null}}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated func makeEventStream(request: URLRequest, deliveryQueue: DispatchQueue, callbacks: OpenCodeEventStreamCallbacks) -> any OpenCodeEventStream {
        CatalogUnusedStream()
    }
}

private final class CatalogUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
