import SwiftUI

struct AccountsView: View {
    @ObservedObject var store: AccountStore
    @State private var query = ""
    @State private var importNote: String?

    private var groups: [(service: String, accounts: [Account])] {
        let filtered = store.accounts.filter { account in
            (store.serviceFilter.map { filter in AccountStore.tags(of: account.service).contains { $0.caseInsensitiveCompare(filter) == .orderedSame } } ?? true)
                && (query.isEmpty || [account.service, account.login, account.notes].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let grouped = Dictionary(grouping: filtered, by: \.service)
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, grouped[$0] ?? []) }
    }

    private func count(_ tag: String) -> Int {
        store.accounts.filter { AccountStore.tags(of: $0.service).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
    }

    private func report(_ added: Int) {
        withAnimation { importNote = added == 0 ? "Nothing new to import. Expected Service · Login · Password · Notes." : "Imported \(added) account\(added == 1 ? "" : "s")" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { importNote = nil } }
    }

    var body: some View {
        if let problem = store.problem {
            EmptyState(icon: "lock", title: "Accounts are locked", subtitle: problem,
                       action: ("Try again", store.start))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                InputField(placeholder: "Search service, login or note", icon: "magnifyingglass", text: $query)
                if store.serviceTags.count > 1 {
                    ServiceMenu(store: store, count: count)
                }
                Menu {
                    Button("From a file…  (Markdown, CSV)") {
                        if let added = store.chooseFileToImport() { report(added) }
                    }
                    Button("From the clipboard") { report(store.importFromClipboard()) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import accounts: a Markdown or CSV file, or table rows copied to the clipboard (Service · Login · Password · Notes)")
                IconButton(icon: "plus", help: "Add account", size: 12) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.editing = Account(service: query, login: "", password: "", notes: "")
                    }
                }
            }
            if let importNote {
                Text(importNote).font(Theme.caption(11, weight: .medium)).foregroundStyle(Theme.accent)
            }

            if let account = store.editing {
                AccountEditor(account: Binding(get: { store.editing ?? account }, set: { store.editing = $0 }),
                              services: store.services) { saved in
                    store.save(saved)
                    withAnimation(.easeOut(duration: 0.2)) { store.editing = nil }
                } onCancel: {
                    withAnimation(.easeOut(duration: 0.2)) { store.editing = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if groups.isEmpty && store.editing == nil {
                EmptyState(icon: "key.horizontal", title: query.isEmpty ? "No accounts yet" : "No matches",
                           subtitle: query.isEmpty ? "Add test accounts one by one, or import a Markdown or CSV file, or rows copied from a table." : "Try another word.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.service) { group in
                            HStack(spacing: 6) {
                                SmallCaps(group.service)
                                Text("\(group.accounts.count)")
                                    .font(Theme.caption(10, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.accounts) { account in
                                AccountRow(account: account, store: store) {
                                    withAnimation(.easeOut(duration: 0.2)) { store.editing = account }
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

/// Which service to show: all, or one (with how many accounts each has).
private struct ServiceMenu: View {
    @ObservedObject var store: AccountStore
    let count: (String) -> Int

    var body: some View {
        Menu {
            Button {
                store.serviceFilter = nil
            } label: {
                if store.serviceFilter == nil { Label("All  \(store.accounts.count)", systemImage: "checkmark") } else { Text("All  \(store.accounts.count)") }
            }
            Divider()
            ForEach(store.serviceTags, id: \.self) { tag in
                Button {
                    store.serviceFilter = tag
                } label: {
                    if store.serviceFilter?.caseInsensitiveCompare(tag) == .orderedSame {
                        Label("\(tag)  \(count(tag))", systemImage: "checkmark")
                    } else {
                        Text("\(tag)  \(count(tag))")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.serviceFilter ?? "All services").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.caption(12, weight: .semibold))
            .foregroundStyle(store.serviceFilter == nil ? Theme.secondary : Theme.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(store.serviceFilter == nil ? Theme.card : Theme.cardHover))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show one service")
    }
}

private struct AccountRow: View {
    let account: Account
    let store: AccountStore
    let onEdit: () -> Void
    @State private var revealed = false
    @State private var copied: String?

    var body: some View {
        HoverRow { hovering in
            HStack(spacing: 12) {
                CopyCell(text: account.login, display: account.login, copied: copied == "login", mono: false) {
                    store.copyPlain(account.login)
                    flash("login")
                }
                .frame(width: 230, alignment: .leading)

                CopyCell(text: account.password, display: revealed ? account.password : String(repeating: "•", count: 8),
                         copied: copied == "password", mono: true) {
                    store.copySecret(account.password)
                    flash("password")
                }
                .frame(width: 96, alignment: .leading)

                Text(account.notes)
                    .font(Theme.caption(11.5, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(account.notes)

                if hovering {
                    IconButton(icon: revealed ? "eye.slash" : "eye", help: revealed ? "Hide password" : "Show password") {
                        revealed.toggle()
                    }
                    IconButton(icon: "pencil", help: "Edit", action: onEdit)
                    IconButton(icon: "trash", help: "Delete") { withAnimation { store.delete(account) } }
                }
            }
        }
    }

    private func flash(_ field: String) {
        withAnimation(.easeOut(duration: 0.15)) { copied = field }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.2)) { if copied == field { copied = nil } }
        }
    }
}

/// Click to copy; shows "Copied" for a moment.
private struct CopyCell: View {
    let text: String
    let display: String
    let copied: Bool
    let mono: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(copied ? "Copied" : display)
                .font(mono ? .system(size: 12.5, weight: .medium, design: .monospaced) : Theme.body(12.5, weight: .medium))
                .foregroundStyle(copied ? Theme.green : (hovering ? Theme.accent : Theme.primary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

private struct AccountEditor: View {
    @Binding var account: Account
    let services: [String]
    let onSave: (Account) -> Void
    let onCancel: () -> Void
    @State private var showPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                field("Service", text: $account.service)
                field("Login", text: $account.login)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Group {
                        if showPassword {
                            TextField("", text: $account.password, prompt: Text("Password").foregroundStyle(Theme.tertiary))
                        } else {
                            SecureField("", text: $account.password, prompt: Text("Password").foregroundStyle(Theme.tertiary))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.primary)
                    IconButton(icon: showPassword ? "eye.slash" : "eye", help: "Show password", size: 10) { showPassword.toggle() }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
                field("Notes: role, environment…", text: $account.notes)
            }
            HStack {
                if !services.isEmpty {
                    Menu {
                        ForEach(services, id: \.self) { name in Button(name) { account.service = name } }
                    } label: {
                        Text("Existing services").font(Theme.caption(11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                PillButton(title: "Cancel", tint: Theme.secondary, prominent: false, action: onCancel)
                PillButton(title: "Save") { onSave(account) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Theme.body(12.5))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

