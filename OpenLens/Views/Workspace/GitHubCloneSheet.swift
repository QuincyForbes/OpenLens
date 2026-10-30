import SwiftUI

struct GitHubCloneSheet: View {
    let defaultParentDirectory: String
    let onSelectRepository: (ClonedRepositorySelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var service = GitHubRepositoryService()
    @State private var mode: GitHubRepositoryService.Mode = .accessible
    @State private var query = ""
    @State private var parentDirectory: String
    @State private var showAccessSettings = false

    init(
        defaultParentDirectory: String,
        onSelectRepository: @escaping (ClonedRepositorySelection) -> Void
    ) {
        self.defaultParentDirectory = defaultParentDirectory
        self.onSelectRepository = onSelectRepository
        _parentDirectory = State(initialValue: defaultParentDirectory)
    }

    var body: some View {
        NavigationStack {
            List {
                destinationSection

                Section {
                    Picker("Source", selection: $mode) {
                        ForEach(GitHubRepositoryService.Mode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                accessSettingsSection

                repositoriesSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Clone Repository")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: mode == .accessible
                    ? "Filter your repos or paste owner/repo"
                    : "Search all of GitHub or paste URL"
            )
            .onSubmit(of: .search) {
                if mode == .globalSearch {
                    Task { await service.searchGitHub(query: query) }
                }
            }
            .onChange(of: query) { _, newValue in
                guard mode == .globalSearch else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard query == newValue else { return }
                    await service.searchGitHub(query: trimmed)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if mode == .accessible {
                                await service.loadAccessibleRepositories(force: true)
                            } else {
                                await service.searchGitHub(query: query)
                            }
                        }
                    } label: {
                        if service.isLoadingAccessible || service.isSearchingGitHub {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Refresh repositories")
                }
            }
            .task {
                await service.loadAccessibleRepositories()
            }
        }
    }

    private var destinationSection: some View {
        Section {
            TextField("Parent directory on server", text: $parentDirectory)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(Color.appSurface)
        } header: {
            Text("Clone Into Folder")
        } footer: {
            Text("The selected repository will be cloned into a subfolder here on your connected computer.")
        }
    }

    private var accessSettingsSection: some View {
        Section {
            DisclosureGroup("GitHub Accounts & Private Access", isExpanded: $showAccessSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub Users / Orgs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("QuincyForbes, my-org", text: $service.ownersText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .monospaced))
                        .onSubmit {
                            Task { await service.loadAccessibleRepositories(force: true) }
                        }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal Access Token (optional, for private repos)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SecureField("ghp_… or github_pat_…", text: $service.personalAccessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .monospaced))
                        .onSubmit {
                            Task { await service.loadAccessibleRepositories(force: true) }
                        }
                }
                .padding(.vertical, 4)

                Button("Reload Accessible Repositories") {
                    Task { await service.loadAccessibleRepositories(force: true) }
                }
                .font(.footnote.weight(.semibold))
            }
            .listRowBackground(Color.appSurface)
        }
    }

    @ViewBuilder
    private var repositoriesSection: some View {
        let displayed = mode == .accessible
            ? service.filteredAccessibleRepositories(query: query)
            : service.searchResults

        Section {
            if (mode == .accessible && service.isLoadingAccessible && displayed.isEmpty)
                || (mode == .globalSearch && service.isSearchingGitHub && displayed.isEmpty) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(mode == .accessible ? "Loading your repositories…" : "Searching GitHub…")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.appSurface)
            } else if displayed.isEmpty {
                if mode == .globalSearch, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Type a repository name, topic, or `owner/repo` above to search all of GitHub.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.appSurface)
                } else {
                    Text(service.errorMessage ?? "No matching repositories found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.appSurface)
                }
            } else {
                ForEach(displayed) { repo in
                    repositoryRow(repo)
                        .listRowBackground(Color.appSurface)
                }
            }
        } header: {
            Text(mode == .accessible ? "Accessible Repositories (\(displayed.count))" : "GitHub Results (\(displayed.count))")
        }
    }

    private func repositoryRow(_ repo: GitHubRepositoryItem) -> some View {
        let targetDir = GitHubRepositoryService.targetDirectory(
            parentDirectory: parentDirectory,
            repositoryName: repo.name
        )
        return Button {
            let selection = ClonedRepositorySelection(
                repository: repo,
                parentDirectory: parentDirectory,
                targetDirectory: targetDir
            )
            onSelectRepository(selection)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(repo.isPrivate ? Color.appWarning : Color.appAccent)

                    Text(repo.fullName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appPrimary)
                        .lineLimit(1)

                    if repo.isPrivate {
                        Text("Private")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appWarning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appWarning.opacity(0.14), in: Capsule())
                    }

                    Spacer()

                    if repo.stargazersCount > 0 {
                        Label("\(repo.stargazersCount)", systemImage: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let description = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let language = repo.language, !language.isEmpty {
                        Text(language)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                    }
                    Text("→ \(targetDir)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("githubClone.repo.\(repo.fullName)")
    }
}
