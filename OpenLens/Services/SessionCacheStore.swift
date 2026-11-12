import CryptoKit
import Foundation
import UIKit

/// Bounded two-tier (in-memory LRU + optional Caches directory) store for
/// session catalogs and recent chat transcripts so switching chats and cold
/// launching OpenLens feel instantaneous without retaining unbounded history.
@MainActor
final class SessionCacheStore {

    struct CachedCatalogSnapshot {
        let rootSessions: [OCSession]
        let childSessions: [OCSession]
        let projects: [OCProject]
        let viewedMarkers: [String: Double]
        let savedAt: Date
    }

    struct CachedTranscriptSnapshot {
        var session: OCSession
        var messages: [ChatMessage]
        var contextEntries: [SessionContextEntry]
        var entryOrder: [String]
        var olderCursor: String?
        var todos: [OCTodo]
        var hiddenTodoCount: Int
        var turnDiffSummariesByMessageID: [String: [TurnFileChangeSummary]]
        var cachedAt: Date
    }

    nonisolated private struct PersistedProjectRecord: Codable, Sendable {
        let id: String
        let worktree: String?
        let vcsDir: String?
        let vcs: String?
    }

    nonisolated private struct PersistedCatalogPayload: Codable, Sendable {
        let schemaVersion: Int
        let savedAt: Date
        let rootSessions: [OCSession]
        let childSessions: [OCSession]
        let projects: [PersistedProjectRecord]
        let viewedMarkers: [String: Double]
    }

    nonisolated private struct PersistedMessageRecord: Codable, Sendable {
        let id: String
        let roleRawValue: String
        let content: String
        let parts: [OCPart]
        let createdAt: Date
        let cost: Double?
        let tokens: OCTokenUsage?
        let modelID: String?
        let providerID: String?
        let finish: String?
        let parentUserMessageID: String?
    }

    nonisolated private struct PersistedTranscriptPayload: Codable, Sendable {
        let schemaVersion: Int
        let savedAt: Date
        let session: OCSession
        let messages: [PersistedMessageRecord]
        let entryOrder: [String]
        let olderCursor: String?
        let todos: [OCTodo]
        let hiddenTodoCount: Int
    }

    private struct TranscriptKey: Hashable {
        let scope: String
        let sessionID: String
    }

    static let currentSchemaVersion = 1
    static let defaultMaximumInMemorySessions = 16
    static let defaultMaximumDiskTranscripts = 32
    static let maximumCachedMessagesPerSession = 20
    static let maximumCachedContextEntriesPerSession = 24
    static let maximumSingleMessageCachedUTF8Bytes = 256 * 1_024
    static let maximumDiskMessageUTF8Bytes = 64 * 1_024
    static let maximumPersistedRootSessions = 400
    static let maximumPersistedChildSessions = 200

    static var defaultProductionDirectory: URL? {
        guard !ScreenshotFixtures.isEnabled,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent("OpenLensSessionCache/v1", isDirectory: true)
    }

    let maximumInMemorySessions: Int
    let maximumDiskTranscripts: Int
    private let storageDirectory: URL?
    private let diskQueue = DispatchQueue(label: "com.openlens.SessionCacheStore.disk", qos: .utility)

    private var catalogsByScope: [String: CachedCatalogSnapshot] = [:]
    private var transcriptsByKey: [TranscriptKey: CachedTranscriptSnapshot] = [:]
    private var transcriptLRUOrder: [TranscriptKey] = []
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    init(
        storageDirectory: URL? = nil,
        maximumInMemorySessions: Int = SessionCacheStore.defaultMaximumInMemorySessions,
        maximumDiskTranscripts: Int = SessionCacheStore.defaultMaximumDiskTranscripts
    ) {
        self.storageDirectory = storageDirectory
        self.maximumInMemorySessions = max(1, maximumInMemorySessions)
        self.maximumDiskTranscripts = max(1, maximumDiskTranscripts)

        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearMemoryCache()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    // MARK: - Memory Management

    func clearMemoryCache() {
        transcriptsByKey.removeAll()
        transcriptLRUOrder.removeAll()
    }

    func clearAll(forServerScope rawScope: String?) {
        let scope = Self.normalizedScope(rawScope)
        catalogsByScope.removeValue(forKey: scope)
        let matchingKeys = transcriptsByKey.keys.filter { $0.scope == scope }
        for key in matchingKeys {
            transcriptsByKey.removeValue(forKey: key)
        }
        transcriptLRUOrder.removeAll { $0.scope == scope }

        guard let scopeDir = scopeDirectory(forNormalizedScope: scope) else { return }
        diskQueue.async {
            try? FileManager.default.removeItem(at: scopeDir)
        }
    }

    // MARK: - Session Catalog Cache

    func loadCatalog(serverScope rawScope: String?) -> CachedCatalogSnapshot? {
        guard let rawScope, !rawScope.isEmpty else { return nil }
        let scope = Self.normalizedScope(rawScope)
        if let memory = catalogsByScope[scope] {
            return memory
        }
        guard let url = catalogFileURL(forNormalizedScope: scope),
              let data = try? Data(contentsOf: url),
              let decoded = Self.decodeCatalogPayload(from: data),
              decoded.schemaVersion == Self.currentSchemaVersion else {
            return nil
        }

        let snapshot = CachedCatalogSnapshot(
            rootSessions: decoded.rootSessions,
            childSessions: decoded.childSessions,
            projects: decoded.projects.map {
                OCProject(id: $0.id, worktree: $0.worktree, vcsDir: $0.vcsDir, vcs: $0.vcs)
            },
            viewedMarkers: decoded.viewedMarkers,
            savedAt: decoded.savedAt
        )
        catalogsByScope[scope] = snapshot
        return snapshot
    }

    func saveCatalog(
        serverScope rawScope: String?,
        rootSessions: [OCSession],
        childSessions: [OCSession],
        projects: [OCProject],
        viewedMarkers: [String: Double]
    ) {
        guard let rawScope, !rawScope.isEmpty else { return }
        let scope = Self.normalizedScope(rawScope)
        let boundedRoots = Array(rootSessions.prefix(Self.maximumPersistedRootSessions))
        let boundedChildren = Array(childSessions.prefix(Self.maximumPersistedChildSessions))
        let now = Date()

        let snapshot = CachedCatalogSnapshot(
            rootSessions: boundedRoots,
            childSessions: boundedChildren,
            projects: projects,
            viewedMarkers: viewedMarkers,
            savedAt: now
        )
        catalogsByScope[scope] = snapshot

        guard let fileURL = catalogFileURL(forNormalizedScope: scope) else { return }
        let payload = PersistedCatalogPayload(
            schemaVersion: Self.currentSchemaVersion,
            savedAt: now,
            rootSessions: boundedRoots,
            childSessions: boundedChildren,
            projects: projects.map {
                PersistedProjectRecord(id: $0.id, worktree: $0.worktree, vcsDir: $0.vcsDir, vcs: $0.vcs)
            },
            viewedMarkers: viewedMarkers
        )
        diskQueue.async {
            Self.writeAtomically(payload, to: fileURL)
        }
    }

    // MARK: - Session Transcript Cache

    func transcript(serverScope rawScope: String?, sessionID: String) -> CachedTranscriptSnapshot? {
        guard !sessionID.isEmpty else { return nil }
        let scope = Self.normalizedScope(rawScope)
        let key = TranscriptKey(scope: scope, sessionID: sessionID)

        if let hit = transcriptsByKey[key] {
            touchLRU(key)
            return hit
        }

        guard let fileURL = transcriptFileURL(forNormalizedScope: scope, sessionID: sessionID),
              let data = try? Data(contentsOf: fileURL),
              let decoded = Self.decodeTranscriptPayload(from: data),
              decoded.schemaVersion == Self.currentSchemaVersion,
              decoded.session.id == sessionID else {
            return nil
        }

        let restoredMessages = decoded.messages.map { record -> ChatMessage in
            let role = OCMessageRole(rawValue: record.roleRawValue) ?? .assistant
            return ChatMessage(
                id: record.id,
                role: role,
                content: record.content,
                parts: record.parts,
                isStreaming: false,
                createdAt: record.createdAt,
                cost: record.cost,
                tokens: record.tokens,
                modelID: record.modelID,
                providerID: record.providerID,
                finish: record.finish,
                parentUserMessageID: record.parentUserMessageID
            )
        }

        let snapshot = CachedTranscriptSnapshot(
            session: decoded.session,
            messages: restoredMessages,
            contextEntries: [],
            entryOrder: decoded.entryOrder,
            olderCursor: decoded.olderCursor,
            todos: decoded.todos,
            hiddenTodoCount: decoded.hiddenTodoCount,
            turnDiffSummariesByMessageID: [:],
            cachedAt: decoded.savedAt
        )
        insertIntoLRU(snapshot, for: key)
        return snapshot
    }

    func saveTranscript(
        serverScope rawScope: String?,
        session: OCSession,
        messages: [ChatMessage],
        contextEntries: [SessionContextEntry],
        entryOrder: [String],
        olderCursor: String?,
        todos: [OCTodo],
        hiddenTodoCount: Int,
        turnDiffSummaries: [String: [TurnFileChangeSummary]] = [:]
    ) {
        guard !session.id.isEmpty else { return }
        if messages.isEmpty && contextEntries.isEmpty && todos.isEmpty {
            return
        }

        let scope = Self.normalizedScope(rawScope)
        let key = TranscriptKey(scope: scope, sessionID: session.id)

        let recentMessages = Array(messages.suffix(Self.maximumCachedMessagesPerSession))
        let droppedEarlierMessages = messages.count > recentMessages.count
        let cacheableMessages: [ChatMessage] = recentMessages.compactMap { msg in
            guard msg.content.utf8.count <= Self.maximumSingleMessageCachedUTF8Bytes else {
                return nil
            }
            if !msg.isStreaming {
                return msg
            }
            // Snapshot an in-flight message as a static preview so switching back
            // shows its latest progress immediately before SSE/REST catches up.
            let matSnap = msg.streamingMaterializationSnapshot()
            guard matSnap.estimatedCharacterCount <= Self.maximumSingleMessageCachedUTF8Bytes else {
                return nil
            }
            let materialized = ChatMessage.materialize(matSnap)
            let snap = ChatMessage(
                id: msg.id,
                role: msg.role,
                content: materialized.content,
                parts: msg.parts,
                isStreaming: false,
                createdAt: msg.createdAt,
                cost: msg.cost,
                tokens: msg.tokens,
                modelID: msg.modelID,
                providerID: msg.providerID,
                finish: msg.finish,
                parentUserMessageID: msg.parentUserMessageID
            )
            return snap
        }

        guard !cacheableMessages.isEmpty || !todos.isEmpty else { return }

        let boundedContexts = Array(contextEntries.suffix(Self.maximumCachedContextEntriesPerSession))
        let keptIDs = Set(cacheableMessages.map(\.id)).union(boundedContexts.map(\.id))
        let filteredOrder = entryOrder.filter { keptIDs.contains($0) }
        let resolvedOlderCursor = olderCursor ?? (droppedEarlierMessages ? nil : olderCursor)

        var relevantDiffs: [String: [TurnFileChangeSummary]] = [:]
        for message in cacheableMessages {
            if let existing = turnDiffSummaries[message.id] {
                relevantDiffs[message.id] = existing
            } else if !message.turnFileChanges.isEmpty {
                relevantDiffs[message.id] = message.turnFileChanges
            }
        }

        let now = Date()
        let snapshot = CachedTranscriptSnapshot(
            session: session,
            messages: cacheableMessages,
            contextEntries: boundedContexts,
            entryOrder: filteredOrder,
            olderCursor: resolvedOlderCursor,
            todos: todos,
            hiddenTodoCount: hiddenTodoCount,
            turnDiffSummariesByMessageID: relevantDiffs,
            cachedAt: now
        )
        insertIntoLRU(snapshot, for: key)

        guard let transcriptsDir = transcriptsDirectory(forNormalizedScope: scope),
              let fileURL = transcriptFileURL(forNormalizedScope: scope, sessionID: session.id) else {
            return
        }

        let persistedMessages: [PersistedMessageRecord] = cacheableMessages.map { msg in
            let safeContent: String = msg.content.utf8.count <= Self.maximumDiskMessageUTF8Bytes
                ? msg.content
                : StreamDisplayValue.preview(msg.content, maximumBytes: Self.maximumDiskMessageUTF8Bytes)
            let safeParts = msg.parts.filter { part in
                (part.text?.utf8.count ?? 0) <= Self.maximumDiskMessageUTF8Bytes
            }
            return PersistedMessageRecord(
                id: msg.id,
                roleRawValue: msg.role.rawValue,
                content: safeContent,
                parts: safeParts,
                createdAt: msg.createdAt,
                cost: msg.cost,
                tokens: msg.tokens,
                modelID: msg.modelID,
                providerID: msg.providerID,
                finish: msg.finish,
                parentUserMessageID: msg.parentUserMessageID
            )
        }

        let payload = PersistedTranscriptPayload(
            schemaVersion: Self.currentSchemaVersion,
            savedAt: now,
            session: session,
            messages: persistedMessages,
            entryOrder: filteredOrder,
            olderCursor: resolvedOlderCursor,
            todos: todos,
            hiddenTodoCount: hiddenTodoCount
        )
        let maxFiles = maximumDiskTranscripts
        diskQueue.async {
            Self.writeAtomically(payload, to: fileURL)
            Self.pruneOldTranscriptFiles(in: transcriptsDir, keeping: maxFiles)
        }
    }

    func removeSession(serverScope rawScope: String?, sessionID: String) {
        guard !sessionID.isEmpty else { return }
        let scope = Self.normalizedScope(rawScope)
        let key = TranscriptKey(scope: scope, sessionID: sessionID)
        transcriptsByKey.removeValue(forKey: key)
        transcriptLRUOrder.removeAll { $0 == key }

        if let existingCatalog = catalogsByScope[scope] {
            catalogsByScope[scope] = CachedCatalogSnapshot(
                rootSessions: existingCatalog.rootSessions.filter { $0.id != sessionID },
                childSessions: existingCatalog.childSessions.filter { $0.id != sessionID },
                projects: existingCatalog.projects,
                viewedMarkers: existingCatalog.viewedMarkers,
                savedAt: existingCatalog.savedAt
            )
        }

        guard let fileURL = transcriptFileURL(forNormalizedScope: scope, sessionID: sessionID) else { return }
        diskQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            diskQueue.async {
                continuation.resume()
            }
        }
    }

    // MARK: - Private Helpers

    private func insertIntoLRU(_ snapshot: CachedTranscriptSnapshot, for key: TranscriptKey) {
        transcriptsByKey[key] = snapshot
        touchLRU(key)
        while transcriptLRUOrder.count > maximumInMemorySessions {
            let evicted = transcriptLRUOrder.removeFirst()
            transcriptsByKey.removeValue(forKey: evicted)
        }
    }

    private func touchLRU(_ key: TranscriptKey) {
        transcriptLRUOrder.removeAll { $0 == key }
        transcriptLRUOrder.append(key)
    }

    private static func normalizedScope(_ rawScope: String?) -> String {
        guard let trimmed = rawScope?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return "local"
        }
        return trimmed.lowercased()
    }

    private func scopeDirectory(forNormalizedScope scope: String) -> URL? {
        guard let storageDirectory else { return nil }
        return storageDirectory.appendingPathComponent(Self.hashedFileName(for: scope), isDirectory: true)
    }

    private func catalogFileURL(forNormalizedScope scope: String) -> URL? {
        scopeDirectory(forNormalizedScope: scope)?.appendingPathComponent("catalog.json", isDirectory: false)
    }

    private func transcriptsDirectory(forNormalizedScope scope: String) -> URL? {
        scopeDirectory(forNormalizedScope: scope)?.appendingPathComponent("transcripts", isDirectory: true)
    }

    private func transcriptFileURL(forNormalizedScope scope: String, sessionID: String) -> URL? {
        transcriptsDirectory(forNormalizedScope: scope)?
            .appendingPathComponent("\(Self.hashedFileName(for: sessionID)).json", isDirectory: false)
    }

    nonisolated private static func hashedFileName(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func decodeCatalogPayload(from data: Data) -> PersistedCatalogPayload? {
        try? JSONDecoder().decode(PersistedCatalogPayload.self, from: data)
    }

    nonisolated private static func decodeTranscriptPayload(from data: Data) -> PersistedTranscriptPayload? {
        try? JSONDecoder().decode(PersistedTranscriptPayload.self, from: data)
    }

    nonisolated private static func writeAtomically<T: Encodable>(_ value: T, to fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Disk cache is best-effort only.
        }
    }

    nonisolated private static func pruneOldTranscriptFiles(in directory: URL, keeping maximumCount: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > maximumCount else {
            return
        }

        let sorted = urls.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        for staleURL in sorted.dropFirst(maximumCount) {
            try? fm.removeItem(at: staleURL)
        }
    }
}
