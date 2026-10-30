import Foundation

/// Resolves presentation identity without rewriting the directory used for API calls.
/// Project IDs join worktrees; authoritative roots can identify sessions missing an ID.
struct SessionRepositoryIndex {
    struct Repository {
        let id: String
        let title: String
        let directory: String?
    }

    private var repositoriesBySessionID: [String: Repository] = [:]

    init(sessions: [OCSession] = [], projects: [OCProject] = []) {
        let sessions = SessionListOrganization.uniqueSessions(sessions)
        var roots: [String: String] = [:]
        for project in projects.sorted(by: { ($0.worktree ?? "") < ($1.worktree ?? "") }) {
            guard let id = Self.projectID(project.id), let path = Self.displayPath(project.worktree),
                  path != "/", roots[id] == nil else { continue }
            roots[id] = path
        }
        let rootAliases = Dictionary(grouping: roots.keys, by: { Self.pathKey(roots[$0]) ?? $0 })
        var canonicalIDs: [String: String] = [:]
        for ids in rootAliases.values {
            guard let canonical = ids.sorted().first else { continue }
            for id in ids { canonicalIDs[id] = canonical }
        }
        var projectsByPath: [String: Set<String>] = [:]
        for (id, root) in roots {
            if let key = Self.pathKey(root) { projectsByPath[key, default: []].insert(canonicalIDs[id] ?? id) }
        }
        for session in sessions {
            if let id = Self.projectID(session.projectID), let key = Self.pathKey(session.directory) {
                projectsByPath[key, default: []].insert(canonicalIDs[id] ?? id)
            }
        }

        var members: [String: [OCSession]] = [:]
        for session in sessions {
            var projectID = Self.projectID(session.projectID)
            projectID = projectID.map { canonicalIDs[$0] ?? $0 }
            // "global" explicitly means a non-repository folder, not one big repo.
            if projectID == nil, session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) != "global",
               let path = Self.pathKey(session.directory) {
                if let ids = projectsByPath[path], ids.count == 1 {
                    projectID = ids.first
                } else if projectsByPath[path] == nil {
                    let matches = roots.compactMap { id, root -> (String, String)? in
                        guard let key = Self.pathKey(root), path == key || path.hasPrefix(key + "/") else { return nil }
                        return (canonicalIDs[id] ?? id, key)
                    }
                    let longest = matches.map { $0.1.count }.max()
                    let ids = Set(matches.filter { $0.1.count == longest }.map { $0.0 })
                    if ids.count == 1 { projectID = ids.first }
                }
            }
            let id = projectID.map { "projectID:\($0)" }
                ?? Self.pathKey(session.directory).map { "directory:\($0)" }
                ?? "unknown"
            members[id, default: []].append(session)
        }

        for (id, sessions) in members {
            let projectID = id.hasPrefix("projectID:") ? String(id.dropFirst("projectID:".count)) : nil
            // Stable across refresh/order changes. Prefer the server's root, then
            // the shallowest known directory; never use the most recently active row.
            let paths = sessions.compactMap { Self.displayPath($0.directory) }.sorted {
                let left = $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").count
                let right = $1.replacingOccurrences(of: "\\", with: "/").split(separator: "/").count
                return left == right ? $0 < $1 : left < right
            }
            let directory = projectID.flatMap { roots[$0] } ?? paths.first
            let repository = Repository(
                id: id,
                title: directory.map(WorkspaceSelectionBuilder.displayName(for:)) ?? projectID ?? AppText.projectFallback,
                directory: directory
            )
            for session in sessions { repositoriesBySessionID[session.id] = repository }
        }
    }

    func repository(for session: OCSession) -> Repository {
        repositoriesBySessionID[session.id] ?? Repository(
            id: Self.projectID(session.projectID).map { "projectID:\($0)" }
                ?? Self.pathKey(session.directory).map { "directory:\($0)" } ?? "unknown",
            title: session.workspaceDisplayName ?? Self.projectID(session.projectID) ?? AppText.projectFallback,
            directory: Self.displayPath(session.directory)
        )
    }

    static func projectID(_ value: String?) -> String? {
        guard let id = value?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id != "global" else { return nil }
        return id
    }

    private static func displayPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("\\\\") || value.hasPrefix("//") {
            return value.replacingOccurrences(of: "\\", with: "/")
        }
        return WorkspaceSelectionBuilder.normalizedDirectory(value)
    }

    /// Lexical server-path comparison: do not resolve symlinks on the phone.
    /// Windows drive/UNC paths compare case-insensitively; POSIX paths retain case.
    static func pathKey(_ value: String?) -> String? {
        guard var path = value?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("/"), WorkspaceSelectionBuilder.isWindowsAbsolutePath(String(path.dropFirst())) {
            path.removeFirst()
        }
        let drive = WorkspaceSelectionBuilder.isWindowsAbsolutePath(path)
        let unc = path.hasPrefix("\\\\") || path.hasPrefix("//")
        let windows = drive || unc
        if windows { path = path.replacingOccurrences(of: "\\", with: "/") }
        guard windows || path.hasPrefix("/") else { return path }
        let floor = drive ? 1 : (unc ? 2 : 0)
        var components: [String] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if components.count > floor { components.removeLast() }
            } else {
                components.append(String(component))
            }
        }
        let prefix = drive ? "" : (unc ? "//" : "/")
        let result = prefix + components.joined(separator: "/")
        return windows ? result.lowercased() : result
    }
}
