import Foundation
import Observation

/// The tasks as the UI sees them, split the way the panel shows them.
struct TodoSections {
    /// Still pending from an earlier day.
    var carriedOver: [TodoItem] = []
    /// Pending, added today.
    var today: [TodoItem] = []
    /// Completed today, whenever they were added.
    var doneToday: [TodoItem] = []
    /// Completed on earlier days, newest day first.
    var history: [(day: Date, items: [TodoItem])] = []
}

/// Keeps the UI in sync with `~/.kodisle/tasks.json`. Claude Code changes that file through
/// the MCP server, so it's watched rather than assuming the app is the only writer.
@MainActor @Observable
final class TodoList {
    static let shared = TodoList()

    private(set) var items: [TodoItem] = []
    private(set) var error: String?
    /// Start of the current day. Moving it is what rolls pending tasks over to "carried over".
    private(set) var today = Calendar.current.startOfDay(for: Date())

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: Bridge.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        reload(announce: false)
        // The file is replaced atomically, so the folder is what can be watched.
        watcher = DirectoryWatcher(url: Bridge.directory) {
            Task { @MainActor in TodoList.shared.scheduleReload() }
        }
    }

    func refreshDay() {
        let start = Calendar.current.startOfDay(for: Date())
        if start != today { today = start }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.reload(announce: true)
        }
    }

    private func reload(announce: Bool) {
        do {
            let loaded = try TodoFile.load()
            error = nil
            guard loaded != items else { return }
            if announce { announceClaudeChanges(from: items, to: loaded) }
            items = loaded
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func announceClaudeChanges(from old: [TodoItem], to new: [TodoItem]) {
        guard AppSettings.shared.config.tasksEvents else { return }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = new.filter { before[$0.id] == nil && $0.createdBy == .claude }
        let completed = new.filter { $0.completedBy == .claude && before[$0.id]?.isDone == false }
        guard !added.isEmpty || !completed.isEmpty else { return }

        func count(_ n: Int) -> String { n == 1 ? "a task" : "\(n) tasks" }
        let title: String, subtitle: String
        if added.isEmpty {
            title = "Claude completed \(count(completed.count))"
            subtitle = completed[0].title
        } else if completed.isEmpty {
            title = "Claude added \(count(added.count))"
            subtitle = added[0].title
        } else {
            title = "Claude updated your tasks"
            subtitle = "\(completed.count) completed · \(added.count) added"
        }
        KodisleStore.shared.post(KodisleEvent(symbol: completed.isEmpty ? "plus.circle.fill" : "checkmark.circle.fill",
                                              title: title, subtitle: subtitle,
                                              tint: completed.isEmpty ? .indigo : .green, widget: .tasks))
    }

    // MARK: Reading

    var pendingCount: Int { items.lazy.filter { !$0.isDone }.count }

    var doneTodayCount: Int { items.lazy.filter { ($0.completedAt ?? .distantPast) >= self.today }.count }

    /// What's next: the most important pending task, oldest first.
    var next: TodoItem? { Self.byPriority(items.filter { !$0.isDone }).first }

    var projects: [String] {
        Array(Set(items.compactMap(\.project))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func sections(project: String?) -> TodoSections {
        var sections = TodoSections()
        var earlier: [TodoItem] = []
        for item in items where project == nil || item.project == project {
            if let done = item.completedAt {
                if done >= today { sections.doneToday.append(item) } else { earlier.append(item) }
            } else if item.createdAt < today {
                sections.carriedOver.append(item)
            } else {
                sections.today.append(item)
            }
        }
        sections.carriedOver = Self.byPriority(sections.carriedOver)
        sections.today = Self.byPriority(sections.today)
        sections.doneToday.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let calendar = Calendar.current
        let days = Dictionary(grouping: earlier) { calendar.startOfDay(for: $0.completedAt ?? $0.createdAt) }
        sections.history = days.keys.sorted(by: >).map { day in
            (day, (days[day] ?? []).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
        }
        return sections
    }

    /// Stable: within a priority, tasks keep the order they were added in.
    private static func byPriority(_ items: [TodoItem]) -> [TodoItem] {
        TodoPriority.allCases.flatMap { priority in items.filter { $0.priority == priority } }
    }

    // MARK: Actions

    func add(_ title: String, project: String? = nil) {
        perform { try TodoFile.add(title: title, project: project, by: .user).all }
    }

    func toggle(_ item: TodoItem) {
        perform { try TodoFile.setDone(item.id, !item.isDone, by: .user).all }
    }

    func update(_ item: TodoItem, _ patch: TodoPatch) {
        perform { try TodoFile.update(item.id, patch).all }
    }

    func delete(_ item: TodoItem) {
        perform { try TodoFile.delete(item.id).all }
    }

    private func perform(_ work: () throws -> [TodoItem]) {
        do {
            items = try work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
