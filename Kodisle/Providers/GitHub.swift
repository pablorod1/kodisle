import Foundation

/// GitHub data through the official `gh` CLI.
///
/// Kodisle never sees a GitHub token: `gh` reads its own credential from the Keychain and
/// performs the request. If `gh` isn't installed or logged in, the widget explains how to fix it.
enum GitHubProvider {
    enum GHError: LocalizedError {
        case missing, notAuthenticated, failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: "Install GitHub CLI: brew install gh"
            case .notAuthenticated: "Run `gh auth login` in a terminal"
            case .failed(let message): message
            }
        }
    }

    private static var cachedLogin: String?

    static func fetch(repos: [String]) async throws -> GitHubSnapshot {
        guard Shell.which("gh") != nil else { throw GHError.missing }
        let login = try await viewerLogin()

        async let prs = pullRequests(login: login)
        async let runs = workflowRuns(repos: repos)
        async let unread = unreadNotifications()
        let (mine, review) = try await prs
        return GitHubSnapshot(login: login, myPRs: mine, reviewRequests: review,
                              runs: await runs, unreadNotifications: await unread, fetchedAt: .now)
    }

    private static func viewerLogin() async throws -> String {
        if let cachedLogin { return cachedLogin }
        let result = try await Shell.run("gh", ["api", "user", "--jq", ".login"])
        guard result.ok else { throw GHError.notAuthenticated }
        let login = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw GHError.notAuthenticated }
        cachedLogin = login
        return login
    }

    private static let query = """
    query($mine: String!, $review: String!) {
      mine: search(query: $mine, type: ISSUE, first: 20) { nodes { ...PR } }
      review: search(query: $review, type: ISSUE, first: 20) { nodes { ...PR } }
    }
    fragment PR on PullRequest {
      number title url isDraft updatedAt reviewDecision
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    private static func pullRequests(login: String) async throws -> ([PullRequest], [PullRequest]) {
        let result = try await Shell.run("gh", [
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "mine=is:pr is:open archived:false author:\(login)",
            "-f", "review=is:pr is:open archived:false review-requested:\(login)",
        ])
        guard result.ok else { throw GHError.failed("GitHub request failed") }
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any],
              let data = json["data"] as? [String: Any] else { throw GHError.failed("Unexpected GitHub response") }

        func parse(_ key: String) -> [PullRequest] {
            let nodes = ((data[key] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            return nodes.compactMap { node in
                guard let url = node["url"] as? String, let number = node["number"] as? Int else { return nil }
                let rollup = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
                let checks: CheckState = switch rollup?["state"] as? String {
                case "SUCCESS": .success
                case "FAILURE", "ERROR": .failure
                case "PENDING", "EXPECTED": .pending
                default: .none
                }
                return PullRequest(url: url, number: number, title: node["title"] as? String ?? "",
                                   repo: (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
                                   isDraft: node["isDraft"] as? Bool ?? false, checks: checks,
                                   reviewDecision: node["reviewDecision"] as? String,
                                   updatedAt: (node["updatedAt"] as? String).flatMap(ISO.parse))
            }
        }
        return (parse("mine"), parse("review"))
    }

    private static func workflowRuns(repos: [String]) async -> [WorkflowRun] {
        await withTaskGroup(of: [WorkflowRun].self) { group in
            for repo in repos {
                group.addTask {
                    guard let result = try? await Shell.run("gh", [
                        "run", "list", "-R", repo, "-L", "5", "--json",
                        "databaseId,displayTitle,status,conclusion,workflowName,headBranch,url,updatedAt",
                    ]), result.ok,
                    let items = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [[String: Any]]
                    else { return [] }
                    return items.compactMap { item in
                        guard let id = item["databaseId"] as? Int else { return nil }
                        return WorkflowRun(id: id, repo: repo, title: item["displayTitle"] as? String ?? "",
                                           workflow: item["workflowName"] as? String ?? "",
                                           branch: item["headBranch"] as? String ?? "",
                                           status: item["status"] as? String ?? "",
                                           conclusion: item["conclusion"] as? String ?? "",
                                           url: item["url"] as? String ?? "",
                                           updatedAt: (item["updatedAt"] as? String).flatMap(ISO.parse))
                    }
                }
            }
            var all: [WorkflowRun] = []
            for await runs in group { all += runs }
            return all.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
    }

    private static func unreadNotifications() async -> Int {
        guard let result = try? await Shell.run("gh", ["api", "notifications", "--jq", "length"]), result.ok else { return 0 }
        return Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

/// Local git repositories discovered under the projects folder.
enum GitProvider {
    private static let skipped: Set<String> = ["node_modules", "vendor", "build", "dist", "Pods", "DerivedData", "target", "venv"]

    static func discover(root: URL, depth: Int = 3) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        while let (dir, level) = queue.first {
            queue.removeFirst()
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { found.append(dir); continue }
            guard level < depth,
                  let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for child in children where !skipped.contains(child.lastPathComponent) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    queue.append((child, level + 1))
                }
            }
        }
        return found
    }

    static func activity(of repo: URL) -> Date {
        let git = repo.appendingPathComponent(".git")
        return ["index", "logs/HEAD", "FETCH_HEAD"].compactMap {
            (try? git.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }

    static func fetch(root: URL, limit: Int) async -> [RepoStatus] {
        let repos = await Task.detached(priority: .utility) {
            discover(root: root).map { ($0, activity(of: $0)) }.sorted { $0.1 > $1.1 }.prefix(limit)
        }.value
        return await withTaskGroup(of: RepoStatus?.self) { group in
            for (url, activity) in repos {
                group.addTask { await status(of: url, activity: activity) }
            }
            var result: [RepoStatus] = []
            for await status in group { if let status { result.append(status) } }
            return result.sorted { $0.lastActivity > $1.lastActivity }
        }
    }

    private static func status(of repo: URL, activity: Date) async -> RepoStatus? {
        guard let result = try? await Shell.run("git", ["--no-optional-locks", "-C", repo.path, "status", "--porcelain=v2", "--branch"]),
              result.ok else { return nil }
        var branch = "HEAD", ahead = 0, behind = 0, changes = 0
        for line in result.text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                ahead = Int(parts.first?.dropFirst() ?? "0") ?? 0
                behind = Int(parts.last?.dropFirst() ?? "0") ?? 0
            } else if !line.hasPrefix("#") { changes += 1 }
        }
        let remote = try? await Shell.run("git", ["-C", repo.path, "remote", "get-url", "origin"])
        return RepoStatus(path: repo.path, name: repo.lastPathComponent, branch: branch, ahead: ahead, behind: behind,
                          changes: changes, githubSlug: remote.flatMap { Redact.githubSlug(fromRemote: $0.text) },
                          lastActivity: activity)
    }
}
