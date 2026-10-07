// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RamGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RamGuard",
            path: "Sources/RamGuard",
            swiftSettings: [.unsafeFlags([])]
        ),
    ]
)
