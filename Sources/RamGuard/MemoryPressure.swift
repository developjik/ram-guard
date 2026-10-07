import Darwin

/// Available system memory, computed exactly like the validated baseline script
/// (`vm_stat` free + speculative pages), via `host_statistics64`.
struct MemoryPressure {
    /// Available memory in MiB (free + speculative).
    let availableMiB: Double

    /// Raw page counts kept for verification/diagnostics.
    let freePages: UInt64
    let speculativePages: UInt64

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
            speculativePages: UInt64(vmStats.speculative_count)
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
}
