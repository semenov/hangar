import Foundation
import Observation
import UIKit
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
    /// Projects whose description Claude is writing right now.
    var describing: Set<String> = []

    /// The Macs this phone knows and the one shown; changes go through select/pair/unpair.
    private(set) var macs: [PairedMac] = Macs.all
    private(set) var current: PairedMac? = Macs.current

    func select(_ mac: PairedMac) {
        Macs.select(mac.id)
        reloadMacs()
    }

    func pair(_ link: PairLink) async throws {
        _ = try await RelayConnection.pair(link, phoneName: UIDevice.current.name)
        reloadMacs()
    }

    func startDemo() {
        Macs.add(.demo)
        reloadMacs()
    }

    func unpair(_ mac: PairedMac) async {
        await API.unpair(mac)
        reloadMacs()
    }

    private func reloadMacs() {
        let old = current?.id
        macs = Macs.all
        current = Macs.current
        if current?.id != old {
            overview = API.cachedOverview
            usage = API.cachedUsage
            error = nil
            Task {
                await refresh()
                await refreshUsage()
            }
        }
    }

    var sessions: [Session] { overview?.sessions ?? [] }
    var running: Set<String> { Set(sessions.filter { !$0.server }.map(\.dir)) }
    /// Projects without a running session.
    var idleProjects: [Project] { (overview?.projects ?? []).filter { !running.contains($0.name) } }

    func refresh() async {
        guard !isLoading, current != nil else { return }
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
        guard current != nil else { return }
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

    /// Returns the new description, or nil (with `error` set).
    @discardableResult
    func regenerateDescription(_ project: String) async -> String? {
        describing.insert(project)
        defer { describing.remove(project) }
        do {
            let text = try await API.describe(project)
            error = nil
            await refresh()
            return text
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Returns the new path, or nil (with `error` set).
    func rename(_ project: String, to name: String) async -> String? {
        busy.insert((project as NSString).lastPathComponent)
        defer { busy.remove((project as NSString).lastPathComponent) }
        do {
            let path = try await API.rename(project, to: name)
            error = nil
            await refresh()
            return path
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func saveDescription(_ project: String, _ text: String) async -> Bool {
        do {
            _ = try await API.setDescription(project, text)
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
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
        await refresh()
    }
}
