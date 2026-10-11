import AppKit

// MARK: - Protected-app row

/// One protected-app row: app icon on a neutral chip, name, memory footprint,
/// and a switch mirroring the exclusion ("체크 = 보호") rule. Highlights on
/// hover. Fixed 26 pt height so the pane fits six rows.
@MainActor
final class AppRowView: NSView {
    private let iconChip = DesignSystem.iconChip(size: 20)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let memLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private(set) var currentApp: PickableApp?

    /// Fired with the switch's new value; the owner maps it to exclusions.
    var onToggle: ((Bool, PickableApp) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.row

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = DesignSystem.Font.label(11.5, .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        memLabel.font = DesignSystem.Font.mono(10.5)
        memLabel.textColor = .secondaryLabelColor
        memLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .mini
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(toggleChanged)

        addSubview(iconChip)
        iconChip.addSubview(iconView)
        addSubview(nameLabel)
        addSubview(memLabel)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            nameLabel.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            memLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            memLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: memLabel.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = DesignSystem.Palette.rowHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    func update(app: PickableApp) {
        currentApp = app
        let icon = NSWorkspace.shared.icon(forFile: app.representativePath)
        icon.size = NSSize(width: 13, height: 13)
        iconView.image = icon
        nameLabel.stringValue = app.label
        memLabel.stringValue = StatusLine.formatMemory(Double(app.footprintKiBTotal) / 1024)
        toggle.state = app.protected ? .on : .off
    }

    @objc private func toggleChanged() {
        guard let app = currentApp else { return }
        onToggle?(toggle.state == .on, app)
    }
}

// MARK: - Stat tile

/// One compact stat in the hero card: caption, monospaced value, and an
/// optional hairline bar (the swap tile uses it to show spill usage).
@MainActor
final class StatTileView: NSView {
    private let captionLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let barTrack = NSView()
    private let barFill = CALayer()
    private var barFraction: CGFloat = 0

    init(caption: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 90, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.tile
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.45).cgColor

        captionLabel.font = DesignSystem.Font.label(9.5, .semibold)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = DesignSystem.Font.mono(12.5, .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        barTrack.wantsLayer = true
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.layer?.cornerRadius = 2
        barTrack.layer?.backgroundColor = DesignSystem.Palette.trackFill.cgColor
        barFill.cornerRadius = 2
        barTrack.layer?.addSublayer(barFill)

        addSubview(captionLabel)
        addSubview(valueLabel)
        addSubview(barTrack)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            valueLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            barTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            barTrack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            barTrack.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 5),
            barTrack.heightAnchor.constraint(equalToConstant: 4),
        ])
        captionLabel.stringValue = caption
        hideBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    func update(value: String, valueColor: NSColor = .labelColor) {
        valueLabel.stringValue = value
        valueLabel.textColor = valueColor
    }

    func showBar(fraction: CGFloat, color: NSColor) {
        barTrack.isHidden = false
        barFill.backgroundColor = color.cgColor
        barFraction = min(max(fraction, 0), 1)
        layoutBar()
    }

    func hideBar() {
        barTrack.isHidden = true
    }

    override func layout() {
        super.layout()
        layoutBar()
    }

    private func layoutBar() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        barFill.frame = NSRect(x: 0, y: 0, width: barTrack.bounds.width * barFraction, height: barTrack.bounds.height)
        CATransaction.commit()
    }
}

// MARK: - Hero summary card

/// The panel's hero card: ring gauge (combined used fraction + VM 임계
/// notch), the big combined-usage number in the band color, the humanized
/// status sentence, the 10-minute sparkline, and four stat tiles
/// (사용 · 스왑 · 총 가용 · 한도).
final class MemorySummaryCardView: NSView {
    private let ring = RingGaugeView(diameter: 56, lineWidth: 6.5)
    private let valueLabel = NSTextField(labelWithString: "—")
    private let unitLabel = NSTextField(labelWithString: "총 사용량")
    private let sentenceLabel = NSTextField(wrappingLabelWithString: "")
    private let trendCaption = NSTextField(labelWithString: "추이 · 최근 10분")
    private let sparkline = SparklineView()
    private let usedTile = StatTileView(caption: "사용")
    private let swapTile = StatTileView(caption: "스왑")
    private let totalTile = StatTileView(caption: "총 가용")
    private let capacityTile = StatTileView(caption: "한도")
    private let tintLayer = CAGradientLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        DesignSystem.styleCard(self)

        valueLabel.font = DesignSystem.Font.rounded(25, .bold)
        unitLabel.font = DesignSystem.Font.label(10)
        unitLabel.textColor = .secondaryLabelColor
        sentenceLabel.font = DesignSystem.Font.label(10.5)
        sentenceLabel.textColor = .secondaryLabelColor
        sentenceLabel.maximumNumberOfLines = 2
        sentenceLabel.translatesAutoresizingMaskIntoConstraints = false
        trendCaption.font = DesignSystem.Font.label(9.5, .semibold)
        trendCaption.textColor = .tertiaryLabelColor
        trendCaption.translatesAutoresizingMaskIntoConstraints = false

        let valueRow = NSStackView(views: [valueLabel, unitLabel])
        valueRow.orientation = .horizontal
        valueRow.alignment = .lastBaseline
        valueRow.spacing = 6
        valueRow.translatesAutoresizingMaskIntoConstraints = false

        let tilesRow = NSStackView(views: [usedTile, swapTile, totalTile, capacityTile])
        tilesRow.orientation = .horizontal
        tilesRow.distribution = .fillEqually
        tilesRow.spacing = 8
        tilesRow.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        tintLayer.startPoint = CGPoint(x: 0.5, y: 0)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(tintLayer)

        addSubview(ring)
        addSubview(valueRow)
        addSubview(sentenceLabel)
        addSubview(trendCaption)
        addSubview(sparkline)
        addSubview(tilesRow)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            valueRow.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 14),
            valueRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            // Raised a touch so a two-line warning sentence (with the swap
            // note) still clears the ring's bottom edge.
            valueRow.centerYAnchor.constraint(equalTo: ring.centerYAnchor, constant: -10),

            sentenceLabel.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 14),
            sentenceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sentenceLabel.topAnchor.constraint(equalTo: valueRow.bottomAnchor, constant: 3),
            sentenceLabel.bottomAnchor.constraint(lessThanOrEqualTo: ring.bottomAnchor, constant: 0),

            trendCaption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            trendCaption.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 10),

            sparkline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sparkline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sparkline.topAnchor.constraint(equalTo: trendCaption.bottomAnchor, constant: 3),

            tilesRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tilesRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tilesRow.topAnchor.constraint(equalTo: sparkline.bottomAnchor, constant: 10),
            tilesRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            usedTile.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DesignSystem.refreshCardChrome(self)
    }

    func update(
        availableMiB: Double,
        thresholdMiB: Double,
        totalMiB: Double,
        band: StatusLine.Band,
        posture: WatchdogPosture,
        triggered: Bool,
        lastEventName: String?,
        lastEventWasKill: Bool,
        swap: SwapUsage?,
        swapoutMiBPerTick: Double?,
        breached: Bool,
        swapFloorMiB: Double,
        history: [Double]
    ) {
        let tint = DesignSystem.bandColor(band)

        // Combined physical+swap pool. The ring, the big number and the
        // 사용/한도 tiles all run on this pool (한도 = installed RAM +
        // allocated swapfiles + storage that can still back new ones); the
        // band color still carries the engine's danger signal.
        let capacity = max(StatusLine.combinedCapacityMiB(totalMiB: totalMiB, swap: swap), 1)
        let combinedUsed = StatusLine.combinedUsedMiB(totalMiB: totalMiB, availableMiB: availableMiB, swap: swap)
        let usedFraction = min(max(combinedUsed / capacity, 0), 1)
        // Notch = the combined danger line: crossing it means the remaining
        // pool (총 가용) has fallen under the VM 여유 임계.
        let notchFraction = min(max((capacity - swapFloorMiB) / capacity, 0), 1)
        ring.update(
            usedFraction: usedFraction,
            thresholdUsedFraction: notchFraction,
            color: tint,
            animated: true,
            centerText: "\(Int((usedFraction * 100).rounded()))%"
        )

        valueLabel.stringValue = StatusLine.formatMemory(combinedUsed)
        valueLabel.textColor = tint
        unitLabel.stringValue = "총 사용량 · 한도 \(StatusLine.formatMemoryCompact(capacity))"
        sentenceLabel.stringValue = StatusLine.line(
            availableMiB: availableMiB,
            thresholdMiB: thresholdMiB,
            totalMiB: totalMiB,
            posture: posture,
            triggered: triggered,
            lastEventName: lastEventName,
            lastEventWasKill: lastEventWasKill,
            swapHeadroomMiB: swap?.headroomMiB,
            swapoutMiBPerTick: swapoutMiBPerTick,
            swapFloorMiB: swapFloorMiB
        )
        tintLayer.colors = [
            tint.withAlphaComponent(0.10).cgColor,
            tint.withAlphaComponent(0.0).cgColor,
        ]
        sparkline.tintColor = tint
        sparkline.update(samples: history, thresholdMiB: thresholdMiB)

        let usedPercent = Int((usedFraction * 100).rounded())
        usedTile.update(value: "\(usedPercent)%")
        if let swap = swap, swap.totalBytes > 0 {
            swapTile.update(value: StatusLine.formatMemory(swap.usedMiB))
            let capacityMiB = swap.usedMiB + swap.headroomMiB
            let fillFraction = capacityMiB > 0 ? swap.usedMiB / capacityMiB : 0
            // Orange = spilling; red = actively thrashing (sustained swap
            // writes at the trigger rate).
            let thrashing = (swapoutMiBPerTick ?? 0) >= WatchdogEngine.thrashRateMiBPerTick
            swapTile.showBar(fraction: fillFraction, color: thrashing ? .systemRed : .systemOrange)
        } else {
            swapTile.update(value: "—", valueColor: .tertiaryLabelColor)
            swapTile.hideBar()
        }
        // 총 가용 = RAM available + storage-backed VM headroom. Display-only
        // figure; turns orange while the spill valve (the disk) is running
        // short — that's the combined pool running low.
        if let swap = swap {
            let shallowValve = swap.headroomMiB <= swapFloorMiB
            if let total = StatusLine.totalAvailableMiB(availableMiB: availableMiB, swap: swap) {
                totalTile.update(value: StatusLine.formatMemory(total),
                                 valueColor: shallowValve ? .systemOrange : .labelColor)
            } else {
                totalTile.update(value: "—", valueColor: .tertiaryLabelColor)
            }
        } else {
            totalTile.update(value: "—", valueColor: .tertiaryLabelColor)
        }
        capacityTile.update(value: StatusLine.formatMemory(capacity))
    }
}

// MARK: - Panel controller

/// The v3 popover — a fixed-height surface instead of a scrolling stack:
/// header (posture capsule), hero ring card, then a three-tab pane
/// (보호 앱 / 임계치 / 기록) and a footer. Same external contract as the
/// v2 panel: StatusItemController feeds `PanelState`, and the callbacks
/// route posture/threshold/exclusion changes back to the app.
@MainActor
final class PopoverPanelController: NSViewController {
    static let panelWidth: CGFloat = 360

    // Wired by StatusItemController.
    var onPostureChanged: (() -> Void)?
    var onThresholdChanged: (() -> Void)?
    var onExclusionsChanged: (() -> Void)?
    var showWelcome: (() -> Void)?
    var showHistory: (() -> Void)?

    private var settings: SettingsStore
    private let exclusions: ExclusionsStore
    private let history: HistoryStore

    private var availableMiB: Double = 0
    private var thresholdMiB: Double = SettingsStore.defaultThresholdMiB
    private var posture: WatchdogPosture = .observe

    // Header
    private let postureToggle = CapsuleSegmentedControl(labels: ["관찰", "방어"])
    private let postureHint = NSTextField(wrappingLabelWithString: "")

    // Hero
    private let summaryCard = MemorySummaryCardView()

    // Tabs
    private let tabCapsule = CapsuleSegmentedControl(
        labels: ["보호 앱", "임계치", "기록"],
        symbols: ["memorychip", "slider.horizontal.3", "clock.arrow.circlepath"],
        height: 28
    )
    private let tabContainer = NSView()
    private var panes: [NSView] = []

    // Apps pane
    private var appRows: [AppRowView] = (0..<ExclusionPicker.maxRows).map { _ in AppRowView() }
    private let appsEmptyLabel = NSTextField(labelWithString: "지금은 눈에 띄는 큰 앱이 없어요")
    private let openExclusionsButton = NSButton(title: "제외 파일 열기", target: nil, action: nil)

    // Threshold pane
    private let thresholdSlider = NSSlider(value: SettingsStore.defaultThresholdMiB, minValue: 512, maxValue: 4096, target: nil, action: nil)
    private let thresholdValueLabel = NSTextField(labelWithString: "")
    private var thresholdChips: [(button: NSButton, value: Double)] = []
    private var floorChips: [(button: NSButton, value: Double)] = []
    private let swapFloorCaption = NSTextField(labelWithString: "")
    private let thresholdNote = NSTextField(wrappingLabelWithString: "")

    // History pane
    private var historyRows: [(dot: NSView, message: NSTextField, time: NSTextField, card: NSView)] = []
    private let historyEmptyLabel = NSTextField(labelWithString: "아직 방어 기록이 없어요 — 조용한 게 좋은 신호예요.")
    private let historyOpenButton = NSButton(title: "전체 이력 보기", target: nil, action: nil)

    // Footer
    private let loginSwitch = NSSwitch()
    private let loginLabel = NSTextField(labelWithString: "로그인 시 자동 시작")
    private let usageButton = NSButton(title: "사용법", target: nil, action: nil)
    private let quitButton = NSButton(title: "종료", target: nil, action: nil)

    init(settings: SettingsStore, history: HistoryStore, exclusions: ExclusionsStore) {
        self.settings = settings
        self.history = history
        self.exclusions = exclusions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    private static let contentPadding: CGFloat = 14

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 540))
        // Layer-backed root: the whole tree rasterizes into layers, which the
        // uitour diagnostic relies on for offscreen QA snapshots.
        view.wantsLayer = true
        let contentWidth = Self.panelWidth - Self.contentPadding * 2

        // --- Header -----------------------------------------------------
        let shieldChip = DesignSystem.iconChip(size: 24)
        let shieldImage = NSImage(
            systemSymbolName: "shield.lefthalf.filled",
            accessibilityDescription: "RAM Guard"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        let shieldView = NSImageView()
        shieldView.image = shieldImage
        shieldView.contentTintColor = .controlAccentColor
        shieldView.translatesAutoresizingMaskIntoConstraints = false
        shieldChip.addSubview(shieldView)
        NSLayoutConstraint.activate([
            shieldView.centerXAnchor.constraint(equalTo: shieldChip.centerXAnchor),
            shieldView.centerYAnchor.constraint(equalTo: shieldChip.centerYAnchor),
        ])

        let titleLabel = DesignSystem.makeLabel("RAM Guard", size: 14, weight: .bold)
        let headerRow = NSStackView(views: [shieldChip, titleLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        postureToggle.widthAnchor.constraint(equalToConstant: 128).isActive = true
        postureToggle.selectedFill = { index in
            index == 1 ? NSColor.systemGreen : NSColor.quaternaryLabelColor.withAlphaComponent(0.9)
        }
        postureToggle.selectedText = { index in
            index == 1 ? .white : .labelColor
        }
        postureToggle.onSelect = { [weak self] index in
            self?.postureSelected(index == 1 ? .armed : .observe)
        }

        postureHint.font = DesignSystem.Font.label(10.5)
        postureHint.textColor = .secondaryLabelColor
        postureHint.translatesAutoresizingMaskIntoConstraints = false

        // --- Tab bar + panes ---------------------------------------------
        tabCapsule.onSelect = { [weak self] index in self?.showTab(index) }
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.heightAnchor.constraint(equalToConstant: 204).isActive = true

        buildAppsPane(width: contentWidth)
        buildThresholdPane(width: contentWidth)
        buildHistoryPane(width: contentWidth)
        panes = [appsPane, thresholdPane, historyPane]
        tabContainer.addSubview(appsPane)
        tabContainer.addSubview(thresholdPane)
        tabContainer.addSubview(historyPane)
        for pane in panes {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: tabContainer.topAnchor),
                pane.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            ])
        }

        // --- Footer ------------------------------------------------------
        loginSwitch.controlSize = .mini
        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged)
        loginLabel.font = DesignSystem.Font.label(11.5)
        for button in [usageButton, quitButton] {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.font = DesignSystem.Font.label(11.5)
        }
        usageButton.target = self
        usageButton.action = #selector(openWelcomeWindow)
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        let footerRow = NSStackView(views: [loginSwitch, loginLabel, spacer(), usageButton, quitButton])
        footerRow.orientation = .horizontal
        footerRow.spacing = 6
        footerRow.alignment = .centerY
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        // --- Vertical chain ----------------------------------------------
        let hairline = DesignSystem.hairline()
        view.addSubview(headerRow)
        view.addSubview(postureToggle)
        view.addSubview(postureHint)
        view.addSubview(summaryCard)
        view.addSubview(tabCapsule)
        view.addSubview(tabContainer)
        view.addSubview(hairline)
        view.addSubview(footerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            headerRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),

            postureToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            postureToggle.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            postureHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            postureHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            postureHint.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 7),

            summaryCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            summaryCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            summaryCard.topAnchor.constraint(equalTo: postureHint.bottomAnchor, constant: 10),

            tabCapsule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            tabCapsule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            tabCapsule.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 10),

            tabContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            tabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            tabContainer.topAnchor.constraint(equalTo: tabCapsule.bottomAnchor, constant: 9),

            hairline.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            hairline.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            hairline.topAnchor.constraint(equalTo: tabContainer.bottomAnchor, constant: 9),

            footerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentPadding),
            footerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentPadding),
            footerRow.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 7),
            footerRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -11),
        ])

        refreshPostureHint()
        refreshThresholdUI()
        refreshLoginUI()
        refreshHistoryRows()
        showTab(0, animated: false)
    }

    private func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    // MARK: - Panes

    private var appsPane = NSView()
    private var thresholdPane = NSView()
    private var historyPane = NSView()

    private func buildAppsPane(width contentWidth: CGFloat) {
        appsPane.translatesAutoresizingMaskIntoConstraints = false
        let rowsStack = NSStackView(views: appRows)
        rowsStack.orientation = .vertical
        rowsStack.spacing = 4
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        appsEmptyLabel.font = DesignSystem.Font.label(11)
        appsEmptyLabel.textColor = .tertiaryLabelColor
        appsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        openExclusionsButton.isBordered = false
        openExclusionsButton.font = DesignSystem.Font.label(10)
        openExclusionsButton.contentTintColor = .tertiaryLabelColor
        openExclusionsButton.target = self
        openExclusionsButton.action = #selector(openExclusionsFile)
        openExclusionsButton.translatesAutoresizingMaskIntoConstraints = false

        appsPane.addSubview(rowsStack)
        appsPane.addSubview(appsEmptyLabel)
        appsPane.addSubview(openExclusionsButton)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: appsPane.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: appsPane.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: appsPane.topAnchor),
            rowsStack.widthAnchor.constraint(equalToConstant: contentWidth),
            appsEmptyLabel.centerXAnchor.constraint(equalTo: appsPane.centerXAnchor),
            appsEmptyLabel.centerYAnchor.constraint(equalTo: appsPane.centerYAnchor, constant: -6),
            openExclusionsButton.trailingAnchor.constraint(equalTo: appsPane.trailingAnchor),
            openExclusionsButton.bottomAnchor.constraint(equalTo: appsPane.bottomAnchor),
        ])
    }

    private func buildThresholdPane(width contentWidth: CGFloat) {
        thresholdPane.translatesAutoresizingMaskIntoConstraints = false

        thresholdSlider.isContinuous = true
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        thresholdSlider.target = self
        thresholdSlider.action = #selector(thresholdSliderChanged)
        thresholdSlider.numberOfTickMarks = 0
        // Physical kill line caps at a quarter of installed RAM (16GB → 4GB,
        // 32GB → 8GB) — beyond that the machine is not "running out"; the
        // VM-headroom line below is the right lever for tighter defense.
        let ramMiB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        thresholdSlider.maxValue = max(4096, (ramMiB / 4 / 64).rounded() * 64)
        thresholdSlider.font = DesignSystem.Font.mono(10)
        thresholdValueLabel.font = DesignSystem.Font.mono(12, .semibold)
        thresholdValueLabel.textColor = .labelColor
        thresholdValueLabel.alignment = .right

        for (index, preset) in [512.0, 1200, 2048, 4096].enumerated() {
            let label = StatusLine.formatMemory(preset)
                .replacingOccurrences(of: "GB", with: "G")
                .replacingOccurrences(of: "MB", with: "M")
            let chip = NSButton(title: label, target: self, action: #selector(chipClicked(_:)))
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 9
            chip.font = DesignSystem.Font.mono(10.5)
            chip.tag = index
            thresholdChips.append((chip, preset))
        }
        let chipsRow = NSStackView(views: thresholdChips.map(\.button))
        chipsRow.orientation = .horizontal
        chipsRow.distribution = .fillEqually
        chipsRow.spacing = 6
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // Combined-pool line: swap free + disk free below this escalates the
        // band (🟡) and arms the secondary trigger (🔴 once RAM degrades too).
        swapFloorCaption.stringValue = "가상메모리 여유 임계 (스왑 + 디스크)"
        swapFloorCaption.font = DesignSystem.Font.label(9.5, .semibold)
        swapFloorCaption.textColor = .tertiaryLabelColor
        swapFloorCaption.translatesAutoresizingMaskIntoConstraints = false
        for value in [4096.0, 8192.0, 16384.0, 32768.0] {
            let label = StatusLine.formatMemory(value)
                .replacingOccurrences(of: "GB", with: "G")
                .replacingOccurrences(of: "MB", with: "M")
            let chip = NSButton(title: label, target: self, action: #selector(floorChipClicked(_:)))
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 9
            chip.font = DesignSystem.Font.mono(10.5)
            floorChips.append((chip, value))
        }
        let floorChipsRow = NSStackView(views: floorChips.map(\.button))
        floorChipsRow.orientation = .horizontal
        floorChipsRow.distribution = .fillEqually
        floorChipsRow.spacing = 6
        floorChipsRow.translatesAutoresizingMaskIntoConstraints = false

        thresholdNote.font = DesignSystem.Font.label(10)
        thresholdNote.textColor = .tertiaryLabelColor
        thresholdNote.translatesAutoresizingMaskIntoConstraints = false

        let valueRow = NSStackView(views: [spacer(), thresholdValueLabel])
        valueRow.orientation = .horizontal
        valueRow.alignment = .centerY
        valueRow.translatesAutoresizingMaskIntoConstraints = false

        thresholdPane.addSubview(thresholdSlider)
        thresholdPane.addSubview(chipsRow)
        thresholdPane.addSubview(swapFloorCaption)
        thresholdPane.addSubview(floorChipsRow)
        thresholdPane.addSubview(valueRow)
        thresholdPane.addSubview(thresholdNote)
        NSLayoutConstraint.activate([
            valueRow.topAnchor.constraint(equalTo: thresholdPane.topAnchor),
            valueRow.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            valueRow.trailingAnchor.constraint(equalTo: thresholdPane.trailingAnchor),

            thresholdSlider.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            thresholdSlider.trailingAnchor.constraint(equalTo: thresholdPane.trailingAnchor),
            thresholdSlider.topAnchor.constraint(equalTo: valueRow.bottomAnchor, constant: 4),

            chipsRow.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            chipsRow.trailingAnchor.constraint(equalTo: thresholdPane.trailingAnchor),
            chipsRow.topAnchor.constraint(equalTo: thresholdSlider.bottomAnchor, constant: 10),
            chipsRow.heightAnchor.constraint(equalToConstant: 22),

            swapFloorCaption.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            swapFloorCaption.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: 10),

            floorChipsRow.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            floorChipsRow.trailingAnchor.constraint(equalTo: thresholdPane.trailingAnchor),
            floorChipsRow.topAnchor.constraint(equalTo: swapFloorCaption.bottomAnchor, constant: 4),
            floorChipsRow.heightAnchor.constraint(equalToConstant: 22),

            thresholdNote.leadingAnchor.constraint(equalTo: thresholdPane.leadingAnchor),
            thresholdNote.trailingAnchor.constraint(equalTo: thresholdPane.trailingAnchor),
            thresholdNote.topAnchor.constraint(equalTo: floorChipsRow.bottomAnchor, constant: 10),
        ])
    }

    private func buildHistoryPane(width contentWidth: CGFloat) {
        historyPane.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = DesignSystem.Radius.row
            card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.4).cgColor
            card.translatesAutoresizingMaskIntoConstraints = false
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            let message = NSTextField(labelWithString: "")
            message.font = DesignSystem.Font.label(11)
            message.lineBreakMode = .byTruncatingTail
            message.translatesAutoresizingMaskIntoConstraints = false
            let time = NSTextField(labelWithString: "")
            time.font = DesignSystem.Font.mono(10)
            time.textColor = .secondaryLabelColor
            time.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(dot)
            card.addSubview(message)
            card.addSubview(time)
            NSLayoutConstraint.activate([
                card.heightAnchor.constraint(equalToConstant: 30),
                dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                message.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
                message.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                time.leadingAnchor.constraint(equalTo: message.trailingAnchor, constant: 8),
                time.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                time.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                message.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),
            ])
            historyRows.append((dot, message, time, card))
            historyPane.addSubview(card)
        }

        historyEmptyLabel.font = DesignSystem.Font.label(11)
        historyEmptyLabel.textColor = .tertiaryLabelColor
        historyEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        historyEmptyLabel.maximumNumberOfLines = 2

        historyOpenButton.isBordered = false
        historyOpenButton.font = DesignSystem.Font.label(10.5, .medium)
        historyOpenButton.contentTintColor = .controlAccentColor
        historyOpenButton.target = self
        historyOpenButton.action = #selector(openHistoryWindow)
        historyOpenButton.translatesAutoresizingMaskIntoConstraints = false

        historyPane.addSubview(historyEmptyLabel)
        historyPane.addSubview(historyOpenButton)

        NSLayoutConstraint.activate([
            historyRows[0].card.topAnchor.constraint(equalTo: historyPane.topAnchor),
            historyRows[1].card.topAnchor.constraint(equalTo: historyRows[0].card.bottomAnchor, constant: 6),
            historyRows[2].card.topAnchor.constraint(equalTo: historyRows[1].card.bottomAnchor, constant: 6),
            historyRows[2].card.leadingAnchor.constraint(equalTo: historyPane.leadingAnchor),
            historyRows[0].card.leadingAnchor.constraint(equalTo: historyPane.leadingAnchor),
            historyRows[1].card.leadingAnchor.constraint(equalTo: historyPane.leadingAnchor),
            historyRows[2].card.trailingAnchor.constraint(equalTo: historyPane.trailingAnchor),
            historyRows[0].card.trailingAnchor.constraint(equalTo: historyPane.trailingAnchor),
            historyRows[1].card.trailingAnchor.constraint(equalTo: historyPane.trailingAnchor),

            historyEmptyLabel.centerXAnchor.constraint(equalTo: historyPane.centerXAnchor),
            historyEmptyLabel.centerYAnchor.constraint(equalTo: historyPane.centerYAnchor, constant: -10),
            historyEmptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            historyOpenButton.trailingAnchor.constraint(equalTo: historyPane.trailingAnchor),
            historyOpenButton.bottomAnchor.constraint(equalTo: historyPane.bottomAnchor),
        ])
    }

    /// Switches the pane below the tab capsule. Internal so the `uitour`
    /// diagnostic can render every pane for QA captures.
    func showTab(_ index: Int, animated: Bool = true) {
        for (paneIndex, pane) in panes.enumerated() {
            let visible = paneIndex == index
            pane.isHidden = !visible
            // Sync the layer flag directly: a pane that is never re-displayed
            // after an isHidden change would keep rendering in layer snapshots.
            pane.layer?.isHidden = !visible
        }
        tabCapsule.select(index, animated: animated)
        if animated {
            tabContainer.alphaValue = 0.4
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                tabContainer.animator().alphaValue = 1
            }
        }
    }

    // MARK: - State application (called by StatusItemController)

    struct PanelState {
        var availableMiB: Double?
        var thresholdMiB: Double
        var posture: WatchdogPosture
        var triggered: Bool
        var lastEventName: String?
        var lastEventWasKill: Bool
        var swap: SwapUsage?
        var swapoutMiBPerTick: Double?
        var breached: Bool = false
        var history: [Double] = []
    }

    func apply(state: PanelState) {
        if let available = state.availableMiB { availableMiB = available }
        thresholdMiB = state.thresholdMiB
        posture = state.posture
        summaryCard.update(
            availableMiB: availableMiB,
            thresholdMiB: thresholdMiB,
            totalMiB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            band: StatusLine.band(availableMiB: availableMiB, thresholdMiB: thresholdMiB,
                                  swapHeadroomMiB: state.swap?.headroomMiB, engineBreached: state.breached,
                                  swapFloorMiB: settings.swapHeadroomFloorMiB),
            posture: posture,
            triggered: state.triggered,
            lastEventName: state.lastEventName,
            lastEventWasKill: state.lastEventWasKill,
            swap: state.swap,
            swapoutMiBPerTick: state.swapoutMiBPerTick,
            breached: state.breached,
            swapFloorMiB: settings.swapHeadroomFloorMiB,
            history: state.history
        )
        postureToggle.select(posture == .armed ? 1 : 0, animated: false)
        refreshPostureHint()
        refreshThresholdUI()
        refreshHistoryRows()
    }

    /// Process scan — run when the popover opens and after toggles, not every
    /// tick (the engine already polls the table on breach).
    func refreshApps() {
        let apps = ExclusionPicker.pickable(
            from: ProcessTable.live().snapshotAll(),
            ownPID: getpid(),
            ownUID: getuid(),
            ownBundlePath: Bundle.main.bundleIdentifier != nil ? Bundle.main.bundlePath : nil,
            exclusions: exclusions.entries
        )
        appsEmptyLabel.isHidden = !apps.isEmpty
        for (index, row) in appRows.enumerated() {
            if index < apps.count {
                row.isHidden = false
                row.update(app: apps[index])
                row.onToggle = { [weak self] on, app in
                    self?.setExclusion(app.label, protected: on)
                }
            } else {
                row.isHidden = true
            }
        }
        syncPreferredContentSize()
    }

    private func setExclusion(_ entry: String, protected: Bool) {
        if protected {
            exclusions.add(entry)
            Log.policy.notice("exclusion added -> \(entry, privacy: .public)")
        } else {
            exclusions.remove(entry)
            Log.policy.notice("exclusion removed -> \(entry, privacy: .public)")
        }
        onExclusionsChanged?()
        refreshApps()
    }

    private func refreshPostureHint() {
        postureHint.stringValue = posture == .observe
            ? "관찰 모드 — 아직 어떤 앱도 종료하지 않고 기록만 해요."
            : "방어 모드 — 메모리가 바닥나면 가장 큰 앱을 종료해 맥을 지켜요."
    }

    private func refreshThresholdUI() {
        thresholdSlider.doubleValue = thresholdMiB
        thresholdValueLabel.stringValue = StatusLine.formatMemory(thresholdMiB)
        let warning = availableMiB > 0 && thresholdMiB > availableMiB + 512
        thresholdNote.textColor = warning ? NSColor.systemOrange : .tertiaryLabelColor
        thresholdNote.stringValue = warning
            ? "⚠️ 지금 가용보다 높아요 — 방어가 곧 발동해요."
            : "변경은 다음 틱(최대 10초)에 적용되고 저장돼요."
        for (chip, value) in thresholdChips {
            let isCurrent = abs(value - thresholdMiB) < 0.5
            chip.layer?.backgroundColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
            chip.attributedTitle = NSAttributedString(
                string: chip.title,
                attributes: [
                    .font: DesignSystem.Font.mono(10.5, isCurrent ? .semibold : .regular),
                    .foregroundColor: isCurrent ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ]
            )
        }
        for (chip, value) in floorChips {
            let isCurrent = abs(value - settings.swapHeadroomFloorMiB) < 0.5
            chip.layer?.backgroundColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
            chip.attributedTitle = NSAttributedString(
                string: chip.title,
                attributes: [
                    .font: DesignSystem.Font.mono(10.5, isCurrent ? .semibold : .regular),
                    .foregroundColor: isCurrent ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ]
            )
        }
    }

    private func refreshHistoryRows() {
        let events = history.snapshot()
        let hasEvents = !events.isEmpty
        historyEmptyLabel.isHidden = hasEvents
        historyOpenButton.isHidden = !hasEvents
        for (index, row) in historyRows.enumerated() {
            if index < events.count {
                let event = events[index]
                row.card.isHidden = false
                row.dot.layer?.backgroundColor = DesignSystem.eventColor(event.kind).cgColor
                row.message.stringValue = StatusLine.historyParts(event).message
                row.time.stringValue = StatusLine.historyParts(event).time
            } else {
                row.card.isHidden = true
            }
        }
    }

    private func refreshLoginUI() {
        switch LoginItemManager.status {
        case .enabled:
            loginSwitch.state = .on
            loginLabel.stringValue = "로그인 시 자동 시작"
        case .requiresApproval:
            loginSwitch.state = .on
            loginLabel.stringValue = "로그인 시작 (승인 필요)"
        case .notRegistered, .notFound:
            loginSwitch.state = .off
            loginLabel.stringValue = "로그인 시 자동 시작"
        @unknown default:
            loginSwitch.state = .off
            loginLabel.stringValue = "로그인 시 자동 시작"
        }
    }

    private func syncPreferredContentSize() {
        let fit = view.fittingSize.height
        let height = fit > 100 ? fit : 540
        preferredContentSize = NSSize(width: Self.panelWidth, height: min(max(height, 400), 620))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncPreferredContentSize()
    }

    /// Called right before the popover shows: scan processes + sync size.
    func prepareForOpen() {
        refreshApps()
        refreshHistoryRows()
        refreshLoginUI()
        syncPreferredContentSize()
    }

    // MARK: - Actions

    private func postureSelected(_ newPosture: WatchdogPosture) {
        posture = newPosture
        settings.posture = newPosture
        Log.policy.notice("posture -> \(newPosture.rawValue, privacy: .public)")
        refreshPostureHint()
        onPostureChanged?()
    }

    @objc private func thresholdSliderChanged() {
        // Snap to 64 MiB steps so the value reads cleanly and persists stably.
        let snapped = (thresholdSlider.doubleValue / 64).rounded() * 64
        thresholdMiB = snapped
        settings.thresholdMiB = snapped
        Log.policy.notice("threshold -> \(Int(snapped)) MiB (effective next tick)")
        refreshThresholdUI()
        onThresholdChanged?()
    }

    @objc private func chipClicked(_ sender: NSButton) {
        guard let chip = thresholdChips.first(where: { $0.button === sender }) else { return }
        thresholdMiB = chip.value
        settings.thresholdMiB = chip.value
        Log.policy.notice("threshold -> \(Int(chip.value)) MiB (effective next tick)")
        refreshThresholdUI()
        onThresholdChanged?()
    }

    @objc private func floorChipClicked(_ sender: NSButton) {
        guard let chip = floorChips.first(where: { $0.button === sender }) else { return }
        settings.swapHeadroomFloorMiB = chip.value
        Log.policy.notice("swap floor -> \(Int(chip.value)) MiB (effective next tick)")
        refreshThresholdUI()
        onThresholdChanged?()
    }

    @objc private func openExclusionsFile() {
        NSWorkspace.shared.open(ExclusionsStore.defaultPath)
    }

    @objc private func openHistoryWindow() {
        showHistory?()
    }

    @objc private func openWelcomeWindow() {
        showWelcome?()
    }

    @objc private func loginSwitchChanged() {
        do {
            if loginSwitch.state == .on {
                try LoginItemManager.register()
            } else {
                try LoginItemManager.unregister()
            }
        } catch {
            Log.ui.error("login item toggle failed: \(String(describing: error), privacy: .public)")
        }
        refreshLoginUI()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
