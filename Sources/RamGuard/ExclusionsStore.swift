import Foundation

/// Exclusion (protection) list: `~/.config/ramguard/exclusions.txt`.
/// One process-name per line, `#` comments, case-insensitive substring match.
/// Loaded once at app start; the menu picker mutates the in-memory list via
/// `add`/`remove` (the engine's policyProvider re-reads `entries` each tick,
/// so changes take effect within one poll) and persists them to the file,
/// preserving comments. Hand edits to the file still need an app restart.
final class ExclusionsStore {
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

    /// Adds an entry (case-insensitive dedupe) and appends it to the file.
    func add(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !entries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        entries.append(trimmed)
        appendLineToFile(trimmed)
    }

    /// Removes case-insensitively equal entries and rewrites the file,
    /// keeping comments and blank lines.
    func remove(_ entry: String) {
        entries.removeAll { $0.caseInsensitiveCompare(entry) == .orderedSame }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            line.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(entry) != .orderedSame
        }
        text = kept.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func appendLineToFile(_ line: String) {
        let data = Data("\n\(line)".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
