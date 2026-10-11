import Foundation

/// One aggregated row for the "지금 메모리 큰 앱" exclusion picker.
/// `label` doubles as the exclusion entry — an .app label (e.g. "Whale")
/// protects all of its helpers under the substring rule. `representativePath`
/// is one member's executable path, used by the UI to resolve the app icon.
struct PickableApp: Equatable {
    let label: String
    let footprintKiBTotal: UInt64
    let protected: Bool
    let representativePath: String
}

/// Pure selection/aggregation for the exclusion picker. No AppKit — fully
/// unit-testable. Mirrors the kill policy's fail-safe filters (same user,
/// resolvable path, non-system, non-self) so the picker only ever offers
/// processes the watchdog could actually act on.
enum ExclusionPicker {
    /// Below this a process is picker noise, not defense-relevant.
    static let minFootprintKiB: UInt64 = 200_000
    static let maxRows = 6

    /// Friendly app name: the outermost `.app` bundle component in path order
    /// ("Whale Helper (Renderer)" -> "Whale"); falls back to the file name.
    static func appLabel(fromPath path: String) -> String {
        for component in path.split(separator: "/") {
            if component.hasSuffix(".app") {
                return String(component.dropLast(4))
            }
        }
        return (path as NSString).lastPathComponent
    }

    /// Same-user, resolvable-path, non-system processes aggregated by app
    /// label (helpers sum into their app), largest total RSS first.
    /// `protected` mirrors the kill policy's exclusion rule for the group.
    static func pickable(
        from snapshots: [ProcSnapshot],
        ownPID: pid_t,
        ownUID: uid_t,
        ownBundlePath: String?,
        exclusions: [String]
    ) -> [PickableApp] {
        let config = KillPolicyConfig(ownPID: ownPID, ownBundlePath: ownBundlePath, ownUID: ownUID, exclusions: exclusions)
        var totals: [String: (rss: UInt64, protected: Bool, path: String)] = [:]
        for snap in snapshots {
            guard snap.uid == ownUID, let path = snap.path else { continue }
            guard snap.pid != ownPID else { continue }
            if let bundle = ownBundlePath, path == bundle || path.hasPrefix(bundle + "/") { continue }
            guard snap.name != KillPolicyConfig.kernelTaskName else { continue }
            guard !KillPolicyConfig.systemPathPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            guard snap.footprintKiB >= minFootprintKiB else { continue }
            let label = appLabel(fromPath: path)
            if var agg = totals[label] {
                agg.rss &+= snap.footprintKiB
                agg.protected = agg.protected || KillPolicy.reasonIfRejected(snap, config: config) == .excluded
                totals[label] = agg
            } else {
                totals[label] = (
                    snap.footprintKiB,
                    KillPolicy.reasonIfRejected(snap, config: config) == .excluded,
                    path
                )
            }
        }
        return totals
            .map { PickableApp(label: $0.key, footprintKiBTotal: $0.value.rss, protected: $0.value.protected, representativePath: $0.value.path) }
            .sorted { $0.footprintKiBTotal > $1.footprintKiBTotal }
            .prefix(maxRows)
            .map { $0 }
    }
}
