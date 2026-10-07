import os

/// Structured logging categories per the plan (watchdog/kill/policy/ui).
enum Log {
    static let watchdog = Logger(subsystem: subsystem, category: "watchdog")
    static let kill = Logger(subsystem: subsystem, category: "kill")
    static let policy = Logger(subsystem: subsystem, category: "policy")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    private static let subsystem = "dev.ramguard.RamGuard"
}
