import SwiftUI

struct GitLabView: View {
    @ObservedObject var store: GitLabStore
    let openSettings: () -> Void

    var body: some View {
        if !store.isConnected {
            EmptyState(icon: "arrow.triangle.branch", title: "Connect GitLab",
                       subtitle: "See your merge requests, the ones waiting for your review, and new comments. Add your GitLab server and a read-only token in Settings.",
                       action: ("Open Settings", openSettings))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Chip(title: "All", count: store.requests.count, selected: store.filter == nil && !store.showingPipelines) {
                        store.filter = nil
                        store.showingPipelines = false
                    }
                    Chip(title: "Mine", count: store.requests.filter { $0.role == .mine }.count, selected: store.filter == .mine && !store.showingPipelines) {
                        store.filter = .mine
                        store.showingPipelines = false
                    }
                    Chip(title: "To review", count: store.requests.filter { $0.role == .review }.count, selected: store.filter == .review && !store.showingPipelines) {
                        store.filter = .review
                        store.showingPipelines = false
                    }
                    Chip(title: "Pipelines", count: store.pipelines.count, selected: store.showingPipelines) { store.showingPipelines = true }
                    Spacer()
                    if store.newComments > 0 {
                        Text("\(store.newComments) new comment\(store.newComments == 1 ? "" : "s")")
                            .font(Theme.caption(11.5, weight: .semibold))
                            .foregroundStyle(Theme.orange)
                    }
                    if store.isLoading { ProgressView().controlSize(.mini) }
                    IconButton(icon: "arrow.clockwise", help: "Refresh", action: store.refresh)
                }
                if let problem = store.problem {
                    Text(problem).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.orange)
                }
                if store.showingPipelines {
                    if store.pipelines.isEmpty {
                        EmptyState(icon: "gearshape.2", title: "No pipelines today", subtitle: "Pipelines you start show up here, with a note from the notch when they finish.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(store.pipelines) { PipelineRow(pipeline: $0) }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                } else if store.visible.isEmpty {
                    EmptyState(icon: "checkmark.circle", title: "Nothing open", subtitle: "No open merge requests here.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.visible) { request in
                                MRRow(request: request, comments: store.comments[request.id] ?? [], store: store)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Theme.onPrimary.opacity(0.6) : Theme.tertiary)
            }
            .font(Theme.caption(11.5, weight: .semibold))
            .foregroundStyle(selected ? Theme.onPrimary : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Theme.primary : Theme.card))
        }
        .buttonStyle(.plain)
    }
}

struct PipelineIcon: View {
    let status: Pipeline.Status

    var body: some View {
        Image(systemName: status.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PipelineIcon.tint(status))
            .symbolEffect(.rotate, options: .repeating, isActive: status == .running)
    }

    static func tint(_ status: Pipeline.Status) -> Color {
        switch status {
        case .success: Theme.green
        case .failed: Theme.red
        case .running: Theme.blue
        case .pending, .created, .preparing, .waiting_for_resource: Theme.orange
        default: Theme.tertiary
        }
    }
}

private struct PipelineRow: View {
    let pipeline: Pipeline

    var body: some View {
        HoverRow { _ in
            HStack(spacing: 10) {
                PipelineIcon(status: pipeline.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pipeline.project).font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    Text(pipeline.ref).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer()
                Text(pipeline.status.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(Theme.caption(11, weight: .semibold))
                    .foregroundStyle(PipelineIcon.tint(pipeline.status))
                Text(Fmt.ago(pipeline.updatedAt)).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
            }
        }
        .onTapGesture { NSWorkspace.shared.open(pipeline.url) }
        .help("Open in GitLab")
    }
}

private struct MRRow: View {
    let request: MergeRequest
    let comments: [MRComment]
    @ObservedObject var store: GitLabStore

    var body: some View {
        HoverRow { hovering in
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(comments.isEmpty ? (request.role == .review ? Theme.blue : Theme.accent) : Theme.orange)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let status = request.pipeline { PipelineIcon(status: status).help("Pipeline: \(status.rawValue)") }
                        if request.isDraft { Text("Draft").font(Theme.caption(10, weight: .bold)).foregroundStyle(Theme.tertiary) }
                        Text(request.title).font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        if hovering && !comments.isEmpty {
                            IconButton(icon: "checkmark", help: "Mark comments as read", size: 9) { store.markSeen(request) }
                        } else {
                            Text(Fmt.ago(request.updatedAt)).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(request.reference).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        if request.role == .review { Text("by \(request.author)").font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary) }
                        if request.unresolved { Label("Unresolved threads", systemImage: "bubble.left.and.exclamationmark.bubble.right").labelStyle(.iconOnly).foregroundStyle(Theme.orange).help("Unresolved threads") }
                        if request.conflicts { Text("Conflicts").font(Theme.caption(10, weight: .semibold)).foregroundStyle(Theme.red) }
                        if request.notes > 0 {
                            Label("\(request.notes)", systemImage: "text.bubble").font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    ForEach(comments.prefix(2)) { comment in
                        Text("\(comment.author): \(comment.body.replacingOccurrences(of: "\n", with: " "))")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    if comments.count > 2 {
                        Text("+\(comments.count - 2) more").font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.orange)
                    }
                }
            }
        }
        .onTapGesture { store.open(request) }
        .help("Open in GitLab")
    }
}
