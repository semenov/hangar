import Foundation

/// A Mac the app talks to: paired through the relay, reached directly over HTTP (advanced: your
/// own proxy or Tailscale), or the built-in demo.
struct PairedMac: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case relay, direct, demo }

    var id: String // the Mac's ID for relay Macs
    var name: String
    var kind: Kind
    // relay
    var relay: String?
    var macKey: Data? // the Mac's X25519 public key
    // direct
    var url: String?
    var homebaseToken: String?
    var managerToken: String?

    static let demo = PairedMac(id: "demo", name: "Demo Mac", kind: .demo)

    /// Keychain account of the phone's private key for this Mac.
    var keyAccount: String { "phone-key." + id }
}

enum Macs {
    static var defaults: UserDefaults { .standard }
    private static let listKey = "macs", currentKey = "currentMac", migratedKey = "macsMigrated"

    static var all: [PairedMac] {
        get {
            migrateIfNeeded()
            return defaults.data(forKey: listKey).flatMap { try? JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: listKey) }
    }

    static var current: PairedMac? {
        let list = all
        let id = defaults.string(forKey: currentKey)
        return list.first { $0.id == id } ?? list.first
    }

    static func select(_ id: String) { defaults.set(id, forKey: currentKey) }

    static func add(_ mac: PairedMac) {
        var list = all.filter { $0.id != mac.id }
        list.append(mac)
        all = list
        select(mac.id)
    }

    static func remove(_ id: String) {
        all = all.filter { $0.id != id }
        Keychain.delete("phone-key." + id)
        if defaults.string(forKey: currentKey) == id { defaults.removeObject(forKey: currentKey) }
    }

    /// Builds from before pairing existed used one direct server from Secrets.swift and Settings.
    private static func migrateIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let url = defaults.string(forKey: "publicURL") ?? Secrets.publicServer
        guard !url.isEmpty, defaults.data(forKey: listKey) == nil else { return }
        let mac = PairedMac(id: "direct-" + UUID().uuidString, name: "My Mac", kind: .direct,
                            url: url,
                            homebaseToken: defaults.string(forKey: "token") ?? Secrets.homebaseToken,
                            managerToken: defaults.string(forKey: "managerToken") ?? Secrets.managerToken)
        defaults.set(try? JSONEncoder().encode([mac]), forKey: listKey)
    }
}

/// A `hangar://pair?...` link, as `hangar pair` shows it.
struct PairLink: Sendable {
    let relay: String
    let macID: String
    let macKey: Data
    let secret: Data
    let name: String

    init?(_ string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "hangar", c.host == "pair" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let relay = q["relay"], !relay.isEmpty, let mac = q["mac"], mac.count == 32,
              let key = Data(base64URL: q["key"] ?? ""), key.count == 32,
              let secret = Data(base64URL: q["secret"] ?? ""), !secret.isEmpty else { return nil }
        self.relay = relay
        macID = mac
        macKey = key
        self.secret = secret
        // Go's url.Values encodes spaces as "+" (a literal "+" would be %2B).
        let n = (q["name"] ?? "").replacingOccurrences(of: "+", with: " ")
        name = n.isEmpty ? "Mac" : n
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
