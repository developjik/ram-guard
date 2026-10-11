import AppKit

/// Menu-bar surface (v2): shield icon + compact available-memory text, and a
/// custom popover panel instead of the v1 NSMenu. All NSStatusItem/NSPopover
/// mutations happen on the main actor (contract).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let settings: SettingsStore
    private let history: HistoryStore
    /// Shared with the engine's policyProvider (class semantics) — panel
    /// toggles take effect on the next tick without a restart.
    private let exclusions: ExclusionsStore
    private let panel: PopoverPanelController
    private let popover = NSPopover()
    /// Transient popovers close on an outside click — including the very
    /// status-item click that toggles. Remember when we closed to swallow the
    /// immediate re-open.
    private var lastClosedAt: Date?

    private var availableMiB: Double = 0
    private var thresholdMiB: Double = SettingsStore.defaultThresholdMiB
    private var posture: WatchdogPosture = .observe
    private var triggered = false
    private var lastSwap: SwapUsage?
    /// Swap-write volume of the last tick; non-trivial values mean the
    /// system is spilling to disk right now.
    private var lastSwapoutRate: Double?
    /// The engine's live breach decision (all three triggers) — the UI band
    /// mirrors it so a combined-headroom or thrash breach shows red.
    private var lastBreached = false
    /// Most recent would-kill/kill target, for naming it in the status line.
    /// Cleared once pressure returns to the normal band (stale-event guard).
    private var lastEventName: String?
    private var lastEventWasKill = false
    /// Available-memory samples, one per engine tick (~10 s), oldest first.
    /// Feeds the hero card's sparkline; 60 samples ≈ 10 minutes of trend.
    private var availabilityHistory: [Double] = []
    private static let historySampleLimit = 60

    private static let totalRamMiB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576

    /// Wired by AppController — opens the onboarding window.
    var showWelcome: (() -> Void)?
    /// Wired by AppController — opens the full-history window.
    var showHistory: (() -> Void)?

    init(settings: SettingsStore, history: HistoryStore, exclusions: ExclusionsStore) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.settings = settings
        self.history = history
        self.exclusions = exclusions
        self.panel = PopoverPanelController(settings: settings, history: history, exclusions: exclusions)
        super.init()

        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self

        panel.onPostureChanged = { [weak self] in self?.render() }
        panel.onThresholdChanged = { [weak self] in self?.render() }
        panel.onExclusionsChanged = { [weak self] in self?.render() }
        panel.showWelcome = { [weak self] in self?.showWelcome?() }
        panel.showHistory = { [weak self] in self?.showHistory?() }

        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        render()
    }

    // MARK: - Updates (called from the AppController event sink)

    func update(availableMiB: Double?, thresholdMiB: Double, posture: WatchdogPosture, triggered: Bool, wouldKill: ProcSnapshot? = nil, killed: ProcSnapshot? = nil, swap: SwapUsage? = nil, swapoutMiBPerTick: Double? = nil, breached: Bool = false) {
        if let available = availableMiB {
            self.availableMiB = available
            availabilityHistory.append(available)
            if availabilityHistory.count > Self.historySampleLimit {
                availabilityHistory.removeFirst(availabilityHistory.count - Self.historySampleLimit)
            }
        }
        self.thresholdMiB = thresholdMiB
        self.posture = posture
        self.triggered = triggered
        self.lastSwap = swap
        if let rate = swapoutMiBPerTick { lastSwapoutRate = rate }
        self.lastBreached = breached
        if let snap = wouldKill {
            lastEventName = snap.name
            lastEventWasKill = false
            Log.ui.notice("[observe] would kill \(snap.name, privacy: .public) pid=\(snap.pid)")
        }
        if let snap = killed {
            lastEventName = snap.name
            lastEventWasKill = true
        }
        // Stale-event guard: once pressure is comfortably clear, drop the
        // remembered event so a future breach never cites an old victim.
        if let available = availableMiB,
           StatusLine.band(availableMiB: available, thresholdMiB: thresholdMiB,
                           swapHeadroomMiB: lastSwap?.headroomMiB, engineBreached: lastBreached,
                           swapFloorMiB: settings.swapHeadroomFloorMiB) == .normal {
            lastEventName = nil
            lastEventWasKill = false
        }
        applyToPanel()
        render()
    }

    func refreshHistory() {
        applyToPanel()
        render()
    }

    private func applyToPanel() {
        panel.apply(state: PopoverPanelController.PanelState(
            availableMiB: availableMiB,
            thresholdMiB: thresholdMiB,
            posture: posture,
            triggered: triggered,
            lastEventName: lastEventName,
            lastEventWasKill: lastEventWasKill,
            swap: lastSwap,
            swapoutMiBPerTick: lastSwapoutRate,
            breached: lastBreached,
            history: availabilityHistory
        ))
    }

    // MARK: - Menu bar rendering

    private func render() {
        let button = item.button
        let tint: NSColor?
        switch posture {
        case .observe:
            button?.image = Self.symbol("shield")
            tint = nil
        case .armed:
            if triggered {
                button?.image = Self.symbol("shield.lefthalf.filled")
                tint = .systemRed
            } else {
                button?.image = Self.symbol("shield.fill")
                tint = .systemGreen
            }
        }
        button?.contentTintColor = tint

        // Compact available-memory readout next to the icon (iStat/Stats
        // convention). Native label color normally; band colors on warning.
        if availableMiB > 0 {
            let band = StatusLine.band(availableMiB: availableMiB, thresholdMiB: thresholdMiB,
                                       swapHeadroomMiB: lastSwap?.headroomMiB, engineBreached: lastBreached,
                                       swapFloorMiB: settings.swapHeadroomFloorMiB)
            let color: NSColor
            if triggered || band == .breached {
                color = .systemRed
            } else if band == .approaching {
                color = .systemYellow
            } else {
                color = .labelColor
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            // Combined usage (RAM used + swap used) — the pool the user thinks
            // in; danger coloring still follows the engine band.
            let used = max(Self.totalRamMiB - availableMiB, 0) + (lastSwap?.usedMiB ?? 0)
            let text = " " + StatusLine.formatMemoryCompact(used)
            button?.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
        } else {
            button?.attributedTitle = NSAttributedString(string: "")
        }
        var tooltip = "RAM Guard — \(posture == .armed ? "방어" : "관찰") · 클릭해서 상태 보기"
        if availableMiB > 0 {
            let used = max(Self.totalRamMiB - availableMiB, 0) + (lastSwap?.usedMiB ?? 0)
            let capacity = StatusLine.combinedCapacityMiB(totalMiB: Self.totalRamMiB, swap: lastSwap)
            tooltip += "\n총 사용량 \(StatusLine.formatMemoryCompact(used)) / 한도 \(StatusLine.formatMemoryCompact(capacity))"
            tooltip += "\nRAM 가용 \(StatusLine.formatMemory(availableMiB))"
            if let remaining = StatusLine.totalAvailableMiB(availableMiB: availableMiB, swap: lastSwap) {
                tooltip += " · 남음 \(StatusLine.formatMemory(remaining))"
            }
        }
        if let rate = lastSwapoutRate, rate >= StatusLine.swapIONoteFloorMiB {
            tooltip += "\n스왑 I/O \(StatusLine.formatMemory(rate))/10초 ⚠️"
        }
        button?.toolTip = tooltip
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: nil)
    }

    // MARK: - Popover toggling

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let lastClosedAt, Date().timeIntervalSince(lastClosedAt) < 0.2 {
            return
        }
        panel.prepareForOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.lastClosedAt = Date()
        }
    }
}
