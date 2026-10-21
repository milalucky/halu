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

    private let url = HaluStorage.directory.appendingPathComponent("accounts.vault")
    private var key: SymmetricKey?
    private var clearWork: DispatchWorkItem?

    func start() {
        do {
            let key = try Vault.loadOrCreateKey()
            self.key = key
            if let data = try? Data(contentsOf: url) {
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
                accounts = try JSONDecoder().decode([Account].self, from: plain)
            }
            problem = nil
        } catch {
            problem = "Halu couldn't unlock your accounts. Allow access to the Keychain item “Halu Vault” and reopen Halu."
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

    /// Imports rows copied from a table (Word, Excel, Numbers): Service, Login, Password, Notes.
    @discardableResult
    func importFromClipboard() -> Int {
        guard let text = NSPasteboard.general.string(forType: .string) else { return 0 }
        var added = 0
        for line in text.components(separatedBy: .newlines) {
            let cells = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, !cells[0].isEmpty, !cells[1].isEmpty else { continue }
            let header = cells[1].lowercased()
            if header == "login" || header == "логин" || header == "username" { continue }
            let notes = cells.count > 3 ? cells[3...].joined(separator: " ").trimmingCharacters(in: .whitespaces) : ""
            if accounts.contains(where: { $0.service == cells[0] && $0.login == cells[1] }) { continue }
            accounts.append(Account(service: cells[0], login: cells[1], password: cells[2], notes: notes))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

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
    static let service = "com.milana.halu.vault"
    static let account = "Halu Vault"

    static func loadOrCreateKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw VaultError.keychain(status) }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw VaultError.keychain(added) }
        return key
    }

    enum VaultError: Error { case keychain(OSStatus) }
}
