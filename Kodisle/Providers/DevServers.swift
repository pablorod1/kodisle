import Darwin
import Foundation

/// Lists TCP ports in LISTEN state owned by processes started from a project folder.
///
/// Only the process name, ports and working directory are read. Command-line arguments
/// are deliberately ignored because they often contain tokens (`--token=…`, DB URLs…).
enum DevServerProvider {
    /// Native scan with libproc (no `lsof`/`ps` processes): for every process whose working
    /// directory is inside the home folder, list its TCP sockets in LISTEN state. ~4 ms.
    static func fetch() async -> [DevServer] {
        await Task.detached(priority: .utility) { scan() }.value
    }

    private static func scan() -> [DevServer] {
        let home = NSHomeDirectory() + "/"
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getpid()
        var servers: [DevServer] = []

        for pid in pids.prefix(Int(max(0, count))) where pid > 0 && pid != me {
            // Cheap filter first: apps launched from Finder/launchd run in "/" or "~".
            var vpi = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { continue }
            let cwd = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard cwd.hasPrefix(home) else { continue }

            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            proc_name(pid, &name, UInt32(name.count))
            let command = String(cString: name)
            var info = proc_bsdinfo()
            let uptime = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                ? Fmt.duration(Date().timeIntervalSince1970 - TimeInterval(info.pbi_start_tvsec)) : nil
            servers.append(DevServer(pid: pid, command: command, ports: ports, cwd: cwd,
                                     project: (cwd as NSString).lastPathComponent,
                                     framework: framework(cwd: cwd, command: command), uptime: uptime))
        }
        return servers.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    private static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP),
                  si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
        }
        return ports.sorted()
    }

    /// Framework detection reads package.json; cache it per folder (it rarely changes).
    private static let frameworkCache = NSCache<NSString, NSString>()

    private static let jsFrameworks: [(String, String)] = [
        ("next", "Next.js"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("@sveltejs/kit", "SvelteKit"),
        ("@remix-run/dev", "Remix"), ("@react-router/dev", "React Router"), ("@angular/core", "Angular"),
        ("expo", "Expo"), ("@nestjs/core", "NestJS"), ("vite", "Vite"), ("hono", "Hono"),
        ("fastify", "Fastify"), ("express", "Express"), ("storybook", "Storybook"),
    ]

    private static func framework(cwd: String, command: String) -> String? {
        let key = (cwd + "|" + command) as NSString
        if let cached = frameworkCache.object(forKey: key) { return cached.length == 0 ? nil : cached as String }
        let result = detectFramework(cwd: cwd, command: command)
        frameworkCache.setObject((result ?? "") as NSString, forKey: key)
        return result
    }

    private static func detectFramework(cwd: String, command: String) -> String? {
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
