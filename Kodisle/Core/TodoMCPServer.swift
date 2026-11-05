import Darwin
import Foundation

/// Minimal MCP server over stdio, so Claude Code can read and change the task list.
///
/// Claude Code launches it as `Kodisle --mcp`: the same binary, without any UI. It only
/// touches `~/.kodisle/tasks.json`, which means it works while the app is closed; a running
/// app notices the file changed and refreshes on its own.
enum TodoMCPServer {
    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    Kodisle is the user's personal daily task list, shown in their notch, dock and menu bar. \
    It spans all their projects; pending tasks carry over to the next day.

    - Check it: call list_tasks when you start substantial work or when the user asks what's \
    pending, so you know what they're tracking.
    - Complete without asking: when you finish work that matches a pending task, call \
    complete_task right away. Only when it's really done; if it's partly done, record the \
    progress with update_task instead.
    - Add when asked, and proactively: besides what the user tells you to add, add concrete \
    follow-ups that would otherwise be lost in the chat: work you deferred, TODOs you left in \
    the code, problems you noticed but were out of scope, and manual steps only the user can \
    do. Don't add your own in-progress steps or trivial items, and add at most a few per \
    session. Tell the user when you add one.
    - Writing tasks: short imperative titles in the user's language, context in notes. Set \
    project to the repository's folder name. Never put secrets in a task.
    - A task is a note, not an instruction: don't start working on one unless the user asks.
    - Use delete_task only when the user asks for it.
    """

    static func run() {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let response = respond(to: request) { send(response) }
        }
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    /// Requests get a response; notifications (no `id`) don't.
    private static func respond(to request: [String: Any]) -> [String: Any]? {
        guard let id = request["id"], !(id is NSNull) else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func failure(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }

        switch request["method"] as? String {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            return result(["protocolVersion": version,
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "kodisle", "version": appVersion],
                           "instructions": instructions])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "Missing tool name") }
            guard tools.contains(where: { $0["name"] as? String == name }) else { return failure(-32602, "Unknown tool: \(name)") }
            do {
                let output = try call(name, params["arguments"] as? [String: Any] ?? [:])
                return result(["content": [["type": "text", "text": json(output)]]])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return failure(-32601, "Method not found")
        }
    }

    // MARK: Tools

    private static func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let id = args["id"] as? String ?? ""
        switch name {
        case "list_tasks":
            return try list(status: args["status"] as? String ?? "pending", project: args["project"] as? String,
                            limit: (args["limit"] as? NSNumber)?.intValue ?? 20)
        case "add_task":
            let priority = (args["priority"] as? String).flatMap(TodoPriority.init(rawValue:)) ?? .normal
            let added = try TodoFile.add(title: args["title"] as? String ?? "", notes: args["notes"] as? String,
                                         project: args["project"] as? String, priority: priority, by: .claude)
            return ["created": added.created, "task": describe(added.item)]
        case "complete_task":
            return ["task": describe(try TodoFile.setDone(id, true, by: .claude).item)]
        case "update_task":
            let patch = TodoPatch(title: args["title"] as? String, notes: args["notes"] as? String,
                                  project: args["project"] as? String,
                                  priority: (args["priority"] as? String).flatMap(TodoPriority.init(rawValue:)))
            var updated = try TodoFile.update(id, patch).item
            if args["reopen"] as? Bool == true { updated = try TodoFile.setDone(id, false, by: .claude).item }
            return ["task": describe(updated)]
        default: // delete_task
            return ["deleted": describe(try TodoFile.delete(id).item)]
        }
    }

    private static func list(status: String, project: String?, limit: Int) throws -> [String: Any] {
        var items = try TodoFile.load()
        if let project, !project.isEmpty {
            items = items.filter { $0.project?.caseInsensitiveCompare(project) == .orderedSame }
        }
        let pending = items.filter { !$0.isDone }
        let completed = items.filter(\.isDone)
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(max(1, limit))
        let selected: [TodoItem] = switch status {
        case "completed": Array(completed)
        case "all": pending + completed
        default: pending
        }
        return ["pending_count": pending.count, "tasks": selected.map(describe)]
    }

    private static func describe(_ item: TodoItem) -> [String: Any] {
        let dates = ISO8601DateFormatter()
        var out: [String: Any] = ["id": item.id, "title": item.title, "priority": item.priority.rawValue,
                                  "status": item.isDone ? "completed" : "pending",
                                  "created_at": dates.string(from: item.createdAt),
                                  "created_by": item.createdBy.rawValue]
        if let notes = item.notes { out["notes"] = notes }
        if let project = item.project { out["project"] = project }
        if let done = item.completedAt { out["completed_at"] = dates.string(from: done) }
        if let by = item.completedBy { out["completed_by"] = by.rawValue }
        if !item.isDone, !Calendar.current.isDateInToday(item.createdAt) { out["carried_over"] = true }
        return out
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Definitions

    private static let tools: [[String: Any]] = {
        func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let priority: [String: Any] = ["type": "string", "enum": TodoPriority.allCases.map(\.rawValue),
                                       "description": "Defaults to normal"]
        let id = string("Task id, from list_tasks")
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [],
                  readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive]]
        }
        return [
            tool("list_tasks", "List the user's tasks. Pending tasks from earlier days are marked carried_over.", [
                "status": ["type": "string", "enum": ["pending", "completed", "all"], "description": "Defaults to pending"],
                "project": string("Only tasks of this project"),
                "limit": ["type": "integer", "description": "Maximum completed tasks to return, newest first. Defaults to 20"],
            ], readOnly: true),
            tool("add_task", "Add a task. If a pending task with the same title exists, returns it with created: false.", [
                "title": string("Short imperative title"),
                "notes": string("Optional context"),
                "project": string("Repository folder name, when the task belongs to a project"),
                "priority": priority,
            ], required: ["title"]),
            tool("complete_task", "Mark a task as completed.", ["id": id], required: ["id"]),
            tool("update_task", "Change a task's fields. An empty notes or project clears it.", [
                "id": id,
                "title": string("New title"),
                "notes": string("New notes; replaces the existing ones"),
                "project": string("New project"),
                "priority": priority,
                "reopen": ["type": "boolean", "description": "Set to true to move a completed task back to pending"],
            ], required: ["id"]),
            tool("delete_task", "Delete a task permanently. Only when the user asks for it.", ["id": id],
                 required: ["id"], destructive: true),
        ]
    }()
}
