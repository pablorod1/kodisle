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
        async let main = pullRequestsAndRuns(login: login, repos: repos)
        async let unread = unreadNotifications()
        let (mine, review, runs) = try await main
        return GitHubSnapshot(login: login, myPRs: mine, reviewRequests: review, runs: runs,
                              unreadNotifications: await unread, fetchedAt: .now)
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

    private static let prFragment = """
    fragment PR on PullRequest {
      number title url isDraft updatedAt reviewDecision
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    /// One GraphQL request for everything: my PRs, review requests, and the latest workflow
    /// runs (check suites) on the default branch of each tracked repo — a single `gh` process.
    private static func pullRequestsAndRuns(login: String, repos: [String]) async throws -> ([PullRequest], [PullRequest], [WorkflowRun]) {
        let safe = repos.filter { $0.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }.prefix(15)
        let repoFields = safe.enumerated().map { i, slug -> String in
            let parts = slug.split(separator: "/")
            return """
            r\(i): repository(owner: "\(parts[0])", name: "\(parts[1])") {
              nameWithOwner
              defaultBranchRef { name target { ... on Commit { history(first: 3) { nodes { messageHeadline
                checkSuites(first: 8) { nodes { status conclusion updatedAt workflowRun { databaseId url workflow { name } } } } } } } } }
            }
            """
        }.joined(separator: "\n")
        let query = """
        query($mine: String!, $review: String!) {
          mine: search(query: $mine, type: ISSUE, first: 20) { nodes { ...PR } }
          review: search(query: $review, type: ISSUE, first: 20) { nodes { ...PR } }
          \(repoFields)
        }
        \(prFragment)
        """
        let result = try await Shell.run("gh", [
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "mine=is:pr is:open archived:false author:\(login)",
            "-f", "review=is:pr is:open archived:false review-requested:\(login)",
        ])
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            throw GHError.failed(result.ok ? "Unexpected GitHub response" : "GitHub request failed")
        }

        func parsePRs(_ key: String) -> [PullRequest] {
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

        var runs: [WorkflowRun] = []
        for i in safe.indices {
            guard let repo = data["r\(i)"] as? [String: Any], let slug = repo["nameWithOwner"] as? String,
                  let branchRef = repo["defaultBranchRef"] as? [String: Any] else { continue }
            let branch = branchRef["name"] as? String ?? ""
            let commits = (((branchRef["target"] as? [String: Any])?["history"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for commit in commits {
                let title = commit["messageHeadline"] as? String ?? ""
                for suite in ((commit["checkSuites"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                    guard let run = suite["workflowRun"] as? [String: Any], let id = run["databaseId"] as? Int else { continue }
                    runs.append(WorkflowRun(id: id, repo: slug, title: title,
                                            workflow: (run["workflow"] as? [String: Any])?["name"] as? String ?? "",
                                            branch: branch,
                                            status: (suite["status"] as? String ?? "").lowercased(),
                                            conclusion: (suite["conclusion"] as? String ?? "").lowercased(),
                                            url: run["url"] as? String ?? "",
                                            updatedAt: (suite["updatedAt"] as? String).flatMap(ISO.parse)))
                }
            }
        }
        runs.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return (parsePRs("mine"), parsePRs("review"), Array(runs.prefix(30)))
    }

    private static func unreadNotifications() async -> Int {
        guard let result = try? await Shell.run("gh", ["api", "notifications", "--jq", "length"]), result.ok else { return 0 }
        return Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

/// Local git repositories discovered under the projects folder.
enum GitProvider {
    private static let skipped: Set<String> = ["node_modules", "vendor", "build", "dist", "Pods", "DerivedData", "target", "venv"]

    /// Deep enough for repos inside plain folders, like ~/Dev/auvex/crm/monorepo/rs-crm.
    static func discover(root: URL, depth: Int = 6) -> [URL] {
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

    /// Discovery is cached for 10 minutes; `git status` only re-runs for repos whose index /
    /// HEAD changed since the last scan; remotes are read once per repo.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var discovered: (root: URL, date: Date, repos: [URL])?
        var statuses: [String: (status: RepoStatus, checked: Date)] = [:]
        var remotes: [String: String?] = [:]
    }
    private static let cache = Cache()

    static func fetch(root: URL, limit: Int) async -> [RepoStatus] {
        let repos = await Task.detached(priority: .utility) { () -> [(URL, Date)] in
            cache.lock.lock()
            let cached = cache.discovered
            cache.lock.unlock()
            let urls: [URL]
            if let cached, cached.root == root, Date().timeIntervalSince(cached.date) < 600 {
                urls = cached.repos
            } else {
                urls = discover(root: root)
                cache.lock.lock(); cache.discovered = (root, Date(), urls); cache.lock.unlock()
            }
            return Array(urls.map { ($0, activity(of: $0)) }.sorted { $0.1 > $1.1 }.prefix(limit))
        }.value
        return await withTaskGroup(of: RepoStatus?.self) { group in
            for (url, activity) in repos {
                cache.lock.lock()
                let previous = cache.statuses[url.path]
                cache.lock.unlock()
                // Unstaged edits don't touch the index, so also refresh anything older than 2 minutes.
                if let previous, previous.status.lastActivity == activity, Date().timeIntervalSince(previous.checked) < 120 {
                    group.addTask { previous.status }
                } else {
                    group.addTask {
                        let fresh = await status(of: url, activity: activity)
                        if let fresh { cache.lock.lock(); cache.statuses[url.path] = (fresh, Date()); cache.lock.unlock() }
                        return fresh
                    }
                }
            }
            var result: [RepoStatus] = []
            for await status in group { if let status { result.append(status) } }
            return result.sorted { $0.lastActivity > $1.lastActivity }
        }
    }

    private static func remoteSlug(_ repo: URL) async -> String? {
        cache.lock.lock()
        if let known = cache.remotes[repo.path] { cache.lock.unlock(); return known }
        cache.lock.unlock()
        let remote = try? await Shell.run("git", ["-C", repo.path, "remote", "get-url", "origin"])
        let slug = remote.flatMap { Redact.githubSlug(fromRemote: $0.text) }
        cache.lock.lock(); cache.remotes[repo.path] = .some(slug); cache.lock.unlock()
        return slug
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
        return RepoStatus(path: repo.path, name: repo.lastPathComponent, branch: branch, ahead: ahead, behind: behind,
                          changes: changes, githubSlug: await remoteSlug(repo), lastActivity: activity)
    }
}
