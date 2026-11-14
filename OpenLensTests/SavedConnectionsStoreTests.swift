import Foundation
import Testing
@testable import OpenLens

struct SavedConnectionsStoreTests {

    @Test func keepsRecentConnectionsForSuggestions() {
        let store = SavedConnectionsStore(initialConnections: [])

        store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: ""
        )
        store.saveConnection(
            serverURL: "http://10.0.0.12:4096",
            username: "opencode",
            password: "secret"
        )

        #expect(store.connections.count == 2)
        #expect(Set(store.suggestions(for: "").map(\.serverURL)) == Set([
            "http://192.168.1.50:4096",
            "http://10.0.0.12:4096",
        ]))
        #expect(store.suggestions(for: "10.0").map(\.serverURL) == [
            "http://10.0.0.12:4096",
        ])
    }

    @Test func capsHistoryToMostRecentConnections() {
        let connections = (0..<23).map { index in
            SavedConnection(
                id: "\(index)",
                serverURL: "http://192.168.1.\(index):4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let store = SavedConnectionsStore(initialConnections: connections)

        #expect(store.connections.map(\.id) == (3..<23).reversed().map(String.init))
    }

    @Test func reusingSavedConnectionMovesItToFront() {
        let store = SavedConnectionsStore(initialConnections: [
            SavedConnection(
                id: "newer",
                serverURL: "http://10.0.0.12:4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: 20)
            ),
            SavedConnection(
                id: "older",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: "",
                lastConnectedAt: Date(timeIntervalSince1970: 10)
            ),
        ])

        store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "updated"
        )

        #expect(store.connections.count == 2)
        #expect(store.mostRecent?.id == "older")
        #expect(store.mostRecent?.password == "updated")
    }

    @Test func publicSnapshotFallbackRestoresAddressWithoutPassword() {
        let snapshots = [
            SavedConnectionPublicSnapshot(connection: SavedConnection(
                id: "fallback",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: "secret",
                lastConnectedAt: Date(timeIntervalSince1970: 10)
            )),
        ]

        let restored = SavedConnectionsStore.mergeKeychainConnections([], withPublicSnapshots: snapshots)

        #expect(restored.count == 1)
        #expect(restored.first?.serverURL == "http://192.168.1.50:4096")
        #expect(restored.first?.username == "opencode")
        #expect(restored.first?.password == "")
    }

    @Test func publicSnapshotMergePreservesKeychainPassword() {
        let keychainConnection = SavedConnection(
            id: "existing",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "secret",
            lastConnectedAt: Date(timeIntervalSince1970: 5)
        )
        let snapshot = SavedConnectionPublicSnapshot(connection: SavedConnection(
            id: "existing",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "",
            selectedProjectDirectory: "/Users/me/project",
            lastConnectedAt: Date(timeIntervalSince1970: 15)
        ))

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [keychainConnection],
            withPublicSnapshots: [snapshot]
        )

        #expect(restored.count == 1)
        #expect(restored.first?.password == "secret")
        #expect(restored.first?.selectedProjectDirectory == "/Users/me/project")
        #expect(restored.first?.lastConnectedAt == Date(timeIntervalSince1970: 15))
    }

    @Test func legacyRemoteProfilesAreDroppedOnLoad() {
        let direct = SavedConnection(
            id: "direct",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "secret"
        )
        let remote = SavedConnection(
            id: "remote",
            serverURL: "https://openlens.example.com",
            username: "opencode",
            password: ""
        )
        var remoteSnapshot = SavedConnectionPublicSnapshot(connection: remote)
        remoteSnapshot.remoteGatewayID = "gateway"

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [direct, remote],
            withPublicSnapshots: [SavedConnectionPublicSnapshot(connection: direct), remoteSnapshot]
        )

        #expect(restored.map(\.id) == ["direct"])
    }

    @Test func remembersRecentProjectDirectoriesNewestFirst() throws {
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: ""
        )

        store.updateProjectSelection(connectionID: connection.id, directory: "/Users/me/Alpha")
        store.updateProjectSelection(connectionID: connection.id, directory: "/Users/me/Beta")
        store.updateProjectSelection(connectionID: connection.id, directory: "/Users/me/Alpha")

        #expect(store.savedProjectSelection(connectionID: connection.id) == "/Users/me/Alpha")
        #expect(store.recentProjectSelections(connectionID: connection.id) == [
            "/Users/me/Alpha",
            "/Users/me/Beta",
        ])
    }

    @Test func remembersRecentModelSelectionsNewestFirstAndDeduplicated() {
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: ""
        )

        store.updateModelSelection(
            connectionID: connection.id,
            providerID: "anthropic",
            modelID: "claude-sonnet",
            variant: nil
        )
        store.updateModelSelection(
            connectionID: connection.id,
            providerID: "openai",
            modelID: "gpt-5",
            variant: nil
        )
        store.updateModelSelection(
            connectionID: connection.id,
            providerID: "anthropic",
            modelID: "claude-sonnet",
            variant: "high"
        )

        #expect(store.recentModelSelections(connectionID: connection.id).map(\.id) == [
            "anthropic/claude-sonnet",
            "openai/gpt-5",
        ])
    }

    @Test func recentModelSelectionsIncludesCurrentSelectionFromBeforeHistory() {
        let connection = SavedConnection(
            id: "legacy-model-selection",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "",
            selectedProviderID: "anthropic",
            selectedModelID: "claude-sonnet"
        )
        let store = SavedConnectionsStore(initialConnections: [connection])

        #expect(store.recentModelSelections(connectionID: connection.id).map(\.id) == [
            "anthropic/claude-sonnet",
        ])
    }

    @Test func persistsGlobalQuickModelAssignmentsWithVariants() {
        let suiteName = "OpenLensTests.quick-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let assignments: [ModelQuickAction: QuickModelAssignment] = [
            .code: QuickModelAssignment(
                providerID: "anthropic",
                modelID: "claude-sonnet",
                variant: "high"
            ),
            .review: QuickModelAssignment(providerID: "openai", modelID: "gpt-5"),
        ]

        AppPreferences.saveQuickModelAssignments(assignments, userDefaults: defaults)

        #expect(AppPreferences.quickModelAssignments(userDefaults: defaults) == assignments)
    }

    @Test func publicSnapshotFallbackRestoresRecentModelSelections() {
        let selections = [
            SavedModelSelection(providerID: "openai", modelID: "gpt-5"),
            SavedModelSelection(providerID: "anthropic", modelID: "claude-sonnet"),
        ]
        let connection = SavedConnection(
            id: "model-history",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "secret",
            recentModelSelections: selections,
            lastConnectedAt: Date(timeIntervalSince1970: 10)
        )

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [],
            withPublicSnapshots: [SavedConnectionPublicSnapshot(connection: connection)]
        )

        #expect(restored.first?.recentModelSelections == selections)
    }

    @Test func publicSnapshotFallbackRestoresRecentProjectDirectories() {
        let snapshots = [
            SavedConnectionPublicSnapshot(connection: SavedConnection(
                id: "workspace-history",
                serverURL: "http://192.168.1.50:4096",
                username: "opencode",
                password: "secret",
                selectedProjectDirectory: "/Users/me/Alpha",
                recentProjectDirectories: ["/Users/me/Alpha", "/Users/me/Beta"],
                lastConnectedAt: Date(timeIntervalSince1970: 10)
            )),
        ]

        let restored = SavedConnectionsStore.mergeKeychainConnections([], withPublicSnapshots: snapshots)

        #expect(restored.first?.selectedProjectDirectory == "/Users/me/Alpha")
        #expect(restored.first?.recentProjectDirectories == ["/Users/me/Alpha", "/Users/me/Beta"])
    }

    @Test func updatesAndClearsDefaultModelSelection() {
        let store = SavedConnectionsStore(initialConnections: [])
        let connection = store.saveConnection(
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: ""
        )

        store.updateDefaultModelSelection(
            connectionID: connection.id,
            providerID: "anthropic",
            modelID: "claude-sonnet-4-20250514"
        )

        #expect(store.defaultModelSelection(connectionID: connection.id)?.providerID == "anthropic")
        #expect(store.defaultModelSelection(connectionID: connection.id)?.modelID == "claude-sonnet-4-20250514")

        store.clearDefaultModelSelection(connectionID: connection.id)

        #expect(store.defaultModelSelection(connectionID: connection.id) == nil)
    }

    @Test func publicSnapshotFallbackRestoresDefaultModelSelection() {
        var connection = SavedConnection(
            id: "default-model",
            serverURL: "http://192.168.1.50:4096",
            username: "opencode",
            password: "secret",
            lastConnectedAt: Date(timeIntervalSince1970: 10)
        )
        connection.defaultProviderID = "anthropic"
        connection.defaultModelID = "claude-sonnet-4-20250514"

        let snapshots = [
            SavedConnectionPublicSnapshot(connection: connection),
        ]

        let restored = SavedConnectionsStore.mergeKeychainConnections([], withPublicSnapshots: snapshots)

        #expect(restored.first?.defaultProviderID == "anthropic")
        #expect(restored.first?.defaultModelID == "claude-sonnet-4-20250514")
    }

    @Test func encryptedCredentialFallbackStorePersistsOverwritesAndDeletesAcrossInstances() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLensCredStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let writer = EncryptedFileCredentialStore(directory: tempDirectory)
        let saved = [
            SavedConnection(
                id: "mac-lan",
                serverURL: "http://192.168.3.3:4096",
                username: "opencode",
                password: "super-secret-lan-token",
                selectedProjectDirectory: "/Users/me/OpenLens",
                alternateServerURLs: ["http://100.114.113.63:4096"]
            ),
        ]
        let payload = try JSONEncoder().encode(saved)
        #expect(writer.save(key: "saved_connections_v1", data: payload))

        // Fresh instance simulates relaunching OpenLens after restarting the Mac.
        let reader = EncryptedFileCredentialStore(directory: tempDirectory)
        let loadedData = try #require(reader.load(key: "saved_connections_v1"))
        let decoded = try JSONDecoder().decode([SavedConnection].self, from: loadedData)
        #expect(decoded.count == 1)
        #expect(decoded.first?.password == "super-secret-lan-token")
        #expect(decoded.first?.alternateServerURLs == ["http://100.114.113.63:4096"])

        // Authenticated encryption binds the key name, so another key cannot decrypt it.
        #expect(reader.load(key: "different_key") == nil)

        reader.delete(key: "saved_connections_v1")
        #expect(reader.load(key: "saved_connections_v1") == nil)
    }

    @Test func updatingConnectionViaReplacingIDPreservesWorkspaceAndModelWhilePruningStaleEphemeralPort() {
        let store = SavedConnectionsStore(initialConnections: [])
        let initial = store.saveConnection(
            serverURL: "http://192.168.3.3:54321",
            username: "opencode",
            password: "token-1",
            alternateServerURLs: ["http://100.114.113.63:4096", "https://ephemeral.opentunnel.xyz"]
        )
        store.updateProjectSelection(connectionID: initial.id, directory: "/Users/me/OpenLens")
        store.updateModelSelection(
            connectionID: initial.id,
            providerID: "anthropic",
            modelID: "claude-sonnet-4-20250514",
            variant: "high"
        )

        let updated = store.saveConnection(
            serverURL: "http://192.168.3.3:28894",
            username: "opencode",
            password: "token-1",
            alternateServerURLs: [initial.serverURL] + (initial.alternateServerURLs ?? []),
            replacingConnectionID: initial.id
        )

        #expect(store.connections.count == 1)
        #expect(updated.id == initial.id)
        #expect(updated.serverURL == "http://192.168.3.3:28894")
        #expect(store.savedProjectSelection(connectionID: initial.id) == "/Users/me/OpenLens")
        #expect(store.savedModelSelection(connectionID: initial.id)?.modelID == "claude-sonnet-4-20250514")
        // Keeps distinct Tailscale and remote origins, but drops the dead same-host ephemeral port 54321.
        #expect(updated.alternateServerURLs == [
            "http://100.114.113.63:4096",
            "https://ephemeral.opentunnel.xyz",
        ])
    }

    @Test func publicSnapshotFallbackPreservesAlternateServerURLs() {
        let connection = SavedConnection(
            id: "alt-urls",
            serverURL: "https://ephemeral.opentunnel.xyz",
            username: "opencode",
            password: "secret",
            alternateServerURLs: ["http://192.168.3.3:4096", "http://100.114.113.63:4096"],
            lastConnectedAt: Date(timeIntervalSince1970: 10)
        )

        let restored = SavedConnectionsStore.mergeKeychainConnections(
            [],
            withPublicSnapshots: [SavedConnectionPublicSnapshot(connection: connection)]
        )

        #expect(restored.first?.alternateServerURLs == [
            "http://192.168.3.3:4096",
            "http://100.114.113.63:4096",
        ])
    }
}
