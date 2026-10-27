import AppKit
import SwiftUI

/// A place you test: a name, its address, and the account you sign in with (from Accounts).
struct Stand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var accountID: UUID?
    var note: String = ""
}

@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var items: [Stand]
    @Published var editing: Stand?
    @Published var query = ""
    @Published private(set) var flash: (id: UUID, text: String)?
    private let file = JSONFile<[Stand]>("environments.json")

    init() { items = file.load() ?? [] }

    var visible: [Stand] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
    }

    func save(_ item: Stand) {
        var item = item
        item.name = item.name.trimmingCharacters(in: .whitespaces)
        item.url = item.url.trimmingCharacters(in: .whitespaces)
        guard !item.name.isEmpty, !item.url.isEmpty else { return }
        if !item.url.contains("://") { item.url = "https://" + item.url }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        file.save(items)
    }

    func delete(_ item: Stand) {
        items.removeAll { $0.id == item.id }
        file.save(items)
    }

    func move(_ item: Stand, by step: Int) {
        guard let index = items.firstIndex(of: item), items.indices.contains(index + step) else { return }
        items.swapAt(index, index + step)
        file.save(items)
    }

    /// Opens the stand and puts its login on the clipboard, ready to paste.
    func open(_ item: Stand, account: Account?, accounts: AccountStore) {
        if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        if let account {
            accounts.copyPlain(account.login)
            show(item, "Login copied")
        }
    }

    func show(_ item: Stand, _ text: String) {
        flash = (item.id, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flash?.id == item.id { self?.flash = nil }
        }
    }
}

struct EnvironmentsView: View {
    @ObservedObject var store: EnvironmentStore
    @ObservedObject var accounts: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                InputField(placeholder: "Search stands", icon: "magnifyingglass", text: $store.query)
                IconButton(icon: "plus", help: "Add a stand", size: 12) {
                    withAnimation { store.editing = Stand(name: "", url: "") }
                }
            }
            if let item = store.editing {
                EnvironmentEditor(item: Binding(get: { store.editing ?? item }, set: { store.editing = $0 }), accounts: accounts) {
                    store.save($0)
                    withAnimation { store.editing = nil }
                } onCancel: { withAnimation { store.editing = nil } }
            }
            if store.items.isEmpty && store.editing == nil {
                EmptyState(icon: "server.rack", title: "No stands yet",
                           subtitle: "Add the places you test: a name, the address, and the account to sign in with. One click opens it and copies the login.",
                           action: ("Add a stand", { withAnimation { store.editing = Stand(name: "", url: "") } }))
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.visible) { EnvironmentRow(item: $0, store: store, accounts: accounts) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct EnvironmentRow: View {
    let item: Stand
    @ObservedObject var store: EnvironmentStore
    @ObservedObject var accounts: AccountStore
    @State private var hovering = false

    var body: some View {
        let account = item.accountID.flatMap { id in accounts.accounts.first { $0.id == id } }
        HStack(spacing: 12) {
            Text(String(item.name.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Theme.body(13.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(URL(string: item.url)?.host ?? item.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            if let flash = store.flash, flash.id == item.id {
                Text(flash.text).font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.green).transition(.opacity)
            } else if let account {
                Text(account.login).font(Theme.caption(11.5, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
            if hovering {
                if let account {
                    IconButton(icon: "person", help: "Copy login", size: 11) { accounts.copyPlain(account.login); store.show(item, "Login copied") }
                    IconButton(icon: "key", help: "Copy password (clears in a minute)", size: 11) {
                        accounts.copySecret(account.password); store.show(item, "Password copied")
                    }
                }
                IconButton(icon: "pencil", help: "Edit", size: 11) { withAnimation { store.editing = item } }
                IconButton(icon: "trash", help: "Delete", size: 11) { withAnimation { store.delete(item) } }
            }
            PillButton(title: "Open", icon: "arrow.up.right", prominent: hovering) { store.open(item, account: account, accounts: accounts) }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Move up") { store.move(item, by: -1) }
            Button("Move down") { store.move(item, by: 1) }
        }
    }
}

private struct EnvironmentEditor: View {
    @Binding var item: Stand
    @ObservedObject var accounts: AccountStore
    let onSave: (Stand) -> Void
    let onCancel: () -> Void

    var body: some View {
        let chosen = item.accountID.flatMap { id in accounts.accounts.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $item.name, prompt: Text("Name: losolo3, presolo…").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain).font(Theme.body(13, weight: .semibold)).frame(width: 180)
                TextField("", text: $item.url, prompt: Text("Address: https://…").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { onSave(item) }
            }
            HStack(spacing: 8) {
                Menu {
                    Button("No account") { item.accountID = nil }
                    ForEach(accounts.services, id: \.self) { service in
                        Menu(service) {
                            ForEach(accounts.accounts.filter { $0.service == service }) { account in
                                Button(account.login) {
                                    item.accountID = account.id
                                    if item.name.isEmpty { item.name = service }
                                }
                            }
                        }
                    }
                } label: {
                    Label(chosen.map { "\($0.service) · \($0.login)" } ?? "Sign in with… (from Accounts)", systemImage: "person.crop.circle")
                        .font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                Spacer()
                PillButton(title: "Save") { onSave(item) }
                IconButton(icon: "xmark", help: "Cancel", size: 10, action: onCancel)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardHover))
    }
}
