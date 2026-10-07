import Darwin

/// One process snapshot. Snapshots are consumed immediately and never stored
/// beyond the current tick (low-footprint contract).
struct ProcSnapshot: Equatable {
    let pid: pid_t
    /// Resident size in KiB (`resident_size / 1024`, decimal-strict floor rule below).
    let rssKiB: UInt64
    let uid: uid_t
    /// Executable path; nil when unresolvable (fail-safe: never a kill candidate).
    let path: String?
    /// Process name from pbi_comm.
    let name: String

    /// Baseline parity: `ps -o rss` reports KiB, so KiB = resident_size / 1024
    /// (integer division). The >1,000,000 KiB floor matches the validated
    /// script's decimal FLOOR_KB=1000000 intentionally (documented decision).
    static func rssKiB(fromResidentBytes bytes: UInt64) -> UInt64 {
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

        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize) == taskSize else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(Self.pathBufferSize))
        let path: String? = pathLen > 0 ? String(cString: pathBuffer) : nil

        let name = withUnsafeBytes(of: bsdInfo.pbi_comm) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }

        return ProcSnapshot(
            pid: pid,
            rssKiB: ProcSnapshot.rssKiB(fromResidentBytes: UInt64(taskInfo.pti_resident_size)),
            uid: bsdInfo.pbi_uid,
            path: path,
            name: name
        )
    }
}
