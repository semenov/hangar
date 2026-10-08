import Foundation

struct Session: Codable, Equatable, Identifiable {
    let name: String
    let dir: String
    let pid: Int
    let startedAt: Date
    let url: String?
    let state: String // starting | waiting | ready
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
}

struct Project: Codable, Equatable, Identifiable {
    let name: String
    let modified: Date
    let git: Bool
    let description: String?
    var id: String { name }
}

struct Overview: Codable, Equatable {
    let sessions: [Session]
    let projects: [Project]
}

/// Subscription limits, from claude-monitor's backend (proxied by claude-manager).
struct Usage: Codable, Equatable {
    struct Limit: Codable, Equatable, Identifiable {
        let id: String
        let label: String
        let percent: Double
        let resetsAt: Date?
        let resets: String

        /// "Current week (Fable)" → "Week · Fable"
        var shortLabel: String {
            label.replacingOccurrences(of: "Current ", with: "").capitalizedFirst
                .replacingOccurrences(of: " (", with: " · ").replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "all models", with: "All models")
        }
    }

    let limits: [Limit]
    let fetchedAt: Date

    /// The 5-hour session limit, shown as the main gauge.
    var session: Limit? { limits.first { $0.id.contains("session") } ?? limits.first }
    /// The weekly limit across all models.
    var week: Limit? { limits.first { $0.id.contains("week") && $0.id.contains("all") } ?? limits.first { $0.id.contains("week") } }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Talks to `hangar serve` on the selected Mac through the relay, or to the built-in demo.
/// No App Group yet (it needs an explicit provisioning profile), so the widget doesn't see the
/// app's Macs and has nothing to show.
enum API {
    static var defaults: UserDefaults { .standard }
    private static var cacheSuffix: String { Macs.current.map { "." + $0.id } ?? "" }
    private static var overviewKey: String { "lastOverview" + cacheSuffix }
    private static var usageKey: String { "lastUsage" + cacheSuffix }

    enum APIError: LocalizedError {
        case noMac
        var errorDescription: String? { "No Mac connected yet." }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var cachedOverview: Overview? {
        defaults.data(forKey: overviewKey).flatMap { try? decoder.decode(Overview.self, from: $0) }
    }
    static var cachedUsage: Usage? {
        defaults.data(forKey: usageKey).flatMap { try? decoder.decode(Usage.self, from: $0) }
    }

    static func overview(timeout: TimeInterval = 20) async throws -> Overview {
        let (o, data): (Overview, Data) = try await requestData("GET", "/api/overview", timeout: timeout)
        defaults.set(data, forKey: overviewKey)
        return o
    }

    static func usage(force: Bool = false, timeout: TimeInterval = 80) async throws -> Usage {
        let (u, data): (Usage, Data) = try await requestData("GET", "/api/usage" + (force ? "?refresh=1" : ""),
                                                             timeout: timeout)
        defaults.set(data, forKey: usageKey)
        return u
    }

    /// Starts a session; the backend waits until it is registered, so this can take ~10 s.
    static func start(name: String, create: Bool = false) async throws -> Session {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "create": create])
        return try await request("POST", "/api/sessions", body: body, timeout: 75)
    }

    private struct DescriptionReply: Decodable { let description: String }

    /// Asks Claude on the Mac for a new description (a few seconds) and saves it.
    static func describe(_ project: String) async throws -> String {
        let r: DescriptionReply = try await request("POST", "/api/describe/\(project)", timeout: 150)
        return r.description
    }

    private struct RenameReply: Decodable { let project: String }

    /// Renames ~/Dev/<project> (folder and session); returns the new path. A running session restarts.
    static func rename(_ project: String, to: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["to": to])
        let r: RenameReply = try await request("POST", "/api/rename/\(project)", body: body, timeout: 90)
        return r.project
    }

    /// Sets a description by hand; "" removes it.
    static func setDescription(_ project: String, _ text: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["description": text])
        let r: DescriptionReply = try await request("PUT", "/api/projects/\(project)", body: body)
        return r.description
    }

    static func stop(pid: Int) async throws {
        let _: [String: Bool] = try await request("DELETE", "/api/sessions/\(pid)")
    }

    private static func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                              timeout: TimeInterval = 20) async throws -> T {
        try await requestData(method, path, body: body, timeout: timeout).0
    }

    private static func requestData<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                                  timeout: TimeInterval = 20) async throws -> (T, Data) {
        guard let mac = Macs.current else { throw APIError.noMac }
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
        return (try decoder.decode(T.self, from: data), data)
    }

    /// Tells the Mac to forget this phone (relay Macs), then forgets the Mac here.
    static func unpair(_ mac: PairedMac) async {
        if mac.kind == .relay {
            _ = try? await RelayConnection.shared(for: mac).request("POST", "/api/unpair", body: nil, timeout: 10)
            RelayConnection.drop(mac.id)
        }
        Macs.remove(mac.id)
    }
}
