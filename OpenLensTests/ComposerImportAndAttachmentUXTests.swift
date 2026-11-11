import CoreGraphics
@preconcurrency import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenLens

@MainActor
struct ComposerImportAndAttachmentUXTests {

    @Test func localFilePayloadRoutesPNGToImageAndSourceCodeToText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pngURL = folder.appendingPathComponent("diagram.png")
        let pngBytes = Self.makeImageData(width: 240, height: 180, type: .png)
        try pngBytes.write(to: pngURL)

        let swiftURL = folder.appendingPathComponent("App.swift")
        try Data("struct App {}\n".utf8).write(to: swiftURL)

        let zipURL = folder.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF]).write(to: zipURL)

        let pngPayload = try LocalComposerFilePayload.read(from: pngURL)
        switch pngPayload {
        case let .image(data, name):
            #expect(data == pngBytes)
            #expect(name == "diagram.png")
        case .textFile:
            Issue.record("Expected PNG file to be classified as an image attachment")
        }

        let swiftPayload = try LocalComposerFilePayload.read(from: swiftURL)
        switch swiftPayload {
        case let .textFile(file):
            #expect(file.name == "App.swift")
            #expect(file.text == "struct App {}\n")
        case .image:
            Issue.record("Expected Swift file to be classified as a UTF-8 text attachment")
        }

        #expect(throws: PromptAttachmentError.unsupportedTextFile(name: "archive.zip")) {
            try LocalComposerFilePayload.read(from: zipURL)
        }
    }

    @Test func fileImporterAttachesPNGPreservingFilenameAndSendsWithoutText() async throws {
        let server = AttachmentUXFakeServer()
        let chat = try await Self.openChat(server: server)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pngURL = folder.appendingPathComponent("Screenshot 2026-11-11.png")
        let pngBytes = Self.makeImageData(width: 320, height: 200, type: .png)
        try pngBytes.write(to: pngURL)

        await chat.attachComposerFile(at: pngURL)

        #expect(chat.errorMessage == nil)
        #expect(chat.composerImages.count == 1)
        #expect(chat.composerImages.first?.mime == "image/png")
        #expect(chat.composerImages.first?.name == "Screenshot 2026-11-11.png")

        // Send with empty inputText (image-only prompt).
        #expect(chat.inputText.isEmpty)
        chat.send()
        try await Self.waitUntil { await server.promptRequests.count == 1 }

        let body = try #require(await server.promptRequests.first?.json)
        let files = try #require(body["files"] as? [[String: Any]])
        #expect(body["text"] as? String == "")
        #expect(files.count == 1)
        #expect(files.first?["name"] as? String == "Screenshot 2026-11-11.png")
        #expect((files.first?["uri"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func pastingCopiedFinderPNGAndTextFilesAttachesInsteadOfTypingFilename() async throws {
        let server = AttachmentUXFakeServer()
        let chat = try await Self.openChat(server: server)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pngURL = folder.appendingPathComponent("FinderShot.png")
        try Self.makeImageData(width: 160, height: 120, type: .png).write(to: pngURL)

        let notesURL = folder.appendingPathComponent("notes.md")
        try Data("# Release Notes\nAll green.\n".utf8).write(to: notesURL)

        // Simulate macOS Finder Cmd+C, which registers both public.file-url AND
        // the bare filename as public.utf8-plain-text on the same NSItemProvider.
        let finderPNGProvider = NSItemProvider()
        let pngURLData = pngURL.dataRepresentation
        finderPNGProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(pngURLData, nil)
            return nil
        }
        finderPNGProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("FinderShot.png".utf8), nil)
            return nil
        }

        let finderNotesProvider = NSItemProvider()
        let notesURLData = notesURL.dataRepresentation
        finderNotesProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(notesURLData, nil)
            return nil
        }
        finderNotesProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("notes.md".utf8), nil)
            return nil
        }

        #expect(ComposerItemImporter.shouldInterceptTextFieldPaste(finderPNGProvider))
        #expect(ComposerItemImporter.shouldInterceptTextFieldPaste(finderNotesProvider))

        let imported = await ComposerItemImporter.extractItems(
            from: [finderPNGProvider, finderNotesProvider],
            includePlainText: false
        )
        await chat.importComposerItems(imported)

        #expect(chat.inputText.isEmpty)
        #expect(chat.errorMessage == nil)
        #expect(chat.composerAttachments.map(\.promptFile.name) == ["FinderShot.png", "notes.md"])
    }

    @Test func pastingScreenshotImageBytesAndPlainTextBehaveCorrectly() async throws {
        let server = AttachmentUXFakeServer()
        let chat = try await Self.openChat(server: server)

        let pngBytes = Self.makeImageData(width: 180, height: 100, type: .png)
        let screenshotProvider = NSItemProvider()
        screenshotProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(pngBytes, nil)
            return nil
        }

        let plainTextProvider = NSItemProvider()
        plainTextProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("Explain this screenshot".utf8), nil)
            return nil
        }

        #expect(ComposerItemImporter.shouldInterceptTextFieldPaste(screenshotProvider))
        #expect(!ComposerItemImporter.shouldInterceptTextFieldPaste(plainTextProvider))

        let items = await ComposerItemImporter.extractItems(
            from: [screenshotProvider, plainTextProvider],
            includePlainText: true
        )
        await chat.importComposerItems(items)

        #expect(chat.composerImages.count == 1)
        #expect(chat.composerImages.first?.mime == "image/png")
        #expect(chat.inputText == "Explain this screenshot")
    }

    @Test func deliveredSubmissionsReleaseDuplicateAttachmentMemoryWhileKeepingAcceptedState() async throws {
        let server = AttachmentUXFakeServer()
        await server.setPromotesToTranscript(true)
        let chat = try await Self.openChat(server: server)
        let image = try PromptImagePreparer.prepare(
            Self.makeImageData(width: 100, height: 100, type: .png),
            maximumBytes: 500_000,
            preferredName: "chart.png"
        )

        chat.inputText = "Review chart"
        chat.addComposerAttachment(.image(image))
        chat.send()
        try await Self.waitUntil {
            if case .accepted = chat.promptSubmissions.first?.state { return true }
            return false
        }
        try await Self.waitUntil { !chat.messages.isEmpty }
        _ = await chat.loadMessages(syncModelSelection: false)

        let submission = try #require(chat.promptSubmissions.first)
        if case .accepted = submission.state {
            #expect(submission.attachments.isEmpty)
            #expect(submission.text.isEmpty)
        } else {
            Issue.record("Expected submission to remain in accepted state")
        }
    }

    @Test func appRouterDesktopCommandsIncrementAndFocusExpectedTabs() {
        let router = AppRouter()
        router.selectedTab = .settings

        router.requestNewSession()
        #expect(router.selectedTab == .chat)
        #expect(router.newSessionCommandCount == 1)

        router.requestToggleSidebar()
        #expect(router.toggleSidebarCommandCount == 1)

        router.selectedTab = .workspace
        router.requestChooseModel()
        #expect(router.selectedTab == .chat)
        #expect(router.chooseModelCommandCount == 1)

        router.requestAttachFile()
        #expect(router.attachFileCommandCount == 1)

        router.requestPasteClipboard()
        #expect(router.pasteClipboardCommandCount == 1)
    }

    // MARK: - Helpers

    private static func makeImageData(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.15, green: 0.55, blue: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func openChat(server: AttachmentUXFakeServer) async throws -> ChatClient {
        let api = OpenCodeClient(baseURL: URL(string: "https://example.com")!, transport: server)
        let connection = ConnectionManager(testClient: api, capabilities: try await api.probeCapabilities())
        let chat = ChatClient(
            connection: connection,
            liveActivity: TestLiveActivityProvider(),
            sessionsService: SessionsService(connection: connection),
            messagesService: MessagesService(connection: connection),
            providersService: ProvidersService(connection: connection),
            questionService: QuestionService(connection: connection),
            savedConnectionsStore: SavedConnectionsStore(initialConnections: []),
            recordedReplayStore: RecordedReplayStore()
        )
        await chat.loadProviders()
        await chat.loadSession(OCSession(id: "ses_1", directory: "/workspace", title: "Session", time: .init(created: 0, updated: 0)))
        return chat
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

private actor AttachmentUXFakeServer: OpenCodeTransport {
    struct Request: Sendable {
        let path: String
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private var promotesToTranscript = false
    private var transcriptIDs: [(id: String, text: String)] = []
    private(set) var requests: [Request] = []

    var promptRequests: [Request] { requests.filter { $0.path.hasSuffix("/prompt") } }

    func setPromotesToTranscript(_ promotes: Bool) {
        promotesToTranscript = promotes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        let recorded = Request(path: path, body: request.httpBody ?? Data())
        requests.append(recorded)

        func respond(_ status: Int, _ json: String = "") -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        let location = #""location":{"directory":"/workspace","project":{"id":"p","directory":"/workspace"}}"#
        let model = #"{"id":"claude-a","providerID":"anthropic","name":"Claude A","capabilities":{"tools":true,"input":["text","image"],"output":["text"]}}"#
        switch path {
        case "/api/session/ses_1/prompt":
            let id = recorded.json["id"] as? String ?? "msg_1"
            let text = recorded.json["text"] as? String ?? ""
            if promotesToTranscript {
                transcriptIDs.append((id, text))
            }
            return respond(200, #"{"data":{"id":"\#(id)","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":"\#(text)"},"delivery":"steer"}}"#)
        case "/api/info":
            return respond(200, #"{"version":"2.0.23"}"#)
        case "/api/location":
            return respond(200, #"{"directory":"/workspace","project":{"id":"p","directory":"/workspace"}}"#)
        case "/api/vcs":
            return respond(200, #"{\#(location),"data":{"branch":"main"}}"#)
        case "/api/model":
            return respond(200, #"{\#(location),"data":[\#(model)]}"#)
        case "/api/model/default":
            return respond(200, #"{\#(location),"data":\#(model)}"#)
        case "/api/provider":
            return respond(200, #"{\#(location),"data":[{"id":"anthropic","name":"Anthropic"}]}"#)
        case "/api/session/active":
            return respond(200, #"{"data":{}}"#)
        case "/api/session/ses_1":
            return respond(200, #"{"data":{"id":"ses_1","title":"Session","time":{"created":0,"updated":0},\#(location)}}"#)
        case "/api/session/ses_1/inbox":
            return respond(200, #"{"data":[]}"#)
        case "/api/session/ses_1/message":
            let rows = transcriptIDs.map { item in
                #"{"id":"\#(item.id)","type":"user","time":{"created":1},"text":"\#(item.text)"}"#
            }.joined(separator: ",")
            return respond(200, #"{"data":[\#(rows)],"cursor":{"next":null}}"#)
        case "/api/session/ses_1/permission", "/api/session/ses_1/form":
            return respond(200, #"{"data":[]}"#)
        default:
            return respond(404)
        }
    }

    nonisolated func makeEventStream(
        request: URLRequest,
        deliveryQueue: DispatchQueue,
        callbacks: OpenCodeEventStreamCallbacks
    ) -> any OpenCodeEventStream {
        AttachmentUXUnusedStream()
    }
}

private final class AttachmentUXUnusedStream: OpenCodeEventStream, @unchecked Sendable {
    func start() {}
    func suspend() {}
    func resume() {}
    func cancel() {}
}
