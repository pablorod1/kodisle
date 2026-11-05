import Darwin
import Foundation

enum TodoActor: String, Codable { case user, claude }

enum TodoPriority: String, Codable, CaseIterable, Identifiable {
    case high, normal, low
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct TodoItem: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var notes: String?
    var project: String?
    var priority: TodoPriority
    var createdAt: Date
    var createdBy: TodoActor
    var completedAt: Date?
    var completedBy: TodoActor?

    var isDone: Bool { completedAt != nil }
}

/// Fields to change on a task. `nil` keeps the value; an empty string clears notes / project.
struct TodoPatch {
    var title: String?
    var notes: String?
    var project: String?
    var priority: TodoPriority?
}

enum TodoError: LocalizedError {
    case notFound(String)
    case emptyTitle
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "No task with id \(id)"
        case .emptyTitle: "A task needs a title"
        case .unreadable(let reason): "tasks.json can't be read (\(reason)). It was left untouched."
        }
    }
}

/// The task list on disk: `~/.kodisle/tasks.json`.
///
/// It's the single source of truth shared by the app and the MCP server (a separate process
/// that also works while Kodisle is closed). Writes take an advisory lock and replace the
/// file atomically, so neither side can lose the other's change.
enum TodoFile {
    static var url: URL { Bridge.directory.appendingPathComponent("tasks.json") }
    private static var lockURL: URL { Bridge.directory.appendingPathComponent("tasks.lock") }
    private static let formatVersion = 1

    private struct Document: Codable {
        var version: Int
        var items: [TodoItem]
    }

    // MARK: Reading

    static func load() throws -> [TodoItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let document = try decoder.decode(Document.self, from: data)
            guard document.version <= formatVersion else {
                throw TodoError.unreadable("written by a newer Kodisle")
            }
            return document.items
        } catch let error as TodoError {
            throw error
        } catch {
            // Never overwrite a file we couldn't parse: the user may be able to repair it.
            throw TodoError.unreadable("invalid JSON")
        }
    }

    // MARK: Operations

    /// Adds a task. A pending task with the same title is returned instead of creating a
    /// duplicate (`created` is false), so agents can add follow-ups without checking first.
    static func add(title: String, notes: String? = nil, project: String? = nil,
                    priority: TodoPriority = .normal, by actor: TodoActor) throws -> (item: TodoItem, created: Bool, all: [TodoItem]) {
        let title = cleanTitle(title)
        guard !title.isEmpty else { throw TodoError.emptyTitle }
        let result = try mutate { items -> (TodoItem, Bool) in
            if let existing = items.first(where: { !$0.isDone && $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return (existing, false)
            }
            let item = TodoItem(id: newID(in: items), title: title, notes: cleanOptional(notes, limit: 10_000),
                                project: cleanOptional(project, limit: 100), priority: priority,
                                createdAt: Date(), createdBy: actor)
            items.append(item)
            return (item, true)
        }
        return (result.value.0, result.value.1, result.all)
    }

    static func setDone(_ id: String, _ done: Bool, by actor: TodoActor) throws -> (item: TodoItem, all: [TodoItem]) {
        let result = try mutate { items -> TodoItem in
            let index = try index(of: id, in: items)
            // Keeps the original timestamp and author when completing twice.
            if done != items[index].isDone {
                items[index].completedAt = done ? Date() : nil
                items[index].completedBy = done ? actor : nil
            }
            return items[index]
        }
        return (result.value, result.all)
    }

    static func update(_ id: String, _ patch: TodoPatch) throws -> (item: TodoItem, all: [TodoItem]) {
        let result = try mutate { items -> TodoItem in
            let index = try index(of: id, in: items)
            if let title = patch.title {
                let title = cleanTitle(title)
                guard !title.isEmpty else { throw TodoError.emptyTitle }
                items[index].title = title
            }
            if let notes = patch.notes { items[index].notes = cleanOptional(notes, limit: 10_000) }
            if let project = patch.project { items[index].project = cleanOptional(project, limit: 100) }
            if let priority = patch.priority { items[index].priority = priority }
            return items[index]
        }
        return (result.value, result.all)
    }

    static func delete(_ id: String) throws -> (item: TodoItem, all: [TodoItem]) {
        let result = try mutate { items in items.remove(at: try index(of: id, in: items)) }
        return (result.value, result.all)
    }

    // MARK: Storage

    /// Read-modify-write under an exclusive lock. Nothing is written if `body` throws.
    private static func mutate<T>(_ body: (inout [TodoItem]) throws -> T) throws -> (value: T, all: [TodoItem]) {
        try FileManager.default.createDirectory(at: Bridge.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }          // Closing the descriptor also releases the lock.
        flock(lock, LOCK_EX)

        var items = try load()
        let before = items
        let value = try body(&items)
        if items != before { try write(items) }
        return (value, items)
    }

    private static func write(_ items: [TodoItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(version: formatVersion, items: items))
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private static func index(of id: String, in items: [TodoItem]) throws -> Int {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw TodoError.notFound(id) }
        return index
    }

    private static func newID(in items: [TodoItem]) -> String {
        while true {
            let id = String(UUID().uuidString.prefix(6)).lowercased()
            if !items.contains(where: { $0.id == id }) { return id }
        }
    }

    private static func cleanTitle(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(line.trimmingCharacters(in: .whitespaces).prefix(300))
    }

    private static func cleanOptional(_ text: String?, limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }
}
