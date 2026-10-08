import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class Store {
    var overview: Overview? = API.cachedOverview // last known state, shown while the request runs
    var usage: Usage? = API.cachedUsage
    var usageError: String?
    var error: String?
    var isLoading = false
    var fetchedAt: Date?
    /// Names of projects whose session is being started or stopped.
    var busy: Set<String> = []

    var publicURL: String {
        get { API.publicURL }
        set { API.publicURL = newValue }
    }
    var token: String {
        get { API.token }
        set { API.token = newValue }
    }
    var managerToken: String {
        get { API.managerToken }
        set { API.managerToken = newValue }
    }

    var sessions: [Session] { overview?.sessions ?? [] }
    var running: Set<String> { Set(sessions.filter { !$0.server }.map(\.dir)) }
    /// Projects without a running session.
    var idleProjects: [Project] { (overview?.projects ?? []).filter { !running.contains($0.name) } }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            overview = try await API.overview()
            fetchedAt = .now
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshUsage(force: Bool = false) async {
        do {
            let fresh = try await API.usage(force: force)
            if fresh.limits != usage?.limits {
                WidgetCenter.shared.reloadAllTimelines()
            }
            usage = fresh
            usageError = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            usageError = error.localizedDescription
        }
    }

    /// Starts a session and returns it, or nil (with `error` set) if that failed.
    func start(_ name: String, create: Bool = false) async -> Session? {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            let s = try await API.start(name: name, create: create)
            error = nil
            await refresh()
            return s
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func stop(_ session: Session) async {
        busy.insert(session.name)
        defer { busy.remove(session.name) }
        do {
            try await API.stop(pid: session.pid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if session.server {
            try? await Task.sleep(for: .seconds(2)) // launchd brings the server back
        }
        await refresh()
    }
}
