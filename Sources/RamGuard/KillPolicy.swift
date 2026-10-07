import Foundation

/// Kill-policy filter inputs. Everything here is contract-fixed.
struct KillPolicyConfig {
    /// RSS floor in KiB. Decimal 1,000,000 (baseline FLOOR_KB parity — intentional).
    static let rssFloorKiB: UInt64 = 1_000_000
    /// System path prefixes that are never candidates.
    static let systemPathPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/"]
    /// Kernel task name (excluded even without a path).
    static let kernelTaskName = "kernel_task"

    let ownPID: pid_t
    let ownBundlePath: String?
    let ownUID: uid_t
    let exclusions: [String]

    init(ownPID: pid_t, ownBundlePath: String?, ownUID: uid_t, exclusions: [String]) {
        self.ownPID = ownPID
        self.ownBundlePath = ownBundlePath
        self.ownUID = ownUID
        self.exclusions = exclusions
    }
}

/// Why a snapshot was rejected. Surfaced for logging/tests (AC-9 completeness).
enum KillRejection: Equatable {
    case differentUser
    case belowRssFloor
    case systemPath
    case kernelTask
    case selfProcess
    case excluded
    case pathUnresolvable
}

/// Pure victim-selection filter. No I/O — fully unit-testable.
struct KillPolicy {
    let config: KillPolicyConfig

    /// Returns the single largest-RSS eligible candidate, or nil when the
    /// candidate set is empty. `rejections` receives every rejection reason
    /// (highest-severity first per snapshot) for observability.
    func selectCandidate(from snapshots: [ProcSnapshot], rejections: ((ProcSnapshot, KillRejection) -> Void)? = nil) -> ProcSnapshot? {
        var best: ProcSnapshot?
        for snap in snapshots {
            switch Self.reasonIfRejected(snap, config: config) {
            case .none:
                if best == nil || snap.rssKiB > best!.rssKiB {
                    best = snap
                }
            case .some(let reason):
                rejections?(snap, reason)
            }
        }
        return best
    }

    static func reasonIfRejected(_ snap: ProcSnapshot, config: KillPolicyConfig) -> KillRejection? {
        // Fail-safe first: a snapshot whose path cannot be resolved is never a
        // candidate (we cannot prove it is not a system process).
        guard let path = snap.path else {
            return .pathUnresolvable
        }
        if snap.pid == config.ownPID {
            return .selfProcess
        }
        if let bundle = config.ownBundlePath, path == bundle || path.hasPrefix(bundle + "/") {
            return .selfProcess
        }
        if snap.uid != config.ownUID {
            return .differentUser
        }
        if snap.name == KillPolicyConfig.kernelTaskName {
            return .kernelTask
        }
        if KillPolicyConfig.systemPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .systemPath
        }
        // Exclusions: case-insensitive substring match on the executable name.
        let lowerName = snap.name.lowercased()
        for entry in config.exclusions {
            let lower = entry.lowercased()
            if !lower.isEmpty && lowerName.contains(lower) {
                return .excluded
            }
        }
        // NOTE: decimal-strict floor. 1,000,000 KiB is excluded, 1,000,001 passes.
        if snap.rssKiB <= KillPolicyConfig.rssFloorKiB {
            return .belowRssFloor
        }
        return nil
    }
}
