import AppKit

/// Full session history in a scrollable window (v3): a vertical timeline —
/// colored dots on a continuous rail, humanized message left, time right —
/// under a header that carries the session count as a pill. The panel caps
/// at 3 rows; the ring buffer holds 200.
@MainActor
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let store: HistoryStore
    /// Internal so the uitour diagnostic can snapshot the content view.
    var window: NSWindow?
    private var tableView: NSTableView?
    private var emptyStateView: NSView?
    private var countPillLabel: NSTextField?
    private var footerCountLabel: NSTextField?
    private var events: [HistoryEvent] = []

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("HistoryRow")

    init(store: HistoryStore) {
        self.store = store
    }

    func show() {
        let win: NSWindow
        if let window {
            win = window
        } else {
            win = buildWindow()
            window = win
            win.center()
        }
        // Order front first: refresh() skips invisible windows, so loading
        // data before the window is visible would leave the first open blank.
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    /// Reloads from the store; safe to call on every engine event (no-ops
    /// while the window is closed).
    func refresh() {
        guard let tableView, let window, window.isVisible else { return }
        events = store.snapshot()
        tableView.reloadData()
        emptyStateView?.isHidden = !events.isEmpty
        tableView.isHidden = events.isEmpty
        countPillLabel?.stringValue = "세션 \(events.count)건"
        footerCountLabel?.stringValue = "이 세션 동안 \(events.count)건 기록"
    }

    private func buildWindow() -> NSWindow {
        let table = NSTableView()
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("event")))
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 40
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Header: title + session-count pill.
        let headerTitle = DesignSystem.makeLabel("방어 이력", size: 15, weight: .bold)
        let countPill = NSView()
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 9
        countPill.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
        countPill.translatesAutoresizingMaskIntoConstraints = false
        let pillLabel = NSTextField(labelWithString: "세션 0건")
        pillLabel.font = DesignSystem.Font.mono(10.5, .medium)
        pillLabel.textColor = .secondaryLabelColor
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        countPill.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 9),
            pillLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -9),
            pillLabel.topAnchor.constraint(equalTo: countPill.topAnchor, constant: 3),
            pillLabel.bottomAnchor.constraint(equalTo: countPill.bottomAnchor, constant: -3),
        ])
        let headerRow = NSStackView(views: [headerTitle, spacer(), countPill])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Empty state: a calm explanation instead of a bare table.
        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(
            systemSymbolName: "shield",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = DesignSystem.makeLabel("아직 기록이 없어요", size: 15, weight: .semibold)
        let emptyDetail = NSTextField(wrappingLabelWithString: "메모리 압박 상황이 오면 방어 기록이 이 타임라인에 쌓여요. 조용하다는 건 지금 맥이 건강하다는 뜻이에요.")
        emptyDetail.font = DesignSystem.Font.label(12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        let empty = NSStackView(views: [emptyIcon, emptyTitle, emptyDetail])
        empty.orientation = .vertical
        empty.spacing = 8
        empty.setCustomSpacing(10, after: emptyTitle)
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true

        let footerCount = NSTextField(labelWithString: "이 세션 동안 0건 기록")
        footerCount.font = DesignSystem.Font.label(11)
        footerCount.textColor = .tertiaryLabelColor
        footerCount.translatesAutoresizingMaskIntoConstraints = false
        let footerHint = NSTextField(labelWithString: "기록은 앱을 끄면 사라져요")
        footerHint.font = DesignSystem.Font.label(11)
        footerHint.textColor = .tertiaryLabelColor
        footerHint.alignment = .right
        footerHint.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RAM Guard — 방어 이력 (세션)"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(headerRow)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(empty)
        window.contentView?.addSubview(footerCount)
        window.contentView?.addSubview(footerHint)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14),
            headerRow.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footerCount.topAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),

            empty.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            footerCount.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            footerCount.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -10),

            footerHint.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            footerHint.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -10),
        ])
        tableView = table
        emptyStateView = empty
        countPillLabel = pillLabel
        footerCountLabel = footerCount
        return window
    }

    private func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        events.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = events[row]
        let cell: HistoryRowView
        if let reused = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? HistoryRowView {
            cell = reused
        } else {
            cell = HistoryRowView()
            cell.identifier = Self.rowIdentifier
        }
        let parts = StatusLine.historyParts(event)
        cell.configure(
            dotColor: DesignSystem.eventColor(event.kind),
            message: parts.message,
            time: parts.time,
            prominent: event.kind == .kill
        )
        return cell
    }
}

/// One timeline row: a continuous rail on the left, a colored status dot on
/// it, the humanized message, and the right-aligned time. Kill rows render
/// their message semibold so real interventions stand out when scanning.
@MainActor
private final class HistoryRowView: NSView {
    private let rail = NSView()
    private let dot = NSView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 40))
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.borderWidth = 1.5
        dot.layer?.borderColor = NSColor.textBackgroundColor.withAlphaComponent(0.8).cgColor
        messageLabel.font = DesignSystem.Font.label(12)
        messageLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = DesignSystem.Font.mono(11)
        timeLabel.textColor = .secondaryLabelColor
        addSubview(rail)
        addSubview(dot)
        addSubview(messageLabel)
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    func configure(dotColor: NSColor, message: String, time: String, prominent: Bool) {
        dot.layer?.backgroundColor = dotColor.cgColor
        messageLabel.stringValue = message
        messageLabel.font = DesignSystem.Font.label(12, prominent ? .semibold : .regular)
        timeLabel.stringValue = time
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        rail.frame = NSRect(x: 21, y: 0, width: 1.5, height: h)
        dot.frame = NSRect(x: 17.5, y: (h - 9) / 2, width: 9, height: 9)
        let timeSize = timeLabel.intrinsicContentSize
        timeLabel.frame = NSRect(
            x: bounds.width - timeSize.width - 18,
            y: (h - timeSize.height) / 2,
            width: timeSize.width,
            height: timeSize.height
        )
        messageLabel.frame = NSRect(
            x: 38,
            y: (h - 17) / 2,
            width: timeLabel.frame.minX - 12 - 38,
            height: 17
        )
    }
}
