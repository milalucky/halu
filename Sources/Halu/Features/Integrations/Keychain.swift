import Foundation
import Security

/// Halu's secrets (API tokens, the accounts vault key) in one generic password in the login Keychain,
/// read once per launch. A locally signed build has a new identity after every rebuild, so macOS asks
/// once per Keychain item: keeping everything in one item means one question instead of several.
enum Keychain {
    private static let service = "com.milana.halu.secrets"
    private static let account = "Halu"
    /// Where secrets lived before; read once to move them over and left in place.
    private static let legacy: [(service: String, account: String, key: String, isData: Bool)] = [
        ("com.milana.halu.integrations", "jira-token", "jira-token", false),
        ("com.milana.halu.vault", "Halu Vault", "vault-key", true),
    ]

    private static var cache: [String: String]?
    private static let lock = NSLock()

    /// False when the Keychain couldn't be read (e.g. access was denied): callers must not treat
    /// missing secrets as absent then, or the vault would get a new key.
    static var isReadable: Bool { lock.withLock { load() != nil } }

    static func read(_ key: String) -> String? {
        lock.withLock { load()?[key] }
    }

    @discardableResult
    static func write(_ value: String, for key: String) -> Bool {
        lock.withLock {
            guard var all = load() else { return false }
            all[key] = value
            return save(all)
        }
    }

    static func delete(_ key: String) {
        lock.withLock {
            guard var all = load(), all[key] != nil else { return }
            all[key] = nil
            _ = save(all)
        }
    }

    // MARK: Storage

    private enum Lookup { case found(Data), missing, failed }

    private static func load() -> [String: String]? {
        if let cache { return cache }
        // Demo mode never touches the Keychain.
        if Demo.isOn {
            cache = [:]
            return cache
        }
        switch copy(service: service, account: account) {
        case .found(let data):
            cache = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        case .missing:
            var all: [String: String] = [:]
            for item in legacy {
                switch copy(service: item.service, account: item.account) {
                case .found(let data):
                    all[item.key] = item.isData ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
                case .missing:
                    break
                case .failed:
                    return nil // Try again next time rather than lose an old secret.
                }
            }
            guard all.isEmpty || save(all) else { return nil }
            cache = all
        case .failed:
            return nil
        }
        return cache
    }

    private static func copy(service: String, account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return .found(data) }
        return status == errSecItemNotFound ? .missing : .failed
    }

    private static func save(_ all: [String: String]) -> Bool {
        if Demo.isOn { return true }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecAttrLabel as String] = "Halu"
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        cache = all
        return true
    }
}
