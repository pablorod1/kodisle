import AppKit
import SwiftUI

struct TasksPanel: View {
    private var list: TodoList { .shared }
    @State private var draft = ""
    @State private var project: String?
    @State private var expandedID: String?
    @State private var showHistory = false

    var body: some View {
        let sections = list.sections(project: project)
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(symbol: "checklist", title: "Tasks", tint: .indigo, subtitle: summary) {
                if list.pendingCount + list.doneTodayCount > 0 {
                    UsageRing(percent: Double(list.doneTodayCount) / Double(list.pendingCount + list.doneTodayCount) * 100,
                              tint: .indigo, size: 26, lineWidth: 3.5, showsLabel: false)
                        .help("Done today")
                }
                if !list.projects.isEmpty { projectFilter }
            }

            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Add a task…", text: $draft).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(add)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))

            if let error = list.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }

            if sections.carriedOver.isEmpty && sections.today.isEmpty && sections.doneToday.isEmpty {
                EmptyHint(symbol: "checklist", text: "Nothing pending.\nPending tasks carry over to the next day.")
            }
            taskSection("Carried over", sections.carriedOver, showsAge: true)
            taskSection("Today", sections.today + sections.doneToday, showsAge: false)
            if !sections.history.isEmpty { history(sections.history) }
        }
        .onAppear { list.refreshDay() }
    }

    private var summary: String {
        let pending = list.pendingCount == 0 ? "All done" : "\(list.pendingCount) pending"
        return list.doneTodayCount > 0 ? "\(pending) · \(list.doneTodayCount) done today" : pending
    }

    private var projectFilter: some View {
        Menu {
            Button("All projects") { project = nil }
            Divider()
            ForEach(list.projects, id: \.self) { name in Button(name) { project = name } }
        } label: {
            Image(systemName: project == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .frame(width: 26, height: 26).background(Circle().fill(.primary.opacity(0.07)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(project ?? "Filter by project")
    }

    @ViewBuilder
    private func taskSection(_ title: String, _ items: [TodoItem], showsAge: Bool) -> some View {
        if !items.isEmpty {
            SectionLabel(text: title).padding(.top, 4)
            ForEach(items) { item in row(item, showsAge: showsAge) }
        }
    }

    private func row(_ item: TodoItem, showsAge: Bool) -> some View {
        TodoRow(item: item, age: showsAge ? Self.age(of: item, today: list.today) : nil, expandedID: $expandedID)
    }

    private func history(_ days: [(day: Date, items: [TodoItem])]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showHistory.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showHistory ? 90 : 0))
                    SectionLabel(text: "History")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            if showHistory {
                ForEach(days.prefix(30), id: \.day) { day, items in
                    Text(Self.dayTitle(day)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    ForEach(items) { item in row(item, showsAge: false) }
                }
            }
        }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        withAnimation(.snappy) { list.add(title, project: project) }
        draft = ""
    }

    private static func age(of item: TodoItem, today: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.createdAt), to: today).day ?? 0
        return days <= 1 ? "yesterday" : "\(days) days ago"
    }

    private static func dayTitle(_ day: Date) -> String {
        Calendar.current.isDateInYesterday(day) ? "Yesterday"
            : day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let age: String?
    @Binding var expandedID: String?
    private var list: TodoList { .shared }
    private var expanded: Bool { expandedID == item.id }

    private var meta: String {
        [item.project, age, item.isDone && item.completedBy == .claude ? "done by Claude" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Button {
                    withAnimation(.snappy) { list.toggle(item) }
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(item.isDone ? Color.green : item.priority == .high ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isDone ? "Mark as pending" : "Complete")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.priority == .high ? .semibold : .regular))
                        .foregroundStyle(item.isDone ? .secondary : item.priority == .low ? .secondary : .primary)
                        .strikethrough(item.isDone)
                        .lineLimit(expanded ? nil : 2)
                        .privacySensitive()
                    if !meta.isEmpty {
                        Text(meta).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                    }
                }
                Spacer(minLength: 0)
                if item.notes != nil {
                    Image(systemName: "note.text").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 3)
                }
                if item.createdBy == .claude {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.purple).padding(.top, 3)
                        .help("Added by Claude")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { expandedID = expanded ? nil : item.id }
            }
            if expanded {
                TodoEditor(item: item) { expandedID = nil }.id(item.id)
            }
        }
        .rowStyle()
        .contextMenu {
            Picker("Priority", selection: Binding(get: { item.priority }, set: { list.update(item, TodoPatch(priority: $0)) })) {
                ForEach(TodoPriority.allCases) { Text($0.label).tag($0) }
            }
            Button("Copy title") { Clipboard.copy(item.title) }
            Divider()
            Button("Delete", role: .destructive) { list.delete(item) }
        }
    }
}

/// Edits save when the editor closes, so a half-typed note is never lost.
private struct TodoEditor: View {
    let item: TodoItem
    let close: () -> Void
    @State private var title: String
    @State private var notes: String
    @State private var project: String
    @State private var priority: TodoPriority
    @State private var deleted = false

    init(item: TodoItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _title = State(initialValue: item.title)
        _notes = State(initialValue: item.notes ?? "")
        _project = State(initialValue: item.project ?? "")
        _priority = State(initialValue: item.priority)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Title", text: $title)
            TextField("Notes", text: $notes, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...6)
                .padding(7).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
                .privacySensitive()
            HStack(spacing: 8) {
                field("Project", text: $project)
                Picker("", selection: $priority) {
                    ForEach(TodoPriority.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            HStack {
                if let created = createdLine { Text(created).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                Spacer()
                Button("Delete", role: .destructive) {
                    deleted = true
                    withAnimation(.snappy) { TodoList.shared.delete(item) }
                }
                Button("Done") { withAnimation(.snappy, close) }
            }
            .controlSize(.small)
        }
        .onDisappear(perform: save)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(7).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
            .privacySensitive()
    }

    private var createdLine: String? {
        let author = item.createdBy == .claude ? "Added by Claude" : "Added"
        return "\(author) \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func save() {
        guard !deleted else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let patch = TodoPatch(title: trimmedTitle.isEmpty || trimmedTitle == item.title ? nil : trimmedTitle,
                              notes: notes == (item.notes ?? "") ? nil : notes,
                              project: project == (item.project ?? "") ? nil : project,
                              priority: priority == item.priority ? nil : priority)
        guard patch.title != nil || patch.notes != nil || patch.project != nil || patch.priority != nil else { return }
        TodoList.shared.update(item, patch)
    }
}
