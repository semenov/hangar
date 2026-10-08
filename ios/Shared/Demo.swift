import Foundation

/// A pretend Mac for trying the app (and for App Review): answers the API from memory.
actor Demo {
    static let shared = Demo()

    private struct S: Codable {
        var name: String, dir: String, pid: Int, startedAt: Date, url: String?, state: String
        var waiting: String?, managed: Bool, server: Bool, description: String?
    }

    private struct P: Codable {
        var name: String, modified: Date, git: Bool, description: String?
    }

    private var sessions: [S]
    private var projects: [P]
    private var nextPID = 4200

    private init() {
        let now = Date()
        func s(_ n: String, _ hours: Double, _ d: String) -> S {
            S(name: n, dir: n, pid: Int.random(in: 1000...9000), startedAt: now.addingTimeInterval(-hours * 3600),
              url: "https://claude.ai/code", state: "ready", waiting: nil, managed: true, server: false, description: d)
        }
        sessions = [
            s("todo-app", 0.4, "SwiftUI to-do app with iCloud sync and widgets"),
            s("blog", 3.2, "Static blog generator in Go with Markdown posts and an RSS feed"),
            s("api-gateway", 26, "Rate-limiting reverse proxy for internal services, with Prometheus metrics"),
        ]
        func p(_ n: String, _ days: Double, _ git: Bool, _ d: String?) -> P {
            P(name: n, modified: now.addingTimeInterval(-days * 86400), git: git, description: d)
        }
        projects = [
            p("todo-app", 0.1, true, "SwiftUI to-do app with iCloud sync and widgets"),
            p("blog", 0.5, true, "Static blog generator in Go with Markdown posts and an RSS feed"),
            p("api-gateway", 1, true, "Rate-limiting reverse proxy for internal services, with Prometheus metrics"),
            p("weather-cli", 3, true, "Command-line weather forecasts from Open-Meteo, with ASCII charts"),
            p("recipes", 9, false, "Personal recipe collection as Markdown, with a shopping-list generator"),
            p("game-jam", 30, true, "2D platformer made in a weekend with Godot"),
            p("ideas", 45, false, nil),
        ]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func json(_ v: some Encodable) -> (Int, Data) { (200, (try? Self.encoder.encode(v)) ?? Data()) }
    private func error(_ status: Int, _ msg: String) -> (Int, Data) {
        (status, (try? JSONSerialization.data(withJSONObject: ["error": msg])) ?? Data())
    }

    func handle(_ method: String, _ path: String, body: Data?) async -> (Int, Data) {
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init) // ["api", ...]
        switch (method, parts.dropFirst().first ?? "") {
        case ("GET", "version"):
            return json(["version": "demo", "mac": "Demo Mac"])
        case ("GET", "overview"):
            struct O: Encodable { let sessions: [S], projects: [P] }
            return json(O(sessions: sessions, projects: projects))
        case ("GET", "usage"):
            let now = Date()
            struct L: Encodable { let id, label: String, percent: Double, resetsAt: Date, resets: String }
            struct U: Encodable { let limits: [L], fetchedAt: Date }
            return json(U(limits: [
                L(id: "current-session", label: "Current session", percent: 34, resetsAt: now.addingTimeInterval(2.4 * 3600), resets: ""),
                L(id: "current-week-all-models", label: "Current week (all models)", percent: 21, resetsAt: now.addingTimeInterval(3.2 * 86400), resets: ""),
            ], fetchedAt: now))
        case ("POST", "sessions"):
            let name = (obj["name"] as? String) ?? ""
            if obj["create"] as? Bool == true {
                projects.insert(P(name: name, modified: .now, git: false, description: nil), at: 0)
            }
            try? await Task.sleep(for: .seconds(1.5))
            nextPID += 1
            let d = projects.first { $0.name == name }?.description
            let s = S(name: name, dir: name, pid: nextPID, startedAt: .now, url: "https://claude.ai/code", state: "ready",
                      waiting: nil, managed: true, server: false, description: d)
            sessions.insert(s, at: 0)
            return json(s)
        case ("DELETE", "sessions"):
            let pid = Int(parts.last ?? "") ?? 0
            sessions.removeAll { $0.pid == pid }
            return json(["ok": true])
        case ("POST", "describe"):
            let name = parts.dropFirst(2).joined(separator: "/")
            try? await Task.sleep(for: .seconds(2))
            let text = "A small \(name) project (demo description)"
            setDescription(name, text)
            return json(["description": text])
        case ("PUT", "projects"):
            let name = parts.dropFirst(2).joined(separator: "/")
            let text = (obj["description"] as? String) ?? ""
            setDescription(name, text.isEmpty ? nil : text)
            return json(["description": text])
        case ("POST", "rename"):
            let name = parts.dropFirst(2).joined(separator: "/")
            let to = (obj["to"] as? String) ?? name
            if let i = projects.firstIndex(where: { $0.name == name }) { projects[i].name = to }
            for i in sessions.indices where sessions[i].dir == name {
                sessions[i].dir = to
                sessions[i].name = to
            }
            return json(["project": to])
        default:
            return error(404, "not in the demo")
        }
    }

    private func setDescription(_ name: String, _ text: String?) {
        if let i = projects.firstIndex(where: { $0.name == name }) { projects[i].description = text }
        for i in sessions.indices where sessions[i].dir == name { sessions[i].description = text }
    }
}
