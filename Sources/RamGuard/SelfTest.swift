import Foundation

/// Built-in unit-test suite.
///
/// Why not `swift test`: this machine's Command Line Tools ship neither the
/// XCTest nor the swift-testing module, so the test target cannot compile.
/// The same assertions live here behind `ramguard selftest`; a zero exit code
/// is the M1 unit-gate evidence.
struct TestRunner {
    private var passed = 0
    private var failed = 0
    private var context: String

    init() { context = "" }

    private func line(_ message: String) {
        print("[selftest] \(message)")
    }

    mutating func check(_ condition: Bool, _ label: String,
                        file: StaticString = #fileID, lineNumber: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            line("FAIL \(context) — \(label) (\(file):\(lineNumber))")
        }
    }

    mutating func run(_ name: String, _ body: (inout TestRunner) -> Void) {
        let savedContext = context
        context = name
        body(&self)
        context = savedContext
    }

    mutating func finish() -> Never {
        line("\(passed) passed, \(failed) failed")
        if failed > 0 {
            line("RESULT: FAIL")
            exit(1)
        }
        line("RESULT: PASS")
        exit(0)
    }
}

func runSelfTest() -> Never {
    var t = TestRunner()

    // MARK: - KillPolicy filter matrix (AC-9)
    let config = KillPolicyConfig(
        ownPID: 100,
        ownBundlePath: "/Applications/RamGuard.app",
        ownUID: 501,
        exclusions: ["cursor"]
    )
    func snap(pid: pid_t = 1, rssKiB: UInt64 = 2_000_000, uid: uid_t = 501,
              path: String? = "/Users/dev/workers/agent", name: String = "agent") -> ProcSnapshot {
        ProcSnapshot(pid: pid, rssKiB: rssKiB, uid: uid, path: path, name: name)
    }
    let policy = KillPolicy(config: config)

    t.run("policy.select") { t in
        t.check(policy.selectCandidate(from: [snap(pid: 1, rssKiB: 1_500_000), snap(pid: 2, rssKiB: 3_500_000)])?.pid == 2, "largest eligible wins")
        t.check(policy.selectCandidate(from: []) == nil, "empty set -> nil")
    }
    t.run("policy.floor-boundary") { t in
        // Decimal parity: 1,000,000 KiB excluded, 1,000,001 passes.
        t.check(policy.selectCandidate(from: [snap(rssKiB: 1_000_000)]) == nil, "exactly 1,000,000 KiB is below floor")
        t.check(policy.selectCandidate(from: [snap(rssKiB: 1_000_001)])?.rssKiB == 1_000_001, "1,000,001 KiB passes")
    }
    t.run("policy.rss-conversion") { t in
        t.check(ProcSnapshot.rssKiB(fromResidentBytes: 1_048_576_000) == 1_024_000, "bytes/1024 exact")
        t.check(ProcSnapshot.rssKiB(fromResidentBytes: 1_024_000_000 + 1023) == 1_000_000, "floor at KiB boundary (below)")
        t.check(ProcSnapshot.rssKiB(fromResidentBytes: 1_024_000_000 + 1024) == 1_000_001, "floor at KiB boundary (at)")
    }
    t.run("policy.guards") { t in
        t.check(KillPolicy.reasonIfRejected(snap(uid: 0), config: config) == .differentUser, "other-user rejected")
        for path in ["/System/Library/foo", "/usr/libexec/tccd", "/bin/ls", "/sbin/launchd"] {
            t.check(KillPolicy.reasonIfRejected(snap(path: path), config: config) == .systemPath, "system prefix rejected: \(path)")
        }
        t.check(KillPolicy.reasonIfRejected(snap(path: "/kernel", name: "kernel_task"), config: config) == .kernelTask, "kernel_task rejected")
        t.check(KillPolicy.reasonIfRejected(snap(pid: 100), config: config) == .selfProcess, "own pid rejected")
        t.check(KillPolicy.reasonIfRejected(snap(pid: 101, path: "/Applications/RamGuard.app/Contents/MacOS/RamGuard"), config: config) == .selfProcess, "own bundle binary rejected")
        t.check(KillPolicy.reasonIfRejected(snap(pid: 102, path: "/Applications/RamGuard.app/Contents/XPC/Helper"), config: config) == .selfProcess, "own bundle child rejected")
        t.check(KillPolicy.reasonIfRejected(snap(path: "/Users/dev/apps/Cursor.app/Contents/MacOS/Cursor", name: "Cursor Helper (GPU)"), config: config) == .excluded, "exclusion substring matches")
        t.check(KillPolicy.reasonIfRejected(snap(path: "/Users/dev/bin/xd", name: "MYCURSORD"), config: config) == .excluded, "exclusion case-insensitive")
        t.check(KillPolicy.reasonIfRejected(snap(path: "/Users/dev/bin/bun", name: "bun"), config: config) == nil, "unrelated name passes")
        t.check(KillPolicy.reasonIfRejected(snap(rssKiB: 9_999_999, path: nil), config: config) == .pathUnresolvable, "unresolvable path fail-safe")
    }
    t.run("policy.eligible-sorted") { t in
        let ordered = WatchdogEngine.eligibleCandidates(
            from: [snap(pid: 1, rssKiB: 1_500_000), snap(pid: 2, rssKiB: 4_500_000), snap(pid: 3, rssKiB: 999_999)],
            policy: policy
        )
        t.check(ordered.map(\.pid) == [2, 1], "descending by RSS")
    }

    // MARK: - Memory math
    t.run("memory.pages-to-mib") { t in
        t.check(abs(MemoryPressure.pagesToMiB(free: 70, speculative: 7, pageSize: 16_384) - 1.203125) < 1e-9, "16K pages exact")
        t.check(abs(MemoryPressure.pagesToMiB(free: 128, speculative: 128, pageSize: 4_096) - 1.0) < 1e-9, "4K pages = 1 MiB")
        t.check(MemoryPressure.pagesToMiB(free: 0, speculative: 0, pageSize: 16_384) == 0, "zero pages")
        t.check(abs(MemoryPressure.pagesToMiB(free: 60_000, speculative: 40_000, pageSize: 16_384) - 1562.5) < 1e-6, "realistic large count")
    }

    // MARK: - Settings sanitize (Architect N2)
    t.run("settings.sanitize") { t in
        t.check(SettingsStore.sanitizeThreshold(.nan) == SettingsStore.defaultThresholdMiB, "NaN -> default")
        t.check(SettingsStore.sanitizeThreshold(0) == SettingsStore.defaultThresholdMiB, "0 -> default")
        t.check(SettingsStore.sanitizeThreshold(.infinity) == SettingsStore.defaultThresholdMiB, "inf -> default")
        t.check(SettingsStore.sanitizeThreshold(100) == SettingsStore.defaultThresholdMiB, "below lower bound -> default")
        t.check(SettingsStore.sanitizeThreshold(1_000_000) == SettingsStore.defaultThresholdMiB, "above upper bound -> default")
        t.check(SettingsStore.sanitizeThreshold(512) == 512, "512 passes")
        t.check(SettingsStore.sanitizeThreshold(1200) == 1200, "1200 passes")
        t.check(SettingsStore.sanitizeThreshold(4096) == 4096, "4096 passes")
        let suiteName = "ramguard-selftest-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        var store = SettingsStore(defaults: suite)
        t.check(store.posture == .observe, "default posture is observe")
        store.posture = .armed
        t.check(store.posture == .armed, "armed persists in defaults")
        t.check(store.thresholdMiB == SettingsStore.defaultThresholdMiB, "default threshold 1200")
        store.posture = .observe
    }

    // MARK: - CooldownGate boundaries
    let gate = CooldownGate(window: 30)
    let epoch = Date(timeIntervalSince1970: 1_000_000)
    t.run("cooldown.boundaries") { t in
        t.check(gate.allowsKill(now: epoch, lastKill: nil), "no last kill -> allowed")
        t.check(!gate.allowsKill(now: epoch.addingTimeInterval(29), lastKill: epoch), "+29s suppressed")
        t.check(gate.allowsKill(now: epoch.addingTimeInterval(30), lastKill: epoch), "+30s allowed (>= gate)")
        t.check(!gate.allowsKill(now: epoch.addingTimeInterval(10), lastKill: epoch), "+10s suppressed (tick grid)")
        t.check(!gate.allowsKill(now: epoch.addingTimeInterval(20), lastKill: epoch), "+20s suppressed (tick grid)")
        t.check(abs(gate.remainingSeconds(now: epoch.addingTimeInterval(5), lastKill: epoch) - 25) < 0.001, "remaining 25s")
        t.check(gate.remainingSeconds(now: epoch.addingTimeInterval(30), lastKill: epoch) == 0, "remaining 0 at +30s")
    }

    // MARK: - Engine tick behaviour (fake deps)
    let bomb = ProcSnapshot(pid: 42, rssKiB: 4_000_000, uid: 501, path: "/Users/dev/scripts/bomb", name: "bomb")
    func makeDeps(available: Double, snapshots: [ProcSnapshot],
                  killed: @escaping ((pid_t, Date) -> Void) = { _, _ in },
                  now: @escaping () -> Date) -> WatchdogEngine.Dependencies {
        WatchdogEngine.Dependencies(
            readMemory: { MemoryPressure(availableMiB: available, freePages: 0, speculativePages: 0) },
            snapshotProcesses: { snapshots },
            kill: { pid in
                killed(pid, now())
                return 0
            },
            now: now
        )
    }
    t.run("engine.observe") { t in
        var killedPids: [pid_t] = []
        let engine = WatchdogEngine(
            dependencies: makeDeps(available: 500, snapshots: [bomb], killed: { pid, _ in killedPids.append(pid) }, now: { Date() }),
            policyProvider: { KillPolicy(config: config) },
            postureProvider: { .observe },
            thresholdProvider: { 1200 }
        )
        engine.tick()
        t.check(killedPids.isEmpty, "observe kills nothing")
        t.check(engine.history.snapshot().first?.kind == .wouldKill, "observe records would-kill")
    }
    t.run("engine.armed-cooldown") { t in
        let start = Date(timeIntervalSince1970: 2_000_000)
        var currentTime = start
        var killedAt: [Date] = []
        let deps = WatchdogEngine.Dependencies(
            readMemory: { MemoryPressure(availableMiB: 500, freePages: 0, speculativePages: 0) },
            snapshotProcesses: { [bomb] },
            kill: { _ in
                killedAt.append(currentTime)
                return 0
            },
            now: { currentTime }
        )
        let engine = WatchdogEngine(
            dependencies: deps,
            policyProvider: { KillPolicy(config: config) },
            postureProvider: { .armed },
            thresholdProvider: { 1200 }
        )
        engine.tick()
        t.check(killedAt.count == 1, "T0 kill happens")
        currentTime = start.addingTimeInterval(10)
        engine.tick()
        t.check(killedAt.count == 1, "+10s suppressed by cooldown")
        let kinds = engine.history.snapshot().map(\.kind)
        t.check(kinds.contains(.cooldownSuppressed), "cooldown-suppressed event recorded: \(kinds)")
        currentTime = start.addingTimeInterval(30)
        engine.tick()
        t.check(killedAt.count == 2, "+30s second kill allowed")
        t.check(killedAt[1].timeIntervalSince(killedAt[0]) >= 30, "kill interval >= 30s (assertion e)")
    }
    t.run("engine.no-candidate") { t in
        let engine = WatchdogEngine(
            dependencies: makeDeps(available: 500, snapshots: [], now: { Date() }),
            policyProvider: { KillPolicy(config: config) },
            postureProvider: { .armed },
            thresholdProvider: { 1200 }
        )
        engine.tick()
        t.check(engine.history.snapshot().first?.kind == .noCandidate, "no-candidate event recorded")
        // F9 discretion: repeated no-candidate ticks dedupe to a single event.
        engine.tick()
        engine.tick()
        let noCandidateEvents = engine.history.snapshot().filter { $0.kind == .noCandidate }.count
        t.check(noCandidateEvents == 1, "no-candidate deduped across ticks (got \(noCandidateEvents))")
    }
    t.run("engine.path-unresolvable-guard") { t in
        // Plan F2: unresolvable-path snapshots above the floor are excluded
        // from candidacy (fail-safe) and surfaced to history for audit.
        let ghost = ProcSnapshot(pid: 77, rssKiB: 2_000_000, uid: 501, path: nil, name: "ghost")
        var killedPids: [pid_t] = []
        let engine = WatchdogEngine(
            dependencies: makeDeps(available: 500, snapshots: [ghost],
                                   killed: { pid, _ in killedPids.append(pid) }, now: { Date() }),
            policyProvider: { KillPolicy(config: config) },
            postureProvider: { .armed },
            thresholdProvider: { 1200 }
        )
        engine.tick()
        t.check(killedPids.isEmpty, "unresolvable-path process never killed")
        let kinds = engine.history.snapshot().map(\.kind)
        t.check(kinds.contains(.pathUnresolvable), "path-unresolvable recorded (got \(kinds))")
        t.check(kinds.contains(.noCandidate), "breach with only unresolvable candidates logs no-candidate")
    }
    t.run("engine.above-threshold") { t in
        var killedPids: [pid_t] = []
        let engine = WatchdogEngine(
            dependencies: makeDeps(available: 4000, snapshots: [bomb], killed: { pid, _ in killedPids.append(pid) }, now: { Date() }),
            policyProvider: { KillPolicy(config: config) },
            postureProvider: { .armed },
            thresholdProvider: { 1200 }
        )
        engine.tick()
        t.check(killedPids.isEmpty, "above threshold -> no action")
        t.check(engine.history.snapshot().isEmpty, "above threshold -> no events")
    }

    // MARK: - ExclusionsStore
    t.run("exclusions.parse") { t in
        let text = """
        # comment
        Cursor

           bun
        # another
        node
        """
        t.check(ExclusionsStore.parse(text: text) == ["Cursor", "bun", "node"], "comments/blanks dropped, trimmed")
    }
    do {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramguard-selftest-\(UUID().uuidString)/exclusions.txt")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        t.run("exclusions.template") { t in
            t.check(!FileManager.default.fileExists(atPath: tempURL.path), "precondition: file absent")
            let store = ExclusionsStore(url: tempURL)
            t.check(store.entries.isEmpty, "template yields no entries")
            t.check(FileManager.default.fileExists(atPath: tempURL.path), "template file created")
            t.check(ExclusionsStore(url: tempURL).entries == [], "re-load of template is empty")
        }
        t.run("exclusions.existing") { t in
            try! FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "bomb\n# x\nSleeper\n".data(using: .utf8)!.write(to: tempURL)
            t.check(ExclusionsStore(url: tempURL).entries == ["bomb", "Sleeper"], "existing file parsed")
        }
        t.run("exclusions.fail-safe") { t in
            try! Data([0xFF, 0xFE, 0x00, 0x13]).write(to: tempURL)
            t.check(ExclusionsStore(url: tempURL).entries == [], "invalid UTF-8 -> empty list (fail-safe)")
        }
    }

    // MARK: - HistoryStore ring buffer
    t.run("history.ring-buffer") { t in
        let store = HistoryStore()
        for i in 0..<(HistoryStore.capacity + 150) {
            store.append(HistoryEvent(kind: .kill, pid: pid_t(i), name: "p\(i)", rssKiB: 1, reason: "", timestamp: Date()))
        }
        t.check(store.count == HistoryStore.capacity, "capped at capacity")
        t.check(store.snapshot().first?.pid == pid_t(HistoryStore.capacity + 149), "newest first")
        t.check(store.snapshot().last?.pid == pid_t(150), "oldest retained evicts correctly")
    }
    t.run("history.thread-safety") { t in
        let store = HistoryStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "selftest", attributes: .concurrent)
        for _ in 0..<8 {
            group.enter()
            queue.async {
                for i in 0..<500 {
                    store.append(HistoryEvent(kind: .wouldKill, pid: pid_t(i), name: "x", rssKiB: 1, reason: "", timestamp: Date()))
                }
                group.leave()
            }
        }
        group.wait()
        t.check(store.count == HistoryStore.capacity, "concurrent appends stay capped")
    }

    // MARK: - NotificationCoalescer (KillNotifierTests port)
    let coalescer = NotificationCoalescer(window: 30)
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    t.run("notifier.coalescing") { t in
        var state = NotificationCoalescer.State()
        t.check(coalescer.shouldNotify(now: t0, state: &state), "first kill notifies")
        t.check(!coalescer.shouldNotify(now: t0.addingTimeInterval(15), state: &state), "+15s suppressed")
        t.check(!coalescer.shouldNotify(now: t0.addingTimeInterval(29.9), state: &state), "+29.9s suppressed")
        t.check(!coalescer.shouldNotify(now: t0.addingTimeInterval(30), state: &state), "+30s still inside window (<=)")
        t.check(coalescer.shouldNotify(now: t0.addingTimeInterval(31), state: &state), "+31s opens new window and notifies")
        t.check(!coalescer.shouldNotify(now: t0.addingTimeInterval(50), state: &state), "new window anchored at +31 (re-anchor)")
    }

    t.finish()
}
