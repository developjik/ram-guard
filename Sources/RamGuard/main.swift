import Darwin
import Foundation

// M1 diagnostic entrypoint. The G002 milestone replaces this with the
// menu-bar app bootstrap; until then RamGuard runs observe-only diagnostics.

func printUsage() {
    print("""
    RamGuard diagnostics (M1)
    USAGE:
      ramguard once                print one memory reading (vm_stat parity check)
      ramguard top [N]             print the N largest-RSS same-user processes
      ramguard watch [seconds]     run the observe-only engine for N seconds (default 30)
    """)
}

func ownBundlePath() -> String? {
    Bundle.main.bundleIdentifier != nil ? Bundle.main.bundlePath : CommandLine.arguments.first
}

let arguments = CommandLine.arguments

switch arguments.dropFirst().first ?? "watch" {
case "once":
    do {
        let m = try MemoryPressure.read()
        print(String(format: "available=%.1f MiB (free=%llu speculative=%llu pageSize=%zu)",
                     m.availableMiB, m.freePages, m.speculativePages, vm_page_size))
    } catch {
        FileHandle.standardError.write("memory read failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
case "selftest":
    runSelfTest()
case "top":
    let limit = Int(arguments.count > 2 ? arguments[2] : "10") ?? 10
    let table = ProcessTable.live()
    let uid = getuid()
    let procs = table.snapshotAll()
        .filter { $0.uid == uid && $0.path != nil }
        .sorted { $0.rssKiB > $1.rssKiB }
        .prefix(limit)
        for p in procs {
            let pid = String(p.pid).padding(toLength: 9, withPad: " ", startingAt: 0)
            let rss = String(p.rssKiB).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("\(pid)\(rss)\(p.name)")
        }
case "watch":
    let seconds = Double(arguments.count > 2 ? arguments[2] : "30") ?? 30
    let settings = SettingsStore()
    let history = HistoryStore()
    let engine = WatchdogEngine(
        dependencies: .live(),
        history: history,
        policyProvider: {
            KillPolicy(config: KillPolicyConfig(
                ownPID: getpid(),
                ownBundlePath: ownBundlePath(),
                ownUID: getuid(),
                exclusions: ExclusionsStore().entries
            ))
        },
        postureProvider: { .observe },
        thresholdProvider: { settings.thresholdMiB }
    )
    engine.onEvent = { event in
        switch event {
        case .tick(let available, let threshold):
            print(String(format: "[tick] available=%.1f MiB (threshold=%.0f)", available, threshold))
        case .wouldKill(let snap):
            print(String(format: "[observe] WOULD KILL %@ pid=%d rss=%lluKiB", snap.name, snap.pid, snap.rssKiB))
        case .killed(let snap):
            print(String(format: "[armed] KILLED %@ pid=%d rss=%lluKiB", snap.name, snap.pid, snap.rssKiB))
        case .killFailed(let pid, let name, let kr):
            print(String(format: "[armed] kill failed %@ pid=%d kr=%d", name, pid, kr))
        case .cooldownSuppressed(let snap, let remaining):
            print(String(format: "[armed] cooldown suppressed %@ (%.0fs remaining)", snap.name, remaining))
        case .noCandidate(let available):
            print(String(format: "[tick] threshold breached (%.1f MiB) — no eligible candidate", available))
        case .readFailed(let message):
            print("[error] \(message)")
        }
    }
    engine.start()
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    print("history events: \(history.count)")
default:
    printUsage()
}
