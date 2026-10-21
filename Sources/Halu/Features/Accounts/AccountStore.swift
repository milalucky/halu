import AppKit
import CryptoKit
import Security

struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var service: String
    var login: String
    var password: String
    var notes: String
    var createdAt = Date()
}

/// Test accounts, kept in one AES-GCM encrypted file whose key lives in the login Keychain.
/// One key (instead of a Keychain item per password) means macOS asks at most once.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var problem: String?
    /// The account being added or edited, kept here so a half-filled form survives the panel closing.
    @Published var editing: Account?

    private let url = HaluStorage.directory.appendingPathComponent("accounts.vault")
    private var key: SymmetricKey?
    private var clearWork: DispatchWorkItem?

    func start() {
        do {
            let key = try Vault.loadOrCreateKey(vaultExists: FileManager.default.fileExists(atPath: url.path))
            self.key = key
            if let data = try? Data(contentsOf: url) {
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
                accounts = try JSONDecoder().decode([Account].self, from: plain)
            }
            problem = nil
        } catch {
            problem = "Halu couldn't unlock your accounts. Allow access to the Keychain item “Halu” and reopen Halu."
        }
    }

    var services: [String] {
        Array(Set(accounts.map(\.service))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func save(_ account: Account) {
        var account = account
        account.service = account.service.trimmingCharacters(in: .whitespacesAndNewlines)
        account.login = account.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.service.isEmpty, !account.login.isEmpty else { return }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    func delete(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    /// Imports rows copied from a table (Word, Excel, Numbers) or a Markdown list from the clipboard.
    @discardableResult
    func importFromClipboard() -> Int {
        guard let text = NSPasteboard.general.string(forType: .string) else { return 0 }
        return importText(text)
    }

    /// Imports a Markdown, CSV/TSV or plain table file. Returns how many accounts were added.
    @discardableResult
    func importFile(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return importText(String(decoding: data, as: UTF8.self))
    }

    func chooseFileToImport() -> Int? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText, .init(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importFile(url)
    }

    /// Accounts already there (same service and login) are skipped.
    private func importText(_ text: String) -> Int {
        var added = 0
        for row in AccountImport.parse(text) {
            let service = row.service.trimmingCharacters(in: .whitespaces)
            let login = row.login.trimmingCharacters(in: .whitespaces)
            guard !service.isEmpty, !login.isEmpty,
                  !accounts.contains(where: { $0.service == service && $0.login == login }) else { continue }
            accounts.append(Account(service: service, login: login, password: row.password, notes: row.notes))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    /// Services to filter by. A combined service ("losolo, losolo3", "StarSteer — losolo2") counts for
    /// each of its parts; addresses (hosts, URLs) are left out. Case doesn't split a service in two.
    var serviceTags: [String] {
        var seen: [String: String] = [:]
        for account in accounts {
            for tag in Self.tags(of: account.service) where seen[tag.lowercased()] == nil { seen[tag.lowercased()] = tag }
        }
        return seen.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func tags(of service: String) -> [String] {
        let parts = service.replacingOccurrences(of: #"\S+://\S+"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",—–;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("://") && !$0.contains(".") }
        return parts.isEmpty ? [service] : parts
    }

    /// The service chip picked in the Accounts tab (nil = all); kept while the panel is closed.
    @Published var serviceFilter: String?

    /// Copies a secret marked as concealed (clipboard managers skip it) and clears it after a minute.
    func copySecret(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(value, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = board.changeCount
        clearWork?.cancel()
        let work = DispatchWorkItem {
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func copyPlain(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func persist() {
        guard let key, let plain = try? JSONEncoder().encode(accounts),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private enum Vault {
    static let key = "vault-key"

    /// The vault's key from Halu's Keychain item. A new key is made only for a vault that doesn't exist yet.
    static func loadOrCreateKey(vaultExists: Bool) throws -> SymmetricKey {
        if let encoded = Keychain.read(key), let data = Data(base64Encoded: encoded) {
            return SymmetricKey(data: data)
        }
        guard Keychain.isReadable, !vaultExists else { throw VaultError.keychainUnavailable }
        let fresh = SymmetricKey(size: .bits256)
        guard Keychain.write(fresh.withUnsafeBytes { Data($0) }.base64EncodedString(), for: key) else {
            throw VaultError.keychainUnavailable
        }
        return fresh
    }

    enum VaultError: Error { case keychainUnavailable }
}
