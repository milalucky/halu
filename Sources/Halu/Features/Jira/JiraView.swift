import SwiftUI

struct JiraView: View {
    @ObservedObject var store: JiraStore
    let openSettings: () -> Void

    var body: some View {
        if !store.isConnected {
            EmptyState(icon: "ticket", title: "Connect Jira",
                       subtitle: "See the issues assigned to you and move them along without opening the browser.",
                       action: ("Open Integrations", openSettings))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // Only worth a switcher when there's more than one project to switch between.
                    if store.projects.count > 1 || store.project != nil {
                        Menu {
                            Button("All projects") { store.project = nil }
                            Divider()
                            ForEach(store.projects) { project in
                                Button("\(project.key) · \(project.name)") { store.project = project.key }
                            }
                        } label: {
                            Text(store.project ?? "All").font(Theme.body(12.5, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(store.projectName)
                    }
                    Picker("", selection: $store.mode) {
                        ForEach(JiraStore.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    if store.mode == .queue {
                        Menu {
                            if store.statuses.isEmpty { Text("Loading…") }
                            ForEach(store.statuses, id: \.self) { status in
                                Button(status) { store.queueStatus = status }
                            }
                        } label: {
                            Text(store.queueStatus ?? "Choose status").font(Theme.body(12.5, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .onAppear { if store.statuses.isEmpty { store.loadStatuses() } }
                    }
                    Spacer()
                    if store.isLoading { ProgressView().controlSize(.small) }
                    IconButton(icon: "arrow.clockwise", help: "Refresh", size: 11, action: store.refresh)
                }
                if let problem = store.problem {
                    Text(problem).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.orange)
                }
                if store.issues.isEmpty && !store.isLoading {
                    EmptyState(icon: "checkmark.seal", title: "Nothing here",
                               subtitle: store.mode == .queue && store.queueStatus == nil
                                   ? "Pick a status to see every issue in it, whoever it's assigned to."
                                   : "No issues in this view.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.issues) { issue in
                                IssueRow(issue: issue, store: store, showAssignee: store.mode == .queue)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                HStack(spacing: 8) {
                    Text(countText).monospacedDigit()
                    if !store.hiddenStatuses.isEmpty {
                        Menu {
                            ForEach(store.hiddenStatuses, id: \.self) { status in
                                Button("Show “\(status)”") { store.showStatus(status) }
                            }
                        } label: {
                            Text("\(store.hiddenStatuses.count) hidden status\(store.hiddenStatuses.count == 1 ? "" : "es")")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Spacer()
                }
                .font(Theme.caption(11.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var countText: String {
        let count = store.issues.count
        let number = count >= store.pageLimit ? "\(count)+" : "\(count)"
        return count == 1 ? "1 issue" : "\(number) issues"
    }
}

private struct IssueRow: View {
    let issue: JiraIssue
    @ObservedObject var store: JiraStore
    var showAssignee = false
    @State private var transitions: [JiraTransition] = []

    private var statusTint: Color {
        switch issue.category {
        case .todo: Theme.tertiary
        case .inProgress: Theme.blue
        case .done: Theme.green
        }
    }

    var body: some View {
        HoverRow { hovering in
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: issue.type))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.tint(for: issue.type))
                    .frame(width: 14)
                    .help(issue.type)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.summary)
                        .font(Theme.body(12.5, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(issue.key).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        if showAssignee { Text("· \(issue.assignee ?? "Unassigned")") }
                        if let priority = issue.priority, !showAssignee { Text("· \(priority)") }
                        Text("· \(Fmt.ago(issue.updated))")
                    }
                    .font(Theme.caption(10.5, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 6)

                if store.busy.contains(issue.key) {
                    ProgressView().controlSize(.small)
                } else if hovering {
                    if issue.category == .todo {
                        PillButton(title: "Start", icon: "play.fill", tint: Theme.blue) { store.startProgress(issue) }
                    }
                    Menu {
                        if transitions.isEmpty { Text("Loading…") }
                        ForEach(transitions) { transition in
                            Button(transition.name) { store.perform(transition, on: issue) }
                        }
                        Divider()
                        Button("Hide “\(issue.status)” issues") { withAnimation { store.hideStatus(issue.status) } }
                        Button("Copy \(issue.key)") { store.copyKey(issue) }
                        Button("Open in Browser") { store.open(issue) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .task { transitions = await store.transitions(for: issue) }
                } else {
                    Text(issue.status)
                        .font(Theme.caption(10.5, weight: .semibold))
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusTint.opacity(0.14)))
                        .lineLimit(1)
                }
            }
        }
        .onTapGesture(count: 2) { store.open(issue) }
        .help("Double-click to open \(issue.key)")
    }

    private static func icon(for type: String) -> String {
        switch type.lowercased() {
        case let name where name.contains("bug"): "ladybug.fill"
        case let name where name.contains("story"): "bookmark.fill"
        case let name where name.contains("epic"): "bolt.fill"
        case let name where name.contains("sub"): "arrow.turn.down.right"
        default: "checkmark.square.fill"
        }
    }

    private static func tint(for type: String) -> Color {
        switch type.lowercased() {
        case let name where name.contains("bug"): Theme.red
        case let name where name.contains("story"): Theme.green
        case let name where name.contains("epic"): Theme.accent
        default: Theme.blue
        }
    }
}
