import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class Store {
    var overview: Overview? // last known state, shown while the request runs
    var usage: Usage?
    var usageError: String?
    var usageLoading = false
    /// Why the Mac's list can't be refreshed; cleared by the next refresh that works.
    var trouble: Trouble?
    /// A start, stop or restart that failed, or why a session can't be opened; stays until dismissed.
    var notice: Notice?
    var isLoading = false
    var fetchedAt: Date?
    /// Projects (`Project.name`, `Session.key`) whose session is being started, stopped or renamed.
    var busy: Set<String> = []
    /// Projects whose description Claude is writing right now.
    var describing: Set<String> = []
    /// Whether the app is in front. A refresh that fails on the way to the background (iOS cuts
    /// the connection) isn't a problem worth showing.
    var active = true {
        didSet { if active && !oldValue { failures = 0 } }
    }

    /// The Macs this phone knows and the one shown; changes go through select/pair/unpair.
    private(set) var macs: [PairedMac] = Macs.all
    private(set) var current: PairedMac? = Macs.current

    private var failures = 0
    private var inFlight: Task<Void, Never>?
    private var queued: Task<Void, Never>?
    private var usageAskedAt = Date.distantPast

    init() {
        overview = API.cachedOverview(for: current)
        usage = API.cachedUsage(for: current)
    }

    /// What is wrong with the connection, in the terms the list shows it.
    struct Trouble: Equatable {
        enum Kind { case offline, notPaired, mismatch, other }
        let kind: Kind
        let message: String

        init(_ error: Error) {
            message = error.localizedDescription
            kind = switch error {
            case RelayConnection.RelayError.offline: .offline
            case RelayConnection.RelayError.notPaired: .notPaired
            case API.APIError.unreadable: .mismatch
            default: .other
            }
        }

        var title: String {
            switch kind {
            case .offline: "The Mac is offline"
            case .notPaired: "Not paired any more"
            case .mismatch: "Update needed"
            case .other: "Can't reach the Mac"
            }
        }
    }

    // MARK: Macs

    func select(_ mac: PairedMac) {
        Macs.select(mac.id)
        reloadMacs()
    }

    func pair(_ link: PairLink) async throws {
        _ = try await RelayConnection.pair(link, phoneName: UIDevice.current.name)
        reloadMacs(force: true)
    }

    func startDemo() {
        Macs.add(.demo)
        reloadMacs()
    }

    /// Returns whether the Mac was told to forget this phone.
    @discardableResult
    func unpair(_ mac: PairedMac) async -> Bool {
        let told = await API.unpair(mac)
        reloadMacs()
        return told
    }

    /// `force`: the same Mac was paired again, so what is shown about it is out of date.
    private func reloadMacs(force: Bool = false) {
        let old = current?.id
        macs = Macs.all
        current = Macs.current
        guard current?.id != old || force else { return }
        overview = API.cachedOverview(for: current)
        usage = API.cachedUsage(for: current)
        trouble = nil
        usageError = nil
        failures = 0
        busy = []
        describing = []
        Task {
            await refresh()
            await refreshUsage()
        }
    }

    // MARK: Refreshing

    var sessions: [Session] { overview?.sessions ?? [] }
    var running: Set<String> { Set(sessions.filter { !$0.server }.map(\.dir)) }
    /// Projects without a running session.
    var idleProjects: [Project] { (overview?.projects ?? []).filter { !running.contains($0.name) } }

    /// How long the list waits before asking again: longer while the Mac can't be reached, and
    /// not at all once it has unpaired this phone (pairing again or pulling to refresh asks).
    var pollDelay: Duration? {
        switch trouble?.kind {
        case nil: .seconds(5)
        case .notPaired: nil
        default: .seconds(min(30, 5 * max(1, failures)))
        }
    }

    /// Fetches the Mac's sessions and projects. The list this returns with was asked for after the
    /// call: if a request is already on its way (and may have been answered before whatever the
    /// caller just did), another one follows it.
    func refresh() async {
        if let queued { return await queued.value }
        if let running = inFlight {
            let next = Task {
                await running.value
                await self.load()
            }
            queued = next
            return await next.value
        }
        await load()
    }

    private func load() async {
        let t = Task { await self.fetchOverview() }
        queued = nil
        inFlight = t
        await t.value
        if inFlight == t { inFlight = nil }
    }

    private func fetchOverview() async {
        guard let mac = current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await API.overview(on: mac)
            guard mac.id == current?.id else { return } // switched Macs meanwhile
            overview = fresh
            fetchedAt = .now
            trouble = nil
            failures = 0
        } catch {
            guard mac.id == current?.id, active else { return }
            failures += 1
            let t = Trouble(error)
            // One missed poll isn't news while there is a list to show: the next one usually works.
            if failures >= 2 || overview == nil || t.kind == .notPaired || t.kind == .mismatch { trouble = t }
        }
    }

    func refreshUsage(force: Bool = false) async {
        guard let mac = current, !usageLoading || force else { return }
        usageLoading = true
        usageAskedAt = .now
        defer { usageLoading = false }
        do {
            let fresh = try await API.usage(on: mac, force: force)
            guard mac.id == current?.id else { return }
            if fresh.limits != usage?.limits {
                WidgetCenter.shared.reloadAllTimelines()
            }
            usage = fresh
            usageError = nil
        } catch {
            guard mac.id == current?.id, active else { return }
            usageError = error.localizedDescription
        }
    }

    /// A limit's window ended since the numbers were fetched: get new ones (at most once a minute).
    func refreshUsageIfReset() async {
        guard let usage, usage.limits.contains(where: { $0.hasReset() }),
              Date.now.timeIntervalSince(usageAskedAt) > 60 else { return }
        await refreshUsage(force: true)
    }

    // MARK: Actions

    /// Starts a session and returns it, or nil (with `notice` set) if that failed.
    func start(_ name: String) async -> Session? {
        do {
            return try await create(name, create: false)
        } catch {
            notice = Notice(title: "Couldn't start \(name)", message: error.localizedDescription)
            return nil
        }
    }

    /// Starts a session in ~/Dev/<name>, creating the folder first with `create`.
    func create(_ name: String, create: Bool) async throws -> Session {
        try await acting(on: name) { mac in try await API.start(on: mac, name: name, create: create) }
    }

    /// Restarts a session (same conversation); returns it, or nil (with `notice` set).
    func restart(_ session: Session) async -> Session? {
        do {
            return try await acting(on: session.key) { mac in try await API.restart(on: mac, pid: session.pid) }
        } catch {
            notice = Notice(title: "Couldn't restart \(session.name)", message: error.localizedDescription)
            return nil
        }
    }

    func stop(_ session: Session) async {
        do {
            try await acting(on: session.key) { mac in try await API.stop(on: mac, pid: session.pid) }
        } catch {
            // Stopped already (from the Mac, or by an earlier tap whose answer was lost): fine.
            if !sessions.contains(where: { $0.pid == session.pid }) { return }
            notice = Notice(title: "Couldn't stop \(session.name)", message: error.localizedDescription)
        }
    }

    /// Returns the new description.
    @discardableResult
    func regenerateDescription(_ project: String) async throws -> String {
        guard let mac = current else { throw API.APIError.noMac }
        describing.insert(project)
        defer { describing.remove(project) }
        let text = try await Self.inBackground { try await API.describe(on: mac, project) }
        await refresh()
        return text
    }

    /// Returns the new path.
    func rename(_ project: String, to name: String) async throws -> String {
        try await acting(on: project) { mac in try await API.rename(on: mac, project, to: name) }
    }

    func saveDescription(_ project: String, _ text: String) async throws {
        guard let mac = current else { throw API.APIError.noMac }
        _ = try await API.setDescription(on: mac, project, text)
        await refresh()
    }

    /// Runs something that changes a project on the current Mac: the project is busy meanwhile,
    /// and the list is fetched again before this returns, whether it worked or not.
    private func acting<T: Sendable>(on key: String, _ op: @escaping @Sendable (PairedMac) async throws -> T) async throws -> T {
        guard let mac = current else { throw API.APIError.noMac }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let result = try await Self.inBackground { try await op(mac) }
            await refresh()
            return result
        } catch {
            await refresh() // the list now shows what did happen
            throw error
        }
    }

    /// Asks iOS for time to finish if the app leaves the screen meanwhile: starting a session
    /// takes ten seconds or so, and people switch away while it does.
    private static func inBackground<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        let app = UIApplication.shared
        var id = UIBackgroundTaskIdentifier.invalid
        id = app.beginBackgroundTask {
            app.endBackgroundTask(id)
            id = .invalid
        }
        defer { if id != .invalid { app.endBackgroundTask(id) } }
        return try await op()
    }
}

/// Shown as an alert; `restart` adds a Restart button for that session.
struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var restart: Session?
}
