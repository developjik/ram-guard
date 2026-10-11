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
    func snap(pid: pid_t = 1, footprintKiB: UInt64 = 2_000_000, uid: uid_t = 501,
              path: String? = "/Users/dev/workers/agent", name: String = "agent") -> ProcSnapshot {
        ProcSnapshot(pid: pid, footprintKiB: footprintKiB, uid: uid, path: path, name: name)
    }
    let policy = KillPolicy(config: config)

    t.run("policy.select") { t in
        t.check(policy.selectCandidate(from: [snap(pid: 1, footprintKiB: 1_500_000), snap(pid: 2, footprintKiB: 3_500_000)])?.pid == 2, "largest eligible wins")
        t.check(policy.selectCandidate(from: []) == nil, "empty set -> nil")
    }
    t.run("policy.floor-boundary") { t in
        // Decimal parity: 1,000,000 KiB excluded, 1,000,001 passes.
        t.check(policy.selectCandidate(from: [snap(footprintKiB: 1_000_000)]) == nil, "exactly 1,000,000 KiB is below floor")
        t.check(policy.selectCandidate(from: [snap(footprintKiB: 1_000_001)])?.footprintKiB == 1_000_001, "1,000,001 KiB passes")
    }
    t.run("policy.footprint-conversion") { t in
        t.check(ProcSnapshot.footprintKiB(fromBytes: 1_048_576_000) == 1_024_000, "bytes/1024 exact")
        t.check(ProcSnapshot.footprintKiB(fromBytes: 1_024_000_000 + 1023) == 1_000_000, "floor at KiB boundary (below)")
        t.check(ProcSnapshot.footprintKiB(fromBytes: 1_024_000_000 + 1024) == 1_000_001, "floor at KiB boundary (at)")
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
        // P2 regression: long exclusion patterns must match the FULL
        // executable file name when pbi_comm truncates below the pattern.
        let longConfig = KillPolicyConfig(ownPID: 100, ownBundlePath: "/Applications/RamGuard.app", ownUID: 501, exclusions: ["Chrome Helper (Renderer)"])
        t.check(KillPolicy.reasonIfRejected(snap(path: "/Applications/Google Chrome.app/Contents/MacOS/Chrome Helper (Renderer).app/Contents/MacOS/Chrome Helper (Renderer)", name: "Chrome Helper (R"), config: longConfig) == .excluded, "long pattern matches via full path file name")
        t.check(KillPolicy.reasonIfRejected(snap(path: "/Users/dev/bin/bomb", name: "bomb"), config: longConfig) == nil, "long pattern does not over-match")
        t.check(KillPolicy.reasonIfRejected(snap(footprintKiB: 9_999_999, path: nil), config: config) == .pathUnresolvable, "unresolvable path fail-safe")
    }
    t.run("policy.eligible-sorted") { t in
        let ordered = WatchdogEngine.eligibleCandidates(
            from: [snap(pid: 1, footprintKiB: 1_500_000), snap(pid: 2, footprintKiB: 4_500_000), snap(pid: 3, footprintKiB: 999_999)],
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
    let bomb = ProcSnapshot(pid: 42, footprintKiB: 4_000_000, uid: 501, path: "/Users/dev/scripts/bomb", name: "bomb")
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
        let ghost = ProcSnapshot(pid: 77, footprintKiB: 2_000_000, uid: 501, path: nil, name: "ghost")
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
    t.run("engine.thrash-guard") { t in
        // Tertiary trigger end-to-end: availability never breaches, but a
        // huge working set sustains 512 MiB/tick of swap writes. The 4th
        // tick (3 consecutive readings above the rate floor) kills.
        var swapout = 0.0
        var currentTime = Date(timeIntervalSince1970: 3_000_000)
        var killedPids: [pid_t] = []
        let deps = WatchdogEngine.Dependencies(
            readMemory: { MemoryPressure(availableMiB: 4000, freePages: 0, speculativePages: 0, swap: nil, swapoutMiB: swapout) },
            snapshotProcesses: { [bomb] },
            kill: { pid in
                killedPids.append(pid)
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
        for _ in 0..<4 {
            swapout += 512
            currentTime = currentTime.addingTimeInterval(10)
            engine.tick()
        }
        t.check(killedPids.count == 1, "sustained thrash kills despite available above threshold (got \(killedPids.count))")
        let killEvent = engine.history.snapshot().first { $0.kind == .kill }
        t.check(killEvent?.reason.contains("thrash") == true, "kill reason names the thrash trigger: \(killEvent?.reason ?? "nil")")
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
            store.append(HistoryEvent(kind: .kill, pid: pid_t(i), name: "p\(i)", footprintKiB: 1, reason: "", timestamp: Date()))
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
                    store.append(HistoryEvent(kind: .wouldKill, pid: pid_t(i), name: "x", footprintKiB: 1, reason: "", timestamp: Date()))
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

    // MARK: - StatusLine (humanized UI phase 1)
    t.run("ui.format-memory") { t in
        t.check(StatusLine.formatMemory(245) == "245MB", "sub-GiB shows whole MB")
        t.check(StatusLine.formatMemory(1000) == "1000MB", "1000 MiB stays MB")
        t.check(StatusLine.formatMemory(1024) == "1.0GB", "exactly 1 GiB -> GB")
        t.check(StatusLine.formatMemory(1200) == "1.2GB", "default threshold 1200 -> 1.2GB")
        t.check(StatusLine.formatMemory(2048) == "2.0GB", "2048 -> 2.0GB")
    }
    t.run("ui.format-total") { t in
        t.check(StatusLine.formatTotal(16384) == "16GB", "16 GiB whole number")
        t.check(StatusLine.formatTotal(24576) == "24GB", "24 GiB whole number")
        t.check(StatusLine.formatTotal(16384 + 512) == "16.5GB", "fractional GiB keeps one decimal")
    }
    t.run("ui.band") { t in
        t.check(StatusLine.band(availableMiB: 3000, thresholdMiB: 1200) == .normal, "well above threshold")
        t.check(StatusLine.band(availableMiB: 2000, thresholdMiB: 1200) == .approaching, "within 1GiB headroom")
        t.check(StatusLine.band(availableMiB: 1200.5, thresholdMiB: 1200) == .approaching, "just above threshold")
        t.check(StatusLine.band(availableMiB: 1200, thresholdMiB: 1200) == .breached, "at threshold is breached")
        t.check(StatusLine.band(availableMiB: 100, thresholdMiB: 1200) == .breached, "below threshold is breached")
    }
    t.run("ui.band-combined") { t in
        // The combined RAM+VM pool: a shallow spill valve escalates the band,
        // and any engine breach (secondary or thrash) displays as danger.
        t.check(StatusLine.band(availableMiB: 6_000, thresholdMiB: 1_200) == .normal, "comfortable RAM, no swap data -> normal")
        t.check(StatusLine.band(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 5_000) == .approaching, "headroom below floor -> at least approaching")
        t.check(StatusLine.band(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 50_000) == .normal, "ample headroom stays normal")
        t.check(StatusLine.band(availableMiB: 2_000, thresholdMiB: 1_200, swapHeadroomMiB: 5_000, engineBreached: true) == .breached, "secondary breach -> danger")
        t.check(StatusLine.band(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 50_000, engineBreached: true) == .breached, "thrash breach -> danger despite ample RAM+VM")
        t.check(StatusLine.band(availableMiB: 2_000, thresholdMiB: 1_200) == .approaching, "physical approaching unchanged")
    }
    t.run("ui.line") { t in
        t.check(StatusLine.line(availableMiB: 6000, thresholdMiB: 1200, totalMiB: 16384, posture: .observe,
                                triggered: false, lastEventName: nil, lastEventWasKill: false).hasPrefix("🟢"), "normal line")
        t.check(StatusLine.line(availableMiB: 2000, thresholdMiB: 1200, totalMiB: 16384, posture: .observe,
                                triggered: false, lastEventName: nil, lastEventWasKill: false).hasPrefix("🟡"), "approaching line")
        t.check(StatusLine.line(availableMiB: 500, thresholdMiB: 1200, totalMiB: 16384, posture: .armed,
                                triggered: true, lastEventName: "밤", lastEventWasKill: true).contains("방어 발동"), "kill flash names the app")
        t.check(StatusLine.line(availableMiB: 500, thresholdMiB: 1200, totalMiB: 16384, posture: .observe,
                                triggered: false, lastEventName: "밤", lastEventWasKill: false).contains("관찰"), "observe near-miss line")
        t.check(StatusLine.line(availableMiB: 500, thresholdMiB: 1200, totalMiB: 16384, posture: .armed,
                                triggered: false, lastEventName: nil, lastEventWasKill: false).hasPrefix("🔴"), "generic breached line")
    }
    t.run("ui.history-text") { t in
        let kill = HistoryEvent(kind: .kill, pid: 1, name: "밤", footprintKiB: 1_250_864, reason: "", timestamp: Date())
        let text = StatusLine.historyText(kill)
        t.check(text.contains("'밤'") && text.contains("멈춤 방지"), "kill sentence names app")
        t.check(text.contains("1.2GB"), "rss shown in GB")
        t.check(StatusLine.historyText(HistoryEvent(kind: .noCandidate, pid: nil, name: nil, footprintKiB: nil, reason: "", timestamp: Date())).contains("후보 없음"), "no-candidate sentence")
        t.check(StatusLine.historyText(HistoryEvent(kind: .wouldKill, pid: 2, name: "폭탄", footprintKiB: 2_000_000, reason: "", timestamp: Date())).contains("관찰"), "would-kill sentence")
    }
    t.run("ui.notification-copy") { t in
        t.check(StatusLine.notificationTitle.contains("멈출"), "title is friendly, not technical")
        let body = StatusLine.notificationBody(name: "밤", footprintKiB: 1_250_864)
        t.check(body.contains("'밤'") && body.contains("1.2GB"), "body names app and freed memory")
    }
    t.run("ui.vm-headroom-note") { t in
        let breached = StatusLine.line(availableMiB: 300, thresholdMiB: 512, totalMiB: 16384, posture: .armed,
                                       triggered: false, lastEventName: nil, lastEventWasKill: false,
                                       swapHeadroomMiB: 108_243)
        t.check(!breached.contains("스왑 여유"), "ample headroom stays out of the sentence")
        t.check(!breached.contains("⚠️"), "ample headroom is not flagged")
        let low = StatusLine.line(availableMiB: 300, thresholdMiB: 512, totalMiB: 16384, posture: .armed,
                                  triggered: false, lastEventName: nil, lastEventWasKill: false,
                                  swapHeadroomMiB: 5_000)
        t.check(low.contains("스왑 여유 4.9GB ⚠️"), "headroom at/below floor is flagged")
        let thrash = StatusLine.line(availableMiB: 300, thresholdMiB: 512, totalMiB: 16384, posture: .armed,
                                     triggered: false, lastEventName: nil, lastEventWasKill: false,
                                     swapHeadroomMiB: 5_000, swapoutMiBPerTick: 512)
        t.check(thrash.contains("스왑 I/O 512MB/10초 ⚠️"), "active thrash surfaces the I/O note")
        t.check(!thrash.contains("스왑 여유"), "thrash note wins over the headroom note (2-line cap)")
        let noSwap = StatusLine.line(availableMiB: 300, thresholdMiB: 512, totalMiB: 16384, posture: .armed,
                                     triggered: false, lastEventName: nil, lastEventWasKill: false)
        t.check(!noSwap.contains("스왑"), "no swap note without a swap reading")
    }

    // MARK: - Swap secondary trigger, storage-backed (phase 4)
    t.run("ui.total-available") { t in
        let swap = SwapUsage(totalBytes: 2_048 * 1_048_576, usedBytes: 1_596 * 1_048_576, diskFreeBytes: 105 * 1_048_576 * 1024)
        // headroom = 452MB swap free + 105GiB disk free, on top of 3000MiB RAM
        let expected = 3_000.0 + Double(2_048 - 1_596) + 105 * 1024
        let total = StatusLine.totalAvailableMiB(availableMiB: 3_000, swap: swap)
        t.check(total != nil && abs(total! - expected) < 1e-9, "total available = RAM avail + swap headroom")
        t.check(StatusLine.totalAvailableMiB(availableMiB: 3_000, swap: nil) == nil, "no swap reading -> no total figure")
    }
    t.run("ui.combined-pool") { t in
        let swap = SwapUsage(totalBytes: 2_048 * 1_048_576, usedBytes: 512 * 1_048_576, diskFreeBytes: 96 * 1_048_576 * 1024)
        // capacity = RAM 16384 + swap used 512 + headroom (1536 swap free + 98304 disk)
        let capacity = StatusLine.combinedCapacityMiB(totalMiB: 16_384, swap: swap)
        t.check(abs(capacity - (16_384 + 512 + 1_536 + 98_304)) < 1e-9, "한도 = RAM + swap used + headroom")
        let used = StatusLine.combinedUsedMiB(totalMiB: 16_384, availableMiB: 3_000, swap: swap)
        t.check(abs(used - (13_384 + 512)) < 1e-9, "총 사용량 = RAM used + swap used")
        t.check(abs(capacity - used - (3_000 + 1_536 + 98_304)) < 1e-9, "invariant: 한도 - 사용량 = 가용 + 헤드룸")
        t.check(StatusLine.combinedCapacityMiB(totalMiB: 16_384, swap: nil) == 16_384, "no swap reading -> 한도 is RAM only")
    }
    t.run("swap.fraction-and-headroom") { t in
        let swap = SwapUsage(totalBytes: 2_048 * 1_048_576, usedBytes: 1_596 * 1_048_576, diskFreeBytes: 105 * 1_048_576 * 1024)
        t.check(abs(swap.usedFraction - 1_596.0 / 2_048.0) < 1e-12, "used fraction exact")
        t.check(SwapUsage(totalBytes: 0, usedBytes: 0, diskFreeBytes: 0).usedFraction == 0, "zero total is safe (no div by zero)")
        // headroom = swap free (452MB) + disk free (105GiB)
        let expected = Double(2_048 - 1_596) + 105 * 1024
        t.check(abs(swap.headroomMiB - expected) < 1e-9, "headroom = swapfree + diskfree")
    }
    t.run("swap.secondary-breach") { t in
        t.check(WatchdogEngine.isBreached(availableMiB: 400, thresholdMiB: 512, swapHeadroomMiB: nil), "primary trigger works without swap info")
        t.check(!WatchdogEngine.isBreached(availableMiB: 600, thresholdMiB: 512, swapHeadroomMiB: 500_000), "huge disk headroom, above threshold -> idle")
        t.check(!WatchdogEngine.isBreached(availableMiB: 600, thresholdMiB: 512, swapHeadroomMiB: 100_000), "swap 95% but disk can grow it -> idle (moving wall fixed)")
        t.check(WatchdogEngine.isBreached(availableMiB: 900, thresholdMiB: 512, swapHeadroomMiB: 4_000), "low headroom + degraded -> early fire")
        t.check(!WatchdogEngine.isBreached(availableMiB: 1_500, thresholdMiB: 512, swapHeadroomMiB: 4_000), "low headroom + comfortable -> idle (safe state)")
        t.check(WatchdogEngine.isBreached(availableMiB: 1_024, thresholdMiB: 512, swapHeadroomMiB: 8_192), "at floor and exactly 2x window -> fire")
        t.check(!WatchdogEngine.isBreached(availableMiB: 900, thresholdMiB: 512, swapHeadroomMiB: 8_192.1), "just above floor -> idle")
    }
    t.run("swap.custom-floor") { t in
        // The VM-headroom line is user-configurable (임계치 탭).
        t.check(!WatchdogEngine.isBreached(availableMiB: 900, thresholdMiB: 512, swapHeadroomMiB: 16_000),
                "16GB headroom vs default 8GB floor -> idle")
        t.check(WatchdogEngine.isBreached(availableMiB: 900, thresholdMiB: 512, swapHeadroomMiB: 16_000, swapFloorMiB: 32_768),
                "custom 32GB floor widens the early-fire zone")
        t.check(SettingsStore.sanitizeSwapFloor(500) == SettingsStore.defaultSwapFloorMiB, "floor below bound -> default")
        t.check(SettingsStore.sanitizeSwapFloor(24_000) == 24_000, "in-range floor persists")
    }
    t.run("swap.thrash-trigger") { t in
        // The AI-workload freeze: availability above the floor while a huge
        // working set pages out continuously. Capacity metrics look fine;
        // the sustained swap-write rate is the tell.
        t.check(WatchdogEngine.isBreached(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 500_000,
                                          swapoutMiBPerTick: 512, thrashSustainedTicks: 3),
                "sustained swap thrash fires despite ample RAM")
        t.check(!WatchdogEngine.isBreached(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 500_000,
                                           swapoutMiBPerTick: 512, thrashSustainedTicks: 2),
                "short burst -> idle (sustain window)")
        t.check(!WatchdogEngine.isBreached(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 500_000,
                                           swapoutMiBPerTick: 100, thrashSustainedTicks: 9),
                "under rate floor -> idle")
        t.check(!WatchdogEngine.isBreached(availableMiB: 6_000, thresholdMiB: 1_200, swapHeadroomMiB: 500_000),
                "no swap I/O reading -> idle")
    }

    // MARK: - Exclusion picker + persistence (humanized UI phase 2)
    t.run("picker.app-label") { t in
        t.check(ExclusionPicker.appLabel(fromPath: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari", "plain app binary")
        t.check(ExclusionPicker.appLabel(fromPath: "/Applications/Whale.app/Contents/Frameworks/Whale Helper (Renderer).app/Contents/MacOS/Whale Helper (Renderer)") == "Whale", "nested helper -> outermost app")
        t.check(ExclusionPicker.appLabel(fromPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper") == "Google Chrome", "spaced app name")
        t.check(ExclusionPicker.appLabel(fromPath: "/Users/dev/tools/bomb") == "bomb", "no bundle -> file name")
    }
    t.run("picker.aggregate") { t in
        let whale = ProcSnapshot(pid: 1, footprintKiB: 600_000, uid: 501, path: "/Applications/Whale.app/Contents/MacOS/Whale", name: "Whale")
        let whaleHelper = ProcSnapshot(pid: 2, footprintKiB: 400_000, uid: 501, path: "/Applications/Whale.app/Contents/Frameworks/Whale Helper (Renderer).app/Contents/MacOS/Whale Helper (Renderer)", name: "Whale Helper (R")
        let safari = ProcSnapshot(pid: 3, footprintKiB: 300_000, uid: 501, path: "/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari")
        let system = ProcSnapshot(pid: 4, footprintKiB: 900_000, uid: 501, path: "/usr/libexec/tccd", name: "tccd")
        let tiny = ProcSnapshot(pid: 5, footprintKiB: 100_000, uid: 501, path: "/Users/dev/app", name: "tiny")
        let apps = ExclusionPicker.pickable(
            from: [whale, whaleHelper, safari, system, tiny],
            ownPID: 100, ownUID: 501, ownBundlePath: "/Applications/RamGuard.app", exclusions: []
        )
        t.check(apps.map(\.label) == ["Whale", "Safari"], "system + sub-floor filtered, sorted by summed rss")
        t.check(apps[0].footprintKiBTotal == 1_000_000, "helper rss summed into its app")
        t.check(apps.allSatisfy { !$0.protected }, "nothing protected with empty exclusions")
    }
    t.run("picker.protected-flag") { t in
        let whale = ProcSnapshot(pid: 1, footprintKiB: 600_000, uid: 501, path: "/Applications/Whale.app/Contents/MacOS/Whale", name: "Whale")
        let apps = ExclusionPicker.pickable(from: [whale], ownPID: 100, ownUID: 501, ownBundlePath: nil, exclusions: ["whale"])
        t.check(apps.count == 1 && apps[0].protected, "substring exclusion marks the group protected")
    }
    t.run("exclusions.add-remove") { t in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramguard-selftest-\(UUID().uuidString)/exclusions.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "# my apps\nbomb\n".data(using: .utf8)!.write(to: url)
        let store = ExclusionsStore(url: url)
        t.check(store.entries == ["bomb"], "seeded file parsed")
        store.add("Safari")
        t.check(store.entries == ["bomb", "Safari"], "add appends in memory")
        store.add("safari")
        t.check(store.entries == ["bomb", "Safari"], "case-insensitive dedupe")
        let textAfterAdd = try! String(contentsOf: url, encoding: .utf8)
        t.check(textAfterAdd.contains("# my apps") && textAfterAdd.contains("Safari"), "add persists, comment kept")
        store.remove("BOMB")
        t.check(store.entries == ["Safari"], "remove is case-insensitive")
        t.check(ExclusionsStore(url: url).entries == ["Safari"], "remove persisted to file")
        let textAfterRemove = try! String(contentsOf: url, encoding: .utf8)
        t.check(textAfterRemove.contains("# my apps") && !textAfterRemove.contains("bomb"), "comment preserved, entry line gone")
    }

    t.finish()
}
