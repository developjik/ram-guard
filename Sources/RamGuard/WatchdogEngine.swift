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
        case tick(availableMiB: Double, thresholdMiB: Double)
        case wouldKill(ProcSnapshot)
        case killed(ProcSnapshot)
        case killFailed(pid: pid_t, name: String, kr: kern_return_t)
        case cooldownSuppressed(ProcSnapshot, remaining: TimeInterval)
        case noCandidate(availableMiB: Double)
        case readFailed(String)
    }

    static let pollInterval: TimeInterval = 10
    static let maxKillAttemptsPerTick = 3

    let dependencies: Dependencies
    let history: HistoryStore
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var lastKillAt: Date?
    private var wasBreached = false
    /// Called on the engine queue after each tick (single event sink).
    var onEvent: ((Event) -> Void)?

    private var policyProvider: () -> KillPolicy
    private var postureProvider: () -> WatchdogPosture
    private var thresholdProvider: () -> Double
    private let cooldown = CooldownGate(window: 30)

    init(
        dependencies: Dependencies,
        history: HistoryStore = HistoryStore(),
        policyProvider: @escaping () -> KillPolicy,
        postureProvider: @escaping () -> WatchdogPosture,
        thresholdProvider: @escaping () -> Double
    ) {
        self.dependencies = dependencies
        self.history = history
        self.policyProvider = policyProvider
        self.postureProvider = postureProvider
        self.thresholdProvider = thresholdProvider
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
            history.append(HistoryEvent(kind: .noCandidate, pid: nil, name: nil, rssKiB: nil, reason: message, timestamp: now))
            onEvent?(.readFailed(message))
            return
        }

        onEvent?(.tick(availableMiB: memory.availableMiB, thresholdMiB: threshold))

        guard memory.availableMiB <= threshold else {
            if wasBreached {
                Log.watchdog.info("pressure cleared (\(memory.availableMiB, format: .fixed(precision: 0)) MiB available)")
            }
            wasBreached = false
            return
        }
        wasBreached = true

        let policy = policyProvider()
        let snapshots = dependencies.snapshotProcesses()
        let eligible = Self.eligibleCandidates(from: snapshots, policy: policy)

        guard let top = eligible.first else {
            // Rate-limited: log only on the breach-state transition (and after
            // any kill), never as 10s spam.
            Log.policy.notice("threshold breached (\(memory.availableMiB, format: .fixed(precision: 0)) MiB avail) — no candidate")
            history.append(HistoryEvent(kind: .noCandidate, pid: nil, name: nil, rssKiB: nil, reason: "threshold breached, no eligible candidate", timestamp: now))
            onEvent?(.noCandidate(availableMiB: memory.availableMiB))
            return
        }

        switch posture {
        case .observe:
            Log.watchdog.notice("[observe] would kill \(top.name, privacy: .public) pid=\(top.pid) rss=\(top.rssKiB)KiB")
            history.append(HistoryEvent(kind: .wouldKill, pid: top.pid, name: top.name, rssKiB: top.rssKiB, reason: "observe mode", timestamp: now))
            onEvent?(.wouldKill(top))
        case .armed:
            guard cooldown.allowsKill(now: now, lastKill: lastKillAt) else {
                let remaining = cooldown.remainingSeconds(now: now, lastKill: lastKillAt)
                Log.watchdog.notice("cooldown suppressed kill of \(top.name, privacy: .public) (\(Int(remaining))s remaining)")
                history.append(HistoryEvent(kind: .cooldownSuppressed, pid: top.pid, name: top.name, rssKiB: top.rssKiB, reason: "cooldown \(Int(remaining))s remaining, candidate present", timestamp: now))
                onEvent?(.cooldownSuppressed(top, remaining: remaining))
                return
            }
            for candidate in eligible.prefix(Self.maxKillAttemptsPerTick) {
                let kr = dependencies.kill(candidate.pid)
                if kr == KERN_SUCCESS {
                    lastKillAt = now
                    Log.kill.critical("SIGKILL \(candidate.name, privacy: .public) pid=\(candidate.pid) rss=\(candidate.rssKiB)KiB")
                    history.append(HistoryEvent(kind: .kill, pid: candidate.pid, name: candidate.name, rssKiB: candidate.rssKiB, reason: "threshold \(Int(threshold))MiB breached", timestamp: now))
                    onEvent?(.killed(candidate))
                    return
                }
                Log.kill.error("kill failed pid=\(candidate.pid) kr=\(kr) — trying next candidate")
                onEvent?(.killFailed(pid: candidate.pid, name: candidate.name, kr: kr))
            }
        }
    }

    /// Eligible snapshots, largest RSS first.
    static func eligibleCandidates(from snapshots: [ProcSnapshot], policy: KillPolicy) -> [ProcSnapshot] {
        snapshots
            .filter { KillPolicy.reasonIfRejected($0, config: policy.config) == nil }
            .sorted { $0.rssKiB > $1.rssKiB }
    }
}
