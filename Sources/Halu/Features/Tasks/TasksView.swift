import SwiftUI

struct TasksView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var speech: SpeechInput
    @State private var showingDone = false
    @State private var checking: Set<UUID> = []

    var body: some View {
        if showingDone {
            DoneTasksView(store: store) { showingDone = false }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            list.transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var list: some View {
        let open = store.open
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "To do", detail: open.isEmpty ? nil : "\(open.count) left")
            InputField(placeholder: "Add a task or dictate it", text: $store.draft, speech: speech) {
                speech.stop()
                withAnimation(.spring(response: 0.3)) { store.add(store.draft) }
                store.draft = ""
            }
            if let problem = speech.problem {
                Text(problem).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.orange)
            }

            if open.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "All clear",
                           subtitle: "Write down what you shouldn't forget today.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(open) { task in
                            TaskRow(task: task, checked: checking.contains(task.id),
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

private struct TaskRow: View {
    let task: TaskItem
    let checked: Bool
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
                }

                if hovering && !editing {
                    IconButton(icon: "pencil", help: "Edit", action: startEditing)
                    IconButton(icon: "trash", help: "Delete", action: onDelete)
                }
            }
        }
        .contextMenu {
            Button("Edit", action: startEditing)
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
