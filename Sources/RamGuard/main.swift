import Darwin
import Foundation
import ServiceManagement

// Default = run the menu-bar app. Diagnostics subcommands stay available:
//   RamGuard once | top [N] | selftest | watch [seconds]

func printUsage() {
    print("""
    RamGuard
    USAGE:
      (no args)                    run the menu-bar app
      ramguard once                print one memory reading (vm_stat parity check)
      ramguard top [N]             print the N largest-RSS same-user processes
      ramguard selftest            run the built-in unit suite (M1 gate)
      ramguard watch [seconds]     run the observe-only engine for N seconds (default 30)
    """)
}

func ownBundlePath() -> String? {
    Bundle.main.bundleIdentifier != nil ? Bundle.main.bundlePath : CommandLine.arguments.first
}

var arguments = CommandLine.arguments
let subcommand = arguments.count > 1 ? arguments[1] : "app"
if subcommand != "app" {
    arguments.removeFirst() // keep diagnostics argument positions stable
}

switch subcommand {
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
    let limit = Int(arguments.count > 1 ? arguments[1] : "10") ?? 10
    let table = ProcessTable.live()
    let uid = getuid()
    let procs = table.snapshotAll()
        .filter { $0.uid == uid && $0.path != nil }
        .sorted { $0.rssKiB > $1.rssKiB }
        .prefix(limit)
    print("PID      RSS_KiB    NAME")
    for p in procs {
        let pid = String(p.pid).padding(toLength: 9, withPad: " ", startingAt: 0)
        let rss = String(p.rssKiB).padding(toLength: 11, withPad: " ", startingAt: 0)
        print("\(pid)\(rss)\(p.name)")
    }
case "watch":
    let seconds = Double(arguments.count > 1 ? arguments[1] : "30") ?? 30
    let settings = SettingsStore()
    let history = HistoryStore()
    let ownPID = getpid()
    let ownBundle = ownBundlePath()
    let ownUID = getuid()
    let exclusions = ExclusionsStore()
    let engine = WatchdogEngine(
        dependencies: .live(),
        history: history,
        policyProvider: {
            KillPolicy(config: KillPolicyConfig(
                ownPID: ownPID,
                ownBundlePath: ownBundle,
                ownUID: ownUID,
                exclusions: exclusions.entries
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
case "loginitem":
    let sub = arguments.count > 1 ? arguments[1] : "status"
    switch sub {
    case "status":
        print("SMAppService.mainApp status: \(LoginItemManager.status.rawValue)")
        print("running from app bundle: \(LoginItemManager.isRunningFromAppBundle)")
    case "register":
        do { try LoginItemManager.register(); print("registered: \(LoginItemManager.status.rawValue)") }
        catch { print("register failed: \(error)"); exit(1) }
    case "unregister":
        do { try LoginItemManager.unregister(); print("unregistered: \(LoginItemManager.status.rawValue)") }
        catch { print("unregister failed: \(error)"); exit(1) }
    default:
        print("usage: ramguard loginitem [status|register|unregister]")
    }
case "app":
    MainActor.assumeIsolated {
        runApp()
    }
default:
    printUsage()
    exit(64)
}
