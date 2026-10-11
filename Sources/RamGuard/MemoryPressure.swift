import Darwin
import Foundation

/// Swap usage from the `vm.swapusage` sysctl, plus the disk headroom that
/// actually backs it. macOS swapfiles grow dynamically into free storage —
/// `xsu_total` is the currently allocated size, NOT the limit — so the true
/// spill-valve capacity is (swap free + disk free). The engine's secondary
/// trigger reads headroom, not the moving allocated wall.
struct SwapUsage: Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    /// Free space of the volume backing swap (same APFS container as /).
    let diskFreeBytes: UInt64

    /// 0 when no swap is configured (guards a division by zero).
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    var usedMiB: Double { Double(usedBytes) / 1_048_576 }
    var totalMiB: Double { Double(totalBytes) / 1_048_576 }

    /// Remaining spill capacity: unallocated swapfile space + storage that
    /// can still back new swapfiles.
    var headroomMiB: Double {
        let swapFree = totalBytes > usedBytes ? Double(totalBytes - usedBytes) : 0
        return (swapFree + Double(diskFreeBytes)) / 1_048_576
    }
}

/// Available system memory, computed exactly like the validated baseline script
/// (`vm_stat` free + speculative pages), via `host_statistics64`.
struct MemoryPressure {
    /// Available memory in MiB (free + speculative).
    let availableMiB: Double

    /// Raw page counts kept for verification/diagnostics.
    let freePages: UInt64
    let speculativePages: UInt64

    /// Swap snapshot; nil when the sysctl read fails (fail-open — swap is a
    /// secondary signal and must never break the primary measurement).
    var swap: SwapUsage? = nil

    /// Cumulative anonymous pages written to swap since boot, in MiB
    /// (`vm_statistics64.swapouts` × page size). Diffs between ticks give
    /// the swap-write rate — the direct thrash signal that availability
    /// numbers miss (a huge working set can page out continuously while
    /// free+speculative stays above the floor).
    var swapoutMiB: Double = 0

    enum ReadError: Error, Equatable {
        case hostStatisticsFailed(kr: kern_return_t)
    }

    static func read(pageSize: UInt64 = UInt64(vm_page_size)) throws -> MemoryPressure {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw ReadError.hostStatisticsFailed(kr: kr)
        }
        return MemoryPressure(
            availableMiB: Self.pagesToMiB(free: UInt64(vmStats.free_count), speculative: UInt64(vmStats.speculative_count), pageSize: pageSize),
            freePages: UInt64(vmStats.free_count),
            speculativePages: UInt64(vmStats.speculative_count),
            swap: readSwapUsage(),
            swapoutMiB: Double(vmStats.swapouts) * Double(pageSize) / 1_048_576
        )
    }

    /// Pure conversion (unit-tested): pages -> MiB.
    ///
    /// The baseline script computes `(free + speculative) * 16384 / 1048576` MiB.
    /// Page size is injected so tests can pin the math.
    static func pagesToMiB(free: UInt64, speculative: UInt64, pageSize: UInt64) -> Double {
        let pages = free &+ speculative
        let bytes = pages.multipliedReportingOverflow(by: pageSize)
        precondition(!bytes.overflow, "page byte count overflow")
        return Double(bytes.partialValue) / 1_048_576.0
    }

    static func readSwapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return nil }
        // Swapfiles live under /System/Volumes/VM, same APFS container as /
        // (System volume is sealed; free space is container-wide).
        let diskFree = (try? FileManager.default.attributesOfFileSystem(forPath: "/"))?[.systemFreeSize] as? UInt64 ?? 0
        return SwapUsage(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used, diskFreeBytes: diskFree)
    }
}
