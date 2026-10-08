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
    /// The Mac couldn't be reached or didn't answer; cleared by the next refresh that works.
    var error: String?
    /// A start, stop or restart that failed, or why a session can't be opened; stays until dismissed.
    var notice: Notice?
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

    /// Starts a session and returns it, or nil (with `notice` set) if that failed.
    func start(_ name: String, create: Bool = false) async -> Session? {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            let s = try await API.start(name: name, create: create)
            await refresh()
            return s
        } catch {
            notice = Notice(title: "Couldn't start \(name)", message: error.localizedDescription)
            await refresh() // the project now shows why
            return nil
        }
    }

    /// Restarts a session (same conversation); returns it, or nil (with `notice` set).
    func restart(_ session: Session) async -> Session? {
        busy.insert(session.name)
        defer { busy.remove(session.name) }
        do {
            let s = try await API.restart(pid: session.pid)
            await refresh()
            return s
        } catch {
            notice = Notice(title: "Couldn't restart \(session.name)", message: error.localizedDescription)
            await refresh()
            return nil
        }
    }

    /// Returns the new description.
    @discardableResult
    func regenerateDescription(_ project: String) async throws -> String {
        describing.insert(project)
        defer { describing.remove(project) }
        let text = try await API.describe(project)
        await refresh()
        return text
    }

    /// Returns the new path.
    func rename(_ project: String, to name: String) async throws -> String {
        busy.insert((project as NSString).lastPathComponent)
        defer { busy.remove((project as NSString).lastPathComponent) }
        let path = try await API.rename(project, to: name)
        await refresh()
        return path
    }

    func saveDescription(_ project: String, _ text: String) async throws {
        _ = try await API.setDescription(project, text)
        await refresh()
    }

    func stop(_ session: Session) async {
        busy.insert(session.name)
        defer { busy.remove(session.name) }
        do {
            try await API.stop(pid: session.pid)
        } catch {
            notice = Notice(title: "Couldn't stop \(session.name)", message: error.localizedDescription)
        }
        await refresh()
    }
}

/// Shown as an alert; `restart` adds a Restart button for that session.
struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var restart: Session?
}
