import Darwin

/// One process snapshot. Snapshots are consumed immediately and never stored
/// beyond the current tick (low-footprint contract).
struct ProcSnapshot: Equatable {
    let pid: pid_t
    /// Memory footprint in KiB (`phys_footprint / 1024`): resident + compressed
    /// (+ IOKit) pages the process is accountable for — Activity Monitor's
    /// "Memory" column. Unlike raw RSS this does NOT shrink when the kernel
    /// compresses pages, so a big-but-cold process cannot escape the floor.
    let footprintKiB: UInt64
    let uid: uid_t
    /// Executable path; nil when unresolvable (fail-safe: never a kill candidate).
    let path: String?
    /// Process name from pbi_comm.
    let name: String

    static func footprintKiB(fromBytes bytes: UInt64) -> UInt64 {
        bytes / 1024
    }
}

/// Enumerates the process table via public libproc APIs. Read-only.
struct ProcessTable {
    /// proc_pidpath buffer size (PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN).
    static let pathBufferSize = 4096

    var snapshotAll: () -> [ProcSnapshot]

    /// Live implementation. `ownPID` is passed through for convenience of callers;
    /// candidate filtering happens in `KillPolicy`.
    static func live() -> ProcessTable {
        return ProcessTable(snapshotAll: {
            let needed = proc_listallpids(nil, 0)
            guard needed > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(needed))
            let written = proc_listallpids(&pids, Int32(needed))
            guard written > 0 else { return [] }

            var result: [ProcSnapshot] = []
            result.reserveCapacity(Int(written))
            for pid in pids[0..<Int(written)] where pid > 0 {
                if let snap = Self.snapshot(for: pid) {
                    result.append(snap)
                }
            }
            return result
        })
    }

    static func snapshot(for pid: pid_t) -> ProcSnapshot? {
        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize else { return nil }

        // Footprint comes from proc_pid_rusage — this CLT SDK's proc_taskinfo
        // predates the pti_phys_footprint field, and rusage carries it in
        // every flavor. Same public syscall family, per-pid, no task port.
        var rusage = rusage_info_current()
        let rusageResult = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard rusageResult == 0 else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(Self.pathBufferSize))
        let path: String? = pathLen > 0 ? String(cString: pathBuffer) : nil

        let name = withUnsafeBytes(of: bsdInfo.pbi_comm) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }

        return ProcSnapshot(
            pid: pid,
            footprintKiB: ProcSnapshot.footprintKiB(fromBytes: rusage.ri_phys_footprint),
            uid: bsdInfo.pbi_uid,
            path: path,
            name: name
        )
    }
}
