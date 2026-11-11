import CryptoKit
import Foundation
import os

/// The WebSocket under a `RelayConnection`; tests put a pretend Mac behind it.
protocol RelaySocket: AnyObject, Sendable {
    /// Queues a binary message. Called in the order the messages must arrive.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// The next binary message; throws once the socket is closed.
    func receive() async throws -> Data
    /// Completes when the other end answers a ping. May never complete on a dead connection:
    /// callers close the socket when they stop waiting.
    func ping() async throws
    /// Closes the socket; everything waiting on it throws.
    func close()
    /// The WebSocket close code, 0 while open.
    var closeCode: Int { get }
}

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

    enum RelayError: LocalizedError, Equatable {
        case offline, notPaired, refused(String), protocolError(String), timeout, connectionLost

        var errorDescription: String? {
            switch self {
            case .offline: "The Mac is offline: it's asleep, or `hangar serve` isn't running."
            case .notPaired: "This phone isn't paired with the Mac any more. Pair it again with `hangar pair`."
            case .refused(let why): why
            case .protocolError(let why): "Connection error: \(why)"
            case .timeout: "The Mac didn't answer in time."
            case .connectionLost: "Lost the connection to the Mac."
            }
        }
    }

    /// How long things may take; tests shorten these.
    struct Timing: Sendable {
        /// Opening the WebSocket and the handshake with the Mac, together.
        var handshake: TimeInterval = 15
        /// A ping that checks whether a connection is still there.
        var ping: TimeInterval = 4
        /// A connection unused for this long is checked with a ping before the next request:
        /// iOS kills sockets in the background, and a network change leaves them dead without a word.
        var idle: TimeInterval = 12
        /// Before the second try when the relay says the Mac is offline (the Mac reconnects).
        var offlinePause: TimeInterval = 2
    }

    typealias Connector = @Sendable (URL) -> any RelaySocket

    private let mac: PairedMac
    private let connector: Connector
    private let timing: Timing
    private var socket: (any RelaySocket)?
    private var sendKey: SymmetricKey?
    private var recvKey: SymmetricKey?
    private var sendN: UInt64 = 0
    private var recvN: UInt64 = 0
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<(Int, Data), Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    /// Agreed in the handshake: messages carry a flag byte and the Mac may compress them.
    private var deflate = false
    /// The Mac remembers answers by request key (API 2), so a start, stop or rename whose answer
    /// was lost can be sent again without happening twice.
    private var replaySafe = false
    private var lastHeard = Date.distantPast
    /// Last response per GET path, so the Mac can answer 304 instead of resending it.
    private var etags: [String: (etag: String, body: Data)] = [:]
    private var pendingPath: [Int: String] = [:]
    private var connecting: Task<Void, Error>?

    init(mac: PairedMac, timing: Timing = Timing(), connector: @escaping Connector = { URLSessionSocket(url: $0) }) {
        self.mac = mac
        self.timing = timing
        self.connector = connector
    }

    // MARK: Requests

    /// Sends a request and waits for the Mac's answer. When the connection turns out to be dead
    /// (the relay's proxy reloaded, iOS killed the socket in the background, the network changed),
    /// the request goes out once more over a new one: GETs always, anything else when the Mac
    /// recognises a repeated request by its key.
    func request(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) async throws -> (Int, Data) {
        let key = method == "GET" ? nil : UUID().uuidString
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await ensureConnected()
            } catch {
                // Nothing was sent yet, so another try is always safe.
                guard attempt == 1, Self.isConnectionError(error) else { throw Self.plain(error) }
                Log.add("connect failed (\(Self.brief(error))); trying once more")
                if case RelayError.offline = error { try? await Task.sleep(for: .seconds(timing.offlinePause)) }
                continue
            }
            do {
                return try await exchange(method, path, body: body, key: key, timeout: timeout)
            } catch {
                guard attempt == 1, Self.isConnectionError(error) else { throw Self.plain(error) }
                // No answer in time: the Mac may just be slow, and then asking again doesn't help.
                if case RelayError.timeout = error, await alive() { throw error }
                guard method == "GET" || replaySafe else { throw Self.plain(error) }
                Log.add("\(method) \(path) failed (\(Self.brief(error))); sending it again")
                if case RelayError.offline = error { try? await Task.sleep(for: .seconds(timing.offlinePause)) }
            }
        }
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        switch error {
        case RelayError.timeout, RelayError.offline, RelayError.connectionLost, RelayError.protocolError: true
        case is URLError: true
        default: (error as NSError).domain == NSPOSIXErrorDomain
        }
    }

    /// iOS's own wording ("Software caused connection abort") means nothing to the user.
    private static func plain(_ error: Error) -> Error {
        error is URLError || (error as NSError).domain == NSPOSIXErrorDomain ? RelayError.connectionLost : error
    }

    private static func brief(_ error: Error) -> String {
        if let e = error as? RelayError { return "\(e)" }
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }

    private func exchange(_ method: String, _ path: String, body: Data?, key: String?,
                          timeout: TimeInterval) async throws -> (Int, Data) {
        guard let socket else { throw RelayError.connectionLost }
        let id = nextID
        nextID += 1
        var msg: [String: Any] = ["id": id, "method": method, "path": path]
        if let body, let json = try? JSONSerialization.jsonObject(with: body) { msg["body"] = json }
        if let key { msg["key"] = key }
        if method == "GET", let cached = etags[path] { msg["if_none_match"] = cached.etag }
        let frame = try seal(JSONSerialization.data(withJSONObject: msg))
        if method == "GET" { pendingPath[id] = path }
        timers[id] = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            await self?.fail(id, RelayError.timeout)
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            socket.send(frame) { error in
                if let error { Task { await self.fail(id, error) } }
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pendingPath.removeValue(forKey: id)
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func close() {
        socket?.close()
        reset(RelayError.connectionLost)
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if socket != nil, sendKey != nil {
            if Date.now.timeIntervalSince(lastHeard) < timing.idle { return }
            if await alive() { return }
        }
        if let connecting { return try await connecting.value }
        let t = Task { try await connect() }
        connecting = t
        defer { connecting = nil }
        try await t.value
    }

    /// Whether the connection still answers a ping. A connection that doesn't is dropped, and
    /// whatever was waiting on it fails as "connection lost".
    private func alive() async -> Bool {
        guard let s = socket, sendKey != nil else { return false }
        do {
            try await Self.within(timing.ping, on: s) { try await s.ping() }
            if s === socket { lastHeard = .now }
            return true
        } catch {
            Log.add("connection is dead (\(Self.brief(error)))")
            s.close()
            reset(RelayError.connectionLost, for: s)
            return false
        }
    }

    private func connect() async throws {
        guard let relay = mac.relay, let macKey = mac.macKey,
              let raw = Keychain.get(mac.keyAccount),
              let phone = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw RelayError.notPaired
        }
        let started = Date.now
        do {
            let opened = try await Self.handshake(relay: relay, macID: mac.id, macKey: macKey, phone: phone, pairing: nil,
                                                  deadline: timing.handshake, connector: connector)
            socket = opened.socket
            (sendKey, recvKey) = (opened.send, opened.receive)
            deflate = opened.deflate
            replaySafe = opened.api >= 2
            sendN = 0
            recvN = 0
            lastHeard = .now
            receiveLoop(opened.socket)
            Log.add(String(format: "connected to %@ in %.1fs (api %d)", mac.name, Date.now.timeIntervalSince(started), opened.api))
        } catch {
            Log.add("couldn't connect to \(mac.name): \(Self.brief(error))")
            throw error
        }
    }

    private func receiveLoop(_ s: any RelaySocket) {
        Task { [weak self] in
            while true {
                do {
                    let frame = try await s.receive()
                    await self?.deliver(frame, from: s)
                } catch {
                    let err: Error = s.closeCode == 4404 ? RelayError.offline : error
                    await self?.reset(err, for: s)
                    return
                }
            }
        }
    }

    private func deliver(_ frame: Data, from s: any RelaySocket) {
        guard s === socket else { return } // an old connection
        lastHeard = .now
        guard let plain = try? open(frame),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let id = obj["id"] as? Int else {
            // Not a response: an error the Mac sent before closing ("not paired").
            if let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
               let why = obj["error"] as? String {
                Log.add("the Mac closed the connection: \(why)")
                reset(why == "not paired" ? RelayError.notPaired : RelayError.refused(why))
            }
            return
        }
        var status = obj["status"] as? Int ?? 500
        var body = (obj["body"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) } ?? Data()
        if let path = pendingPath.removeValue(forKey: id) {
            if status == 304, let cached = etags[path] {
                (status, body) = (200, cached.body) // unchanged: the Mac sent no body
            } else if status == 200, let etag = obj["etag"] as? String {
                etags[path] = (etag, body)
            }
        }
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: (status, body))
    }

    private func reset(_ error: Error, for s: (any RelaySocket)? = nil) {
        if let s, s !== socket { return } // an old connection
        if socket != nil { Log.add("connection closed: \(Self.brief(error))") }
        socket = nil
        sendKey = nil
        recvKey = nil
        let waiting = pending
        pending = [:]
        pendingPath = [:]
        for (_, t) in timers { t.cancel() }
        timers = [:]
        for (_, c) in waiting { c.resume(throwing: error) }
    }

    // MARK: Encryption

    private func seal(_ message: Data) throws -> Data {
        guard let sendKey else { throw RelayError.connectionLost }
        let plain = deflate ? Data([0]) + message : message // requests are small: sent as is
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
        guard deflate else { return plain }
        // Flag byte: 0 = as is, 1 = raw DEFLATE (what the Compression framework calls zlib).
        guard let flag = plain.first else { throw RelayError.protocolError("empty message") }
        let rest = plain.dropFirst()
        switch flag {
        case 0: return Data(rest)
        case 1: return try (Data(rest) as NSData).decompressed(using: .zlib) as Data
        default: throw RelayError.protocolError("unknown message encoding")
        }
    }

    // MARK: Handshake

    struct Pairing: Sendable {
        let secret: Data
        let name: String
    }

    struct Opened: Sendable {
        let socket: any RelaySocket
        let send: SymmetricKey
        let receive: SymmetricKey
        /// Whether messages may be compressed.
        let deflate: Bool
        /// The Mac's API version; 1 for Macs that don't say.
        let api: Int
    }

    /// Runs `op`, closing the socket if it takes longer than `seconds`. Closing is what ends the
    /// wait: a WebSocket's send and receive don't stop when their task is cancelled.
    static func within<T: Sendable>(_ seconds: TimeInterval, on socket: any RelaySocket,
                                    _ op: @Sendable () async throws -> T) async throws -> T {
        let late = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            late.withLock { $0 = true }
            socket.close()
        }
        defer { watchdog.cancel() }
        do {
            return try await op()
        } catch {
            throw late.withLock { $0 } ? RelayError.timeout : error
        }
    }

    /// Opens a WebSocket to the relay and runs the handshake; with `pairing`, it pairs first.
    static func handshake(relay: String, macID: String, macKey: Data, phone: Curve25519.KeyAgreement.PrivateKey,
                          pairing: Pairing?, deadline: TimeInterval = 15,
                          connector: Connector = { URLSessionSocket(url: $0) }) async throws -> Opened {
        guard let url = URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/phone?id=" + macID) else {
            throw RelayError.protocolError("bad relay address")
        }
        let socket = connector(url)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = phone.publicKey.rawRepresentation, ephKey = eph.publicKey.rawRepresentation
        var hello: [String: Any] = ["t": "hello", "key": phoneKey.base64EncodedString(), "eph": ephKey.base64EncodedString(),
                                    "compress": ["deflate"]]
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
            let helloData = try JSONSerialization.data(withJSONObject: hello)
            let data = try await within(deadline, on: socket) {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    socket.send(helloData) { error in
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                }
                return try await socket.receive()
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            return Opened(socket: socket, send: key("phone→mac"), receive: key("mac→phone"),
                          deflate: obj["compress"] as? String == "deflate", api: obj["api"] as? Int ?? 1)
        } catch {
            let code = socket.closeCode
            socket.close()
            if code == 4404 { throw RelayError.offline }
            throw error
        }
    }

    /// Pairs with the Mac from a `hangar pair` link and saves it.
    static func pair(_ link: PairLink, phoneName: String) async throws -> PairedMac {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let opened = try await handshake(relay: link.relay, macID: link.macID, macKey: link.macKey, phone: phone,
                                         pairing: Pairing(secret: link.secret, name: phoneName))
        opened.socket.close()
        let mac = PairedMac(id: link.macID, name: link.name, kind: .relay, relay: link.relay, macKey: link.macKey)
        guard Keychain.set(phone.rawRepresentation, for: mac.keyAccount) else {
            throw RelayError.refused("Couldn't save this phone's key in the keychain.")
        }
        drop(mac.id)
        Macs.add(mac)
        Log.add("paired with \(mac.name)")
        return mac
    }
}

/// A real WebSocket to the relay.
final class URLSessionSocket: RelaySocket {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 4 << 20
        task.resume()
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.data(data), completionHandler: completion)
    }

    func receive() async throws -> Data {
        while true {
            if case .data(let data) = try await task.receive() { return data }
        }
    }

    func ping() async throws {
        // The handler runs once per ping, but nothing promises that for a socket that is closed
        // meanwhile; a continuation must be resumed exactly once.
        let done = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                guard done.withLock({ was in defer { was = true }; return !was }) else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    var closeCode: Int { task.closeCode.rawValue }
}
