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
    static func fetch() async -> [DockerContainer]? {
        guard Shell.which("docker") != nil,
              let result = try? await Shell.run("docker", ["ps", "-a", "--format", "{{json .}}"], timeout: 8), result.ok
        else { return nil }
        return result.text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = item["ID"] as? String else { return nil }
            return DockerContainer(id: id, name: item["Names"] as? String ?? id, image: item["Image"] as? String ?? "",
                                   state: item["State"] as? String ?? "", status: item["Status"] as? String ?? "",
                                   ports: item["Ports"] as? String ?? "")
        }
        .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    static func perform(_ action: String, id: String) async {
        _ = try? await Shell.run("docker", [action, id], timeout: 30)
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
