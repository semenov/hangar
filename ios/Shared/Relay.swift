import CryptoKit
import Foundation

/// The phone's side of the relay: one WebSocket per Mac, end-to-end encrypted with the Mac.
/// The protocol is described in backend/e2e.go; this mirrors it with CryptoKit.
actor RelayConnection {
    nonisolated(unsafe) private static var pool: [String: RelayConnection] = [:] // guarded by poolLock
    private static let poolLock = NSLock()

    static func shared(for mac: PairedMac) -> RelayConnection {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let c = pool[mac.id] { return c }
        let c = RelayConnection(mac: mac)
        pool[mac.id] = c
        return c
    }

    static func drop(_ macID: String) {
        poolLock.lock()
        let c = pool.removeValue(forKey: macID)
        poolLock.unlock()
        if let c { Task { await c.close() } }
    }

    enum RelayError: LocalizedError {
        case offline, notPaired, refused(String), protocolError(String), timeout

        var errorDescription: String? {
            switch self {
            case .offline: "The Mac is offline: it's asleep, or `hangar serve` isn't running."
            case .notPaired: "This phone isn't paired with the Mac any more. Pair it again with `hangar pair`."
            case .refused(let why): why
            case .protocolError(let why): "Connection error: \(why)"
            case .timeout: "The Mac didn't answer in time."
            }
        }
    }

    private let mac: PairedMac
    private var task: URLSessionWebSocketTask?
    private var sendKey: SymmetricKey?
    private var recvKey: SymmetricKey?
    private var sendN: UInt64 = 0
    private var recvN: UInt64 = 0
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<(Int, Data), Error>] = [:]
    private var connecting: Task<Void, Error>?

    private init(mac: PairedMac) { self.mac = mac }

    // MARK: Requests

    func request(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) async throws -> (Int, Data) {
        try await ensureConnected()
        let id = nextID
        nextID += 1
        var msg: [String: Any] = ["id": id, "method": method, "path": path]
        if let body, let json = try? JSONSerialization.jsonObject(with: body) { msg["body"] = json }
        let frame = try seal(JSONSerialization.data(withJSONObject: msg))
        let t = task
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.fail(id, RelayError.timeout)
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            t?.send(.data(frame)) { error in
                if let error { Task { await self.fail(id, error) } }
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        reset(RelayError.protocolError("closed"))
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if task != nil, sendKey != nil { return }
        if let connecting { return try await connecting.value }
        let t = Task { try await connect() }
        connecting = t
        defer { connecting = nil }
        try await t.value
    }

    private func connect() async throws {
        guard let relay = mac.relay, let macKey = mac.macKey,
              let raw = Keychain.get(mac.keyAccount),
              let phone = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw RelayError.notPaired
        }
        let (task, keys) = try await Self.handshake(relay: relay, macID: mac.id, macKey: macKey, phone: phone,
                                                    pairing: nil)
        self.task = task
        (sendKey, recvKey) = keys
        sendN = 0
        recvN = 0
        receiveLoop(task)
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let msg = try await t.receive()
                    guard case .data(let frame) = msg else { continue }
                    await self?.deliver(frame)
                } catch {
                    let err: Error = t.closeCode.rawValue == 4404 ? RelayError.offline : error
                    await self?.reset(err, for: t)
                    return
                }
            }
        }
    }

    private func deliver(_ frame: Data) {
        guard let plain = try? open(frame),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let id = obj["id"] as? Int else {
            // Not a response: an error the Mac sent before closing ("not paired").
            if let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
               let why = obj["error"] as? String {
                reset(why == "not paired" ? RelayError.notPaired : RelayError.refused(why))
            }
            return
        }
        let status = obj["status"] as? Int ?? 500
        let body = (obj["body"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) } ?? Data()
        pending.removeValue(forKey: id)?.resume(returning: (status, body))
    }

    private func reset(_ error: Error, for t: URLSessionWebSocketTask? = nil) {
        if let t, t !== task { return } // an old connection
        task = nil
        sendKey = nil
        recvKey = nil
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: error) }
    }

    // MARK: Encryption

    private func seal(_ plain: Data) throws -> Data {
        guard let sendKey else { throw RelayError.protocolError("not connected") }
        var nonce = Data(count: 4)
        withUnsafeBytes(of: sendN.bigEndian) { nonce.append(contentsOf: $0) }
        sendN += 1
        return try ChaChaPoly.seal(plain, using: sendKey, nonce: ChaChaPoly.Nonce(data: nonce)).combined
    }

    private func open(_ frame: Data) throws -> Data {
        guard let recvKey, frame.count >= 28 else { throw RelayError.protocolError("bad frame") }
        let n = frame[frame.startIndex + 4 ..< frame.startIndex + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard n >= recvN else { throw RelayError.protocolError("replayed frame") }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: frame), using: recvKey)
        recvN = n + 1
        return plain
    }

    struct Pairing: Sendable {
        let secret: Data
        let name: String
    }

    /// Opens a WebSocket to the relay and runs the handshake; with `pairing`, it pairs first.
    /// Returns the socket and the (send, receive) keys.
    static func handshake(relay: String, macID: String, macKey: Data, phone: Curve25519.KeyAgreement.PrivateKey,
                          pairing: Pairing?) async throws -> (URLSessionWebSocketTask, (SymmetricKey, SymmetricKey)) {
        guard let url = URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/phone?id=" + macID) else {
            throw RelayError.protocolError("bad relay address")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 4 << 20
        task.resume()

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = phone.publicKey.rawRepresentation, ephKey = eph.publicKey.rawRepresentation
        var hello: [String: Any] = ["t": "hello", "key": phoneKey.base64EncodedString(), "eph": ephKey.base64EncodedString()]
        if let pairing {
            var mac = HMAC<SHA256>(key: SymmetricKey(data: pairing.secret))
            mac.update(data: Data("hangar-pair-v1".utf8))
            mac.update(data: phoneKey)
            mac.update(data: ephKey)
            hello["t"] = "pair"
            hello["name"] = pairing.name
            hello["proof"] = Data(mac.finalize()).base64EncodedString()
        }
        do {
            try await task.send(.data(JSONSerialization.data(withJSONObject: hello)))
            let reply = try await withTimeout(15) { try await task.receive() }
            guard case .data(let data) = reply,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RelayError.protocolError("unexpected reply")
            }
            if let why = obj["error"] as? String {
                throw why == "not paired" ? RelayError.notPaired : RelayError.refused(why)
            }
            guard obj["t"] as? String == "welcome", let e = (obj["eph"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                throw RelayError.protocolError("unexpected reply")
            }
            let macStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey)
            let macEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: e)
            var ikm = Data()
            for s in [try phone.sharedSecretFromKeyAgreement(with: macStatic),
                      try eph.sharedSecretFromKeyAgreement(with: macEph),
                      try eph.sharedSecretFromKeyAgreement(with: macStatic)] {
                s.withUnsafeBytes { ikm.append(contentsOf: $0) }
            }
            var h = SHA256()
            h.update(data: Data("hangar-v1".utf8))
            h.update(data: phoneKey)
            h.update(data: ephKey)
            h.update(data: e)
            let salt = Data(h.finalize())
            func key(_ info: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                       info: Data(info.utf8), outputByteCount: 32)
            }
            return (task, (key("phone→mac"), key("mac→phone")))
        } catch {
            let code = task.closeCode.rawValue
            task.cancel(with: .normalClosure, reason: nil)
            if code == 4404 { throw RelayError.offline }
            throw error
        }
    }

    /// Pairs with the Mac from a `hangar pair` link and saves it.
    static func pair(_ link: PairLink, phoneName: String) async throws -> PairedMac {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let (task, _) = try await handshake(relay: link.relay, macID: link.macID, macKey: link.macKey, phone: phone,
                                            pairing: Pairing(secret: link.secret, name: phoneName))
        task.cancel(with: .normalClosure, reason: nil)
        let mac = PairedMac(id: link.macID, name: link.name, kind: .relay, relay: link.relay, macKey: link.macKey)
        Keychain.set(phone.rawRepresentation, for: mac.keyAccount)
        drop(mac.id)
        Macs.add(mac)
        return mac
    }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RelayConnection.RelayError.timeout
        }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}
