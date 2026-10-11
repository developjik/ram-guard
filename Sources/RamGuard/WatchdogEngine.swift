import Darwin
import Foundation
import os

/// The watchdog core: dedicated serial queue + DispatchSourceTimer at 10s
/// (first tick fires immediately; ticks pause during system sleep and resume
/// on wake). The engine owns the poll loop; the UI only subscribes to events.
final class WatchdogEngine {
    struct Dependencies {
        var readMemory: () throws -> MemoryPressure
        var snapshotProcesses: () -> [ProcSnapshot]
        var kill: (pid_t) -> kern_return_t
        var now: () -> Date

        static func live() -> Dependencies {
            let table = ProcessTable.live()
            return Dependencies(
                readMemory: { try MemoryPressure.read() },
                snapshotProcesses: table.snapshotAll,
                kill: { pid in Darwin.kill(pid, SIGKILL) },
                now: { Date() }
            )
        }
    }

    enum Event {
        case tick(availableMiB: Double, thresholdMiB: Double, swap: SwapUsage?, swapoutMiBPerTick: Double?, breached: Bool)
        case wouldKill(ProcSnapshot)
        case killed(ProcSnapshot)
        case killFailed(pid: pid_t, name: String, kr: kern_return_t)
        case cooldownSuppressed(ProcSnapshot, remaining: TimeInterval)
        case noCandidate(availableMiB: Double)
        case readFailed(String)
    }

    static let pollInterval: TimeInterval = 10
    static let maxKillAttemptsPerTick = 3
    /// Secondary-trigger floor for the virtual-memory spill valve. macOS
    /// swapfiles grow dynamically into free storage, so the real swap
    /// capacity is (swap free + disk free) — when that headroom drops below
    /// this floor, the system has little room left to absorb pressure.
    static let swapHeadroomFloorMiB: Double = 8_192
    /// How far above the threshold the secondary trigger still reaches
    /// (available <= threshold * swapPressureWindow).
    static let swapPressureWindow: Double = 2.0
    /// Thrash guard (tertiary trigger). The AI-workload freeze mode: one huge
    /// working set pages out continuously while availability stays above the
    /// floor — capacity metrics look fine while the machine drowns in swap
    /// I/O. 128 MiB of swap writes per 10s tick sustained for 3 ticks (~30s)
    /// only happens under real memory starvation; one-off bursts (a model
    /// load, a VM boot) don't outlast the sustain window.
    static let thrashRateMiBPerTick: Double = 128
    static let thrashSustainTicks = 3
    /// Swap I/O deltas spanning a longer gap (sleep, read failure) are not a
    /// rate — skip them and rebuild the baseline.
    static let thrashTickGapLimit: TimeInterval = 15

    /// Breach decision (pure, unit-tested). Primary: available <= threshold.
    /// Secondary: virtual-memory headroom (swap free + disk free) below the
    /// floor AND available degraded (within 2x the threshold) — fires early
    /// when the storage-backed spill valve is nearly shut. Tertiary: thrash
    /// guard — sustained swap-write volume fires regardless of availability.
    /// Plenty of headroom NEVER fires the secondary: that state is safe, and
    /// a kill there would harm an innocent app.
    static func isBreached(availableMiB: Double, thresholdMiB: Double, swapHeadroomMiB: Double?, swapoutMiBPerTick: Double? = nil, thrashSustainedTicks: Int = 0, swapFloorMiB: Double = WatchdogEngine.swapHeadroomFloorMiB) -> Bool {
        if availableMiB <= thresholdMiB { return true }
        if let rate = swapoutMiBPerTick, rate >= thrashRateMiBPerTick, thrashSustainedTicks >= thrashSustainTicks { return true }
        guard let headroom = swapHeadroomMiB else { return false }
        guard headroom <= swapFloorMiB else { return false }
        return availableMiB <= thresholdMiB * swapPressureWindow
    }

    let dependencies: Dependencies
    let history: HistoryStore
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var lastKillAt: Date?
    private var wasBreached = false
    private var wasNoCandidate = false
    private var wasUnresolvableLogged = false
    /// Thrash guard state: previous cumulative swapout MiB with its tick
    /// time, and how many consecutive ticks exceeded the rate floor.
    private var lastSwapoutMiB: Double?
    private var lastSwapoutAt: Date?
    private var thrashStreak = 0
    /// Called on the engine queue after each tick (single event sink).
    var onEvent: ((Event) -> Void)?

    private var policyProvider: () -> KillPolicy
    private var postureProvider: () -> WatchdogPosture
    private var thresholdProvider: () -> Double
    private var swapFloorProvider: () -> Double
    private let cooldown = CooldownGate(window: 30)

    init(
        dependencies: Dependencies,
        history: HistoryStore = HistoryStore(),
        policyProvider: @escaping () -> KillPolicy,
        postureProvider: @escaping () -> WatchdogPosture,
        thresholdProvider: @escaping () -> Double,
        swapFloorProvider: @escaping () -> Double = { WatchdogEngine.swapHeadroomFloorMiB }
    ) {
        self.dependencies = dependencies
        self.history = history
        self.policyProvider = policyProvider
        self.postureProvider = postureProvider
        self.thresholdProvider = thresholdProvider
        self.swapFloorProvider = swapFloorProvider
        self.queue = DispatchQueue(label: "dev.ramguard.watchdog", qos: .userInitiated)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .never)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
        Log.watchdog.info("engine started (poll=10s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One poll cycle. Runs on the engine queue; also directly callable in tests.
    func tick() {
        let now = dependencies.now()
        let threshold = thresholdProvider()
        let posture = postureProvider()

        let memory: MemoryPressure
        do {
            memory = try dependencies.readMemory()
        } catch {
            let message = "memory read failed: \(error)"
            Log.watchdog.error("\(message, privacy: .public)")
            history.append(HistoryEvent(kind: .readFailed, pid: nil, name: nil, footprintKiB: nil, reason: message, timestamp: now))
            onEvent?(.readFailed(message))
            return
        }

        // Thrash rate: delta of the cumulative swapout counter over one poll
        // (fixed 10s cadence, so per-tick volume doubles as a rate). A gap
        // longer than the limit (sleep, read failure) is not a rate.
        let swapoutRate: Double?
        if let last = lastSwapoutMiB, let lastAt = lastSwapoutAt, now > lastAt, now.timeIntervalSince(lastAt) <= Self.thrashTickGapLimit {
            swapoutRate = max(memory.swapoutMiB - last, 0)
        } else {
            swapoutRate = nil
        }
        lastSwapoutMiB = memory.swapoutMiB
        lastSwapoutAt = now
        if let rate = swapoutRate, rate >= Self.thrashRateMiBPerTick {
            thrashStreak += 1
        } else {
            thrashStreak = 0
        }

        let breached = Self.isBreached(
            availableMiB: memory.availableMiB,
            thresholdMiB: threshold,
            swapHeadroomMiB: memory.swap?.headroomMiB,
            swapoutMiBPerTick: swapoutRate,
            thrashSustainedTicks: thrashStreak,
            swapFloorMiB: swapFloorProvider()
        )
        onEvent?(.tick(availableMiB: memory.availableMiB, thresholdMiB: threshold, swap: memory.swap, swapoutMiBPerTick: swapoutRate, breached: breached))

        guard breached else {
            if wasBreached {
                Log.watchdog.info("pressure cleared (\(memory.availableMiB, format: .fixed(precision: 0)) MiB available)")
            }
            wasBreached = false
            wasNoCandidate = false
            return
        }
        wasBreached = true

        let primaryBreach = memory.availableMiB <= threshold
        let breachKind = primaryBreach ? "threshold" : "swap-thrash"
        let breachReason = primaryBreach
            ? "threshold \(Int(threshold))MiB breached"
            : "swap thrash \(Int(swapoutRate ?? 0))MiB/10s × \(thrashStreak) ticks"

        let policy = policyProvider()
        let snapshots = dependencies.snapshotProcesses()
        let eligible = Self.eligibleCandidates(from: snapshots, policy: policy)

        // Plan F2 fail-safe observability: snapshots whose path cannot be
        // resolved are never candidates; surface them (rate-limited on state
        // change) so the guard is auditable, not silent.
        let unresolvable = snapshots.filter {
            KillPolicy.reasonIfRejected($0, config: policy.config) == .pathUnresolvable
                && $0.footprintKiB > KillPolicyConfig.memoryFloorKiB
        }
        if !unresolvable.isEmpty {
            if !wasUnresolvableLogged {
                let top = unresolvable.max(by: { $0.footprintKiB < $1.footprintKiB })!
                Log.watchdog.notice("path unresolvable — excluded from candidates: \(top.name, privacy: .public) pid=\(top.pid) mem=\(top.footprintKiB)KiB (\(unresolvable.count) total)")
                history.append(HistoryEvent(kind: .pathUnresolvable, pid: top.pid, name: top.name, footprintKiB: top.footprintKiB, reason: "\(unresolvable.count) snapshot(s) with unresolvable path excluded", timestamp: now))
                wasUnresolvableLogged = true
            }
        } else {
            wasUnresolvableLogged = false
        }

        guard let top = eligible.first else {
            // Rate-limited (plan F9 discretion): emit no-candidate only on the
            // state transition (entering no-candidate, or after a kill), never
            // as 10s spam.
            if !wasNoCandidate {
                Log.policy.notice("\(breachKind, privacy: .public) breach (\(memory.availableMiB, format: .fixed(precision: 0)) MiB avail) — no candidate")
                history.append(HistoryEvent(kind: .noCandidate, pid: nil, name: nil, footprintKiB: nil, reason: "\(breachKind) breach, no eligible candidate", timestamp: now))
                onEvent?(.noCandidate(availableMiB: memory.availableMiB))
                wasNoCandidate = true
            }
            return
        }
        wasNoCandidate = false

        switch posture {
        case .observe:
            Log.watchdog.notice("[observe] would kill \(top.name, privacy: .public) pid=\(top.pid) mem=\(top.footprintKiB)KiB")
            history.append(HistoryEvent(kind: .wouldKill, pid: top.pid, name: top.name, footprintKiB: top.footprintKiB, reason: "observe mode", timestamp: now))
            onEvent?(.wouldKill(top))
        case .armed:
            guard cooldown.allowsKill(now: now, lastKill: lastKillAt) else {
                let remaining = cooldown.remainingSeconds(now: now, lastKill: lastKillAt)
                Log.watchdog.notice("cooldown suppressed kill of \(top.name, privacy: .public) (\(Int(remaining))s remaining)")
                history.append(HistoryEvent(kind: .cooldownSuppressed, pid: top.pid, name: top.name, footprintKiB: top.footprintKiB, reason: "cooldown \(Int(remaining))s remaining, candidate present", timestamp: now))
                onEvent?(.cooldownSuppressed(top, remaining: remaining))
                return
            }
            for candidate in eligible.prefix(Self.maxKillAttemptsPerTick) {
                let kr = dependencies.kill(candidate.pid)
                if kr == KERN_SUCCESS {
                    lastKillAt = now
                    Log.kill.critical("SIGKILL \(candidate.name, privacy: .public) pid=\(candidate.pid) mem=\(candidate.footprintKiB)KiB")
                    history.append(HistoryEvent(kind: .kill, pid: candidate.pid, name: candidate.name, footprintKiB: candidate.footprintKiB, reason: breachReason, timestamp: now))
                    onEvent?(.killed(candidate))
                    return
                }
                Log.kill.error("kill failed pid=\(candidate.pid) kr=\(kr) — trying next candidate")
                history.append(HistoryEvent(kind: .killFailed, pid: candidate.pid, name: candidate.name, footprintKiB: candidate.footprintKiB, reason: "kill() returned kr=\(kr)", timestamp: now))
                onEvent?(.killFailed(pid: candidate.pid, name: candidate.name, kr: kr))
            }
        }
    }

    /// Eligible snapshots, largest RSS first.
    static func eligibleCandidates(from snapshots: [ProcSnapshot], policy: KillPolicy) -> [ProcSnapshot] {
        snapshots
            .filter { KillPolicy.reasonIfRejected($0, config: policy.config) == nil }
            .sorted { $0.footprintKiB > $1.footprintKiB }
    }
}
