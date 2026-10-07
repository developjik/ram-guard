import Foundation

/// Pure cooldown decision with an injectable clock.
///
/// Contract: after a kill, further kills are suppressed until
/// `now - lastKill >= 30s` (`now-lastKill>=30s` gate — a kill at exactly +30s
/// is allowed). Tick grid is 10s; the gate is evaluated per tick.
struct CooldownGate {
    let window: TimeInterval

    init(window: TimeInterval = 30) {
        self.window = window
    }

    /// True when a kill is permitted now.
    func allowsKill(now: Date, lastKill: Date?) -> Bool {
        guard let lastKill = lastKill else { return true }
        return now.timeIntervalSince(lastKill) >= window
    }

    /// Seconds remaining until a kill is permitted (0 when permitted).
    func remainingSeconds(now: Date, lastKill: Date?) -> TimeInterval {
        guard let lastKill = lastKill else { return 0 }
        let elapsed = now.timeIntervalSince(lastKill)
        return elapsed >= window ? 0 : window - elapsed
    }
}
