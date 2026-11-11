import Foundation
import os

/// What the connection did lately, for Settings → Diagnostics: when something looks off on the
/// phone, this says whether the socket dropped, a request was repeated or the Mac was slow.
/// Kept in memory only, and in the unified log (subsystem ai.semenov.hangar).
enum Log {
    struct Line: Identifiable, Sendable {
        let id: Int
        let at: Date
        let text: String
    }

    private static let logger = Logger(subsystem: "ai.semenov.hangar", category: "connection")
    private static let state = OSAllocatedUnfairLock(initialState: (next: 0, lines: [Line]()))
    private static let limit = 300

    static func add(_ text: String) {
        logger.info("\(text, privacy: .public)")
        state.withLock { s in
            s.lines.append(Line(id: s.next, at: .now, text: text))
            s.next += 1
            if s.lines.count > limit { s.lines.removeFirst(s.lines.count - limit) }
        }
    }

    static var lines: [Line] { state.withLock { $0.lines } }

    /// The log as text, oldest first, for copying into a bug report.
    static var text: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return lines.map { f.string(from: $0.at) + "  " + $0.text }.joined(separator: "\n")
    }
}
