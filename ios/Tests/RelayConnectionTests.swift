import CryptoKit
import XCTest
@testable import Hangar

final class RelayConnectionTests: XCTestCase {
    private var fake: FakeMac!
    private var mac: PairedMac!

    override func setUp() {
        fake = FakeMac()
        mac = PairedMac(id: String(repeating: "t", count: 32), name: "Test Mac", kind: .relay,
                        relay: "wss://relay.test", macKey: fake.key.publicKey.rawRepresentation)
        XCTAssertTrue(Keychain.set(Curve25519.KeyAgreement.PrivateKey().rawRepresentation, for: mac.keyAccount))
    }

    override func tearDown() { Keychain.delete(mac.keyAccount) }

    private func connection(_ timing: RelayConnection.Timing = .init(handshake: 1, ping: 0.3, idle: 60, offlinePause: 0.05)) -> RelayConnection {
        RelayConnection(mac: mac, timing: timing, connector: fake.connector())
    }

    private func elapsed(_ op: () async throws -> Void) async rethrows -> TimeInterval {
        let t = Date.now
        try await op()
        return Date.now.timeIntervalSince(t)
    }

    func testRequestAndAnswer() async throws {
        fake.handler = { r, _ in (200, ["path": r.path]) }
        let (status, body) = try await connection().request("GET", "/api/overview", body: nil, timeout: 2)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["path": "/api/overview"])
    }

    /// The bug this guards: a relay that accepts the socket and then says nothing used to hang the
    /// app for good, because the handshake's timeout waited for a receive that never ends.
    func testSilentHandshakeTimesOut() async {
        fake.behaviour = .silentHandshake
        let c = connection()
        let took = await elapsed {
            do {
                _ = try await c.request("GET", "/api/overview", body: nil, timeout: 2)
                XCTFail("should have failed")
            } catch {
                XCTAssertEqual(error as? RelayConnection.RelayError, .timeout)
            }
        }
        XCTAssertLessThan(took, 4) // two tries of 1 s each
        XCTAssertEqual(fake.sockets.count, 2)
        XCTAssertTrue(fake.sockets.allSatisfy(\.isClosed))
    }

    func testOfflineMac() async {
        fake.behaviour = .offline
        do {
            _ = try await connection().request("GET", "/api/overview", body: nil, timeout: 2)
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? RelayConnection.RelayError, .offline)
        }
    }

    /// The connection drops before the answer to a start: the request goes out again over a new
    /// connection with the same key, so the Mac can answer with the first result.
    func testMutationIsRepeatedWithTheSameKeyAfterADrop() async throws {
        fake.handler = { [fake] r, socket in
            if fake!.requests.count == 1 {
                socket.close()
                return nil
            }
            return (200, ["ok": true])
        }
        let (status, _) = try await connection().request("POST", "/api/sessions", body: nil, timeout: 2)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertNotNil(fake.requests[0].key)
        XCTAssertEqual(fake.requests[0].key, fake.requests[1].key)
        XCTAssertEqual(fake.sockets.count, 2)
    }

    /// An older Mac doesn't know keys: a repeated start could start twice, so it isn't repeated.
    func testMutationIsNotRepeatedForAnOldMac() async {
        fake.api = 1
        fake.handler = { _, socket in
            socket.close()
            return nil
        }
        do {
            _ = try await connection().request("POST", "/api/sessions", body: nil, timeout: 2)
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? RelayConnection.RelayError, .connectionLost)
        }
        XCTAssertEqual(fake.requests.count, 1)
    }

    /// A slow answer to one request must not take down another that is still waiting.
    func testATimeoutLeavesOtherRequestsAlone() async throws {
        fake.handler = { r, socket in
            if r.path == "/api/slow" { return nil }
            if r.path == "/api/start" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { socket.reply(id: r.id, status: 200, body: ["started": true]) }
                return nil
            }
            return (200, ["ok": true])
        }
        let c = connection()
        async let start = c.request("POST", "/api/start", body: nil, timeout: 5)
        do {
            _ = try await c.request("GET", "/api/slow", body: nil, timeout: 0.3)
            XCTFail("should have timed out")
        } catch {
            XCTAssertEqual(error as? RelayConnection.RelayError, .timeout)
        }
        let (status, _) = try await start
        XCTAssertEqual(status, 200)
        XCTAssertEqual(fake.sockets.count, 1, "the connection was alive and should have been kept")
        XCTAssertEqual(fake.requests.filter { $0.path == "/api/start" }.count, 1)
    }

    /// Back from the background on a socket that died without a word: the ping notices within its
    /// deadline and the request goes over a new connection, instead of waiting out its own timeout.
    func testADeadIdleConnectionIsReplacedQuickly() async throws {
        let c = connection(.init(handshake: 1, ping: 0.3, idle: 0, offlinePause: 0.05))
        _ = try await c.request("GET", "/api/overview", body: nil, timeout: 2)
        fake.sockets[0].goDead()
        let took = try await elapsed {
            let (status, _) = try await c.request("GET", "/api/overview", body: nil, timeout: 20)
            XCTAssertEqual(status, 200)
        }
        XCTAssertLessThan(took, 2)
        XCTAssertEqual(fake.sockets.count, 2)
    }
}
