import Foundation

/// Kill/would-kill history — fixed-size ring buffer (200), session scope only
/// (not persisted; v1 contract). Thread-safe.
struct HistoryEvent: Equatable {
    enum Kind: String, Equatable {
        case wouldKill = "would-kill"
        case kill = "kill"
        case noCandidate = "no-candidate"
        case killFailed = "kill-failed"
        case cooldownSuppressed = "cooldown-suppressed"
        case pathUnresolvable = "path-unresolvable"
        case readFailed = "read-failed"
    }

    let kind: Kind
    let pid: pid_t?
    let name: String?
    let rssKiB: UInt64?
    let reason: String
    let timestamp: Date
}

final class HistoryStore {
    static let capacity = 200

    private var buffer: [HistoryEvent] = []
    private let lock = NSLock()

    func append(_ event: HistoryEvent) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(event)
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
        }
    }

    /// Newest-first snapshot for the menu UI.
    func snapshot() -> [HistoryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.reversed()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}
