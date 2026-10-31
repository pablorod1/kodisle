import Foundation

/// Lists TCP ports in LISTEN state owned by processes started from a project folder.
///
/// Only the process name, ports and working directory are read. Command-line arguments
/// are deliberately ignored because they often contain tokens (`--token=…`, DB URLs…).
enum DevServerProvider {
    private struct Entry { var command = ""; var ports = Set<Int>() }

    static func fetch() async -> [DevServer] {
        guard let result = try? await Shell.run("lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]), result.ok || !result.stdout.isEmpty
        else { return [] }

        var entries: [Int32: Entry] = [:]
        var current: Int32 = 0
        for line in result.text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                current = Int32(value) ?? 0
                if entries[current] == nil { entries[current] = Entry() }
            case "c":
                entries[current]?.command = value
            case "n":
                if let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
                    entries[current]?.ports.insert(port)
                }
            default: break
            }
        }
        guard !entries.isEmpty else { return [] }

        let pids = entries.keys.map(String.init).joined(separator: ",")
        let cwds = await workingDirectories(pids: pids)
        let uptimes = await uptimes(pids: pids)
        let home = NSHomeDirectory()

        return entries.compactMap { pid, entry -> DevServer? in
            // Apps launched from Finder/launchd run in "/" or "~": only project folders count.
            guard let cwd = cwds[pid], cwd.hasPrefix(home + "/"), !entry.ports.isEmpty else { return nil }
            let project = (cwd as NSString).lastPathComponent
            return DevServer(pid: pid, command: entry.command, ports: entry.ports.sorted(), cwd: cwd,
                             project: project, framework: framework(cwd: cwd, command: entry.command),
                             uptime: uptimes[pid])
        }
        .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    private static func workingDirectories(pids: String) async -> [Int32: String] {
        guard let result = try? await Shell.run("lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids]) else { return [:] }
        var map: [Int32: String] = [:]
        var current: Int32 = 0
        for line in result.text.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") { map[current] = String(line.dropFirst()) }
        }
        return map
    }

    private static func uptimes(pids: String) async -> [Int32: String] {
        guard let result = try? await Shell.run("ps", ["-o", "pid=,etime=", "-p", pids]) else { return [:] }
        var map: [Int32: String] = [:]
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            map[pid] = humanize(etime: String(parts[1]))
        }
        return map
    }

    /// `[[dd-]hh:]mm:ss` → "3d", "2h 5m", "12m"
    private static func humanize(etime: String) -> String {
        var days = 0, rest = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[..<dash]) ?? 0
            rest = String(etime[etime.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        var seconds = days * 86_400
        for (i, value) in parts.reversed().enumerated() { seconds += value * [1, 60, 3600][min(i, 2)] }
        return Fmt.duration(TimeInterval(seconds))
    }

    private static let jsFrameworks: [(String, String)] = [
        ("next", "Next.js"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("@sveltejs/kit", "SvelteKit"),
        ("@remix-run/dev", "Remix"), ("@react-router/dev", "React Router"), ("@angular/core", "Angular"),
        ("expo", "Expo"), ("@nestjs/core", "NestJS"), ("vite", "Vite"), ("hono", "Hono"),
        ("fastify", "Fastify"), ("express", "Express"), ("storybook", "Storybook"),
    ]

    private static func framework(cwd: String, command: String) -> String? {
        let pkg = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkg),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let deps = ((json["dependencies"] as? [String: Any]) ?? [:])
                .merging((json["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
            if let match = jsFrameworks.first(where: { deps[$0.0] != nil }) { return match.1 }
        }
        let c = command.lowercased()
        switch true {
        case c.contains("python"), c.contains("uvicorn"), c.contains("gunicorn"): return "Python"
        case c.contains("ruby"), c.contains("puma"), c.contains("rails"): return "Ruby"
        case c.contains("java"): return "Java"
        case c.contains("php"): return "PHP"
        case c.contains("postgres"): return "PostgreSQL"
        case c.contains("redis"): return "Redis"
        case c.contains("mysql"), c.contains("mariadb"): return "MySQL"
        case c.contains("bun"): return "Bun"
        case c.contains("deno"): return "Deno"
        case c.contains("node"): return "Node"
        default: return nil
        }
    }
}
