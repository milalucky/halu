import SwiftUI

struct TasksView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var speech: SpeechInput
    @State private var showingDone = false
    @State private var checking: Set<UUID> = []

    var body: some View {
        if store.showingRecap {
            RecapView(tasks: store.items) { store.showingRecap = false }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if showingDone {
            DoneTasksView(store: store) { showingDone = false }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            list.transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var list: some View {
        let open = store.open
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "To do", detail: open.isEmpty ? nil : "\(open.count) left")
                if !store.tags.isEmpty { TagFilterMenu(store: store) }
                IconButton(icon: "chart.bar.fill", help: "Your week") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { store.showingRecap = true }
                }
            }
            InputField(placeholder: "Add a task or dictate it · #DTM adds a tag", text: $store.draft, speech: speech) {
                speech.stop()
                withAnimation(.spring(response: 0.3)) { store.add(store.draft) }
                store.draft = ""
            }
            // Typing "#" drops a list of tags under the field.
            .overlay(alignment: .topLeading) { TagSuggestions(store: store).offset(y: 40) }
            .zIndex(1)
            if !store.tags.isEmpty {
                DraftTags(store: store)
            }
            if let problem = speech.problem {
                Text(problem).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.orange)
            }

            if open.isEmpty {
                EmptyState(icon: "checkmark.seal", title: store.tagFilter.map { "Nothing for \($0)" } ?? "All clear",
                           subtitle: "Write down what you shouldn't forget today. Start with #DTM, #DS… to tag it.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(open) { task in
                            TaskRow(task: task, allTags: store.tags, checked: checking.contains(task.id),
                                    onToggleTag: { store.toggle($0, on: task.id) },
                                    onCheck: { check(task) },
                                    onRename: { store.rename(task.id, to: $0) },
                                    onDelete: { withAnimation { store.delete(task.id) } })
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { showingDone = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Done")
                    Text("\(store.done.count)").foregroundStyle(Theme.tertiary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .font(Theme.caption(12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func check(_ task: TaskItem) {
        withAnimation(.easeOut(duration: 0.18)) { _ = checking.insert(task.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.complete(task.id) }
            checking.remove(task.id)
        }
    }
}

/// A quiet colour per tag, the same every time.
enum TagColor {
    private static let palette = [Theme.accent, Theme.blue, Theme.green, Theme.orange, Theme.red,
                                  Color(red: 0.95, green: 0.55, blue: 0.85), Color(red: 0.4, green: 0.85, blue: 0.85)]

    static func of(_ tag: String) -> Color {
        let sum = tag.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

struct TagChip: View {
    let tag: String
    var selected = true

    var body: some View {
        Text(tag)
            .font(Theme.caption(10.5, weight: .semibold))
            .foregroundStyle(selected ? TagColor.of(tag) : Theme.tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(TagColor.of(tag).opacity(selected ? 0.16 : 0.05)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Show all tasks or one tag's.
private struct TagFilterMenu: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        Menu {
            Button {
                store.tagFilter = nil
            } label: {
                if store.tagFilter == nil { Label("All tasks", systemImage: "checkmark") } else { Text("All tasks") }
            }
            Divider()
            ForEach(store.tags, id: \.self) { tag in
                Button {
                    store.tagFilter = tag
                } label: {
                    let title = "\(tag)  \(store.openCount(tag))"
                    if store.tagFilter == tag { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            Divider()
            Menu("Remove a tag") {
                ForEach(store.tags, id: \.self) { tag in Button(tag) { store.forget(tag) } }
            }
        } label: {
            HStack(spacing: 4) {
                if let filter = store.tagFilter { Circle().fill(TagColor.of(filter)).frame(width: 6, height: 6) }
                Text(store.tagFilter ?? "All tags")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.caption(11.5, weight: .semibold))
            .foregroundStyle(store.tagFilter == nil ? Theme.tertiary : Theme.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show tasks with one tag; new tasks get it too")
    }
}

/// While the last word of the new task starts with "#": matching tags to click, or a new one to create.
private struct TagSuggestions: View {
    @ObservedObject var store: TaskStore

    /// The "#tag" being typed, without the "#".
    private var typed: String? {
        guard !store.draft.hasSuffix(" "), let last = store.draft.split(separator: " ").last, last.hasPrefix("#") else { return nil }
        return String(last.dropFirst())
    }

    var body: some View {
        if let typed {
            let matches = store.tags.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed.lowercased()) }
            let isNew = !typed.isEmpty && !store.tags.contains { $0.caseInsensitiveCompare(typed) == .orderedSame }
            if !matches.isEmpty || isNew {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches.prefix(6), id: \.self) { tag in
                        row(TagChip(tag: tag), tag: tag)
                    }
                    if isNew {
                        row(HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                            Text("Create #\(typed)").font(Theme.caption(11.5, weight: .semibold))
                        }.foregroundStyle(Theme.accent), tag: typed)
                    }
                }
                .padding(4)
                .frame(width: 220, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
            }
        }
    }

    private func row(_ label: some View, tag: String) -> some View {
        SuggestionRow(label: AnyView(label)) {
            // Swap the half-typed "#ta" for the full "#Tag ".
            var words = store.draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if !words.isEmpty { words.removeLast() }
            store.draft = (words + ["#" + tag]).joined(separator: " ") + " "
        }
    }

    private struct SuggestionRow: View {
        let label: AnyView
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.cardHover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// Tags for the task being written: picked ones, and a menu to add more.
private struct DraftTags: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        HStack(spacing: 5) {
            if let filter = store.tagFilter { TagChip(tag: filter) }
            ForEach(store.draftTags.filter { $0 != store.tagFilter }, id: \.self) { tag in
                Button { store.toggleDraftTag(tag) } label: { TagChip(tag: tag) }
                    .buttonStyle(.plain)
                    .help("Remove")
            }
            Menu {
                ForEach(store.tags.filter { $0 != store.tagFilter }, id: \.self) { tag in
                    Button {
                        store.toggleDraftTag(tag)
                    } label: {
                        if store.draftTags.contains(tag) { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "tag").font(.system(size: 9, weight: .bold))
                    Text("Tag")
                }
                .font(Theme.caption(10.5, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let allTags: [String]
    let checked: Bool
    let onToggleTag: (String) -> Void
    let onCheck: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HoverRow { hovering in
            HStack(spacing: 11) {
                Button(action: onCheck) {
                    ZStack {
                        Circle()
                            .strokeBorder(checked ? Theme.accent : Theme.tertiary, lineWidth: 1.4)
                            .background(Circle().fill(checked ? Theme.accent : .clear))
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(.black)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 17, height: 17)
                    .overlay { if checked { Burst(tint: Theme.accent) } }
                    .scaleEffect(checked ? 1.15 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: checked)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)

                if editing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(Theme.body())
                        .foregroundStyle(Theme.primary)
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { editing = false }
                } else {
                    Text(task.title)
                        .font(Theme.body())
                        .foregroundStyle(checked ? Theme.tertiary : Theme.primary)
                        .strikethrough(checked, color: Theme.tertiary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { startEditing() }
                    HStack(spacing: 4) {
                        ForEach(task.tags, id: \.self) { TagChip(tag: $0) }
                    }
                }

                if hovering && !editing {
                    IconButton(icon: "pencil", help: "Edit", action: startEditing)
                    IconButton(icon: "trash", help: "Delete", action: onDelete)
                }
            }
        }
        .contextMenu {
            Button("Edit", action: startEditing)
            if !allTags.isEmpty {
                Menu("Tags") {
                    ForEach(allTags, id: \.self) { tag in
                        Button { onToggleTag(tag) } label: {
                            if task.tags.contains(tag) { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                        }
                    }
                }
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func startEditing() {
        text = task.title
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        onRename(text)
        editing = false
    }
}

private struct DoneTasksView: View {
    @ObservedObject var store: TaskStore
    let onBack: () -> Void
    @State private var query = ""

    private var groups: [(day: Date, items: [TaskItem])] {
        let filtered = store.done.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.doneAt ?? .now) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                IconButton(icon: "chevron.left", help: "Back", action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { onBack() }
                })
                SectionHeader(title: "Done", detail: "\(store.done.count) total")
            }
            InputField(placeholder: "Search completed tasks", icon: "magnifyingglass", text: $query)

            if groups.isEmpty {
                EmptyState(icon: "tray", title: query.isEmpty ? "Nothing here yet" : "No matches",
                           subtitle: query.isEmpty ? "Tasks you check off land here." : "Try another word.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(groups, id: \.day) { group in
                            Text(Fmt.dayTitle(group.day).uppercased())
                                .font(Theme.caption(10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 10)
                            ForEach(group.items) { task in
                                HoverRow { hovering in
                                    HStack(spacing: 11) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.accent.opacity(0.55))
                                        Text(task.title)
                                            .font(Theme.body())
                                            .foregroundStyle(Theme.secondary)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        ForEach(task.tags, id: \.self) { TagChip(tag: $0, selected: false) }
                                        if hovering {
                                            IconButton(icon: "arrow.uturn.backward", help: "Move back to To do") {
                                                withAnimation { store.restore(task.id) }
                                            }
                                            IconButton(icon: "trash", help: "Delete") {
                                                withAnimation { store.delete(task.id) }
                                            }
                                        } else if let doneAt = task.doneAt {
                                            Text(Fmt.time.string(from: doneAt))
                                                .font(Theme.caption())
                                                .foregroundStyle(Theme.tertiary)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}
