import SwiftUI

/// Settings → Integrations: where API tokens are entered. Tokens go to the Keychain.
struct IntegrationsView: View {
    @ObservedObject var jira: JiraStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Integrations", detail: "Tokens are stored in your Keychain")
                JiraCard(store: jira)
                ComingSoonCard(icon: "number", name: "Slack", detail: "New messages in the Messages tab")
                ComingSoonCard(icon: "paperplane", name: "Telegram", detail: "New messages in the Messages tab")
            }
        }
        .scrollIndicators(.never)
    }
}

private struct JiraCard: View {
    @ObservedObject var store: JiraStore
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
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
                Field(placeholder: "your-company.atlassian.net", text: $site)
                Field(placeholder: "Work email", text: $email)
                Field(placeholder: "API token", text: $token, secure: true)
                HStack {
                    Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                        .font(Theme.caption(11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    PillButton(title: "Connect") {
                        connecting = true
                        Task {
                            problem = await store.connect(site: site, email: email, token: token)
                            connecting = false
                            if problem == nil { token = "" }
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
        .onAppear {
            site = store.site
            email = store.email
        }
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
