import Foundation

// Hot sleeper for T-AC3: allocates 1.5 GiB and KEEPS TOUCHING it so the
// kernel cannot compress/swap it below the 1 GiB RSS floor. The cold-sleeper
// variant proved that idle memory gets compressed out of candidacy; this
// variant proves the cooldown actually shields a live >1GiB innocent process.
let totalBytes = Int(1.5 * 1_073_741_182)
let chunkSize = 16 * 1024 * 1024
var chunks: [UnsafeMutableRawPointer] = []
var allocated = 0
while allocated + chunkSize <= totalBytes {
    guard let p = malloc(chunkSize) else { break }
    memset(p, 0xCD, chunkSize)
    chunks.append(p)
    allocated += chunkSize
}
print("hot-sleeper allocated=\(allocated / 1_048_576)MiB pid=\(getpid())")
fflush(stdout)

// Re-dirty every chunk forever so pages stay resident (not compressible).
var counter: Int32 = 0
while true {
    for (i, p) in chunks.enumerated() {
        memset(p, counter &+ Int32(i & 0xFF), chunkSize)
    }
    counter &+= 1
    Thread.sleep(forTimeInterval: 0.1)
}
