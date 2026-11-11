import XCTest
@testable import Hangar

final class ModelTests: XCTestCase {
    private let query = "relay=wss%3A%2F%2Fhangar.example&mac=" + String(repeating: "a", count: 32)
        + "&key=" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        + "&secret=c2VjcmV0&name=Vlad%27s+Mac"

    func testPairLinkForms() {
        let app = PairLink("hangar://pair?" + query)
        XCTAssertEqual(app?.relay, "wss://hangar.example")
        XCTAssertEqual(app?.name, "Vlad's Mac")
        // The https form `hangar pair` prints for sending to the phone.
        let web = PairLink("  https://hangar.example/pair#" + query + "\n")
        XCTAssertEqual(web?.macID, app?.macID)
        XCTAssertEqual(web?.macKey, app?.macKey)
        XCTAssertEqual(web?.secret, app?.secret)
        XCTAssertNil(PairLink("https://hangar.example/privacy#" + query))
        XCTAssertNil(PairLink("https://example.com/"))
        XCTAssertNil(PairLink("hangar://pair?mac=short"))
    }

    func testProjectNames() {
        XCTAssertEqual(ProjectName.slug("  Todo App "), "todo-app")
        XCTAssertEqual(ProjectName.slug("-.hidden"), "hidden") // must start with a letter or digit
        XCTAssertEqual(ProjectName.slug("Проект X"), "x")
        XCTAssertEqual(ProjectName.slug("---"), "")
        for typed in ["Todo App", "a.b_c-d", "9 lives", String(repeating: "x", count: 100)] {
            XCTAssertTrue(ProjectName.isValid(ProjectName.slug(typed)), typed)
        }
        XCTAssertFalse(ProjectName.isValid("-x"))
        XCTAssertFalse(ProjectName.isValid("a b"))
    }

    func testPathsAreEscaped() {
        XCTAssertEqual(API.escaped("games/tetris"), "games/tetris")
        XCTAssertEqual(API.escaped("my project/50% done?"), "my%20project/50%25%20done%3F")
        XCTAssertEqual(API.escaped("a#b"), "a%23b")
    }

    /// A Mac with an older or newer `hangar` leaves fields out; the list still loads.
    func testOverviewWithMissingFields() throws {
        let json = #"{"sessions":[{"name":"blog","pid":7}],"projects":[{"name":"blog","new_field":1}]}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        let o = try d.decode(Overview.self, from: Data(json.utf8))
        XCTAssertEqual(o.sessions.first?.state, "starting")
        XCTAssertEqual(o.sessions.first?.server, false)
        XCTAssertEqual(o.projects.first?.git, false)
    }
}

/// The store against the built-in demo Mac.
@MainActor
final class StoreTests: XCTestCase {
    private var saved: [String: Any?] = [:]

    override func setUp() async throws {
        for k in ["macs", "currentMac"] {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
        Macs.add(.demo)
    }

    override func tearDown() async throws {
        for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
    }

    func testStartStopAndTheListInBetween() async throws {
        let store = Store()
        await store.refresh()
        XCTAssertNil(store.trouble)
        let idle = try XCTUnwrap(store.idleProjects.first)

        // A refresh already on its way when the action ends must not be what the list shows.
        async let poll: Void = store.refresh()
        let started = await store.start(idle.name)
        await poll
        let session = try XCTUnwrap(started)
        XCTAssertTrue(store.sessions.contains { $0.pid == session.pid })
        XCTAssertFalse(store.idleProjects.contains { $0.name == idle.name })
        XCTAssertTrue(store.busy.isEmpty)

        await store.stop(session)
        XCTAssertFalse(store.sessions.contains { $0.pid == session.pid })
        XCTAssertNil(store.notice)

        // Stopping what is already gone isn't an error worth an alert.
        await store.stop(session)
        XCTAssertNil(store.notice)
    }

    func testCreatingAProject() async throws {
        let store = Store()
        await store.refresh()
        let name = "new-\(Int.random(in: 1000...9999))"
        let s = try await store.create(name, create: true)
        XCTAssertEqual(s.name, name)
        XCTAssertTrue(store.overview?.projects.contains { $0.name == name } ?? false)
        do {
            _ = try await store.create(name, create: true)
            XCTFail("a second project of the same name should be refused")
        } catch {}
    }
}
