import Foundation
import Testing
@testable import OpenLens

@MainActor
struct GitHubRepositoryServiceTests {
    @Test func parsesDirectRepositoryReferencesFromOwnerRepoHTTPSAndSSHURLs() {
        let shorthand = GitHubRepositoryService.parseDirectRepository(from: "QuincyForbes/OpenLens")
        #expect(shorthand?.fullName == "QuincyForbes/OpenLens")
        #expect(shorthand?.cloneURL == "https://github.com/QuincyForbes/OpenLens.git")

        let httpsURL = GitHubRepositoryService.parseDirectRepository(from: "https://github.com/martynpekala/OpenLens.git")
        #expect(httpsURL?.fullName == "martynpekala/OpenLens")
        #expect(httpsURL?.name == "OpenLens")

        let sshURL = GitHubRepositoryService.parseDirectRepository(from: "git@github.com:QuincyForbes/akvros.git")
        #expect(sshURL?.fullName == "QuincyForbes/akvros")
        #expect(sshURL?.ownerLogin == "QuincyForbes")

        #expect(GitHubRepositoryService.parseDirectRepository(from: "not a repo") == nil)
    }

    @Test func computesDefaultParentAndTargetDirectoriesForWindowsAndPOSIXWorkspaces() {
        let windowsParent = GitHubRepositoryService.defaultParentDirectory(from: [#"C:\Users\Admin\Desktop\OpenLens"#])
        #expect(windowsParent == #"C:\Users\Admin\Desktop"#)
        #expect(
            GitHubRepositoryService.targetDirectory(parentDirectory: windowsParent, repositoryName: "akvros")
                == #"C:\Users\Admin\Desktop\akvros"#
        )

        let posixParent = GitHubRepositoryService.defaultParentDirectory(from: ["/Users/dev/repos/OpenLens"])
        #expect(posixParent == "/Users/dev/repos")
        #expect(
            GitHubRepositoryService.targetDirectory(parentDirectory: posixParent, repositoryName: "akvros")
                == "/Users/dev/repos/akvros"
        )
    }

    @Test func decodesGitHubRepositoriesAndSearchResponses() throws {
        let repoJSON = Data(#"""
        [
          {
            "id": 101,
            "name": "OpenLens",
            "full_name": "QuincyForbes/OpenLens",
            "owner": {"login": "QuincyForbes"},
            "description": "iOS companion for OpenCode",
            "clone_url": "https://github.com/QuincyForbes/OpenLens.git",
            "html_url": "https://github.com/QuincyForbes/OpenLens",
            "private": false,
            "stargazers_count": 48,
            "language": "Swift",
            "updated_at": "2026-10-30T18:00:00Z"
          }
        ]
        """#.utf8)

        let decoded = try GitHubRepositoryService.decodeRepositories(from: repoJSON)
        #expect(decoded.count == 1)
        #expect(decoded[0].fullName == "QuincyForbes/OpenLens")
        #expect(decoded[0].stargazersCount == 48)
        #expect(decoded[0].language == "Swift")
    }
}
