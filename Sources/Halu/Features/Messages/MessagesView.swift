import SwiftUI

struct MessagesView: View {
    @ObservedObject var store: MessagesStore

    var body: some View {
        Group {
            switch store.access {
            case .needsFullDiskAccess:
                EmptyState(icon: "bubble.left.and.bubble.right", title: "Allow Full Disk Access",
                           subtitle: "Halu shows new Slack, Telegram and mail messages from the notifications your Mac already gets. macOS keeps them in a protected place: turn on Halu in Privacy & Security → Full Disk Access.",
                           action: ("Open Settings", store.openFullDiskAccessSettings))
            case .unreadable:
                EmptyState(icon: "exclamationmark.bubble", title: "Can't read notifications",
                           subtitle: "This version of macOS stores them differently. Messages will need an update.")
            default:
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if store.apps.count > 1 {
                    FilterChip(title: "All", selected: store.appFilter == nil) { store.appFilter = nil }
                    ForEach(store.apps, id: \.self) { app in
                        FilterChip(title: app, color: SourceColor.of(app), selected: store.appFilter == app) { store.appFilter = app }
                    }
                }
                Spacer()
                if store.telegramFolders.count > 1 {
                    TelegramFolderMenu(store: store)
                }
                if !store.visible.isEmpty {
                    Button("Clear") { withAnimation { store.dismissAll() } }
                        .buttonStyle(.plain)
                        .font(Theme.caption(11.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            if store.visible.isEmpty {
                EmptyState(icon: "bubble.left.and.bubble.right", title: "All read",
                           subtitle: "Unread Slack, Telegram and mail messages show up here, and leave once you read them in their app.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.visible) { message in
                            MessageRow(message: message, store: store)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// A quiet colour per source instead of app icons.
enum SourceColor {
    static func of(_ source: String) -> Color {
        switch source {
        case "Slack": Color(red: 0.88, green: 0.36, blue: 0.56)
        case "Telegram": Color(red: 0.36, green: 0.70, blue: 0.95)
        case "Gmail", "Mail", "Outlook", "Spark": Color(red: 0.96, green: 0.52, blue: 0.42)
        default: Theme.accent
        }
    }
}

private struct FilterChip: View {
    let title: String
    var color: Color?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title)
            }
                .font(Theme.caption(11.5, weight: .semibold))
                .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Theme.primary : Theme.card))
        }
        .buttonStyle(.plain)
    }
}

/// Which Telegram folder Messages follows, from the folders of the Telegram Web tab.
private struct TelegramFolderMenu: View {
    @ObservedObject var store: MessagesStore

    var body: some View {
        Menu {
            ForEach(store.telegramFolders, id: \.self) { folder in
                Button {
                    store.telegramFolder = folder
                } label: {
                    if folder.lowercased() == current.lowercased() { Label(folder, systemImage: "checkmark") } else { Text(folder) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(SourceColor.of("Telegram")).frame(width: 6, height: 6)
                Text(current)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.caption(11.5, weight: .medium))
            .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Telegram folder to follow")
    }

    private var current: String {
        store.telegramFolder.isEmpty ? (store.telegramFolders.first ?? "All") : store.telegramFolder
    }
}

private struct MessageRow: View {
    let message: IncomingMessage
    @ObservedObject var store: MessagesStore

    var body: some View {
        HoverRow { hovering in
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(SourceColor.of(message.appName))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.title.isEmpty ? message.appName : message.title)
                            .font(Theme.body(12.5, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !message.subtitle.isEmpty {
                            Text(message.subtitle).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if hovering {
                            IconButton(icon: "xmark", help: "Dismiss", size: 9) { withAnimation { store.dismiss(message) } }
                        } else {
                            Text(Fmt.ago(message.date)).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    Text(message.body)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
        }
        .onTapGesture { store.open(message) }
        .help("Open in \(message.appName)")
    }
}
