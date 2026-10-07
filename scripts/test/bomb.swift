import Foundation

// Memory bomb for T-AC verification: allocates and touches N GiB, reports
// its own RSS, then sleeps. Kill it explicitly when the test ends.
let gb = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "4") ?? 4
let totalBytes = Int(gb * 1_073_741_182)
let chunkSize = 16 * 1024 * 1024
var chunks: [UnsafeMutableRawPointer] = []
var allocated = 0
while allocated + chunkSize <= totalBytes {
    guard let p = malloc(chunkSize) else { break }
    memset(p, 0xAB, chunkSize)
    chunks.append(p)
    allocated += chunkSize
}
print("bomb allocated=\(allocated / 1_048_576)MiB pid=\(getpid())")
fflush(stdout)
// Hot mode: keep re-dirtying so the kernel cannot compress us below our
// footprint (cold bombs lose the max-RSS contest to any hot process).
var counter: Int32 = 0
while true {
    for (i, p) in chunks.enumerated() {
        memset(p, counter &+ Int32(i & 0xFF), chunkSize)
    }
    counter &+= 1
    Thread.sleep(forTimeInterval: 0.1)
}
