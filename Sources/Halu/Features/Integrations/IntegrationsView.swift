import SwiftUI

/// Settings: which tabs show, and the integrations with their API tokens (kept in the Keychain).
struct IntegrationsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var jira: JiraStore
    @ObservedObject var mail: MailStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Tabs", detail: "Turned-off tabs disappear and stop working in the background")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(AppModel.configurable) { tab in
                        TabToggle(tab: tab, model: model)
                    }
                }
                SectionHeader(title: "Integrations", detail: "Tokens are stored in your Keychain")
                    .padding(.top, 8)
                JiraCard(store: jira)
                MailCard(store: mail)
                ComingSoonCard(icon: "number", name: "Slack", detail: "New messages in the Messages tab")
                ComingSoonCard(icon: "paperplane", name: "Telegram", detail: "New messages in the Messages tab")
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

private struct MailCard: View {
    @ObservedObject var store: MailStore
    @State private var problem: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "envelope").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.red)
                Text("Mail").font(Theme.body(13.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("unread mail in Messages").font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary)
                Spacer()
                if store.isConnected {
                    Text("Connected").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.green)
                }
            }

            if store.isConnected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.email).font(Theme.body(12.5)).foregroundStyle(Theme.primary)
                        Text(store.problem ?? store.lastCheck.map { "Checked \(Fmt.ago($0))" } ?? store.provider.rawValue)
                            .font(Theme.caption(11, weight: .regular))
                            .foregroundStyle(store.problem == nil ? Theme.tertiary : Theme.orange)
                    }
                    Spacer()
                    PillButton(title: "Disconnect", tint: Theme.red, prominent: false, action: store.disconnect)
                }
            } else {
                Picker("", selection: $store.draftProvider) {
                    ForEach(MailStore.Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if store.draftProvider == .custom {
                    Field(placeholder: "IMAP server, e.g. imap.company.com", text: $store.draftHost)
                }
                Field(placeholder: "Work email", text: $store.draftEmail)
                Field(placeholder: "App password", text: $store.draftPassword, secure: true)
                HStack {
                    if let help = store.draftProvider.passwordHelp {
                        Link("Create an app password", destination: help)
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
                Text("Read-only: Halu only looks at what's unread and never marks anything as read. The password stays in your Keychain.")
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
}

private struct ComingSoonCard: View {
    let icon: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(detail).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text("Soon").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card.opacity(0.6)))
    }
}
