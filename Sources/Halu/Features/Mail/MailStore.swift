import AppKit

/// Work mail over IMAP: the server says what's actually unread, so mail read in Gmail (or anywhere)
/// disappears from Halu too. Read-only: the inbox is EXAMINEd and headers fetched with BODY.PEEK.
@MainActor
final class MailStore: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case google = "Gmail / Google Workspace"
        case yandex = "Yandex"
        case outlook = "Outlook / Microsoft 365"
        case custom = "Other (IMAP)"

        var id: String { rawValue }

        var host: String {
            switch self {
            case .google: "imap.gmail.com"
            case .yandex: "imap.yandex.ru"
            case .outlook: "outlook.office365.com"
            case .custom: ""
            }
        }

        var webName: String {
            switch self {
            case .google: "Gmail"
            case .yandex: "Yandex Mail"
            case .outlook: "Outlook"
            case .custom: "Mail"
            }
        }

        var passwordHelp: URL? {
            switch self {
            case .google: URL(string: "https://myaccount.google.com/apppasswords")
            case .yandex: URL(string: "https://id.yandex.ru/security/app-passwords")
            case .outlook: URL(string: "https://account.live.com/proofs/AppPassword")
            case .custom: nil
            }
        }
    }

    var isActive: () -> Bool = { true }
    /// Called with fresh unread mail after every check.
    var onUpdate: ([IncomingMessage]) -> Void = { _ in }

    @Published private(set) var email = UserDefaults.standard.string(forKey: "mail.email") ?? ""
    @Published private(set) var provider = Provider(rawValue: UserDefaults.standard.string(forKey: "mail.provider") ?? "") ?? .google
    @Published private(set) var host = UserDefaults.standard.string(forKey: "mail.host") ?? ""
    @Published private(set) var problem: String?
    @Published private(set) var lastCheck: Date?

    // Form drafts survive the panel closing.
    @Published var draftProvider: Provider = Provider(rawValue: UserDefaults.standard.string(forKey: "mail.provider") ?? "") ?? .google
    @Published var draftEmail = UserDefaults.standard.string(forKey: "mail.email") ?? ""
    @Published var draftHost = UserDefaults.standard.string(forKey: "mail.host") ?? ""
    @Published var draftPassword = ""

    private static let passwordAccount = "mail-password"
    private var timer: Timer?

    var isConnected: Bool { !email.isEmpty && !host.isEmpty && Keychain.read(Self.passwordAccount) != nil }

    func start() {
        let timer = Timer(timeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func connect() async -> String? {
        let email = draftEmail.trimmingCharacters(in: .whitespaces)
        let password = draftPassword.replacingOccurrences(of: " ", with: "")
        let host = draftProvider == .custom ? draftHost.trimmingCharacters(in: .whitespaces) : draftProvider.host
        guard !email.isEmpty, !password.isEmpty, !host.isEmpty else { return "Fill in the email, password and server." }
        do {
            _ = try await IMAPClient(host: host).unread(user: email, password: password, limit: 1)
        } catch {
            return error.localizedDescription
        }
        guard Keychain.write(password, for: Self.passwordAccount) else { return "Couldn't save the password to the Keychain." }
        self.email = email
        self.host = host
        provider = draftProvider
        draftPassword = ""
        UserDefaults.standard.set(email, forKey: "mail.email")
        UserDefaults.standard.set(host, forKey: "mail.host")
        UserDefaults.standard.set(provider.rawValue, forKey: "mail.provider")
        check()
        return nil
    }

    func disconnect() {
        Keychain.delete(Self.passwordAccount)
        email = ""
        host = ""
        UserDefaults.standard.removeObject(forKey: "mail.email")
        UserDefaults.standard.removeObject(forKey: "mail.host")
        onUpdate([])
    }

    func check() {
        guard isActive(), isConnected, let password = Keychain.read(Self.passwordAccount) else { return }
        let client = IMAPClient(host: host)
        let email = email, provider = provider
        Task {
            do {
                let envelopes = try await client.unread(user: email, password: password)
                problem = nil
                lastCheck = Date()
                onUpdate(envelopes.map { Self.message(from: $0, provider: provider) })
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private static func message(from envelope: IMAPClient.Envelope, provider: Provider) -> IncomingMessage {
        var url: URL?
        switch provider {
        case .google:
            let query = envelope.messageID.map { "rfc822msgid:" + $0 } ?? ""
            url = URL(string: "https://mail.google.com/mail/u/0/#search/" + (query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
        case .yandex: url = URL(string: "https://mail.yandex.ru")
        case .outlook: url = URL(string: "https://outlook.office.com/mail")
        case .custom: url = nil
        }
        // Negative ids keep mail apart from notification records.
        return IncomingMessage(id: -Int64(envelope.uid), appID: "com.apple.mail", appName: provider.webName,
                               title: envelope.from, subtitle: "", body: envelope.subject.isEmpty ? "(no subject)" : envelope.subject,
                               date: envelope.date, url: url)
    }
}
