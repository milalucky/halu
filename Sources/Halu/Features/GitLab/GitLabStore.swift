import AppKit

struct MergeRequest: Identifiable, Equatable {
    enum Role: String { case mine = "Mine", review = "To review" }

    var id: Int
    var projectID: Int
    var iid: Int
    var title: String
    var reference: String
    var author: String
    var url: URL
    var updatedAt: Date
    var isDraft: Bool
    var notes: Int
    var unresolved: Bool
    var role: Role
    var conflicts: Bool
    var pipeline: Pipeline.Status?
}

/// A CI pipeline: its project, branch and how it's going.
struct Pipeline: Identifiable, Equatable {
    enum Status: String {
        case created, waiting_for_resource, preparing, pending, running, success, failed, canceled, skipped, manual, scheduled

        var isActive: Bool { [.created, .waiting_for_resource, .preparing, .pending, .running].contains(self) }
        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .canceled, .skipped: "slash.circle"
            case .manual, .scheduled: "hand.raised.circle"
            default: "circle.dotted.circle"
            }
        }
    }

    var id: Int
    var project: String
    var ref: String
    var status: Status
    var url: URL
    var updatedAt: Date
}

/// A comment someone else left on a merge request since you last opened it.
struct MRComment: Identifiable, Equatable {
    var id: Int
    var author: String
    var body: String
    var date: Date
}

/// Your merge requests and the ones waiting for your review on a GitLab server, with comments other
/// people left since you last opened each one. Read-only, through a personal access token with
/// `read_api` (kept in the Keychain).
@MainActor
final class GitLabStore: ObservableObject {
    var isActive: () -> Bool = { true }

    @Published private(set) var server = UserDefaults.standard.string(forKey: "gitlab.server") ?? ""
    @Published private(set) var userName = UserDefaults.standard.string(forKey: "gitlab.user")
    @Published private(set) var requests: [MergeRequest] = []
    /// New comments per merge request id.
    @Published private(set) var comments: [Int: [MRComment]] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var isLoading = false
    @Published var filter: MergeRequest.Role? = nil
    /// Pipelines you started in the last day, newest first.
    @Published private(set) var pipelines: [Pipeline] = []
    @Published var showingPipelines = false
    /// Called when one of your pipelines finishes.
    var onPipelineFinished: (Pipeline) -> Void = { _ in }

    @Published var draftServer = UserDefaults.standard.string(forKey: "gitlab.server") ?? ""
    @Published var draftToken = ""

    private static let tokenAccount = "gitlab-token"
    private var userID = UserDefaults.standard.integer(forKey: "gitlab.userID")
    /// When you last opened each merge request; comments after that are new.
    private var seen: [String: Date] = UserDefaults.standard.dictionary(forKey: "gitlab.seen") as? [String: Date] ?? [:]
    /// Comment counts at the last look, to fetch comments only where the count moved.
    private var noteCounts: [Int: Int] = [:]
    private var timer: Timer?
    private var username = UserDefaults.standard.string(forKey: "gitlab.username")
    /// Pipeline status per merge request, with the update time it was read at.
    private var mrPipelines: [Int: (Date, Pipeline.Status?)] = [:]

    var isConnected: Bool { !server.isEmpty && userName != nil }
    var newComments: Int { comments.values.reduce(0) { $0 + $1.count } }

    var visible: [MergeRequest] {
        requests.filter { filter == nil || $0.role == filter }
    }

    func start() {
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func connect() async -> String? {
        var host = draftServer.trimmingCharacters(in: .whitespaces)
        if !host.hasPrefix("http") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        let token = draftToken.trimmingCharacters(in: .whitespaces)
        guard URL(string: host) != nil, !token.isEmpty else { return "Fill in the server and the token." }
        do {
            let me = try await Self.get("\(host)/api/v4/user", token: token) as? [String: Any]
            guard let id = me?["id"] as? Int else { return "GitLab didn't accept this token." }
            guard Keychain.write(token, for: Self.tokenAccount) else { return "Couldn't save the token to the Keychain." }
            server = host
            userID = id
            userName = (me?["name"] as? String) ?? (me?["username"] as? String)
            draftToken = ""
            UserDefaults.standard.set(host, forKey: "gitlab.server")
            UserDefaults.standard.set(id, forKey: "gitlab.userID")
            UserDefaults.standard.set(userName, forKey: "gitlab.user")
            refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.delete(Self.tokenAccount)
        server = ""
        userName = nil
        requests = []
        comments = [:]
        UserDefaults.standard.removeObject(forKey: "gitlab.server")
        UserDefaults.standard.removeObject(forKey: "gitlab.user")
    }

    /// Opens it in the browser; its comments count as read.
    func open(_ request: MergeRequest) {
        markSeen(request)
        NSWorkspace.shared.open(request.url)
    }

    func markSeen(_ request: MergeRequest) {
        seen[String(request.id)] = Date()
        comments[request.id] = nil
        UserDefaults.standard.set(seen, forKey: "gitlab.seen")
    }

    func refresh() {
        guard isActive(), isConnected, let token = Keychain.read(Self.tokenAccount) else { return }
        isLoading = true
        let server = server, userID = userID
        Task {
            do {
                let mine = try await Self.requests(server, "merge_requests?scope=created_by_me&state=opened&per_page=50", role: .mine, token: token)
                let review = try await Self.requests(server, "merge_requests?scope=all&reviewer_id=\(userID)&state=opened&per_page=50", role: .review, token: token)
                var all = (mine + review.filter { r in !mine.contains { $0.id == r.id } }).sorted { $0.updatedAt > $1.updatedAt }
                for index in all.indices {
                    all[index].pipeline = await pipelineStatus(of: all[index], token: token)
                }
                requests = all
                problem = nil
                await loadComments(all, token: token)
                await loadPipelines(token: token)
            } catch {
                problem = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Fetches comments only for merge requests whose comment count changed.
    private func loadComments(_ list: [MergeRequest], token: String) async {
        var fresh = comments.filter { id, _ in list.contains { $0.id == id } }
        for request in list where noteCounts[request.id] != request.notes {
            noteCounts[request.id] = request.notes
            // The first look at a merge request sets the baseline: older comments aren't news.
            let since = seen[String(request.id)] ?? {
                seen[String(request.id)] = Date()
                return Date()
            }()
            guard let notes = try? await Self.get("\(server)/api/v4/projects/\(request.projectID)/merge_requests/\(request.iid)/notes?sort=desc&order_by=created_at&per_page=30", token: token) as? [[String: Any]] else { continue }
            let new = notes.compactMap { note -> MRComment? in
                guard note["system"] as? Bool != true,
                      let author = note["author"] as? [String: Any], (author["id"] as? Int) != userID,
                      let date = (note["created_at"] as? String).flatMap(Self.date), date > since,
                      let id = note["id"] as? Int else { return nil }
                return MRComment(id: id, author: author["name"] as? String ?? "Someone", body: note["body"] as? String ?? "", date: date)
            }
            fresh[request.id] = new.isEmpty ? nil : new
        }
        UserDefaults.standard.set(seen, forKey: "gitlab.seen")
        if fresh != comments { comments = fresh }
    }

    /// The latest pipeline of a merge request, read again only when the merge request changed.
    private func pipelineStatus(of request: MergeRequest, token: String) async -> Pipeline.Status? {
        if let cached = mrPipelines[request.id], cached.0 == request.updatedAt, !(cached.1?.isActive ?? false) { return cached.1 }
        let rows = try? await Self.get("\(server)/api/v4/projects/\(request.projectID)/merge_requests/\(request.iid)/pipelines?per_page=1", token: token) as? [[String: Any]]
        let status = (rows?.first?["status"] as? String).flatMap(Pipeline.Status.init(rawValue:))
        mrPipelines[request.id] = (request.updatedAt, status)
        return status
    }

    /// Your pipelines from the last day, across projects you were active in.
    private func loadPipelines(token: String) async {
        if username == nil, let me = try? await Self.get("\(server)/api/v4/user", token: token) as? [String: Any] {
            username = me["username"] as? String
            UserDefaults.standard.set(username, forKey: "gitlab.username")
        }
        guard let username else { return }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400))
        guard let projects = try? await Self.get("\(server)/api/v4/projects?membership=true&simple=true&order_by=last_activity_at&per_page=15&last_activity_after=\(since)", token: token) as? [[String: Any]] else { return }
        let dayAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        var found: [Pipeline] = []
        for project in projects {
            guard let id = project["id"] as? Int else { continue }
            let name = project["path_with_namespace"] as? String ?? project["name"] as? String ?? ""
            guard let rows = try? await Self.get("\(server)/api/v4/projects/\(id)/pipelines?username=\(username)&per_page=10&updated_after=\(dayAgo)", token: token) as? [[String: Any]] else { continue }
            for row in rows {
                guard let pid = row["id"] as? Int, let status = (row["status"] as? String).flatMap(Pipeline.Status.init(rawValue:)),
                      let url = (row["web_url"] as? String).flatMap(URL.init(string:)) else { continue }
                found.append(Pipeline(id: pid, project: name.split(separator: "/").last.map(String.init) ?? name, ref: row["ref"] as? String ?? "",
                                      status: status, url: url, updatedAt: (row["updated_at"] as? String).flatMap(Self.date) ?? .distantPast))
            }
        }
        found.sort { $0.updatedAt > $1.updatedAt }
        // Tell about pipelines that were running last time and have finished now.
        for pipeline in found where !pipeline.status.isActive {
            if pipelines.first(where: { $0.id == pipeline.id })?.status.isActive == true { onPipelineFinished(pipeline) }
        }
        pipelines = found
    }

    // MARK: API

    private static func requests(_ server: String, _ path: String, role: MergeRequest.Role, token: String) async throws -> [MergeRequest] {
        guard let rows = try await get("\(server)/api/v4/\(path)", token: token) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let iid = row["iid"] as? Int, let project = row["project_id"] as? Int,
                  let link = (row["web_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let references = row["references"] as? [String: Any]
            return MergeRequest(id: id, projectID: project, iid: iid, title: row["title"] as? String ?? "",
                                reference: references?["full"] as? String ?? "!\(iid)",
                                author: (row["author"] as? [String: Any])?["name"] as? String ?? "",
                                url: link, updatedAt: (row["updated_at"] as? String).flatMap(date) ?? .distantPast,
                                isDraft: row["draft"] as? Bool ?? false, notes: row["user_notes_count"] as? Int ?? 0,
                                unresolved: row["blocking_discussions_resolved"] as? Bool == false, role: role,
                                conflicts: row["has_conflicts"] as? Bool ?? false)
        }
    }

    private static func get(_ address: String, token: String) async throws -> Any {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw NSError(domain: "GitLab", code: 401, userInfo: [NSLocalizedDescriptionKey: "GitLab didn't accept the token. Make a new one with read_api."])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
