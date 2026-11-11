import CryptoKit
import Foundation
import os
@testable import Hangar

/// The Mac's side of the protocol (backend/e2e.go, relayclient.go), for tests: every socket the
/// connection opens ends here. It answers requests through `handler` and can be told to
/// misbehave the way real connections do.
final class FakeMac: @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let method: String
        let path: String
        let key: String?
    }

    enum Behaviour: Sendable {
        case answer            // the usual
        case silentHandshake   // accepts the socket, never says welcome
        case offline           // the relay closes with 4404: no such Mac connected
    }

    let key = Curve25519.KeyAgreement.PrivateKey()
    private let lock = NSLock()
    private var _behaviour = Behaviour.answer
    private var _sockets: [FakeSocket] = []
    private var _requests: [Request] = []
    private var _handler: @Sendable (Request, FakeSocket) -> (Int, Any)? = { _, _ in (200, ["ok": true]) }
    var api = 2

    var behaviour: Behaviour {
        get { lock.withLock { _behaviour } }
        set { lock.withLock { _behaviour = newValue } }
    }
    var sockets: [FakeSocket] { lock.withLock { _sockets } }
    var requests: [Request] { lock.withLock { _requests } }
    /// Returns (status, JSON body), or nil to leave the request unanswered.
    var handler: @Sendable (Request, FakeSocket) -> (Int, Any)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    func connector() -> RelayConnection.Connector {
        { [self] _ in
            let s = FakeSocket(mac: self)
            lock.withLock { _sockets.append(s) }
            if behaviour == .offline { s.close(code: 4404) }
            return s
        }
    }

    fileprivate func record(_ r: Request) { lock.withLock { _requests.append(r) } }
}

final class FakeSocket: RelaySocket, @unchecked Sendable {
    private let mac: FakeMac
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var pingWaiters: [CheckedContinuation<Void, Error>] = []
    private var code = 0
    private var closed = false
    private var sendKey: SymmetricKey?
    private var recvKey: SymmetricKey?
    private var sendN: UInt64 = 0
    /// A connection that went dead without a word: nothing arrives, pings aren't answered.
    private var dead = false

    init(mac: FakeMac) { self.mac = mac }

    var closeCode: Int { lock.withLock { code } }
    var isClosed: Bool { lock.withLock { closed } }

    func goDead() { lock.withLock { dead = true } }

    func close() { close(code: 1001) }

    func close(code c: Int) {
        let (w, pings): (CheckedContinuation<Data, Error>?, [CheckedContinuation<Void, Error>]) = lock.withLock {
            guard !closed else { return (nil, []) }
            closed = true
            code = c
            defer { waiter = nil; pingWaiters = [] }
            return (waiter, pingWaiters)
        }
        w?.resume(throwing: URLError(.networkConnectionLost))
        for p in pings { p.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            let now: Result<Data, Error>? = lock.withLock {
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                if closed { return .failure(URLError(.networkConnectionLost)) }
                waiter = c
                return nil
            }
            if let now { c.resume(with: now) }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let now: Result<Void, Error>? = lock.withLock {
                if closed { return .failure(URLError(.networkConnectionLost)) }
                if dead { pingWaiters.append(c); return nil }
                return .success(())
            }
            if let now { c.resume(with: now) }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let (isClosed, isDead) = lock.withLock { (closed, dead) }
        if isClosed { return completion(URLError(.networkConnectionLost)) }
        completion(nil)
        if isDead { return }
        if lock.withLock({ recvKey }) == nil { handshake(data) } else { serve(data) }
    }

    private func push(_ data: Data) {
        let w: CheckedContinuation<Data, Error>? = lock.withLock {
            if closed { return nil }
            if let w = waiter { waiter = nil; return w }
            inbox.append(data)
            return nil
        }
        w?.resume(returning: data)
    }

    private func handshake(_ data: Data) {
        guard mac.behaviour == .answer,
              let hello = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phoneKey = (hello["key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let phoneEph = (hello["eph"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let phonePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneKey),
              let phoneEphPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneEph) else { return }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let e = eph.publicKey.rawRepresentation
        var ikm = Data()
        for s in [try! mac.key.sharedSecretFromKeyAgreement(with: phonePub),
                  try! eph.sharedSecretFromKeyAgreement(with: phoneEphPub),
                  try! mac.key.sharedSecretFromKeyAgreement(with: phoneEphPub)] {
            s.withUnsafeBytes { ikm.append(contentsOf: $0) }
        }
        var h = SHA256()
        h.update(data: Data("hangar-v1".utf8))
        h.update(data: phoneKey)
        h.update(data: phoneEph)
        h.update(data: e)
        let salt = Data(h.finalize())
        func key(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        lock.withLock {
            recvKey = key("phone→mac")
            sendKey = key("mac→phone")
        }
        push(try! JSONSerialization.data(withJSONObject: ["t": "welcome", "eph": e.base64EncodedString(), "api": mac.api]))
    }

    private func serve(_ frame: Data) {
        let (rk, _) = lock.withLock { (recvKey, sendKey) }
        guard let rk, let plain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: frame), using: rk),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let id = obj["id"] as? Int else { return }
        let r = FakeMac.Request(id: id, method: obj["method"] as? String ?? "", path: obj["path"] as? String ?? "",
                                key: obj["key"] as? String)
        mac.record(r)
        guard let (status, body) = mac.handler(r, self) else { return }
        reply(id: id, status: status, body: body)
    }

    func reply(id: Int, status: Int, body: Any) {
        let msg = try! JSONSerialization.data(withJSONObject: ["id": id, "status": status, "body": body])
        let frame: Data = lock.withLock {
            var nonce = Data(count: 4)
            withUnsafeBytes(of: sendN.bigEndian) { nonce.append(contentsOf: $0) }
            sendN += 1
            return try! ChaChaPoly.seal(msg, using: sendKey!, nonce: ChaChaPoly.Nonce(data: nonce)).combined
        }
        push(frame)
    }
}
