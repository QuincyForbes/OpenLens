import Foundation
import Observation

nonisolated struct MeridianWindowQuota: Codable, Hashable, Sendable, Identifiable {
    let type: String
    let utilization: Double?
    let resetsAt: Double?

    var id: String { type }

    var label: String {
        switch type {
        case "five_hour": "5h"
        case "seven_day": "7d"
        case "seven_day_fable": "Fable 7d"
        default: type.replacingOccurrences(of: "_", with: " ")
        }
    }

    var remainingFraction: Double {
        let used = min(max(utilization ?? 0, 0), 1)
        return 1.0 - used
    }

    var remainingPercent: Int {
        Int((remainingFraction * 100.0).rounded())
    }

    var resetDate: Date? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        return Date(timeIntervalSince1970: resetsAt / 1000.0)
    }
}

nonisolated struct MeridianAccountProfile: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String
    let email: String?
    let planLabel: String?
    let allowance: String?
    let isActive: Bool
    let windows: [MeridianWindowQuota]
    let stale: Bool
    let failureReason: String?

    var displayName: String {
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return id
    }

    var providerBadge: String {
        provider.lowercased().contains("chatgpt") ? "ChatGPT" : "Claude"
    }

    var subtitle: String {
        let parts = [providerBadge, planLabel, allowance]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? id : parts.joined(separator: " · ")
    }
}

nonisolated struct MeridianModelUsageSummary: Identifiable, Hashable, Sendable {
    let id: String
    let requests: Int
    let estimatedUsd: Double?
}

nonisolated struct MeridianUsageSnapshot: Equatable, Sendable {
    let endpointURL: String
    let engineVersion: String?
    let routingMode: String?
    let profiles: [MeridianAccountProfile]
    let totalRequests24h: Int?
    let totalUsd24h: Double?
    let cacheHitRate24h: Double?
    let models24h: [MeridianModelUsageSummary]
    let fetchedAt: Date
}

@MainActor @Observable
final class MeridianUsageService {
    enum State: Equatable {
        case idle
        case loading
        case loaded(MeridianUsageSnapshot)
        case failed(String)
    }

    nonisolated static let endpointPreferenceKey = "meridianEndpointURL"

    private let connection: ConnectionManager
    private let userDefaults: UserDefaults
    private let loader: @Sendable (URL) async throws -> MeridianUsageSnapshot

    private(set) var state: State = .idle
    private(set) var switchingProfileID: String?

    var customEndpointURL: String {
        didSet {
            let trimmed = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                userDefaults.removeObject(forKey: Self.endpointPreferenceKey)
            } else {
                userDefaults.set(trimmed, forKey: Self.endpointPreferenceKey)
            }
        }
    }

    init(
        connection: ConnectionManager,
        userDefaults: UserDefaults = .standard,
        loader: @escaping @Sendable (URL) async throws -> MeridianUsageSnapshot = MeridianUsageService.fetchSnapshot
    ) {
        self.connection = connection
        self.userDefaults = userDefaults
        self.loader = loader
        self.customEndpointURL = userDefaults.string(forKey: Self.endpointPreferenceKey) ?? ""
    }

    var snapshot: MeridianUsageSnapshot? {
        if case .loaded(let snapshot) = state { return snapshot }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var candidateBaseURLs: [URL] {
        Self.resolveCandidateURLs(
            customEndpoint: customEndpointURL,
            connectedServerURL: connection.serverURL
        )
    }

    nonisolated static func resolveCandidateURLs(
        customEndpoint: String,
        connectedServerURL: URL?
    ) -> [URL] {
        var candidates: [URL] = []
        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            if let url = URL(string: normalized), url.host != nil {
                candidates.append(url)
            }
        }
        if let host = connectedServerURL?.host(percentEncoded: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            if let httpURL = URL(string: "http://\(formattedHost):3456") {
                candidates.append(httpURL)
            }
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    func refresh() async {
        if ScreenshotFixtures.isEnabled {
            state = .loaded(Self.fixtureSnapshot)
            return
        }
        let candidates = candidateBaseURLs
        guard !candidates.isEmpty else {
            state = .failed("Connect to a server or set a Meridian URL (for example http://host:3456).")
            return
        }

        let previous = snapshot
        if previous == nil {
            state = .loading
        }

        var lastError: Error?
        for baseURL in candidates {
            do {
                let loaded = try await loader(baseURL)
                try Task.checkCancellation()
                state = .loaded(loaded)
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
            }
        }

        if let previous {
            state = .loaded(previous)
        } else {
            state = .failed(lastError?.localizedDescription ?? "Could not reach Meridian dashboard.")
        }
    }

    func activateProfile(_ profileID: String) async {
        guard switchingProfileID == nil else { return }
        let baseString = snapshot?.endpointURL ?? candidateBaseURLs.first?.absoluteString
        guard let baseString, let baseURL = URL(string: baseString) else { return }

        switchingProfileID = profileID
        defer { switchingProfileID = nil }

        do {
            try await Self.postActiveProfile(profileID, baseURL: baseURL)
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Networking & Decoding

    nonisolated static func fetchSnapshot(baseURL: URL) async throws -> MeridianUsageSnapshot {
        let session = makeSession()
        async let quotaData = fetchData(path: "/v1/usage/quota/all", baseURL: baseURL, session: session)
        async let profilesData = try? fetchData(path: "/profiles/list", baseURL: baseURL, session: session)
        async let healthData = try? fetchData(path: "/health", baseURL: baseURL, session: session)
        async let telemetryData = try? fetchData(path: "/telemetry/summary?window=86400000", baseURL: baseURL, session: session)

        let quota = try await quotaData
        let profiles = await profilesData
        let health = await healthData
        let telemetry = await telemetryData

        return try decodeSnapshot(
            baseURL: baseURL,
            quotaData: quota,
            profilesData: profiles,
            healthData: health,
            telemetryData: telemetry
        )
    }

    nonisolated static func decodeSnapshot(
        baseURL: URL,
        quotaData: Data,
        profilesData: Data?,
        healthData: Data?,
        telemetryData: Data?,
        now: Date = .now
    ) throws -> MeridianUsageSnapshot {
        let decoder = JSONDecoder()
        let quota = try decoder.decode(QuotaResponse.self, from: quotaData)
        let profileList = profilesData.flatMap { try? decoder.decode(ProfilesListResponse.self, from: $0) }
        let health = healthData.flatMap { try? decoder.decode(HealthResponse.self, from: $0) }
        let telemetry = telemetryData.flatMap { try? decoder.decode(TelemetryResponse.self, from: $0) }

        let metadataByID = Dictionary(
            uniqueKeysWithValues: (profileList?.profiles ?? []).map { ($0.id, $0) }
        )
        let activeIDs = Set(
            [quota.activeProfile, profileList?.activeProfile].compactMap { $0 }
                + Array((quota.activeProfiles ?? [:]).values)
                + Array((profileList?.activeProfiles ?? [:]).values)
        )

        let mergedProfiles = quota.profiles.map { item -> MeridianAccountProfile in
            let meta = metadataByID[item.id]
            let provider = item.provider ?? meta?.provider ?? item.type ?? meta?.type ?? "claude"
            return MeridianAccountProfile(
                id: item.id,
                provider: provider,
                email: meta?.email,
                planLabel: meta?.planName ?? meta?.planLabel ?? item.planTier,
                allowance: meta?.allowance,
                isActive: item.isActive == true || meta?.isActive == true || activeIDs.contains(item.id),
                windows: item.windows ?? [],
                stale: item.stale ?? false,
                failureReason: item.failure?.reason ?? item.error
            )
        }

        let models24h: [MeridianModelUsageSummary] = (telemetry?.byModel ?? [:])
            .map { key, value in
                MeridianModelUsageSummary(
                    id: key,
                    requests: value.count ?? 0,
                    estimatedUsd: telemetry?.costEstimate?.byModel?[key]?.estimatedUsd
                )
            }
            .sorted { lhs, rhs in
                if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
                return lhs.id < rhs.id
            }

        return MeridianUsageSnapshot(
            endpointURL: baseURL.absoluteString,
            engineVersion: health?.version,
            routingMode: profileList?.routing,
            profiles: mergedProfiles,
            totalRequests24h: telemetry?.totalRequests,
            totalUsd24h: telemetry?.costEstimate?.totalUsd,
            cacheHitRate24h: telemetry?.tokenUsage?.avgCacheHitRate,
            models24h: models24h,
            fetchedAt: now
        )
    }

    nonisolated private static func postActiveProfile(_ profileID: String, baseURL: URL) async throws {
        guard let url = URL(string: "/profiles/active", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["profile": profileID])
        let session = makeSession()
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    nonisolated private static func fetchData(path: String, baseURL: URL, session: URLSession) async throws -> Data {
        let baseString = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard let url = URL(string: baseString + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    nonisolated private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }

    nonisolated static let fixtureSnapshot = MeridianUsageSnapshot(
        endpointURL: "http://demo.openlens.local:3456",
        engineVersion: "1.85.0",
        routingMode: "priority",
        profiles: [
            MeridianAccountProfile(
                id: "claude-personal",
                provider: "claude-max",
                email: "developer@openlens.dev",
                planLabel: "Max 20x",
                allowance: "20x",
                isActive: true,
                windows: [
                    MeridianWindowQuota(type: "five_hour", utilization: 0.12, resetsAt: nil),
                    MeridianWindowQuota(type: "seven_day", utilization: 0.64, resetsAt: nil)
                ],
                stale: false,
                failureReason: nil
            )
        ],
        totalRequests24h: 184,
        totalUsd24h: 42.80,
        cacheHitRate24h: 0.89,
        models24h: [
            MeridianModelUsageSummary(id: "claude-sonnet-4-5", requests: 120, estimatedUsd: 28.40),
            MeridianModelUsageSummary(id: "gpt-5.4", requests: 64, estimatedUsd: 14.40)
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_793_458_800)
    )

    // MARK: - Wire Models

    private struct QuotaResponse: Decodable {
        let profiles: [QuotaProfile]
        let activeProfile: String?
        let activeProfiles: [String: String]?
    }

    private struct QuotaProfile: Decodable {
        let id: String
        let isActive: Bool?
        let type: String?
        let provider: String?
        let planTier: String?
        let windows: [MeridianWindowQuota]?
        let stale: Bool?
        let error: String?
        let failure: QuotaFailure?
    }

    private struct QuotaFailure: Decodable {
        let reason: String?
    }

    private struct ProfilesListResponse: Decodable {
        let profiles: [ProfileMetadata]
        let activeProfile: String?
        let activeProfiles: [String: String]?
        let routing: String?
    }

    private struct ProfileMetadata: Decodable {
        let id: String
        let type: String?
        let provider: String?
        let isActive: Bool?
        let email: String?
        let allowance: String?
        let planLabel: String?
        let planName: String?
    }

    private struct HealthResponse: Decodable {
        let version: String?
    }

    private struct TelemetryResponse: Decodable {
        struct ModelEntry: Decodable {
            let count: Int?
        }
        struct TokenUsage: Decodable {
            let avgCacheHitRate: Double?
        }
        struct CostModelEntry: Decodable {
            let estimatedUsd: Double?
        }
        struct CostEstimate: Decodable {
            let totalUsd: Double?
            let byModel: [String: CostModelEntry]?
        }

        let totalRequests: Int?
        let byModel: [String: ModelEntry]?
        let tokenUsage: TokenUsage?
        let costEstimate: CostEstimate?
    }
}
