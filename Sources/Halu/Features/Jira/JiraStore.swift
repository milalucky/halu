import AppKit

struct JiraIssue: Identifiable, Equatable {
    enum Category: String {
        case todo = "new", inProgress = "indeterminate", done
    }

    var key: String
    var summary: String
    var status: String
    var category: Category
    var type: String
    var priority: String?
    var updated: Date
    var url: URL

    var id: String { key }
}

struct JiraTransition: Identifiable, Equatable {
    var id: String
    var name: String
    var category: JiraIssue.Category
}

/// Issues assigned to me in Jira Cloud (REST v3, email + API token).
@MainActor
final class JiraStore: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", todo = "To Do", inProgress = "In Progress"
        var id: String { rawValue }
    }

    @Published private(set) var site: String = UserDefaults.standard.string(forKey: "jira.site") ?? ""
    @Published private(set) var email: String = UserDefaults.standard.string(forKey: "jira.email") ?? ""
    @Published private(set) var accountName: String? = UserDefaults.standard.string(forKey: "jira.accountName")
    @Published private(set) var issues: [JiraIssue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var problem: String?
    @Published private(set) var busy: Set<String> = []
    @Published var filter: Filter = .all

    private static let tokenAccount = "jira-token"
    private var timer: Timer?

    var isConnected: Bool { !site.isEmpty && !email.isEmpty && accountName != nil }

    var visibleIssues: [JiraIssue] {
        switch filter {
        case .all: issues
        case .todo: issues.filter { $0.category == .todo }
        case .inProgress: issues.filter { $0.category == .inProgress }
        }
    }

    func start() {
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: Connection

    /// Checks the credentials against /myself before saving them.
    func connect(site rawSite: String, email: String, token: String) async -> String? {
        guard let host = Self.normalize(rawSite) else { return "Enter your Jira address, e.g. your-company.atlassian.net" }
        let email = email.trimmingCharacters(in: .whitespaces)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !token.isEmpty else { return "Email and API token are both needed." }
        let client = JiraClient(site: host, email: email, token: token)
        do {
            let me = try await client.get("/rest/api/3/myself")
            guard Keychain.write(token, for: Self.tokenAccount) else { return "Couldn't save the token to the Keychain." }
            site = host
            self.email = email
            accountName = (me["displayName"] as? String) ?? email
            UserDefaults.standard.set(host, forKey: "jira.site")
            UserDefaults.standard.set(email, forKey: "jira.email")
            UserDefaults.standard.set(accountName, forKey: "jira.accountName")
            refresh()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func disconnect() {
        Keychain.delete(Self.tokenAccount)
        accountName = nil
        issues = []
        UserDefaults.standard.removeObject(forKey: "jira.accountName")
    }

    // MARK: Issues

    func refresh() {
        guard isConnected, let client else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
                let fields = "summary,status,issuetype,priority,updated"
                let query = "jql=\(Self.encode(jql))&fields=\(fields)&maxResults=50"
                let json = try await client.get("/rest/api/3/search/jql?\(query)")
                issues = (json["issues"] as? [[String: Any]] ?? []).compactMap { parse($0) }
                problem = nil
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    func transitions(for issue: JiraIssue) async -> [JiraTransition] {
        guard let client, let json = try? await client.get("/rest/api/3/issue/\(issue.key)/transitions") else { return [] }
        return (json["transitions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let key = ((item["to"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String
            return JiraTransition(id: id, name: name, category: JiraIssue.Category(rawValue: key ?? "") ?? .todo)
        }
    }

    /// Moves the issue to the first status in the "In Progress" category.
    func startProgress(_ issue: JiraIssue) {
        Task {
            let options = await transitions(for: issue)
            guard let start = options.first(where: { $0.category == .inProgress }) else {
                problem = "\(issue.key) has no transition to In Progress."
                return
            }
            perform(start, on: issue)
        }
    }

    func perform(_ transition: JiraTransition, on issue: JiraIssue) {
        guard let client else { return }
        busy.insert(issue.key)
        Task {
            defer { busy.remove(issue.key) }
            do {
                _ = try await client.post("/rest/api/3/issue/\(issue.key)/transitions", body: ["transition": ["id": transition.id]])
                if let index = issues.firstIndex(where: { $0.key == issue.key }) {
                    issues[index].status = transition.name
                    issues[index].category = transition.category
                }
                refresh()
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    func open(_ issue: JiraIssue) { NSWorkspace.shared.open(issue.url) }

    func copyKey(_ issue: JiraIssue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.key, forType: .string)
    }

    // MARK: Helpers

    private var client: JiraClient? {
        guard !site.isEmpty, let token = Keychain.read(Self.tokenAccount) else { return nil }
        return JiraClient(site: site, email: email, token: token)
    }

    private func parse(_ item: [String: Any]) -> JiraIssue? {
        guard let key = item["key"] as? String, let fields = item["fields"] as? [String: Any],
              let url = URL(string: "https://\(site)/browse/\(key)") else { return nil }
        let status = fields["status"] as? [String: Any]
        let categoryKey = (status?["statusCategory"] as? [String: Any])?["key"] as? String
        return JiraIssue(
            key: key,
            summary: fields["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            category: JiraIssue.Category(rawValue: categoryKey ?? "") ?? .todo,
            type: (fields["issuetype"] as? [String: Any])?["name"] as? String ?? "",
            priority: (fields["priority"] as? [String: Any])?["name"] as? String,
            updated: (fields["updated"] as? String).flatMap(Self.dateFormatter.date(from:)) ?? .distantPast,
            url: url
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    static func normalize(_ site: String) -> String? {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = text.split(separator: "/").first.map(String.init) ?? ""
        guard text.contains(".") else { return nil }
        return text
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "=&+"))) ?? text
    }

    private static func describe(_ error: Error) -> String {
        if case JiraClient.Failure.status(let code, let message) = error {
            switch code {
            case 401: return "Jira didn't accept the email or API token."
            case 403: return "This account has no access to that Jira."
            case 404: return "Jira wasn't found at that address."
            default: return "Jira answered \(code)\(message.map { ": \($0)" } ?? "")."
            }
        }
        return "Couldn't reach Jira: \(error.localizedDescription)"
    }
}

/// Minimal Jira Cloud REST client with basic auth.
struct JiraClient: Sendable {
    enum Failure: Error { case status(Int, String?) }

    let site: String
    let email: String
    let token: String

    func get(_ path: String) async throws -> [String: Any] {
        try await send(path, method: "GET", body: nil)
    }

    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        try await send(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    private func send(_ path: String, method: String, body: Data?) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(site)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["errorMessages"] as? [String])?.first
            throw Failure.status(code, message)
        }
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
