import Foundation
import Observation

nonisolated struct GitHubRepositoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let fullName: String
    let ownerLogin: String
    let description: String?
    let cloneURL: String
    let htmlURL: String
    let isPrivate: Bool
    let stargazersCount: Int
    let language: String?
    let updatedAt: Date?

    init(
        id: String? = nil,
        name: String,
        fullName: String,
        ownerLogin: String,
        description: String? = nil,
        cloneURL: String,
        htmlURL: String,
        isPrivate: Bool = false,
        stargazersCount: Int = 0,
        language: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id ?? fullName.lowercased()
        self.name = name
        self.fullName = fullName
        self.ownerLogin = ownerLogin
        self.description = description
        self.cloneURL = cloneURL
        self.htmlURL = htmlURL
        self.isPrivate = isPrivate
        self.stargazersCount = stargazersCount
        self.language = language
        self.updatedAt = updatedAt
    }
}

nonisolated struct ClonedRepositorySelection: Hashable, Sendable {
    let repository: GitHubRepositoryItem
    let parentDirectory: String
    let targetDirectory: String

    var initialPrompt: String {
        """
        Clone `\(repository.cloneURL)` into `\(targetDirectory)` if it is not already cloned there, then move or switch this session into `\(targetDirectory)` and summarize the repository structure.
        """
    }
}

@MainActor @Observable
final class GitHubRepositoryService {
    enum Mode: String, CaseIterable, Identifiable {
        case accessible = "My Repos"
        case globalSearch = "Search GitHub"

        var id: String { rawValue }
    }

    nonisolated static let tokenPreferenceKey = "github.personalAccessToken"
    nonisolated static let ownersPreferenceKey = "github.knownOwners"
    nonisolated static let defaultOwners = ["QuincyForbes"]

    private let userDefaults: UserDefaults
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private(set) var accessibleRepositories: [GitHubRepositoryItem] = []
    private(set) var searchResults: [GitHubRepositoryItem] = []
    private(set) var isLoadingAccessible = false
    private(set) var isSearchingGitHub = false
    private(set) var errorMessage: String?

    var personalAccessToken: String {
        didSet {
            let trimmed = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                userDefaults.removeObject(forKey: Self.tokenPreferenceKey)
            } else {
                userDefaults.set(trimmed, forKey: Self.tokenPreferenceKey)
            }
        }
    }

    var ownersText: String {
        didSet {
            let trimmed = ownersText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                userDefaults.removeObject(forKey: Self.ownersPreferenceKey)
            } else {
                userDefaults.set(trimmed, forKey: Self.ownersPreferenceKey)
            }
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.userDefaults = userDefaults
        self.dataLoader = dataLoader
        self.personalAccessToken = userDefaults.string(forKey: Self.tokenPreferenceKey) ?? ""
        self.ownersText = userDefaults.string(forKey: Self.ownersPreferenceKey) ?? Self.defaultOwners.joined(separator: ", ")
    }

    var configuredOwners: [String] {
        let parsed = ownersText
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parsed.isEmpty ? Self.defaultOwners : parsed
    }

    func loadAccessibleRepositories(force: Bool = false) async {
        if ScreenshotFixtures.isEnabled {
            accessibleRepositories = Self.fixtureRepositories
            return
        }
        if !force, !accessibleRepositories.isEmpty { return }
        guard !isLoadingAccessible else { return }

        isLoadingAccessible = true
        errorMessage = nil
        defer { isLoadingAccessible = false }

        let token = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let owners = configuredOwners
        var collected: [GitHubRepositoryItem] = []

        do {
            if !token.isEmpty {
                let authenticated = try await fetchRepositories(
                    urlString: "https://api.github.com/user/repos?sort=updated&per_page=100&affiliation=owner,collaborator,organization_member",
                    token: token
                )
                collected.append(contentsOf: authenticated)
            }

            for owner in owners {
                guard let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
                if let userRepos = try? await fetchRepositories(
                    urlString: "https://api.github.com/users/\(encodedOwner)/repos?sort=updated&per_page=100",
                    token: token
                ) {
                    collected.append(contentsOf: userRepos)
                }
            }

            accessibleRepositories = Self.deduplicatedAndSorted(collected)
            if accessibleRepositories.isEmpty {
                errorMessage = "No repositories found. Check your GitHub username or personal access token."
            }
        } catch is CancellationError {
            return
        } catch {
            if collected.isEmpty {
                errorMessage = "Could not load GitHub repositories: \(error.localizedDescription)"
            } else {
                accessibleRepositories = Self.deduplicatedAndSorted(collected)
            }
        }
    }

    func searchGitHub(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        if ScreenshotFixtures.isEnabled {
            searchResults = Self.fixtureRepositories.filter {
                $0.fullName.localizedCaseInsensitiveContains(trimmed)
                    || ($0.description?.localizedCaseInsensitiveContains(trimmed) == true)
            }
            return
        }

        isSearchingGitHub = true
        errorMessage = nil
        defer { isSearchingGitHub = false }

        let token = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/search/repositories?q=\(encoded)&sort=stars&order=desc&per_page=30") else {
            errorMessage = "Invalid search query."
            return
        }

        do {
            let request = Self.makeGitHubRequest(url: url, token: token)
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            var items = try Self.decodeSearchResponse(from: data)
            if let direct = Self.parseDirectRepository(from: trimmed),
               !items.contains(where: { $0.fullName.caseInsensitiveCompare(direct.fullName) == .orderedSame }) {
                items.insert(direct, at: 0)
            }
            searchResults = items
        } catch is CancellationError {
            return
        } catch {
            if let direct = Self.parseDirectRepository(from: trimmed) {
                searchResults = [direct]
            } else {
                errorMessage = "GitHub search failed: \(error.localizedDescription)"
            }
        }
    }

    func filteredAccessibleRepositories(query: String) -> [GitHubRepositoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accessibleRepositories }
        var matches = accessibleRepositories.filter { repo in
            repo.name.localizedCaseInsensitiveContains(trimmed)
                || repo.fullName.localizedCaseInsensitiveContains(trimmed)
                || (repo.description?.localizedCaseInsensitiveContains(trimmed) == true)
                || (repo.language?.localizedCaseInsensitiveContains(trimmed) == true)
        }
        if let direct = Self.parseDirectRepository(from: trimmed),
           !matches.contains(where: { $0.fullName.caseInsensitiveCompare(direct.fullName) == .orderedSame }) {
            matches.insert(direct, at: 0)
        }
        return matches
    }

    // MARK: - Helpers

    nonisolated static func defaultParentDirectory(from workspaceDirectories: [String]) -> String {
        for raw in workspaceDirectories {
            guard let normalized = WorkspaceSelectionBuilder.normalizedDirectory(raw),
                  normalized != "/" else { continue }
            if WorkspaceSelectionBuilder.isWindowsAbsolutePath(normalized) {
                let parts = normalized.split(separator: "\\", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return normalized }
                return parts.dropLast().joined(separator: "\\")
            } else {
                let parent = (normalized as NSString).deletingLastPathComponent
                if !parent.isEmpty, parent != "/" {
                    return parent
                }
            }
        }
        return "/workspace"
    }

    nonisolated static func targetDirectory(parentDirectory: String, repositoryName: String) -> String {
        let cleanParent = WorkspaceSelectionBuilder.normalizedDirectory(parentDirectory) ?? parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanParent.isEmpty else { return cleanName }
        if WorkspaceSelectionBuilder.isWindowsAbsolutePath(cleanParent) || cleanParent.contains("\\") {
            let trimmed = cleanParent.hasSuffix("\\") ? String(cleanParent.dropLast()) : cleanParent
            return "\(trimmed)\\\(cleanName)"
        } else {
            let trimmed = cleanParent.hasSuffix("/") && cleanParent.count > 1 ? String(cleanParent.dropLast()) : cleanParent
            return trimmed == "/" ? "/\(cleanName)" : "\(trimmed)/\(cleanName)"
        }
    }

    nonisolated static func parseDirectRepository(from input: String) -> GitHubRepositoryItem? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if trimmed.hasPrefix("git@github.com:") {
            trimmed = String(trimmed.dropFirst("git@github.com:".count))
        } else if let url = URL(string: trimmed),
                  let host = url.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" {
            trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        if trimmed.hasSuffix(".git") {
            trimmed = String(trimmed.dropLast(4))
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard owner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              repo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        let fullName = "\(owner)/\(repo)"
        return GitHubRepositoryItem(
            name: repo,
            fullName: fullName,
            ownerLogin: owner,
            description: "Direct GitHub repository reference",
            cloneURL: "https://github.com/\(fullName).git",
            htmlURL: "https://github.com/\(fullName)"
        )
    }

    private func fetchRepositories(urlString: String, token: String) async throws -> [GitHubRepositoryItem] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let request = Self.makeGitHubRequest(url: url, token: token)
        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeRepositories(from: data)
    }

    nonisolated private static func makeGitHubRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenLens-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    nonisolated static func decodeRepositories(from data: Data) throws -> [GitHubRepositoryItem] {
        let decoder = makeDecoder()
        let raw = try decoder.decode([WireRepository].self, from: data)
        return raw.map(\.domainItem)
    }

    nonisolated static func decodeSearchResponse(from data: Data) throws -> [GitHubRepositoryItem] {
        let decoder = makeDecoder()
        let raw = try decoder.decode(WireSearchResponse.self, from: data)
        return raw.items.map(\.domainItem)
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func deduplicatedAndSorted(_ items: [GitHubRepositoryItem]) -> [GitHubRepositoryItem] {
        var seen: Set<String> = []
        var unique: [GitHubRepositoryItem] = []
        for item in items {
            let key = item.fullName.lowercased()
            if seen.insert(key).inserted {
                unique.append(item)
            }
        }
        return unique.sorted { lhs, rhs in
            if let lDate = lhs.updatedAt, let rDate = rhs.updatedAt, lDate != rDate {
                return lDate > rDate
            }
            return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
        }
    }

    nonisolated static let fixtureRepositories: [GitHubRepositoryItem] = [
        GitHubRepositoryItem(
            name: "OpenLens",
            fullName: "QuincyForbes/OpenLens",
            ownerLogin: "QuincyForbes",
            description: "Native iOS companion app for OpenCode.",
            cloneURL: "https://github.com/QuincyForbes/OpenLens.git",
            htmlURL: "https://github.com/QuincyForbes/OpenLens",
            isPrivate: false,
            stargazersCount: 42,
            language: "Swift"
        ),
        GitHubRepositoryItem(
            name: "akvros",
            fullName: "QuincyForbes/akvros",
            ownerLogin: "QuincyForbes",
            description: "Autonomous workflow & agent tooling.",
            cloneURL: "https://github.com/QuincyForbes/akvros.git",
            htmlURL: "https://github.com/QuincyForbes/akvros",
            isPrivate: true,
            stargazersCount: 12,
            language: "TypeScript"
        )
    ]

    private struct WireSearchResponse: Decodable {
        let items: [WireRepository]
    }

    private struct WireRepository: Decodable {
        struct Owner: Decodable {
            let login: String
        }

        let id: Int
        let name: String
        let fullName: String
        let owner: Owner
        let description: String?
        let cloneURL: String?
        let htmlURL: String
        let isPrivate: Bool?
        let stargazersCount: Int?
        let language: String?
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, name, owner, description, language
            case fullName = "full_name"
            case cloneURL = "clone_url"
            case htmlURL = "html_url"
            case isPrivate = "private"
            case stargazersCount = "stargazers_count"
            case updatedAt = "updated_at"
        }

        var domainItem: GitHubRepositoryItem {
            GitHubRepositoryItem(
                id: String(id),
                name: name,
                fullName: fullName,
                ownerLogin: owner.login,
                description: description,
                cloneURL: cloneURL ?? "https://github.com/\(fullName).git",
                htmlURL: htmlURL,
                isPrivate: isPrivate ?? false,
                stargazersCount: stargazersCount ?? 0,
                language: language,
                updatedAt: updatedAt
            )
        }
    }
}
