import Foundation

// Innocent sleeper for T-AC3: touches 1.5 GiB and idles. It must NEVER be
// chain-killed while cooldown is active — that is exactly what T-AC3 proves.
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
print("sleeper allocated=\(allocated / 1_048_576)MiB pid=\(getpid())")
fflush(stdout)
Thread.sleep(forTimeInterval: 600)
