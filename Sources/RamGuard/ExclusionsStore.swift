import Foundation

/// Exclusion (protection) list: `~/.config/ramguard/exclusions.txt`.
/// One process-name per line, `#` comments, case-insensitive substring match.
/// Loaded once at app start (restart-to-apply contract). Missing file is
/// created from a template.
struct ExclusionsStore {
    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ramguard/exclusions.txt")

    static let template = """
    # RAM Guard exclusions — one process name per line.
    # A process is protected when its name CONTAINS the entry (case-insensitive).
    # Example:
    # Cursor
    # Apply changes and restart RAM Guard for them to take effect.
    """

    let url: URL
    private(set) var entries: [String]

    init(url: URL = ExclusionsStore.defaultPath) {
        self.url = url
        self.entries = Self.load(url: url)
    }

    /// Loads the file, creating it from the template when absent.
    /// Unreadable/undecodable file yields an empty list (fail-safe: no
    /// exclusions — but the watchdog still applies all hardcoded guards).
    static func load(url: URL) -> [String] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.data(using: .utf8)?.write(to: url, options: .atomic)
            return []
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parse(text: text)
    }

    /// Pure parser (unit-tested): trims lines, drops empties and `#` comments.
    static func parse(text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
