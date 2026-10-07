import Foundation

/// Pure notification-coalescing decision with an injectable clock (the
/// contract's "30초 창 통합" logic). Window anchor = first kill of the window
/// (fixed anchor, not sliding).
///
/// Semantics (unit-proven): the first kill notifies immediately; kills within
/// `window` seconds of the anchor are suppressed; a kill after the window
/// opens a new window and notifies.
struct NotificationCoalescer {
    let window: TimeInterval

    init(window: TimeInterval = 30) {
        self.window = window
    }

    /// State carried across decisions.
    struct State {
        var windowAnchor: Date?
        init() { self.windowAnchor = nil }
    }

    /// Decide whether a kill at `now` should notify. Mutates `state`.
    func shouldNotify(now: Date, state: inout State) -> Bool {
        guard let anchor = state.windowAnchor else {
            state.windowAnchor = now
            return true
        }
        if now.timeIntervalSince(anchor) <= window {
            return false
        }
        state.windowAnchor = now
        return true
    }
}
