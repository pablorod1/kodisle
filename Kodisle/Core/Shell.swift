import Foundation

/// Runs CLI tools with a *minimal* environment.
///
/// Security notes:
/// - The parent environment is never forwarded, so secrets exported in the user's
///   shell (API keys, tokens…) can't leak into child processes or logs.
/// - Output is returned to the caller only; nothing is logged or persisted here.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var ok: Bool { status == 0 }
    }

    enum ShellError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self { case .notFound(let tool): "\(tool) not found" }
        }
    }

    static let searchPaths: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.orbstack/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ]

    static let minimalEnvironment: [String: String] = [
        "HOME": NSHomeDirectory(),
        "USER": NSUserName(),
        "PATH": searchPaths.joined(separator: ":"),
        "LANG": "en_US.UTF-8",
        "NO_COLOR": "1",
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    static func which(_ tool: String) -> String? {
        let fm = FileManager.default
        if tool.hasPrefix("/") { return fm.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPaths {
            let path = dir + "/" + tool
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func run(_ tool: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 20) async throws -> Result {
        guard let path = which(tool) else { throw ShellError.notFound(tool) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = minimalEnvironment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let stdout = Collector(out.fileHandleForReading)
        let stderr = Collector(err.fileHandleForReading)

        // Fully asynchronous: no thread ever blocks waiting for EOF, so a pipe kept open by
        // some descendant can't starve Swift's cooperative thread pool.
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let result = Result(status: finished.terminationStatus, stdout: stdout.finish(),
                                    stderr: String(decoding: stderr.finish(), as: UTF8.self))
                continuation.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                _ = stdout.finish(); _ = stderr.finish()
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Accumulates a pipe's output as it arrives, then drains the rest without blocking.
    private final class Collector: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var data = Data()
        private var closed = false

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] h in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard !self.closed else { return }
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil } else { self.data.append(chunk) }
            }
        }

        func finish() -> Data {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return data }
            closed = true
            handle.readabilityHandler = nil
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            try? handle.close()
            return data
        }
    }
}

/// Ephemeral networking: no cache, no cookies, nothing written to disk.
enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
}

enum ISO {
    /// Parses ISO-8601 dates with any number of fractional digits.
    static func parse(_ string: String) -> Date? {
        let cleaned = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }
}

enum FileTail {
    /// Reads the last `bytes` of a file (used for JSONL logs, never loads whole files).
    static func read(_ url: URL, bytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonLines(_ url: URL, bytes: Int = 64 * 1024) -> [[String: Any]] {
        guard let text = read(url, bytes: bytes) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
