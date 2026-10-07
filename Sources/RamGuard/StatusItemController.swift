import AppKit

/// Menu-bar surface: 3-state icon (observe/armed/triggered) + dropdown menu.
/// All NSStatusItem/NSMenu mutations happen on the main actor (contract).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private var settings: SettingsStore
    private let history: HistoryStore

    private var availableMiB: Double = 0
    private var thresholdMiB: Double = SettingsStore.defaultThresholdMiB
    private var posture: WatchdogPosture = .observe
    private var triggered = false

    private let availMenuItem = NSMenuItem()
    private let postureMenuItem = NSMenuItem()
    private let thresholdHeaderItem = NSMenuItem()
    private let loginItemMenuItem = NSMenuItem()
    private let historySectionItems: [NSMenuItem] = (0..<10).map { _ in NSMenuItem() }

    init(settings: SettingsStore, history: HistoryStore) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.settings = settings
        self.history = history
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        availMenuItem.isEnabled = false
        menu.addItem(availMenuItem)
        menu.addItem(.separator())

        postureMenuItem.action = #selector(togglePosture)
        postureMenuItem.target = self
        menu.addItem(postureMenuItem)
        menu.addItem(.separator())

        thresholdHeaderItem.isEnabled = false
        menu.addItem(thresholdHeaderItem)
        for preset in [512.0, 800, 1200, 1600, 2048, 3072, 4096] {
            let m = NSMenuItem(title: "\(Int(preset)) MiB", action: #selector(setThreshold(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = preset
            m.indentationLevel = 1
            menu.addItem(m)
        }
        let up = NSMenuItem(title: "+100 MiB", action: #selector(stepThreshold(_:)), keyEquivalent: "+")
        up.target = self
        up.indentationLevel = 1
        up.representedObject = 100.0
        let down = NSMenuItem(title: "−100 MiB", action: #selector(stepThreshold(_:)), keyEquivalent: "-")
        down.target = self
        down.indentationLevel = 1
        down.representedObject = -100.0
        menu.addItem(up)
        menu.addItem(down)
        menu.addItem(.separator())

        let exclusions = NSMenuItem(title: "제외 목록 파일 열기", action: #selector(openExclusions), keyEquivalent: "")
        exclusions.target = self
        menu.addItem(exclusions)

        loginItemMenuItem.action = #selector(toggleLoginItem)
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)
        menu.addItem(.separator())

        for h in historySectionItems {
            h.isEnabled = false
            menu.addItem(h)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        refreshStaticItems()
        render()
    }

    // MARK: - Updates (called from the AppController event sink)

    func update(availableMiB: Double?, thresholdMiB: Double, posture: WatchdogPosture, triggered: Bool, wouldKill: ProcSnapshot? = nil) {
        if let available = availableMiB { self.availableMiB = available }
        self.thresholdMiB = thresholdMiB
        self.posture = posture
        self.triggered = triggered
        if let snap = wouldKill {
            Log.ui.notice("[observe] would kill \(snap.name, privacy: .public) pid=\(snap.pid)")
        }
        refreshStaticItems()
        render()
    }

    func refreshHistory() {
        refreshStaticItems()
        render()
    }

    // MARK: - Rendering

    private func render() {
        let button = item.button
        switch posture {
        case .observe:
            button?.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "observe")
            button?.contentTintColor = .secondaryLabelColor
        case .armed:
            if triggered {
                button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "defense fired")
                button?.contentTintColor = .systemRed
            } else {
                button?.image = NSImage(systemSymbolName: "shield.filled", accessibilityDescription: "armed")
                button?.contentTintColor = .systemGreen
            }
        }
        button?.toolTip = "RAM Guard — \(posture == .armed ? "armed" : "observe")"
    }

    private func refreshStaticItems() {
        availMenuItem.title = String(format: "가용 RAM: %.0f MiB (임계 %.0f)", availableMiB, thresholdMiB)
        postureMenuItem.title = posture == .observe ? "Armed로 전환 (실제 킬)" : "Observe로 전환 (기록만)"
        thresholdHeaderItem.title = thresholdHeaderText()
        refreshThresholdStates()
        refreshLoginItemTitle()
        refreshHistoryItems()
    }

    private func thresholdHeaderText() -> String {
        // Show available next to the control + warn on a high threshold
        // (no hard clamp — contract).
        let base = "임계(가용 \(Int(availableMiB)) MiB)"
        if thresholdMiB > availableMiB + 512 {
            return base + " ⚠️ 임계가 가용보다 큼 — 방어가 곧바로 발동됩니다"
        }
        return base
    }

    private func refreshThresholdStates() {
        guard let menu = item.menu else { return }
        for m in menu.items where m.action == #selector(setThreshold(_:)) {
            let value = m.representedObject as? Double ?? 0
            m.state = abs(value - settings.thresholdMiB) < 0.5 ? .on : .off
        }
    }

    private func refreshLoginItemTitle() {
        switch LoginItemManager.status {
        case .enabled:
            loginItemMenuItem.title = "로그인 시 자동 시작: 켜짐"
            loginItemMenuItem.state = .on
        case .requiresApproval:
            loginItemMenuItem.title = "로그인 시 자동 시작: 승인 필요 (시스템 설정)"
            loginItemMenuItem.state = .mixed
        case .notRegistered, .notFound:
            loginItemMenuItem.title = "로그인 시 자동 시작: 꺼짐"
            loginItemMenuItem.state = .off
        @unknown default:
            loginItemMenuItem.title = "로그인 시 자동 시작: 알 수 없음"
            loginItemMenuItem.state = .off
        }
    }

    private func refreshHistoryItems() {
        let events = history.snapshot().prefix(historySectionItems.count)
        for (index, menuItem) in historySectionItems.enumerated() {
            if index < events.count {
                let e = events[index]
                menuItem.isHidden = false
                menuItem.title = Self.format(e)
            } else {
                menuItem.isHidden = true
            }
        }
    }

    static func format(_ e: HistoryEvent) -> String {
        let time = e.timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let rss = e.rssKiB.map { String(format: "%.1f GB", Double($0) / 1_048_576) } ?? "-"
        let name = e.name ?? "-"
        return "\(formatter.string(from: time)) [\(e.kind.rawValue)] \(name) \(rss)"
    }

    // MARK: - Actions

    @objc private func togglePosture() {
        settings.posture = settings.posture == .observe ? .armed : .observe
        let posture = settings.posture
        Log.policy.notice("posture -> \(posture.rawValue, privacy: .public)")
        refreshStaticItems()
        render()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        settings.thresholdMiB = value
        Log.policy.notice("threshold -> \(Int(value)) MiB (effective next tick)")
        refreshStaticItems()
    }

    @objc private func stepThreshold(_ sender: NSMenuItem) {
        guard let delta = sender.representedObject as? Double else { return }
        settings.thresholdMiB = settings.thresholdMiB + delta
        let threshold = settings.thresholdMiB
        Log.policy.notice("threshold -> \(Int(threshold)) MiB (effective next tick)")
        refreshStaticItems()
    }

    @objc private func openExclusions() {
        NSWorkspace.shared.open(ExclusionsStore.defaultPath)
    }

    @objc private func toggleLoginItem() {
        do {
            switch LoginItemManager.status {
            case .enabled:
                try LoginItemManager.unregister()
            default:
                try LoginItemManager.register()
            }
        } catch {
            Log.ui.error("login item toggle failed: \(String(describing: error), privacy: .public)")
        }
        refreshLoginItemTitle()
    }

    // MARK: - NSMenuDelegate (rebuild dynamic items when the menu opens)

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.refreshStaticItems()
        }
    }
}
