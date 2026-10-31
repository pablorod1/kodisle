import Darwin
import Foundation
import IOKit.ps

// MARK: - Endpoints

enum EndpointProvider {
    static func check(_ endpoint: Endpoint) async -> (status: Int?, latency: Double?, ok: Bool, error: String?) {
        guard let url = URL(string: endpoint.url), url.scheme?.hasPrefix("http") == true else {
            return (nil, nil, false, "Invalid URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = endpoint.method
        request.setValue("Kodisle health check", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (_, response) = try await Net.session.data(for: request)
            let latency = Date().timeIntervalSince(start) * 1000
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = endpoint.expectedStatus.map { $0 == code } ?? (200..<400).contains(code)
            return (code, latency, ok, ok ? nil : "HTTP \(code)")
        } catch let error as URLError {
            return (nil, nil, false, error.code == .timedOut ? "Timed out" : "Unreachable")
        } catch {
            return (nil, nil, false, "Unreachable")
        }
    }
}

// MARK: - Docker

enum DockerProvider {
    /// Docker Engine API over its Unix socket — no `docker` CLI process per refresh.
    static var socketPath: String? {
        let home = NSHomeDirectory()
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            return String(host.dropFirst(7))
        }
        return [home + "/.docker/run/docker.sock", home + "/.orbstack/run/docker.sock",
                home + "/.colima/default/docker.sock", "/var/run/docker.sock"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func fetch() async -> [DockerContainer]? {
        guard let path = socketPath else { return nil }
        return await Task.detached(priority: .utility) { () -> [DockerContainer]? in
            guard let body = UnixHTTP.request(socket: path, method: "GET", path: "/containers/json?all=1"),
                  let items = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return nil }
            return items.compactMap { item in
                guard let id = item["Id"] as? String else { return nil }
                let name = ((item["Names"] as? [String])?.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let ports = (item["Ports"] as? [[String: Any]] ?? []).compactMap { p -> String? in
                    guard let pub = p["PublicPort"] as? Int, let priv = p["PrivatePort"] as? Int else { return nil }
                    return "\(pub)→\(priv)"
                }
                return DockerContainer(id: String(id.prefix(12)), name: name, image: item["Image"] as? String ?? "",
                                       state: item["State"] as? String ?? "", status: item["Status"] as? String ?? "",
                                       ports: Array(Set(ports)).sorted().joined(separator: ", "))
            }
            .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
        }.value
    }

    static func perform(_ action: String, id: String) async {
        guard let path = socketPath else { return }
        _ = await Task.detached { UnixHTTP.request(socket: path, method: "POST", path: "/containers/\(id)/\(action)", timeout: 30) }.value
    }
}

/// Minimal HTTP/1.0 client over a Unix domain socket (used for the Docker API).
enum UnixHTTP {
    static func request(socket path: String, method: String, path resource: String, timeout: Int = 5) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        let request = "\(method) \(resource) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        guard request.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
            if response.count > 8 << 20 { break }
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.") && head.split(separator: " ").dropFirst().first.map({ $0.hasPrefix("2") }) == true else { return nil }
        return response[split.upperBound...]
    }
}

// MARK: - System

final class SystemSampler {
    private var previous: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func snapshot() -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.cpu = cpu()
        snap.memUsed = memoryUsed()
        snap.diskFree = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        snap.battery = battery()
        return snap
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let now = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        defer { previous = now }
        guard let p = previous else { return 0 }
        let user = now.0 &- p.user, system = now.1 &- p.system, idle = now.2 &- p.idle, nice = now.3 &- p.nice
        let total = user + system + idle + nice
        return total == 0 ? 0 : Double(user + system + nice) / Double(total)
    }

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let minutes = desc[kIOPSTimeToEmptyKey] as? Int
            return BatteryInfo(percent: max > 0 ? current * 100 / max : current,
                               isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                               onAC: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                               minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }
}

// MARK: - Downloads

enum DownloadsProvider {
    static var folder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    static func list(limit: Int = 300) -> [DownloadItem] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey,
                                      .isPackageKey, .localizedTypeDescriptionKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> DownloadItem? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = (values.isDirectory ?? false) && !(values.isPackage ?? false)
            return DownloadItem(url: url, name: url.lastPathComponent,
                                size: isFolder ? nil : values.fileSize.map(Int64.init),
                                kind: isFolder ? "Folder" : (values.localizedTypeDescription ?? "File"),
                                added: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast,
                                isDirectory: isFolder)
        }
        .sorted { $0.added > $1.added }
        .prefix(limit).map { $0 }
    }
}

/// Watches a directory for changes (create / delete / rename) with a kqueue source.
final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
