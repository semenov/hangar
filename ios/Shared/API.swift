import Foundation

struct Session: Codable, Equatable, Identifiable {
    let name: String
    let dir: String
    let pid: Int
    let startedAt: Date
    let url: String?
    let state: String // starting | waiting | ready | disconnected
    let waiting: String?
    let managed: Bool
    let server: Bool
    let description: String?

    var id: Int { pid }
    var link: URL? { url.flatMap(URL.init(string:)) }
    /// The directory when it doesn't just repeat the name.
    var subtitle: String? {
        if dir.isEmpty { return "~/Dev" }
        return dir == name ? nil : "~/Dev/\(dir)"
    }
    /// What the store marks as busy while this session starts, stops or restarts: the same key as
    /// its project's (`Project.name`), so the row stays busy when it moves between the sections.
    var key: String { dir.isEmpty ? name : dir }
    /// Sessions in a project folder can be restarted, described and renamed.
    var isProject: Bool { !dir.isEmpty && !dir.hasPrefix("/") && !server }
}

// Only what the app can't do without is required, so a Mac with an older or newer `hangar`
// still shows its list.
extension Session {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decode(Int.self, forKey: .pid)
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .now
        url = try c.decodeIfPresent(String.self, forKey: .url)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "starting"
        waiting = try c.decodeIfPresent(String.self, forKey: .waiting)
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? false
        server = try c.decodeIfPresent(Bool.self, forKey: .server) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

struct Project: Codable, Equatable, Identifiable {
    let name: String
    let modified: Date
    let git: Bool
    let description: String?
    /// Why its last session ended, if it crashed or didn't start.
    let lastExit: String?
    let lastExitAt: Date?
    var id: String { name }
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? .now
        git = try c.decodeIfPresent(Bool.self, forKey: .git) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
        lastExit = try c.decodeIfPresent(String.self, forKey: .lastExit)
        lastExitAt = try c.decodeIfPresent(Date.self, forKey: .lastExitAt)
    }
}

struct Overview: Codable, Equatable {
    let sessions: [Session]
    let projects: [Project]
}

/// Folder names the Mac accepts (nameRe in backend/main.go).
enum ProjectName {
    static func isValid(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// "Todo App" → "todo-app": what a typed name becomes as a folder.
    static func slug(_ typed: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let words = typed.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
        let ascii = String(words.unicodeScalars.filter { $0.isASCII && allowed.contains($0) })
        return String(ascii.drop { !$0.isLetter && !$0.isNumber }.prefix(64))
    }
}

/// Subscription limits, from claude-monitor's backend (proxied by claude-manager).
struct Usage: Codable, Equatable {
    struct Limit: Codable, Equatable, Identifiable {
        let id: String
        let label: String
        let percent: Double
        let resetsAt: Date?
        let resets: String

        init(id: String, label: String, percent: Double, resetsAt: Date?, resets: String) {
            (self.id, self.label, self.percent, self.resetsAt, self.resets) = (id, label, percent, resetsAt, resets)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
            percent = try c.decode(Double.self, forKey: .percent)
            resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
            resets = try c.decodeIfPresent(String.self, forKey: .resets) ?? ""
        }

        /// Its window is over: the number is from before the reset.
        func hasReset(at now: Date = .now) -> Bool { resetsAt.map { $0 <= now } ?? false }

        /// "Current week (Fable)" → "Week · Fable"
        var shortLabel: String {
            label.replacingOccurrences(of: "Current ", with: "").capitalizedFirst
                .replacingOccurrences(of: " (", with: " · ").replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "all models", with: "All models")
        }
    }

    let limits: [Limit]
    let fetchedAt: Date
    /// Set when these are the last good limits and the Mac couldn't get new ones.
    var error: String? = nil

    /// The 5-hour session limit, shown as the main gauge.
    var session: Limit? { limits.first { $0.id.contains("session") } ?? limits.first }
    /// The weekly limit across all models.
    var week: Limit? { limits.first { $0.id.contains("week") && $0.id.contains("all") } ?? limits.first { $0.id.contains("week") } }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Talks to `hangar serve` on a Mac through the relay, or to the built-in demo. Every call names
/// its Mac, so an answer can't end up shown or cached under another Mac after a switch.
/// No App Group yet (it needs an explicit provisioning profile), so the widget doesn't see the
/// app's Macs and has nothing to show.
enum API {
    static var defaults: UserDefaults { .standard }
    private static func overviewKey(_ mac: PairedMac) -> String { "lastOverview." + mac.id }
    private static func usageKey(_ mac: PairedMac) -> String { "lastUsage." + mac.id }

    enum APIError: LocalizedError {
        case noMac
        /// The Mac answered, but not in a shape this build knows.
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noMac: "No Mac connected yet."
            case .unreadable: "This app and `hangar` on the Mac don't understand each other. Update both: `brew upgrade hangar` on the Mac, and the app from the App Store."
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func cachedOverview(for mac: PairedMac?) -> Overview? {
        guard let mac else { return nil }
        return defaults.data(forKey: overviewKey(mac)).flatMap { try? decoder.decode(Overview.self, from: $0) }
    }

    static func cachedUsage(for mac: PairedMac?) -> Usage? {
        guard let mac else { return nil }
        return defaults.data(forKey: usageKey(mac)).flatMap { try? decoder.decode(Usage.self, from: $0) }
    }

    static func forgetCache(for mac: PairedMac) {
        defaults.removeObject(forKey: overviewKey(mac))
        defaults.removeObject(forKey: usageKey(mac))
    }

    static func overview(on mac: PairedMac, timeout: TimeInterval = 20) async throws -> Overview {
        let (o, data): (Overview, Data) = try await requestData(mac, "GET", "/api/overview", timeout: timeout)
        defaults.set(data, forKey: overviewKey(mac))
        return o
    }

    static func usage(on mac: PairedMac, force: Bool = false, timeout: TimeInterval = 80) async throws -> Usage {
        let (u, data): (Usage, Data) = try await requestData(mac, "GET", "/api/usage" + (force ? "?refresh=1" : ""),
                                                             timeout: timeout)
        defaults.set(data, forKey: usageKey(mac))
        return u
    }

    /// Starts a session; the backend waits until it is registered, so this can take ~10 s.
    static func start(on mac: PairedMac, name: String, create: Bool = false) async throws -> Session {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "create": create])
        return try await request(mac, "POST", "/api/sessions", body: body, timeout: 75)
    }

    /// Stops a session and starts it again with the same conversation.
    static func restart(on mac: PairedMac, pid: Int) async throws -> Session {
        try await request(mac, "POST", "/api/sessions/\(pid)/restart", timeout: 75)
    }

    private struct DescriptionReply: Decodable { let description: String }

    /// Asks Claude on the Mac for a new description (a few seconds) and saves it.
    static func describe(on mac: PairedMac, _ project: String) async throws -> String {
        let r: DescriptionReply = try await request(mac, "POST", "/api/describe/" + escaped(project), timeout: 150)
        return r.description
    }

    private struct RenameReply: Decodable { let project: String }

    /// Renames ~/Dev/<project> (folder and session); returns the new path. A running session restarts.
    static func rename(on mac: PairedMac, _ project: String, to: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["to": to])
        let r: RenameReply = try await request(mac, "POST", "/api/rename/" + escaped(project), body: body, timeout: 90)
        return r.project
    }

    /// Sets a description by hand; "" removes it.
    static func setDescription(on mac: PairedMac, _ project: String, _ text: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["description": text])
        let r: DescriptionReply = try await request(mac, "PUT", "/api/projects/" + escaped(project), body: body)
        return r.description
    }

    static func stop(on mac: PairedMac, pid: Int) async throws {
        let _: [String: Bool] = try await request(mac, "DELETE", "/api/sessions/\(pid)")
    }

    /// A project path ("games/my game") as it goes into a request path: each folder name escaped.
    static func escaped(_ project: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;")
        return project.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func request<T: Decodable>(_ mac: PairedMac, _ method: String, _ path: String, body: Data? = nil,
                                              timeout: TimeInterval = 20) async throws -> T {
        try await requestData(mac, method, path, body: body, timeout: timeout).0
    }

    private static func requestData<T: Decodable>(_ mac: PairedMac, _ method: String, _ path: String, body: Data? = nil,
                                                  timeout: TimeInterval = 20) async throws -> (T, Data) {
        let status: Int, data: Data
        switch mac.kind {
        case .demo:
            (status, data) = await Demo.shared.handle(method, path, body: body)
        case .relay:
            (status, data) = try await RelayConnection.shared(for: mac).request(method, path, body: body, timeout: timeout)
        }
        if status != 200 {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg ?? "HTTP \(status)"])
        }
        do {
            return (try decoder.decode(T.self, from: data), data)
        } catch {
            Log.add("can't read the answer to \(method) \(path): \(error)")
            throw APIError.unreadable("\(error)")
        }
    }

    /// Tells the Mac to forget this phone (relay Macs), then forgets the Mac here. Returns whether
    /// the Mac was told: if it couldn't be reached, it still lists this phone.
    @discardableResult
    static func unpair(_ mac: PairedMac) async -> Bool {
        var told = true
        if mac.kind == .relay {
            told = (try? await RelayConnection.shared(for: mac).request("POST", "/api/unpair", body: nil, timeout: 10)) != nil
            RelayConnection.drop(mac.id)
        }
        forgetCache(for: mac)
        Macs.remove(mac.id)
        return told
    }
}
