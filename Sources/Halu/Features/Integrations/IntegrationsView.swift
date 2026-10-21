import SwiftUI

/// Settings: which tabs show, and the integrations with their API tokens (kept in the Keychain).
struct IntegrationsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var jira: JiraStore
    @ObservedObject var gitlab: GitLabStore
    @ObservedObject var messages: MessagesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Tabs", detail: "Turned-off tabs disappear and stop working in the background")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(AppModel.configurable) { tab in
                        TabToggle(tab: tab, model: model)
                    }
                }
                SectionHeader(title: "Integrations", detail: "Jira's token stays in your Keychain; the rest is read from open tabs")
                    .padding(.top, 8)
                JiraCard(store: jira)
                GitLabCard(store: gitlab)
                ForEach(WebInbox.Site.allCases, id: \.self) { site in
                    WebSourceCard(site: site, accounts: messages.webAccounts[site.rawValue])
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct TabToggle: View {
    let tab: Tab
    @ObservedObject var model: AppModel

    var body: some View {
        let enabled = model.isEnabled(tab)
        HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primary : Theme.tertiary)
                .frame(width: 18)
            Text(tab.title)
                .font(Theme.body(12.5, weight: .medium))
                .foregroundStyle(enabled ? Theme.primary : Theme.tertiary)
            Spacer()
            Toggle("", isOn: Binding(get: { enabled }, set: { model.setEnabled(tab, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
    }
}

private struct JiraCard: View {
    @ObservedObject var store: JiraStore
    @State private var problem: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "ticket").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.blue)
                Text("Jira").font(Theme.body(13.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                if store.isConnected {
                    Text("Connected").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.green)
                }
            }

            if store.isConnected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.accountName ?? store.email).font(Theme.body(12.5)).foregroundStyle(Theme.primary)
                        Text(store.site).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    PillButton(title: "Disconnect", tint: Theme.red, prominent: false, action: store.disconnect)
                }
            } else {
                Field(placeholder: "your-company.atlassian.net", text: $store.draftSite)
                Field(placeholder: "Work email", text: $store.draftEmail)
                Field(placeholder: "API token", text: $store.draftToken, secure: true)
                HStack {
                    Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                        .font(Theme.caption(11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    PillButton(title: "Connect") {
                        connecting = true
                        Task {
                            problem = await store.connect(site: store.draftSite, email: store.draftEmail, token: store.draftToken)
                            connecting = false
                            if problem == nil { store.draftToken = "" }
                        }
                    }
                }
                if let problem {
                    Text(problem).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.orange)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

private struct GitLabCard: View {
    @ObservedObject var store: GitLabStore
    @State private var problem: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.orange)
                Text("GitLab").font(Theme.body(13.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                if store.isConnected {
                    Text("Connected").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.green)
                }
            }
            if store.isConnected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.userName ?? "").font(Theme.body(12.5)).foregroundStyle(Theme.primary)
                        Text(store.server).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    PillButton(title: "Disconnect", tint: Theme.red, prominent: false, action: store.disconnect)
                }
            } else {
                Field(placeholder: "gitlab.your-company.com", text: $store.draftServer)
                Field(placeholder: "Personal access token (read_api)", text: $store.draftToken, secure: true)
                HStack {
                    if let link = tokenPage {
                        Link("Create a token", destination: link)
                            .font(Theme.caption(11.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    PillButton(title: "Connect") {
                        connecting = true
                        Task {
                            problem = await store.connect()
                            connecting = false
                        }
                    }
                }
                Text("Read-only: Halu only looks at merge requests and comments.")
                    .font(Theme.caption(11, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                if let problem {
                    Text(problem).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.orange)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    /// The server's own token page, with the name and scope filled in.
    private var tokenPage: URL? {
        var host = store.draftServer.trimmingCharacters(in: .whitespaces)
        guard host.contains(".") else { return nil }
        if !host.hasPrefix("http") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        return URL(string: host + "/-/user_settings/personal_access_tokens?name=Halu&scopes=read_api")
    }
}

private struct Field: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
            }
        }
        .textFieldStyle(.plain)
        .font(Theme.body(12.5))
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Slack, Gmail and Telegram need no tokens: Messages reads them from their open browser tabs.
private struct WebSourceCard: View {
    let site: WebInbox.Site
    /// Nil while no tab of the site is open.
    let accounts: [String]?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(SourceColor.of(site.rawValue)).frame(width: 8, height: 8).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.rawValue).font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(detail).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            Text(accounts == nil ? "No open tab" : "Connected")
                .font(Theme.caption(11, weight: .semibold))
                .foregroundStyle(accounts == nil ? Theme.tertiary : Theme.green)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    private var detail: String {
        guard let accounts else { return "Keep \(site.host) open in Chrome, even in the background" }
        let what = switch site {
        case .slack: "Direct messages and mentions"
        case .gmail: "Unread mail"
        case .telegram: "Unread chats"
        }
        return accounts.isEmpty ? "\(what), from the open tab" : "\(what) · " + accounts.joined(separator: ", ")
    }
}
