import Foundation

/// Recent Vercel deployments (personal scope + every team), using the Vercel CLI's session.
///
/// The token in the CLI's `auth.json` is read for each request and dropped. It is **never
/// refreshed**: if it expired, any `vercel` command renews it.
enum VercelProvider {
    enum VercelError: LocalizedError {
        case notInstalled, expired, http(Int)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Install the Vercel CLI and run `vercel login`"
            case .expired: "Vercel session expired — run any `vercel` command"
            case .http(let code): "Vercel returned HTTP \(code)"
            }
        }
    }

    private static var authFile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.vercel.cli/auth.json")
    }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    private static func token() throws -> String {
        guard let data = try? Data(contentsOf: authFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["token"] as? String else { throw VercelError.notInstalled }
        if let expires = (json["expiresAt"] as? NSNumber)?.doubleValue, expires < Date().timeIntervalSince1970 {
            throw VercelError.expired
        }
        return token
    }

    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.vercel.com" + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Kodisle", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Net.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw VercelError.expired }
        guard code == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw VercelError.http(code) }
        return json
    }

    static func fetch() async throws -> [VercelDeployment] {
        let token = try token()
        let teams = ((try? await get("/v2/teams?limit=20", token: token))?["teams"] as? [[String: Any]] ?? [])
            .compactMap { team -> (String, String)? in
                guard let id = team["id"] as? String else { return nil }
                return (id, team["name"] as? String ?? team["slug"] as? String ?? id)
            }
        let scopes: [(String?, String?)] = [(nil, nil)] + teams.map { ($0.0, $0.1) }
        return try await withThrowingTaskGroup(of: [VercelDeployment].self) { group in
            for (teamID, teamName) in scopes {
                group.addTask {
                    let query = "/v6/deployments?limit=10" + (teamID.map { "&teamId=\($0)" } ?? "")
                    let json = try await get(query, token: token)
                    return (json["deployments"] as? [[String: Any]] ?? []).compactMap { parse($0, team: teamName) }
                }
            }
            var all: [VercelDeployment] = []
            for try await batch in group { all += batch }
            var seen = Set<String>()
            return all.filter { seen.insert($0.id).inserted }.sorted { $0.created > $1.created }.prefix(20).map { $0 }
        }
    }

    private static func parse(_ d: [String: Any], team: String?) -> VercelDeployment? {
        guard let id = d["uid"] as? String else { return nil }
        let meta = d["meta"] as? [String: Any] ?? [:]
        let created = (d["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
        let commit = (meta["githubCommitMessage"] ?? meta["gitlabCommitMessage"] ?? meta["bitbucketCommitMessage"]) as? String
        return VercelDeployment(id: id, project: d["name"] as? String ?? "",
                                state: (d["state"] ?? d["readyState"]) as? String ?? "",
                                target: d["target"] as? String, url: d["url"] as? String ?? "",
                                branch: (meta["githubCommitRef"] ?? meta["gitlabCommitRef"] ?? meta["bitbucketCommitRef"]) as? String,
                                commit: commit.map { String($0.split(separator: "\n").first ?? "") },
                                created: created, team: team)
    }
}
