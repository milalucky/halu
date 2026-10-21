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
                SourceOptions(store: store)
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

/// Options of the selected source: Telegram folder, Gmail inbox, Slack scope.
private struct SourceOptions: View {
    @ObservedObject var store: MessagesStore

    var body: some View {
        switch store.appFilter {
        case "Telegram" where store.telegramFolders.count > 1:
            let current = store.telegramFolder.isEmpty ? "All" : store.telegramFolder
            OptionsMenu(source: "Telegram", title: current, help: "Telegram folder to follow",
                        options: store.telegramFolders.map { folder in
                            (folder, folder.lowercased() == current.lowercased(), { store.telegramFolder = folder == "All" ? "" : folder })
                        })
        case "Gmail" where store.gmailAccounts.count > 1 || !store.gmailAccount.isEmpty:
            OptionsMenu(source: "Gmail", title: store.gmailAccount.isEmpty ? "All inboxes" : store.gmailAccount, help: "Gmail inbox to follow",
                        options: [("All inboxes", store.gmailAccount.isEmpty, { store.gmailAccount = "" })]
                            + store.gmailAccounts.map { email in (email, email == store.gmailAccount, { store.gmailAccount = email }) })
        case "Slack":
            OptionsMenu(source: "Slack", title: store.slackOnlyPersonal ? "Mentions & DMs" : "All unread", help: "What to show from Slack",
                        options: [("All unread", !store.slackOnlyPersonal, { store.slackOnlyPersonal = false }),
                                  ("Mentions & DMs", store.slackOnlyPersonal, { store.slackOnlyPersonal = true })])
        default:
            EmptyView()
        }
    }
}

private struct OptionsMenu: View {
    let source: String
    let title: String
    let help: String
    let options: [(String, Bool, () -> Void)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button(action: option.2) {
                    if option.1 { Label(option.0, systemImage: "checkmark") } else { Text(option.0) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(SourceColor.of(source)).frame(width: 6, height: 6)
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.caption(11.5, weight: .medium))
            .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
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
                            Text(message.subtitle)
                                .font(Theme.caption(11, weight: message.isPersonal ? .semibold : .regular))
                                .foregroundStyle(message.isPersonal ? Theme.accent : Theme.tertiary)
                                .lineLimit(1)
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
